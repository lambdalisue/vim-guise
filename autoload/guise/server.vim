vim9script

# Server side of guise for Vim.
#
# A child sends newline-delimited JSON requests in the shape of Vim's channel
# protocol, `[id, [method, ...args]]`, and receives `[id, reply]` once the
# request is done, `{"error": message, "result": value}` where the empty
# message means success and "result" is present only for a request that
# returns a value. A dictionary keeps it apart from the empty string that
# Vim's ch_evalexpr() returns when the connection is lost.

const ROOT = fnamemodify(expand('<script>:p'), ':h:h:h')
const EDITOR_SCRIPT = ROOT .. '/script/editor.vim'
const ASKPASS_SCRIPT = ROOT .. '/script/askpass.vim'
const ASKPASS_SHELL_SCRIPT = ROOT .. '/script/askpass.sh'

var server: channel
# A child proves with it that it was started from this instance.
var token: string
# Replies waiting for a buffer to be wiped, keyed by the buffer number.
var pending: dict<list<func(string, ...list<any>)>> = {}
# The server prompts for a secret only when it has exported askpass, which it
# never does on Windows, where the wrapper cannot run without /bin/sh.
var askpass_exported = false
# Prompts waiting for the one that is reading keys, which a prompt opened in
# the meantime would take over.
var prompts: list<list<any>> = []
var prompting = false

export def Start()
  # A socket in Vim's private temporary directory keeps other local users
  # from opening files in this instance, which a loopback TCP port cannot.
  const address = has('win32') ? '0' : 'unix:' .. tempname()
  server = ch_listen(address, {callback: OnAccept})
  if ch_status(server) !=# 'open'
    echohl WarningMsg
    echomsg '[guise] guise is disabled due to failure to start a channel server'
    echohl None
    return
  endif
  token = Token()
  $GUISE_ADDRESS = (has('win32') ? $'127.0.0.1:{ch_info(server).port}' : address) .. '#' .. token
  if !get(g:, 'guise#disable_editor', 0)
    $EDITOR = join([
      shellescape(exepath(v:progpath)),
      '-Nu NONE -i NONE -n -es -S',
      shellescape(EDITOR_SCRIPT),
      '--',
    ])
    $VISUAL = $EDITOR
  endif
  if !has('win32') && !get(g:, 'guise#disable_askpass', 0)
    ExportAskpass()
  endif

  augroup guise_server_internal
    autocmd!
    autocmd BufWipeout * Resolve(str2nr(expand('<abuf>')))
    autocmd VimLeave * ResolveAll()
  augroup END
enddef

# $SSH_ASKPASS and $SUDO_ASKPASS name a program that is run without arguments
# of our own, so a wrapper script carries the command line.
def ExportAskpass()
  const askpass = tempname()
  writefile([
    '#!/bin/sh',
    join([
      'exec /bin/sh',
      ShellQuote(ASKPASS_SHELL_SCRIPT),
      ShellQuote(exepath(v:progpath)),
      '-Nu NONE -i NONE -n -es -S',
      ShellQuote(ASKPASS_SCRIPT),
      '-- "$@"',
    ]),
  ], askpass)
  setfperm(askpass, 'rwx------')
  $SSH_ASKPASS = askpass
  $SUDO_ASKPASS = askpass
  # A job has no terminal for ssh to read a passphrase from, and ssh uses
  # $SSH_ASKPASS without $DISPLAY only when $SSH_ASKPASS_REQUIRE is "force".
  if empty($SSH_ASKPASS_REQUIRE)
    $SSH_ASKPASS_REQUIRE = 'force'
  endif
  askpass_exported = true
enddef

# A loopback TCP port is open to every local user, so a child must present a
# secret only the environment of this instance carries. Vim reads no random
# bytes but from a file, which Windows lacks. There each srand() draws a fresh
# 32-bit seed from ProcessPrng(), the CSPRNG of the OS, since Vim 9.1.0518;
# its help still names time(NULL), which is used only before Windows 10.
def Token(): string
  try
    return join(mapnew(blob2list(readblob('/dev/urandom', 0, 16)), (_, v) => printf('%02x', v)), '')
  catch
    return sha256(string(mapnew(range(8), (_, _) => srand())))
  endtry
enddef

# shellescape() follows 'shell', but the wrapper is always run by /bin/sh.
def ShellQuote(s: string): string
  return "'" .. substitute(s, "'", "'\\\\''", 'g') .. "'"
enddef

def OnAccept(ch: channel, _: string)
  # An accepted channel does not inherit "mode" from ch_listen(), and the
  # "json" mode would take the child's requests for responses to our own
  # requests. Read raw lines and decode them here instead.
  ch_setoptions(ch, {mode: 'nl', callback: function(OnMessage, [{authorized: false}])})
enddef

def OnMessage(state: dict<bool>, ch: channel, raw: string)
  var message: any
  try
    message = json_decode(raw)
  catch
    return
  endtry
  if type(message) != v:t_list || len(message) != 2 || type(message[1]) != v:t_list
    return
  endif
  const [id, expr] = message
  # Anything but the right token first is not from a child of this instance,
  # and it gets no reply that could tell it what is wrong.
  if !state.authorized
    if get(expr, 0, '') !=# 'auth' || type(get(expr, 1, v:null)) != v:t_string
        || sha256(expr[1]) !=# sha256(token)
      ch_close(ch)
      return
    endif
    state.authorized = true
  endif
  def Reply(err: string, ...result: list<any>)
    if ch_status(ch) ==# 'open'
      ch_sendraw(ch, json_encode([id, extend({error: err}, empty(result) ? {} : {result: result[0]})]) .. "\n")
    endif
  enddef
  try
    Dispatch(expr, Reply, () => ch_status(ch) ==# 'open')
  catch
    Reply(v:exception)
  endtry
enddef

def Dispatch(expr: list<any>, Reply: func(string, ...list<any>), Connected: func(): bool)
  const method = get(expr, 0, '')
  if method ==# 'open'
    tabnew
    WaitWipe(Reply)
  elseif method ==# 'edit'
    # fnameescape() leaves a newline as it is, which ends the command line
    # and runs the rest of the name as a command.
    if expr[1] =~# "\n"
      Reply('[guise] a file name that contains a newline cannot be opened')
      return
    endif
    const opener = get(g:, 'guise_edit_opener', 'tab drop')
    execute $'silent noswapfile {opener} {fnameescape(expr[1])}'
    WaitWipe(Reply)
  elseif method ==# 'ask'
    if !askpass_exported
      Reply('[guise] askpass is disabled')
      return
    endif
    const [prompt, hint] = expr[1 : 2]
    if hint ==# 'none'
      echomsg prompt
      Reply('', '')
    elseif hint ==# 'confirm'
      PromptInTurn(() => input($'{prompt} (yes/no) '), Reply, Connected)
    else
      PromptInTurn(() => inputsecret(prompt), Reply, Connected)
    endif
  elseif method ==# 'auth'
    Reply('')
  elseif method ==# 'error'
    echohl ErrorMsg
    echomsg join(expr[1 :], "\n")
    echohl None
    Reply('')
  else
    Reply($'Unknown method: {method}')
  endif
enddef

def PromptInTurn(Read: func(): string, Reply: func(string, ...list<any>), Connected: func(): bool)
  add(prompts, [Read, Reply, Connected])
  if prompting
    return
  endif
  prompting = true
  try
    while !empty(prompts)
      const [NextRead, NextReply, NextConnected] = remove(prompts, 0)
      # The program exited while its prompt was queued.
      if !NextConnected()
        continue
      endif
      # Keys typed for editing before the prompt opened are not the answer.
      inputsave()
      try
        NextReply('', NextRead())
      catch
        NextReply(v:exception)
      finally
        inputrestore()
      endtry
    endwhile
  finally
    prompting = false
  endtry
enddef

def WaitWipe(Reply: func(string, ...list<any>))
  const bufnr = bufnr('%')
  setbufvar(bufnr, '&bufhidden', 'wipe')
  if !has_key(pending, bufnr)
    pending[bufnr] = []
  endif
  add(pending[bufnr], Reply)
enddef

def Resolve(bufnr: number, err = '')
  if !has_key(pending, bufnr)
    return
  endif
  for Reply in remove(pending, bufnr)
    Reply(err)
  endfor
enddef

# The buffer was never closed, so the edit must not be taken as done.
def ResolveAll()
  for bufnr in keys(pending)
    Resolve(str2nr(bufnr), '[guise] the parent exited before the buffer was closed')
  endfor
enddef
