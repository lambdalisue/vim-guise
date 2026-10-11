-- Server side of guise for Neovim.
--
-- Speaks the same newline-delimited JSON protocol as the Vim server
-- (autoload/guise/server.vim) so that Vim and Neovim children can talk to
-- either parent: a request is `[id, [method, ...args]]` and the reply is
-- `[id, { error = message }]`, where the empty message means success.

local M = {}

local editor_script = vim.fs.joinpath(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))),
  "script",
  "editor.vim"
)

-- Replies waiting for a buffer to be wiped, keyed by the buffer number.
local pending = {}

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
  open = function(reply)
    vim.cmd("tabnew")
    wait_wipe(reply)
  end,
  edit = function(reply, filename)
    local opener = vim.g.guise_edit_opener or "tab drop"
    vim.cmd(("silent noswapfile %s %s"):format(opener, vim.fn.fnameescape(filename)))
    wait_wipe(reply)
  end,
  ping = function(reply)
    reply("")
  end,
  error = function(reply, exception, throwpoint)
    vim.notify(table.concat({ exception, throwpoint }, "\n"), vim.log.levels.ERROR)
    reply("")
  end,
}

local function dispatch(client, line)
  local ok, message = pcall(vim.json.decode, line)
  if not ok or type(message) ~= "table" or type(message[2]) ~= "table" then
    return
  end
  local id, expr = message[1], message[2]
  local function reply(err)
    if not client:is_closing() then
      client:write(vim.json.encode({ id, { error = err } }) .. "\n")
    end
  end
  local handler = handlers[expr[1]]
  if not handler then
    reply(("Unknown method: %s"):format(tostring(expr[1])))
    return
  end
  local succeeded, err = pcall(handler, reply, unpack(expr, 2))
  if not succeeded then
    reply(tostring(err))
  end
end

local function accept(server, new_handle)
  local client = new_handle()
  server:accept(client)
  local buffer = ""
  client:read_start(function(err, chunk)
    if err or not chunk then
      client:close()
      return
    end
    buffer = buffer .. chunk
    for line in buffer:gmatch("([^\n]*)\n") do
      vim.schedule(function()
        dispatch(client, line)
      end)
    end
    buffer = buffer:match("[^\n]*$")
  end)
end

local is_windows = vim.fn.has("win32") == 1

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
  if is_windows then
    local addr = server:getsockname()
    vim.env.GUISE_ADDRESS = ("%s:%d"):format(addr.ip, addr.port)
  else
    vim.env.GUISE_ADDRESS = "unix:" .. server:getsockname()
  end
  local disable_editor = vim.g["guise#disable_editor"]
  if not disable_editor or disable_editor == 0 then
    vim.env.EDITOR = table.concat({
      vim.fn.shellescape(vim.v.progpath),
      "--headless --clean -n -S",
      vim.fn.shellescape(editor_script),
      "--",
    }, " ")
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
