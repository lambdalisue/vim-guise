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

function! s:socket() abort
  return matchstr($GUISE_ADDRESS, '^unix:\zs.\{-}\ze#\x\+$')
endfunction

function! s:test_address_is_a_socket_in_a_private_directory() abort
  call assert_match('^unix:/', $GUISE_ADDRESS)
  call assert_equal('socket', getftype(s:socket()))
  call assert_equal('rwx------', getfperm(fnamemodify(s:socket(), ':h')))
endfunction

" A socket in a private directory is out of reach of other users, but the TCP
" port used on Windows is not.
function! s:test_address_carries_a_token() abort
  call assert_match('#\x\{32,}$', $GUISE_ADDRESS)
endfunction

" Send {lines} to the server of this instance as they are, and return the
" lines it replied before it closed the connection.
function! s:raw_request(lines) abort
  let out = tempname()
  let job = s:spawn([], join([
        \ 'python3 -I', shellescape(s:root .. '/test/raw_request.py'),
        \ shellescape(s:socket()), shellescape(out),
        \] + map(copy(a:lines), { _, v -> shellescape(v) })))
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'raw request does not exit')
  return filter(readfile(out), { _, v -> !empty(v) })
endfunction

" An address without a token comes from something other than guise, and a
" child that silently runs nested leaves no clue why.
function! s:test_child_warns_address_without_token() abort
  let expr = 'execute(''call guise#open("unix:/nonexistent", [])'')'
  call assert_match('has no token', s:probe('vim -Nu NONE -i NONE -n -es', [], expr))
  call assert_match('has no token', s:probe('nvim --headless --clean -n', [], expr))
endfunction

function! s:test_server_answers_the_token() abort
  if !executable('python3')
    return
  endif
  let token = matchstr($GUISE_ADDRESS, '#\zs\x\+$')
  call assert_equal(['[1,{"error":""}]'], map(s:raw_request([json_encode([1, ['auth', token]])]),
        \ { _, v -> substitute(v, '\s', '', 'g') }))
endfunction

function! s:test_server_refuses_request_without_token() abort
  if !executable('python3')
    return
  endif
  let filename = s:tmpdir .. '/untrusted.txt'
  call assert_equal([], s:raw_request([json_encode([1, ['edit', filename]])]))
  call assert_equal(0, s:find_tab({ b -> s:same_file(bufname(b), filename) }))
endfunction

function! s:test_server_refuses_request_with_wrong_token() abort
  if !executable('python3')
    return
  endif
  let filename = s:tmpdir .. '/untrusted.txt'
  call assert_equal([], s:raw_request([
        \ json_encode([1, ['auth', repeat('0', 32)]]),
        \ json_encode([2, ['edit', filename]]),
        \]))
  call assert_equal(0, s:find_tab({ b -> s:same_file(bufname(b), filename) }))
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
  let job = s:spawn([], 'GUISE_ADDRESS= EDITOR=original VISUAL=original SSH_ASKPASS=original SUDO_ASKPASS=original SSH_ASKPASS_REQUIRE= ' .. a:cmd .. ' -S ' .. shellescape(scriptfile))
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
" {setup} in it, and return [job, $GUISE_ADDRESS, $EDITOR] of it. Lines of
" [presetup] run before guise is loaded.
function! s:start_parent(setup, ...) abort
  let info = s:tmpdir .. '/parent.info'
  call delete(info)
  let scriptfile = s:tmpdir .. '/parent.vim'
  call writefile((a:0 ? a:1 : []) + [
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

" Neovim runs each line of a command string as a command of its own, and
" fnameescape() does not escape a newline, so the rest of such a name would
" run in the parent. The payload avoids every character fnameescape() escapes.
function! s:test_edit_refuses_file_name_with_newline() abort
  let g:guise_test_injected = 0
  let command = 'let g:guise_test_injected=1'
  let payload = 'exe(' .. join(map(split(command, '\zs'), { _, c -> 'nr2char(' .. char2nr(c) .. ')' }), '..') .. ')'
  let job = s:spawn([s:tmpdir .. "/a\n" .. payload])
  " Neovim raises the refusal the child reports back as an error of its own.
  silent! call s:wait(5000, { -> job.exitval isnot# v:null })
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'editor does not exit')
  call assert_notequal(0, job.exitval)
  call assert_equal(0, g:guise_test_injected)
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

function! s:test_askpass_is_exported() abort
  call assert_match('^/', $SSH_ASKPASS)
  call assert_true(executable($SSH_ASKPASS), '$SSH_ASKPASS is not executable')
  call assert_equal($SSH_ASKPASS, $SUDO_ASKPASS)
endfunction

" A job has no terminal for ssh to read a passphrase from, and ssh uses
" $SSH_ASKPASS without $DISPLAY only when $SSH_ASKPASS_REQUIRE is "force".
function! s:test_askpass_is_forced_for_ssh() abort
  call assert_equal('force', $SSH_ASKPASS_REQUIRE)
endfunction

function! s:test_ssh_askpass_require_of_user_is_kept() abort
  let setup = ['let g:guise#enable_headless = 1']
  call assert_equal('never', s:probe('SSH_ASKPASS_REQUIRE=never vim -Nu NONE -i NONE -n -es', setup, '$SSH_ASKPASS_REQUIRE'))
  call assert_equal('never', s:probe('SSH_ASKPASS_REQUIRE=never nvim --headless --clean -n', setup, '$SSH_ASKPASS_REQUIRE'))
endfunction

function! s:test_disable_askpass_accepts_boolean() abort
  let setup = ['let g:guise#enable_headless = 1', 'let g:guise#disable_askpass = v:true']
  for cmd in ['vim -Nu NONE -i NONE -n -es', 'nvim --headless --clean -n']
    call assert_equal('original', s:probe(cmd, setup, '$SSH_ASKPASS'))
    call assert_equal('original', s:probe(cmd, setup, '$SUDO_ASKPASS'))
    call assert_equal('', s:probe(cmd, setup, '$SSH_ASKPASS_REQUIRE'))
  endfor
endfunction

" Run {askpass} with {prompt} as a program would, and return [job, file that
" receives its stdout].
function! s:spawn_askpass(askpass, prompt, ...) abort
  let out = tempname()
  let env = a:0 ? a:1 : ''
  let job = s:spawn([], join([env, a:askpass, shellescape(a:prompt), '>', shellescape(out), '</dev/null']))
  return [job, out]
endfunction

" Start a separate parent that s:type() can answer the prompts of, after
" running [setup] in it, and return it. A prompt sets typeahead aside, so the
" keys must arrive once it is open: Vim in silent Ex mode reads them from
" stdin after it marks the prompt open, and a timer of Neovim feeds them while
" a prompt is open.
function! s:start_prompting_parent(...) abort
  let keysfile = tempname()
  let markfile = tempname()
  let setup = a:0 ? a:1 : []
  if has('nvim')
    call add(setup, printf(
          \ 'call timer_start(50, { -> mode() ==# "c" && filereadable(%s) ? feedkeys(readfile(%s, "b")[0], "t") + delete(%s) : 0 }, {"repeat": -1})',
          \ string(keysfile), string(keysfile), string(keysfile)))
  else
    call add(setup, printf('autocmd CmdlineEnter * call writefile([], %s)', string(markfile)))
  endif
  let [job, address, _] = s:start_parent(setup)
  return {
        \ 'job': job,
        \ 'keysfile': keysfile,
        \ 'markfile': markfile,
        \ 'env': 'GUISE_ADDRESS=' .. shellescape(address),
        \}
endfunction

" Type {keys}, which end with "\r" for Vim, into the next prompt of {parent}.
function! s:type(parent, keys) abort
  if has('nvim')
    call writefile([a:keys], a:parent.keysfile .. '.tmp', 'b')
    call rename(a:parent.keysfile .. '.tmp', a:parent.keysfile)
    return
  endif
  if !s:wait(5000, { -> filereadable(a:parent.markfile) })
    return
  endif
  call delete(a:parent.markfile)
  call ch_sendraw(job_getchannel(a:parent.job.id), substitute(a:keys, "\r$", "\n", ''))
endfunction

function! s:test_askpass_prints_answer_typed_in_parent() abort
  let parent = s:start_prompting_parent()
  try
    let [job, out] = s:spawn_askpass(shellescape($SSH_ASKPASS), 'Passphrase:', parent.env)
    call s:type(parent, "s3cr'et\r")
    call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
    call assert_equal(0, job.exitval)
    call assert_equal(["s3cr'et"], readfile(out))
  finally
    call s:kill(parent.job)
  endtry
endfunction

" Keys typed for editing before a prompt opens are not the answer to it.
function! s:test_askpass_keeps_typeahead_of_parent() abort
  let parent = s:start_prompting_parent(['call feedkeys("ordinary\r", "t")'])
  try
    let [job, out] = s:spawn_askpass(shellescape($SSH_ASKPASS), 'Passphrase:', parent.env)
    call s:type(parent, "secret\r")
    call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
    call assert_equal(0, job.exitval)
    call assert_equal(['secret'], readfile(out))
  finally
    call s:kill(parent.job)
  endtry
endfunction

function! s:test_askpass_from_the_other_editor() abort
  let other = has('nvim')
        \ ? 'vim -Nu NONE -i NONE -n -es -S'
        \ : 'nvim --headless --clean -n -S'
  if !executable(split(other)[0])
    throw 'Skipped: ' .. split(other)[0] .. ' is not executable'
  endif
  let parent = s:start_prompting_parent()
  try
    let [job, out] = s:spawn_askpass(join([other, shellescape(s:root .. '/script/askpass.vim'), '--']), 'Passphrase:', parent.env)
    call s:type(parent, "secret\r")
    call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
    call assert_equal(0, job.exitval)
    call assert_equal(['secret'], readfile(out))
  finally
    call s:kill(parent.job)
  endtry
endfunction

" ssh-agent takes an empty answer to a confirmation as approval, so leaving
" the prompt without typing "yes" must refuse it.
function! s:test_askpass_confirmation_needs_yes() abort
  let cases = [
        \ ["yes\r", 0, ['yes']],
        \ ["no\r", 1, []],
        \ ["\r", 1, []],
        \]
  " Vim in silent Ex mode reads a prompt from stdin, where <Esc> is a
  " character.
  if has('nvim')
    call add(cases, ["\<Esc>", 1, []])
  endif
  let parent = s:start_prompting_parent()
  try
    for [keys, exitval, output] in cases
      let [job, out] = s:spawn_askpass(shellescape($SSH_ASKPASS), 'Allow use of key?', parent.env .. ' SSH_ASKPASS_PROMPT=confirm')
      call s:type(parent, keys)
      call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit for ' .. string(keys))
      call assert_equal(exitval, job.exitval, string(keys))
      call assert_equal(output, readfile(out), string(keys))
    endfor
  finally
    call s:kill(parent.job)
  endtry
endfunction

" A prompt opened while another one waits for keys would take over the rest of
" them. The prompt blocks this instance, so timers drive the test.
function! s:test_askpass_prompts_one_at_a_time() abort
  " Timers do not run while input() waits in the silent Ex mode of Vim.
  if !has('nvim')
    return
  endif
  let jobs = {}
  call timer_start(0, { -> extend(jobs, {'first': s:spawn_askpass(shellescape($SSH_ASKPASS), 'First:')}) })
  call timer_start(500, { -> extend(jobs, {'second': s:spawn_askpass(shellescape($SSH_ASKPASS), 'Second:')}) })
  call timer_start(1000, { -> feedkeys("one\<CR>", 't') })
  call timer_start(1500, { -> feedkeys("two\<CR>", 't') })
  let Done = { name -> has_key(jobs, name) && jobs[name][0].exitval isnot# v:null }
  call assert_true(s:wait(5000, { -> Done('first') && Done('second') }), 'askpass does not exit')
  call assert_equal(['one'], readfile(jobs.first[1]))
  call assert_equal(['two'], readfile(jobs.second[1]))
endfunction

" Nobody waits for the answer of a program that exited while its prompt was
" queued, so the prompt must not open.
function! s:test_askpass_skips_prompt_of_exited_program() abort
  " Timers do not run while input() waits in the silent Ex mode of Vim.
  if !has('nvim')
    return
  endif
  let jobs = {}
  let state = {}
  call timer_start(0, { -> extend(jobs, {'first': s:spawn_askpass(shellescape($SSH_ASKPASS), 'First:')}) })
  call timer_start(500, { -> extend(jobs, {'second': s:spawn_askpass(shellescape($SSH_ASKPASS), 'Second:')}) })
  call timer_start(1000, { -> s:kill(jobs.second[0]) })
  call timer_start(1500, { -> feedkeys("one\<CR>", 't') })
  function! s:leave_prompt(state, ...) abort
    let a:state.mode = mode()
    if a:state.mode ==# 'c'
      call feedkeys("\<Esc>", 't')
    endif
  endfunction
  call timer_start(2500, function('s:leave_prompt', [state]))
  call s:wait(3000, { -> has_key(state, 'mode') })
  call assert_equal(['one'], readfile(jobs.first[1]))
  call assert_notequal('c', get(state, 'mode', ''), 'a prompt is open for the exited program')
endfunction

" ssh shows a notification through askpass and kills it when it is done.
function! s:test_askpass_notification_does_not_wait() abort
  let [job, out] = s:spawn_askpass(shellescape($SSH_ASKPASS), 'Confirm user presence', 'SSH_ASKPASS_PROMPT=none')
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
  call assert_equal(0, job.exitval)
  call assert_equal([], readfile(out))
endfunction

" A parent that does not export askpass, as on Windows, must not prompt for a
" secret.
function! s:test_ask_is_refused_when_askpass_is_disabled() abort
  let [parent, address, editor] = s:start_parent([], ['let g:guise#disable_askpass = 1'])
  try
    let askpass = (has('nvim') ? 'nvim --headless --clean -n -S ' : 'vim -Nu NONE -i NONE -n -es -S ')
          \ .. shellescape(s:root .. '/script/askpass.vim') .. ' --'
    let [job, out] = s:spawn_askpass(askpass, 'Passphrase:', 'GUISE_ADDRESS=' .. shellescape(address))
    call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
    call assert_notequal(0, job.exitval)
    call assert_equal([], readfile(out))
  finally
    call s:kill(parent)
  endtry
endfunction

" A parent waiting for a command it started synchronously (system(), :!)
" cannot answer, but the command runs on the terminal of the parent. Vim
" leaves the terminal raw for system() under ":silent".
function! s:test_askpass_falls_back_to_terminal_while_parent_is_busy() abort
  if !executable('python3')
    return
  endif
  let [parent, address, _] = s:start_parent(['call timer_start(0, { -> system("sleep 30") })'])
  try
    for mode in ['cooked', 'raw']
      for [keys, hint, exitval, output] in [
            \ ["pa ss\r", '', 0, ['pa ss']],
            \ ["yes\r", 'confirm', 0, ['yes']],
            \ ["no\r", 'confirm', 1, []],
            \]
        let label = printf('%s %s', mode, string(keys))
        let out = tempname()
        let job = s:spawn([], join([
              \ 'GUISE_ADDRESS=' .. shellescape(address),
              \ 'SSH_ASKPASS_PROMPT=' .. hint,
              \ 'python3 -I', shellescape(s:root .. '/test/pty_run.py'),
              \ mode, 'Passphrase:', shellescape(keys), shellescape(out),
              \ shellescape($SSH_ASKPASS), 'Passphrase:',
              \]))
        call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit for ' .. label)
        call assert_equal(exitval, job.exitval, label)
        call assert_equal(output, filereadable(out) ? readfile(out) : ['<no output>'], label)
      endfor
    endfor
  finally
    call s:kill(parent)
  endtry
endfunction

" A program must not take a warning for the answer.
function! s:test_askpass_fails_without_parent() abort
  let [job, out] = s:spawn_askpass(shellescape($SSH_ASKPASS), 'Passphrase:', 'GUISE_ADDRESS=unix:' .. s:tmpdir .. '/nonexistent')
  call assert_true(s:wait(5000, { -> job.exitval isnot# v:null }), 'askpass does not exit')
  call assert_notequal(0, job.exitval)
  call assert_equal([], readfile(out))
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

" A report gets pasted into issues.
function! s:test_check_does_not_show_the_token() abort
  let report = s:check([])
  call assert_match(escape(s:socket(), '\.*$~['), report)
  call assert_notmatch(matchstr($GUISE_ADDRESS, '#\zs\x\+$'), report)
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
