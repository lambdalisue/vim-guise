function! guise#open(address, argv) abort
  let chan = s:connect(a:address)
  if chan is# v:null
    return
  endif
  try
    if empty(a:argv)
      call s:request(chan, 'open', [])
    else
      for filename in a:argv
        call s:request(chan, 'edit', [fnamemodify(filename, ':p')])
      endfor
    endif
    call s:close(chan)
    qall!
  catch
    call s:request(chan, 'error', [v:exception, v:throwpoint])
    call s:close(chan)
    cquit!
  endtry
endfunction

if has('nvim')
  function! s:connect(address) abort
    if g:guise#disable_neovim
      return v:null
    endif
    let chan = sockconnect('tcp', a:address, {
          \ 'rpc': v:true,
          \})
    if chan is# 0
      echohl WarningMsg
      echomsg printf('[guise] guise is disabled due to connection failure to "%s"')
      echohl None
      return v:null
    endif
    return chan
  endfunction

  function! s:close(chan) abort
    call chanclose(a:chan)
  endfunction

  function! s:request(chan, fn, args) abort
    let err = call('rpcrequest', [a:chan, a:fn] + a:args)
    if !empty(err)
      throw err
    endif
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
      echomsg printf('[guise] guise is disabled due to connection failure to "%s"')
      echohl None
      return v:null
    endif
    return chan
  endfunction

  function! s:close(chan) abort
    call ch_close(a:chan)
  endfunction

  function! s:request(chan, fn, args) abort
    let err = call('ch_evalexpr', [a:chan, [a:fn] + a:args])
    if !empty(err)
      throw err
    endif
  endfunction
endif

let g:guise#disable_vim = get(g:, 'guise#disable_vim', 0)
let g:guise#disable_neovim = get(g:, 'guise#disable_neovim', 0)
let g:guise#disable_editor = get(g:, 'guise#disable_editor', 0)
