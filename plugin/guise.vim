if exists('g:loaded_guise')
  finish
endif
let g:loaded_guise = 1

function! s:is_headless() abort
  if !exists('v:argv')
    return v:false
  endif
  let flags = ''
  for arg in v:argv[1:]
    if arg ==# '--'
      break
    elseif arg ==# '--headless'
      return v:true
    elseif arg =~# '^-\a\+$'
      let flags .= arg[1:]
    endif
  endfor
  " Silent Ex mode is -e or -E with -s, whether given apart (-e -s) or
  " combined into one argument (-es, -eNs).
  return flags =~# '[eE]' && flags =~# 's'
endfunction

let s:address = $GUISE_ADDRESS
if empty(s:address)
  " Nobody can see a tab page opened in a headless instance, so a child
  " forwarded to it would wait forever.
  if s:is_headless() && !get(g:, 'guise#enable_headless', 0)
    finish
  endif
  if has('nvim')
    lua require('guise.server').start()
  elseif exists('*ch_listen')
    " Neovim reports the same through ":checkhealth guise".
    command! GuiseCheck call guise#health#echo()
    call guise#server#Start()
  else
    echohl WarningMsg
    echomsg '[guise] guise requires Vim 9.2.0153 or above (ch_listen()); it is disabled'
    echohl None
  endif
  finish
endif

if s:is_headless()
  finish
endif

augroup guise_plugin_internal
  autocmd!
  autocmd SwapExists * let v:swapchoice = 'o'
  autocmd VimEnter * noautocmd call guise#open(s:address, argv())
augroup END
