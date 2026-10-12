vim9script

# Server side of guise for Vim.
#
# A child sends newline-delimited JSON requests in the shape of Vim's channel
# protocol, `[id, [method, ...args]]`, and receives `[id, reply]` once the
# request is done, `{"error": message}` where the empty message means
# success. A dictionary keeps it apart from the empty string that Vim's
# ch_evalexpr() returns when the connection is lost.

const EDITOR_SCRIPT = fnamemodify(expand('<script>:p'), ':h:h:h') .. '/script/editor.vim'

var server: channel
# Replies waiting for a buffer to be wiped, keyed by the buffer number.
var pending: dict<list<func(string)>> = {}

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
  $GUISE_ADDRESS = has('win32') ? $'127.0.0.1:{ch_info(server).port}' : address
  if !get(g:, 'guise#disable_editor', 0)
    $EDITOR = join([
      shellescape(exepath(v:progpath)),
      '-Nu NONE -i NONE -n -es -S',
      shellescape(EDITOR_SCRIPT),
      '--',
    ])
    $VISUAL = $EDITOR
  endif

  augroup guise_server_internal
    autocmd!
    autocmd BufWipeout * Resolve(str2nr(expand('<abuf>')))
    autocmd VimLeave * ResolveAll()
  augroup END
enddef

def OnAccept(ch: channel, _: string)
  # An accepted channel does not inherit "mode" from ch_listen(), and the
  # "json" mode would take the child's requests for responses to our own
  # requests. Read raw lines and decode them here instead.
  ch_setoptions(ch, {mode: 'nl', callback: OnMessage})
enddef

def OnMessage(ch: channel, raw: string)
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
  const Reply = (err: string) => {
    if ch_status(ch) ==# 'open'
      ch_sendraw(ch, json_encode([id, {error: err}]) .. "\n")
    endif
  }
  try
    Dispatch(expr, Reply)
  catch
    Reply(v:exception)
  endtry
enddef

def Dispatch(expr: list<any>, Reply: func(string))
  const method = get(expr, 0, '')
  if method ==# 'open'
    tabnew
    WaitWipe(Reply)
  elseif method ==# 'edit'
    const opener = get(g:, 'guise_edit_opener', 'tab drop')
    execute $'silent noswapfile {opener} {fnameescape(expr[1])}'
    WaitWipe(Reply)
  elseif method ==# 'ping'
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

def WaitWipe(Reply: func(string))
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
