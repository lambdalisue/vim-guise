" Health check of guise, shared by ":checkhealth guise" on Neovim and
" ":GuiseCheck" on Vim.
"
" A shell started in a terminal reads its startup files after inheriting the
" environment guise exported, so the only reliable way to see what a program
" there gets is to ask an interactive shell itself.

let s:MARKER = '@@guise@@'
let s:VARIABLES = ['GUISE_ADDRESS', 'EDITOR', 'VISUAL']
let s:TIMEOUT = 5000
let s:ADVICE = 'Assign it only when $GUISE_ADDRESS is empty. See :help guise-shell'

" Return a list of sections, each of which is {'name': name, 'results':
" [{'level': 'ok' | 'info' | 'warn' | 'error', 'msg': msg, 'advice': advice}]}.
function! guise#health#check() abort
  let results = []
  let sections = [{'name': 'guise', 'results': results}]
  if empty($GUISE_ADDRESS)
    call add(results, s:result('error', 'The server is not running',
          \ 'guise does not start in a headless instance'))
    return sections
  endif
  call add(results, s:result('ok', printf('The server listens on %s', $GUISE_ADDRESS)))

  if has('win32')
    call add(results, s:result('info', 'The shell is not checked on Windows'))
    return sections
  endif

  let results = []
  call add(sections, {'name': printf('guise: interactive shell (%s)', &shell), 'results': results})
  try
    let env = s:inspect_shell(&shell)
  catch
    call add(results, s:result('warn', printf('Failed to inspect the shell: %s', v:exception)))
    return sections
  endtry

  if env.GUISE_ADDRESS !=# $GUISE_ADDRESS
    call add(results, s:result('error',
          \ printf('$GUISE_ADDRESS in the shell is "%s", so programs there cannot reach this instance', env.GUISE_ADDRESS),
          \ 'Do not overwrite or unset $GUISE_ADDRESS in the startup files of the shell'))
  else
    call add(results, s:result('ok', '$GUISE_ADDRESS reaches the shell'))
  endif
  if get(g:, 'guise#disable_editor', 0)
    call add(results, s:result('info', 'g:guise#disable_editor is set, so $EDITOR and $VISUAL are not checked'))
    return sections
  endif
  for name in ['EDITOR', 'VISUAL']
    if env[name] !=# getenv(name)
      call add(results, s:result('warn',
            \ printf('$%s in the shell is "%s", not the editor guise exported', name, env[name]),
            \ s:ADVICE))
    else
      call add(results, s:result('ok', printf('$%s reaches the shell', name)))
    endif
  endfor
  return sections
endfunction

function! guise#health#echo() abort
  let hlgroups = {'ok': 'None', 'info': 'None', 'warn': 'WarningMsg', 'error': 'ErrorMsg'}
  let labels = {'ok': 'OK', 'info': 'INFO', 'warn': 'WARNING', 'error': 'ERROR'}
  for section in guise#health#check()
    echohl Title
    echo section.name
    echohl None
    for result in section.results
      execute 'echohl' hlgroups[result.level]
      echo printf('- %s %s', labels[result.level], result.msg)
      echohl None
      if !empty(result.advice)
        echo '  ADVICE: ' .. result.advice
      endif
    endfor
  endfor
endfunction

function! s:result(level, msg, ...) abort
  return {'level': a:level, 'msg': a:msg, 'advice': a:0 ? a:1 : ''}
endfunction

" Return the variables an interactive shell ends up with. printenv keeps the
" command independent of the syntax of the shell, and its absolute path keeps
" it independent of the $PATH the startup files leave.
function! s:inspect_shell(shell) abort
  let printenv = exepath('printenv')
  if empty(printenv)
    throw 'printenv is not found'
  endif
  let script = ['echo ' .. s:MARKER]
  for name in s:VARIABLES
    call extend(script, [shellescape(printenv) .. ' ' .. name, 'echo ' .. s:MARKER])
  endfor
  let [code, stdout, stderr] = s:run(s:split_shell(a:shell) + ['-ic', join(script, '; ')])
  " The startup files may print anything before the first marker.
  let sections = []
  for line in stdout
    if line ==# s:MARKER
      call add(sections, [])
    elseif !empty(sections)
      call add(sections[-1], line)
    endif
  endfor
  if code != 0 || len(sections) < len(s:VARIABLES) + 1
    throw printf('exited with %d: %s', code, trim(join(stderr, "\n")))
  endif
  let env = {}
  for i in range(len(s:VARIABLES))
    let env[s:VARIABLES[i]] = join(sections[i], "\n")
  endfor
  return env
endfunction

" 'shell' may quote the program with double quotes to contain spaces.
function! s:split_shell(shell) abort
  let m = matchlist(a:shell, '^\s*"\([^"]*\)"\(.*\)$')
  return empty(m) ? split(a:shell) : [m[1]] + split(m[2])
endfunction

" Run {cmd} and return [exit code, stdout lines, stderr lines].
if has('nvim')
  function! s:run(cmd) abort
    let job = {'stdout': [], 'stderr': []}
    let id = jobstart(a:cmd, {
          \ 'stdout_buffered': v:true,
          \ 'stderr_buffered': v:true,
          \ 'on_stdout': { _, data, ... -> extend(job, {'stdout': data}) },
          \ 'on_stderr': { _, data, ... -> extend(job, {'stderr': data}) },
          \})
    if id <= 0
      throw printf('cannot start %s', string(a:cmd))
    endif
    let code = jobwait([id], s:TIMEOUT)[0]
    if code < 0
      call jobstop(id)
      throw code == -1 ? printf('did not finish in %d ms', s:TIMEOUT) : 'interrupted'
    endif
    return [code, job.stdout, job.stderr]
  endfunction
else
  function! s:run(cmd) abort
    let job = {'stdout': [], 'stderr': [], 'code': v:null, 'closed': v:false}
    " Output callbacks may still be called after exit_cb, so wait for
    " close_cb as well.
    let id = job_start(a:cmd, {
          \ 'out_cb': { _, msg -> add(job.stdout, msg) },
          \ 'err_cb': { _, msg -> add(job.stderr, msg) },
          \ 'exit_cb': { _, code -> extend(job, {'code': code}) },
          \ 'close_cb': { _ -> extend(job, {'closed': v:true}) },
          \})
    if job_status(id) ==# 'fail'
      throw printf('cannot start %s', string(a:cmd))
    endif
    let start = reltime()
    while job.code is# v:null || !job.closed
      if reltimefloat(reltime(start)) * 1000 > s:TIMEOUT
        call job_stop(id, 'kill')
        throw printf('did not finish in %d ms', s:TIMEOUT)
      endif
      sleep 10m
    endwhile
    return [job.code, job.stdout, job.stderr]
  endfunction
endif
