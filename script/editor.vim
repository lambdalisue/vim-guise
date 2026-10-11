" Entry point of the headless editor that guise exports as $EDITOR.
"
" It forwards argv() to the parent through $GUISE_ADDRESS and exits once the
" parent has finished editing them.

let &runtimepath = escape(fnamemodify(expand('<sfile>:p'), ':h:h'), '\,') .. ',' .. &runtimepath
try
  call guise#open($GUISE_ADDRESS, argv())
catch
endtry

" guise#open() quits by itself on success. Reaching here means it failed, and
" the script must not fall through to Ex mode, which would wait on stdin.
cquit!
