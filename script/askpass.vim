" Entry point of the headless askpass program that guise exports as
" $SSH_ASKPASS and $SUDO_ASKPASS.
"
" It asks the parent through $GUISE_ADDRESS to prompt for the first argument,
" prints the answer to stdout, and exits.

let &runtimepath = escape(fnamemodify(expand('<sfile>:p'), ':h:h'), '\,') .. ',' .. &runtimepath
try
  call guise#askpass($GUISE_ADDRESS, get(argv(), 0, ''), $SSH_ASKPASS_PROMPT)
catch
endtry

" guise#askpass() quits by itself on success. Reaching here means it failed,
" and the script must not fall through to Ex mode, which would wait on stdin.
cquit!
