if exists('g:loaded_guise')
  finish
endif
let g:loaded_guise = 1

let s:address = has('nvim') ? $GUISE_NVIM_ADDRESS : $GUISE_VIM_ADDRESS
if empty(s:address)
  finish
endif

" Skip guise if Neovim is running in headless mode
if has('nvim') && exists('v:argv')
  for arg in v:argv
    if arg ==# '--headless'
      finish
    endif
  endfor
endif

augroup guise_plugin_internal
  autocmd!
  autocmd SwapExists * let v:swapchoice = 'o'
  autocmd VimEnter * noautocmd call guise#open(s:address, argv())
augroup END
