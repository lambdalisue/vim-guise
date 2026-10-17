function! guise#open(address, argv) abort
  call s:run(a:address, function('s:edit', [a:argv]), s:PING_TIMEOUT)
endfunction

" Print the answer the parent prompts for {prompt} to stdout, as an askpass
" program does. {hint} is the value of $SSH_ASKPASS_PROMPT: "confirm" asks
" for approval, which only "yes" gives, and "none" only shows {prompt}.
"
" It quits with s:UNREACHABLE when the parent does not answer, which a parent
" waiting for a command it started synchronously (system(), :!) cannot, so
" that script/askpass.sh asks on the terminal of the parent instead. A short
" wait keeps that from stalling the command.
function! guise#askpass(address, prompt, hint) abort
  call s:run(a:address, function('s:ask', [a:prompt, a:hint]), s:ASKPASS_PING_TIMEOUT)
  execute 'cquit!' s:UNREACHABLE
endfunction

function! s:edit(argv, chan) abort
  if empty(a:argv)
    call s:request(a:chan, 'open', [])
  else
    for filename in a:argv
      call s:request(a:chan, 'edit', [fnamemodify(filename, ':p')])
    endfor
  endif
endfunction

function! s:ask(prompt, hint, chan) abort
  let answer = s:request(a:chan, 'ask', [a:prompt, a:hint])
  if a:hint ==# 'none'
    return
  elseif a:hint ==# 'confirm' && answer !~? '^\s*yes\s*$'
    " ssh-agent takes an empty answer as approval, so refuse by the exit
    " status instead.
    return v:false
  endif
  call writefile([answer], '/dev/stdout')
endfunction

" Call {Do} with a channel to the parent at {address} and quit, or return when
" the parent cannot be reached. {Do} returns v:false to quit with failure
" without reporting an error to the parent.
function! s:run(address, Do, ping_timeout) abort
  let chan = s:connect(a:address)
  if chan is# v:null
    return
  endif
  " Vim does not set close-on-exec on a ch_listen() socket, so a process the
  " parent started keeps the socket listening after the parent dies. The
  " connection then succeeds with nobody behind it, and only a reply proves the
  " parent is alive. Waiting for an edit has no time limit, so check it first.
  try
    call s:request(chan, 'ping', [], a:ping_timeout)
  catch
    echohl ErrorMsg
    echomsg printf('[guise] the parent at "%s" does not respond', a:address)
    echohl None
    execute 'cquit!' s:UNREACHABLE
  endtry
  try
    let succeeded = a:Do(chan) isnot# v:false
    call s:close(chan)
    execute succeeded ? 'qall!' : 'cquit!'
  catch
    let [exception, throwpoint] = [v:exception, v:throwpoint]
    try
      call s:request(chan, 'error', [exception, throwpoint])
      call s:close(chan)
    catch
      " The parent may be gone already; quit with failure either way.
    endtry
    cquit!
  endtry
endfunction

let s:PING_TIMEOUT = 5000
let s:ASKPASS_PING_TIMEOUT = 1000
let s:UNREACHABLE = 2

" A reply is {'error': message, 'result': value}, where the empty message
" means success and "result" is present only for a request that returns a
" value. Any other reply means the connection was lost before the request was
" done; Vim's ch_evalexpr() returns an empty string then, which must not read
" as success.
function! s:check(reply) abort
  if type(a:reply) != v:t_dict
    throw '[guise] connection is closed before the request is done'
  endif
  if !empty(a:reply.error)
    throw a:reply.error
  endif
  return get(a:reply, 'result', v:null)
endfunction

if has('nvim')
  function! s:connect(address) abort
    if g:guise#disable_neovim
      return v:null
    endif
    " The parent speaks Vim's JSON channel protocol, not msgpack-rpc, so that
    " a single server serves both Vim and Neovim children.
    let chan = {'id': 0, 'partial': '', 'replies': {}, 'next': 0, 'closed': v:false}
    try
      let [mode, address] = a:address =~# '^unix:'
            \ ? ['pipe', matchstr(a:address, '^unix:\zs.*')]
            \ : ['tcp', a:address]
      let chan.id = sockconnect(mode, address, {
            \ 'on_data': function('s:on_data', [chan]),
            \})
    catch
    endtry
    if chan.id is# 0
      echohl WarningMsg
      echomsg printf('[guise] guise is disabled due to connection failure to "%s"', a:address)
      echohl None
      return v:null
    endif
    return chan
  endfunction

  function! s:on_data(chan, id, data, event) abort
    if a:data ==# ['']
      let a:chan.closed = v:true
      return
    endif
    let a:chan.partial .= a:data[0]
    for line in a:data[1:]
      let [id, reply] = json_decode(a:chan.partial)
      let a:chan.replies[id] = reply
      let a:chan.partial = line
    endfor
  endfunction

  function! s:close(chan) abort
    call chanclose(a:chan.id)
  endfunction

  function! s:request(chan, fn, args, ...) abort
    let a:chan.next += 1
    let id = a:chan.next
    call chansend(a:chan.id, json_encode([id, [a:fn] + a:args]) .. "\n")
    call wait(a:0 ? a:1 : -1, { -> has_key(a:chan.replies, id) || a:chan.closed })
    return s:check(get(a:chan.replies, id, v:null))
  endfunction
else
  function! s:connect(address) abort
    if g:guise#disable_vim
      return v:null
    endif
    let chan = ch_open(a:address, {
          \ 'mode': 'json',
          \ 'drop': 'auto',
          \ 'noblock': 1,
          \ 'timeout': 60 * 60 * 24 * 7 * 1000,
          \})
    if ch_status(chan) !=# 'open'
      echohl WarningMsg
      echomsg printf('[guise] guise is disabled due to connection failure to "%s"', a:address)
      echohl None
      return v:null
    endif
    return chan
  endfunction

  function! s:close(chan) abort
    call ch_close(a:chan)
  endfunction

  function! s:request(chan, fn, args, ...) abort
    let options = a:0 ? {'timeout': a:1} : {}
    return s:check(ch_evalexpr(a:chan, [a:fn] + a:args, options))
  endfunction
endif

let g:guise#disable_vim = get(g:, 'guise#disable_vim', 0)
let g:guise#disable_neovim = get(g:, 'guise#disable_neovim', 0)
let g:guise#disable_editor = get(g:, 'guise#disable_editor', 0)
