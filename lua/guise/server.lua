-- Server side of guise for Neovim.
--
-- Speaks the same newline-delimited JSON protocol as the Vim server
-- (autoload/guise/server.vim) so that Vim and Neovim children can talk to
-- either parent: a request is `[id, [method, ...args]]` and the reply is
-- `[id, { error = message, result = value }]`, where the empty message means
-- success and `result` is present only for a request that returns a value.

local M = {}

local root =
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local editor_script = vim.fs.joinpath(root, "script", "editor.vim")
local askpass_script = vim.fs.joinpath(root, "script", "askpass.vim")
local askpass_shell_script = vim.fs.joinpath(root, "script", "askpass.sh")

-- A child proves with it that it was started from this instance.
local token
-- Replies waiting for a buffer to be wiped, keyed by the buffer number.
local pending = {}
-- The server prompts for a secret only when it has exported askpass, which it
-- never does on Windows, where the wrapper cannot run without /bin/sh.
local askpass_exported = false
-- Prompts waiting for the one that is reading keys, which a prompt opened in
-- the meantime would take over.
local prompts = {}
local prompting = false

local function prompt_in_turn(read, reply, connected)
  table.insert(prompts, { read = read, reply = reply, connected = connected })
  if prompting then
    return
  end
  prompting = true
  while #prompts > 0 do
    local next_prompt = table.remove(prompts, 1)
    -- The program exited while its prompt was queued.
    if next_prompt.connected() then
      -- Keys typed for editing before the prompt opened are not the answer.
      vim.fn.inputsave()
      local ok, result = pcall(next_prompt.read)
      vim.fn.inputrestore()
      if ok then
        next_prompt.reply("", result)
      else
        next_prompt.reply(tostring(result))
      end
    end
  end
  prompting = false
end

local function resolve(bufnr, err)
  local replies = pending[bufnr]
  pending[bufnr] = nil
  for _, reply in ipairs(replies or {}) do
    reply(err or "")
  end
end

local function wait_wipe(reply)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "wipe"
  pending[bufnr] = pending[bufnr] or {}
  table.insert(pending[bufnr], reply)
end

local handlers = {
  open = function(reply, _)
    vim.cmd("tabnew")
    wait_wipe(reply)
  end,
  edit = function(reply, _, filename, line)
    -- fnameescape() leaves a newline as it is, and vim.cmd() runs each line as
    -- a command of its own.
    if filename:find("\n", 1, true) then
      reply("[guise] a file name that contains a newline cannot be opened")
      return
    end
    if line ~= nil and line ~= "$" and (type(line) ~= "number" or line % 1 ~= 0) then
      reply('[guise] a line must be a number or "$"')
      return
    end
    local opener = vim.g.guise_edit_opener or "tab drop"
    vim.cmd(("silent noswapfile %s %s"):format(opener, vim.fn.fnameescape(filename)))
    if line ~= nil then
      local last = vim.api.nvim_buf_line_count(0)
      local lnum = line == "$" and last or math.min(math.max(line, 1), last)
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    end
    wait_wipe(reply)
  end,
  ask = function(reply, connected, prompt, hint)
    if not askpass_exported then
      reply("[guise] askpass is disabled")
    elseif hint == "none" then
      vim.notify(prompt)
      reply("", "")
    elseif hint == "confirm" then
      prompt_in_turn(function()
        return vim.fn.input(("%s (yes/no) "):format(prompt))
      end, reply, connected)
    else
      prompt_in_turn(function()
        return vim.fn.inputsecret(prompt)
      end, reply, connected)
    end
  end,
  auth = function(reply, _)
    reply("")
  end,
  error = function(reply, _, exception, throwpoint)
    vim.notify(table.concat({ exception, throwpoint }, "\n"), vim.log.levels.ERROR)
    reply("")
  end,
}

local function dispatch(client, state, line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" or type(message[2]) ~= "table" then
    return
  end
  local id, expr = message[1], message[2]
  -- Anything but the right token first is not from a child of this instance,
  -- and it gets no reply that could tell it what is wrong.
  if not state.authorized then
    if expr[1] ~= "auth" or type(expr[2]) ~= "string" or vim.fn.sha256(expr[2]) ~= vim.fn.sha256(token) then
      if not client:is_closing() then
        client:close()
      end
      return
    end
    state.authorized = true
  end
  local function reply(err, result)
    if not client:is_closing() then
      client:write(vim.json.encode({ id, { error = err, result = result } }) .. "\n")
    end
  end
  local handler = handlers[expr[1]]
  if not handler then
    reply(("Unknown method: %s"):format(tostring(expr[1])))
    return
  end
  local function connected()
    return not client:is_closing()
  end
  local succeeded, err = pcall(handler, reply, connected, unpack(expr, 2))
  if not succeeded then
    reply(tostring(err))
  end
end

local function accept(server, new_handle)
  local client = new_handle()
  server:accept(client)
  local buffer = ""
  local state = { authorized = false }
  client:read_start(function(err, chunk)
    if err or not chunk then
      client:close()
      return
    end
    buffer = buffer .. chunk
    for line in buffer:gmatch("([^\n]*)\n") do
      vim.schedule(function()
        dispatch(client, state, line)
      end)
    end
    buffer = buffer:match("[^\n]*$")
  end)
end

local is_windows = vim.fn.has("win32") == 1

-- Some programs split $EDITOR on whitespace and run it without a shell, where
-- quotes would stay in the program name.
local function shell_word(s)
  return s:match("^[%w_@%%+=:,./-]+$") and s or vim.fn.shellescape(s)
end

-- shellescape() follows 'shell', but the wrapper is always run by /bin/sh.
local function shell_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- $SSH_ASKPASS and $SUDO_ASKPASS name a program that is run without arguments
-- of our own, so a wrapper script carries the command line.
local function export_askpass()
  local askpass = vim.fn.tempname()
  vim.fn.writefile({
    "#!/bin/sh",
    table.concat({
      "exec /bin/sh",
      shell_quote(askpass_shell_script),
      shell_quote(vim.v.progpath),
      "--headless --clean -n -S",
      shell_quote(askpass_script),
      '-- "$@"',
    }, " "),
  }, askpass)
  vim.fn.setfperm(askpass, "rwx------")
  vim.env.SSH_ASKPASS = askpass
  vim.env.SUDO_ASKPASS = askpass
  -- A job has no terminal for ssh to read a passphrase from, and ssh uses
  -- $SSH_ASKPASS without $DISPLAY only when $SSH_ASKPASS_REQUIRE is "force".
  if (vim.env.SSH_ASKPASS_REQUIRE or "") == "" then
    vim.env.SSH_ASKPASS_REQUIRE = "force"
  end
  askpass_exported = true
end

function M.start()
  -- A socket in Neovim's private temporary directory keeps other local users
  -- from opening files in this instance, which a loopback TCP port cannot.
  local new_handle = is_windows and vim.uv.new_tcp or function()
    return vim.uv.new_pipe(false)
  end
  local server = new_handle()
  local ok, err = pcall(function()
    if is_windows then
      assert(server:bind("127.0.0.1", 0))
    else
      assert(server:bind(vim.fn.tempname()))
    end
    assert(server:listen(128, function(listen_err)
      if not listen_err then
        accept(server, new_handle)
      end
    end))
  end)
  if not ok then
    server:close()
    vim.notify(
      ("[guise] guise is disabled due to failure to start a server: %s"):format(err),
      vim.log.levels.WARN
    )
    return
  end
  -- A loopback TCP port is open to every local user, so a child must present
  -- a secret only the environment of this instance carries.
  token = vim.text.hexencode(assert(vim.uv.random(16)))
  local address
  if is_windows then
    local addr = server:getsockname()
    address = ("%s:%d"):format(addr.ip, addr.port)
  else
    address = "unix:" .. server:getsockname()
  end
  vim.env.GUISE_ADDRESS = address .. "#" .. token
  local disable_editor = vim.g["guise#disable_editor"]
  if not disable_editor or disable_editor == 0 then
    vim.env.EDITOR = table.concat({
      shell_word(vim.v.progpath),
      "--headless --clean -n -S",
      shell_word(editor_script),
      "--",
    }, " ")
    vim.env.VISUAL = vim.env.EDITOR
  end
  local disable_askpass = vim.g["guise#disable_askpass"]
  if not is_windows and (not disable_askpass or disable_askpass == 0) then
    export_askpass()
  end

  local group = vim.api.nvim_create_augroup("guise_server_internal", {})
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      resolve(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeave", {
    group = group,
    callback = function()
      -- The buffer was never closed, so the edit must not be taken as done.
      for bufnr in pairs(pending) do
        resolve(bufnr, "[guise] the parent exited before the buffer was closed")
      end
    end,
  })
end

return M
