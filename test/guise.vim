" Integration tests for guise.
"
" Run headless from the repository root:
"   vim -Nu NONE -i NONE -n -es -S test/guise.vim
"   nvim --headless --clean -S test/guise.vim
"
" The running instance acts as the parent editor. Each test spawns $EDITOR as
" a child process, the same way a program in a terminal would.

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:tmpdir = tempname()
call mkdir(s:tmpdir, 'p')

" Run as a parent even when the tests are started from a guise terminal.
let $GUISE_ADDRESS = ''
let g:guise#enable_headless = 1

" A relative entry makes sure that no path in $EDITOR depends on the cwd.
let s:relroot = fnamemodify(s:root, ':.')
execute 'set runtimepath^=' .. fnameescape(empty(s:relroot) ? '.' : s:relroot)
runtime plugin/guise.vim

function! s:wait(timeout, Cond) abort
  if has('nvim')
    return wait(a:timeout, a:Cond, 10) == 0
  endif
  let start = reltime()
  while reltimefloat(reltime(start)) * 1000 < a:timeout
    if a:Cond()
      return v:true
    endif
    sleep 10m
  endwhile
  return a:Cond()
endfunction

function! s:spawn(args, ...) abort
  let editor = a:0 ? a:1 : $EDITOR
  let cmd = join([editor] + map(copy(a:args), { _, v -> shellescape(v) }))
  let job = {'exitval': v:null}
  if has('nvim')
    let job.id = jobstart(['sh', '-c', cmd], {
          \ 'on_exit': { _, code, ... -> extend(job, {'exitval': code}) },
          \})
  else
    let job.id = job_start(['sh', '-c', cmd], {
          \ 'exit_cb': { _, code -> extend(job, {'exitval': code}) },
          \})
  endif
  return job
endfunction

function! s:same_file(a, b) abort
  return !empty(a:a) && resolve(fnamemodify(a:a, ':p')) ==# resolve(fnamemodify(a:b, ':p'))
endfunction

function! s:find_tab(Pred) abort
  for tabnr in range(1, tabpagenr('$'))
    for bufnr in tabpagebuflist(tabnr)
      if a:Pred(bufnr)
        return bufnr
      endif
    endfor
  endfor
  return 0
endfunction

function! s:test_address_is_a_socket_in_a_private_directory() abort
  call assert_match('^unix:/', $GUISE_ADDRESS)
  let path = matchstr($GUISE_ADDRESS, '^unix:\zs.*')
  call assert_equal('socket', getftype(path))
  call assert_equal('rwx------', getfperm(fnamemodify(path, ':h')))
endfunction

" Load guise in a fresh instance started by {cmd}, after running {setup}, and
" return the value of {expr} there.
function! s:probe(cmd, setup, expr) abort
  let out = s:tmpdir .. '/probe.out'
  call delete(out)
  let scriptfile = s:tmpdir .. '/probe.vim'
  call writefile(a:setup + [
        \ 'set runtimepath^=' .. fnameescape(s:root),
        \ 'runtime plugin/guise.vim',
        \ 'call writefile([' .. a:expr .. '], ' .. string(out) .. ')',
        \ 'qall!',
        \], scriptfile)
  let job = s:spawn([], 'GUISE_ADDRESS= EDITOR=original VISUAL=original ' .. a:cmd .. ' -S ' .. shellescape(scriptfile))
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'probed instance does not exit')
  return filereadable(out) ? readfile(out)[0] : '<no output>'
endfunction

function! s:test_headless_vim_does_not_start_server() abort
  call assert_equal('', s:probe('vim -Nu NONE -i NONE -n -es', [], '$GUISE_ADDRESS'))
  call assert_equal('', s:probe('vim -Nu NONE -i NONE -n -E -s', [], '$GUISE_ADDRESS'))
  call assert_equal('', s:probe('vim -u NONE -i NONE -n -eNs', [], '$GUISE_ADDRESS'))
  call assert_equal('', s:probe('vim -u NONE -i NONE -eN -sn', [], '$GUISE_ADDRESS'))
endfunction

function! s:test_headless_nvim_does_not_start_server() abort
  call assert_equal('', s:probe('nvim --headless --clean -n', [], '$GUISE_ADDRESS'))
  call assert_equal('', s:probe('nvim --clean -n "+let g:x = 1" --headless', [], '$GUISE_ADDRESS'))
endfunction

" Start a separate parent of the same kind as this instance, after running
" {setup} in it, and return [job, $GUISE_ADDRESS, $EDITOR] of it.
function! s:start_parent(setup) abort
  let info = s:tmpdir .. '/parent.info'
  call delete(info)
  let scriptfile = s:tmpdir .. '/parent.vim'
  call writefile([
        \ 'let g:guise#enable_headless = 1',
        \ 'set runtimepath^=' .. fnameescape(s:root),
        \ 'runtime plugin/guise.vim',
        \] + a:setup + [
        \ 'call writefile([$GUISE_ADDRESS, $EDITOR], ' .. string(info) .. ')',
        \ 'while 1 | sleep 100m | endwhile',
        \], scriptfile)
  let parent_cmd = has('nvim') ? 'nvim --headless --clean -n' : 'vim -Nu NONE -i NONE -n -es'
  let parent = s:spawn([], 'GUISE_ADDRESS= exec ' .. parent_cmd .. ' -S ' .. shellescape(scriptfile))
  call assert_true(s:wait(5000, { -> len(filereadable(info) ? readfile(info) : []) == 2 }), 'parent does not start')
  return [parent] + readfile(info)
endfunction

function! s:kill(job) abort
  if has('nvim')
    call jobstop(a:job.id)
  else
    call job_stop(a:job.id, 'kill')
  endif
endfunction

function! s:test_edit_fails_when_parent_dies() abort
  let [parent, address, editor] = s:start_parent([])
  let child = s:spawn([s:tmpdir .. '/orphan.txt'], 'GUISE_ADDRESS=' .. shellescape(address) .. ' ' .. editor)
  call assert_false(s:wait(500, { -> child.exitval isnot# v:null }), 'editor exited before the parent died')
  call s:kill(parent)
  call assert_true(s:wait(5000, { -> child.exitval isnot# v:null }), 'editor does not exit')
  call assert_notequal(0, child.exitval)
endfunction

" Vim does not set close-on-exec on a ch_listen() socket, so a process the
" parent started keeps the socket listening after the parent dies. A child
" then connects fine but nobody ever accepts the connection.
function! s:test_edit_fails_when_parent_died_leaving_descendants() abort
  let pidfile = s:tmpdir .. '/descendant.pid'
  let [parent, address, editor] = s:start_parent([
        \ has('nvim')
        \   ? 'call writefile([jobpid(jobstart(["sleep", "30"], {"detach": 1}))], ' .. string(pidfile) .. ')'
        \   : 'call writefile([job_info(job_start(["sleep", "30"], {"stoponexit": ""})).process], ' .. string(pidfile) .. ')',
        \])
  call s:kill(parent)
  call assert_true(s:wait(5000, { -> parent.exitval isnot# v:null }), 'parent does not die')
  try
    let child = s:spawn([s:tmpdir .. '/orphan.txt'], 'GUISE_ADDRESS=' .. shellescape(address) .. ' ' .. editor)
    call assert_true(s:wait(10000, { -> child.exitval isnot# v:null }), 'editor does not exit')
    call assert_notequal(0, child.exitval)
  finally
    call system('kill ' .. readfile(pidfile)[0])
  endtry
endfunction

function! s:test_disable_editor_accepts_boolean() abort
  let setup = ['let g:guise#enable_headless = 1', 'let g:guise#disable_editor = v:true']
  call assert_equal('original', s:probe('vim -Nu NONE -i NONE -n -es', setup, '$EDITOR'))
  call assert_equal('original', s:probe('nvim --headless --clean -n', setup, '$EDITOR'))
  call assert_equal('original', s:probe('vim -Nu NONE -i NONE -n -es', setup, '$VISUAL'))
  call assert_equal('original', s:probe('nvim --headless --clean -n', setup, '$VISUAL'))
endfunction

function! s:test_editor_is_exported() abort
  call assert_match('guise', $EDITOR)
endfunction

" Many programs prefer $VISUAL to $EDITOR, so a $VISUAL inherited from the
" shell that started this instance would hide $EDITOR.
function! s:test_visual_is_exported_as_editor() abort
  call assert_equal($EDITOR, $VISUAL)
endfunction

" Programs in a terminal may run with another $PATH or working directory
" (direnv, nix shell, cd), so $EDITOR must not depend on either.
function! s:test_editor_uses_absolute_paths() abort
  call assert_match('^''/[^'']\+'' ', $EDITOR)
  call assert_match(' -S ''/[^'']\+/script/editor\.vim'' --$', $EDITOR)
endfunction

function! s:test_edit_waits_until_buffer_is_wiped() abort
  let filename = s:tmpdir .. '/COMMIT_EDITMSG'
  call writefile(['hello'], filename)
  let job = s:spawn([filename])
  let Found = { -> s:find_tab({ b -> s:same_file(bufname(b), filename) }) }
  call assert_true(s:wait(5000, { -> Found() != 0 }), 'buffer is not opened')
  let bufnr = Found()
  call assert_equal(['hello'], getbufline(bufnr, 1, '$'))
  call assert_false(s:wait(200, { -> job.exitval isnot# v:null }), 'editor exited before the buffer was wiped')
  execute 'bwipeout!' bufnr
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'editor does not exit')
  call assert_equal(0, job.exitval)
endfunction

function! s:test_edit_opens_each_file_in_order() abort
  let files = [s:tmpdir .. '/a.txt', s:tmpdir .. '/b.txt']
  let job = s:spawn(files)
  for filename in files
    let Found = { -> s:find_tab({ b -> s:same_file(bufname(b), filename) }) }
    call assert_true(s:wait(5000, { -> Found() != 0 }), filename .. ' is not opened')
    execute 'bwipeout!' Found()
  endfor
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'editor does not exit')
  call assert_equal(0, job.exitval)
endfunction

function! s:test_edit_from_the_other_editor() abort
  let other = has('nvim')
        \ ? 'vim -Nu NONE -i NONE -n -es -S'
        \ : 'nvim --headless --clean -n -S'
  if !executable(split(other)[0])
    throw 'Skipped: ' .. split(other)[0] .. ' is not executable'
  endif
  let filename = s:tmpdir .. '/other.txt'
  let job = s:spawn([filename], join([other, shellescape(s:root .. '/script/editor.vim'), '--']))
  let Found = { -> s:find_tab({ b -> s:same_file(bufname(b), filename) }) }
  call assert_true(s:wait(5000, { -> Found() != 0 }), 'buffer is not opened')
  call assert_false(s:wait(200, { -> job.exitval isnot# v:null }), 'editor exited before the buffer was wiped')
  execute 'bwipeout!' Found()
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'editor does not exit')
  call assert_equal(0, job.exitval)
endfunction

function! s:test_open_without_arguments_opens_scratch_buffer() abort
  let tabcount = tabpagenr('$')
  let job = s:spawn([])
  call assert_true(s:wait(5000, { -> tabpagenr('$') > tabcount }), 'tab is not opened')
  let bufnr = bufnr('%')
  call assert_equal('', bufname(bufnr))
  execute 'bwipeout!' bufnr
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'editor does not exit')
  call assert_equal(0, job.exitval)
endfunction

" Run ":checkhealth guise" on Neovim or ":GuiseCheck" on Vim against an
" interactive sh, or [shell] if given, that reads {rc} through $ENV, and
" return the report.
function! s:check(rc, ...) abort
  let rcfile = s:tmpdir .. '/shellrc'
  call writefile(a:rc, rcfile)
  let saved = [&shell, $ENV]
  let &shell = a:0 ? a:1 : 'sh'
  let $ENV = rcfile
  try
    if has('nvim')
      silent checkhealth guise
      let report = join(getline(1, '$'), "\n")
      bwipeout!
      return report
    endif
    return execute('GuiseCheck')
  finally
    let [&shell, $ENV] = saved
  endtry
endfunction

function! s:test_check_accepts_shell_that_keeps_editor() abort
  let report = s:check(['if [ -z "$GUISE_ADDRESS" ]; then export EDITOR=vi VISUAL=vi; fi'])
  call assert_match('OK', report)
  call assert_notmatch('WARNING\|ERROR', report)
endfunction

function! s:test_check_accepts_quoted_shell() abort
  let report = s:check([], '"' .. exepath('sh') .. '"')
  call assert_notmatch('WARNING\|ERROR', report)
endfunction

function! s:test_check_survives_shell_that_breaks_path() abort
  let report = s:check(['PATH=/nonexistent'])
  call assert_notmatch('WARNING\|ERROR', report)
endfunction

function! s:test_check_warns_shell_that_overwrites_editor() abort
  let report = s:check(['export EDITOR=vi'])
  call assert_match('WARNING[^\n]*\$EDITOR[^\n]*"vi"', report)
endfunction

function! s:test_check_warns_shell_that_overwrites_visual() abort
  let report = s:check(['export VISUAL=vi'])
  call assert_match('WARNING[^\n]*\$VISUAL[^\n]*"vi"', report)
endfunction

function! s:test_check_errors_shell_that_drops_address() abort
  let report = s:check(['unset GUISE_ADDRESS'])
  call assert_match('ERROR[^\n]*\$GUISE_ADDRESS', report)
endfunction

function! s:test_check_skips_shell_when_editor_is_disabled() abort
  let g:guise#disable_editor = 1
  try
    let report = s:check(['export EDITOR=vi'])
  finally
    let g:guise#disable_editor = 0
  endtry
  call assert_notmatch('WARNING\|ERROR', report)
  call assert_match('guise#disable_editor', report)
endfunction

" A nested Vim/Neovim still reaches the instance through $GUISE_ADDRESS when
" $EDITOR is left to the user.
function! s:test_check_errors_dropped_address_when_editor_is_disabled() abort
  let g:guise#disable_editor = 1
  try
    let report = s:check(['unset GUISE_ADDRESS'])
  finally
    let g:guise#disable_editor = 0
  endtry
  call assert_match('ERROR[^\n]*\$GUISE_ADDRESS', report)
endfunction

let s:names = sort(filter(map(split(execute('function /test_'), "\n"),
      \ { _, v -> matchstr(v, '\<SNR>\d\+_\zstest_\w\+') }),
      \ { _, v -> !empty(v) }))
if empty(s:names)
  call writefile(['no tests found'], '/dev/stderr')
  cquit!
endif

let s:results = []
for s:name in s:names
  let v:errors = []
  try
    call call('s:' .. s:name, [])
  catch
    call add(v:errors, v:exception .. ' @ ' .. v:throwpoint)
  endtry
  call add(s:results, printf('%s %s', empty(v:errors) ? 'ok  ' : 'FAIL', s:name))
  call extend(s:results, map(copy(v:errors), { _, v -> '      ' .. v }))
  silent! tabonly!
endfor

let s:failed = len(filter(copy(s:results), { _, v -> v =~# '^FAIL' }))
call add(s:results, printf('%s: %d failed', has('nvim') ? 'nvim' : 'vim', s:failed))
if has('nvim')
  call writefile(s:results, '/dev/stderr')
else
  call writefile(s:results, '/dev/stdout')
endif
execute s:failed ? 'cquit!' : 'qall!'
