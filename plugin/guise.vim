if exists('g:loaded_guise')
  finish
endif
let g:loaded_guise = 1

let s:address = has('nvim') ? $GUISE_NVIM_ADDRESS : $GUISE_VIM_ADDRESS
if empty(s:address)
  finish
endif

augroup guise_plugin_internal
  autocmd!
  autocmd VimEnter * noautocmd call guise#do(s:address, argv())
augroup END
