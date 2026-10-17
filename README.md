# 🎭 guise

[![Vim 9.2.0153 or above](https://img.shields.io/badge/Vim-Support%209.2.0153-yellowgreen.svg?logo=vim)](https://github.com/vim/vim/tree/v9.2.0153)
[![Neovim 0.10.0 or above](https://img.shields.io/badge/Neovim-Support%200.10.0-yellowgreen.svg?logo=neovim&logoColor=white)](https://github.com/neovim/neovim/tree/v0.10.0)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![vim help](https://img.shields.io/badge/vim-%3Ah%20guise-orange.svg)](doc/guise.txt)
[![test](https://github.com/lambdalisue/vim-guise/actions/workflows/test.yml/badge.svg)](https://github.com/lambdalisue/vim-guise/actions/workflows/test.yml)

Guise lets a program started from a job or terminal of Vim/Neovim open files
and ask for passwords in that instance, instead of starting a nested one.

## Why

Run `git commit` in `:terminal` and Git starts `$EDITOR` — a second Vim, drawn
inside the terminal window of the first. It has its own registers, buffers and
undo history, and none of your windows. A job has it worse: it has no terminal
at all, so neither an editor nor ssh asking for a passphrase can run.

```mermaid
flowchart LR
  subgraph without["Without guise"]
    direction TB
    A1["Vim"] --> T1[":terminal"]
    T1 --> G1["git commit"]
    G1 --> N1["nested Vim<br/>inside the terminal"]
  end
  subgraph with["With guise"]
    direction TB
    A2["Vim"] --> T2[":terminal"]
    T2 --> G2["git commit"]
    G2 -. "COMMIT_EDITMSG" .-> A2
    A2 --> P2["new tab page<br/>in the same Vim"]
  end
```

With guise, the file opens in a new tab page of the Vim you are already in.
Git waits until you close it, then goes on as it would after any editor.

## How it works

On startup guise opens a channel server in the instance and exports variables
that point back to it. Every job and terminal started from the instance
inherits them.

```mermaid
flowchart LR
  P["Vim/Neovim<br/>(parent)"] -- "listens on" --> S(("socket"))
  P -- "exports" --> E["$GUISE_ADDRESS<br/>$EDITOR, $VISUAL<br/>$SSH_ASKPASS, $SUDO_ASKPASS"]
  E -- "inherited by" --> J["jobs and :terminal"]
  J -- "connect to" --> S
```

### Editing a file

`$EDITOR` names a headless Vim/Neovim that forwards its arguments to the
parent and waits. A Vim or Neovim you start yourself in the terminal finds
`$GUISE_ADDRESS` and does the same, so `vim foo.txt` there opens `foo.txt` in
the parent too.

```mermaid
sequenceDiagram
  actor U as You
  participant P as Parent Vim
  participant G as git (in :terminal)
  participant C as $EDITOR (headless Vim)
  G->>C: start with COMMIT_EDITMSG
  C->>P: edit COMMIT_EDITMSG
  P->>U: open it in a new tab page
  U->>P: write and close the buffer
  P-->>C: done
  C-->>G: exit 0
  Note over G: git commits with the message
```

The buffer is wiped when it is closed, which tells the waiting program that
editing has finished.

### Answering a password prompt

`$SSH_ASKPASS` and `$SUDO_ASKPASS` name a program that asks the parent the
same way, and the parent prompts with `inputsecret()`. A job has no terminal to
type a passphrase into, so this is what lets `git push` over SSH or `sudo -A`
run from one.

```mermaid
sequenceDiagram
  actor U as You
  participant P as Parent Vim
  participant S as ssh (from a job)
  participant A as $SSH_ASKPASS
  S->>A: Enter passphrase for key
  A->>P: ask the prompt
  P->>U: inputsecret()
  U->>P: type the passphrase
  P-->>A: the answer
  A-->>S: print it to stdout
```

While the parent waits for a command it started synchronously — `system()` or
`:!` — it cannot answer. The askpass program then asks on the terminal instead,
once the parent has not answered for a second.

```mermaid
flowchart LR
  A["$SSH_ASKPASS"] --> Q{"parent answers<br/>within a second?"}
  Q -- "yes" --> I["prompt in Vim"]
  Q -- "no, it runs system() or :!" --> T["prompt on the terminal"]
```

## Requirements

- Vim 9.2.0153 or above (for `ch_listen()`), or Neovim 0.10.0 or above

Askpass is not exported on Windows.

## Installation

Install it with your plugin manager, e.g. [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'lambdalisue/vim-guise'
```

or [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'lambdalisue/vim-guise' }
```

There is nothing to call. guise starts with the instance, unless Vim runs in
silent Ex mode (`-es`) or Neovim runs with `--headless`, where nobody could see
the tab page it opens.

## Shell configuration

A shell started in `:terminal` reads its startup files after it inherits the
variables. A startup file that assigns `$EDITOR` or `$VISUAL` unconditionally
replaces the editor guise exported, and programs in the terminal start a nested
editor again.

```mermaid
flowchart LR
  P["Vim exports<br/>$EDITOR"] --> R{".bashrc / config.fish<br/>sets $EDITOR?"}
  R -- "only if $GUISE_ADDRESS is empty" --> OK["guise's $EDITOR stays:<br/>files open in the parent"]
  R -- "always" --> NG["overwritten:<br/>a nested editor starts"]
```

Assign the editor variables only when `$GUISE_ADDRESS` is empty:

```sh
# sh, bash, zsh
if [ -z "$GUISE_ADDRESS" ]; then
  export EDITOR=nvim
  export VISUAL="$EDITOR"
fi
```

```fish
# fish
if test -z "$GUISE_ADDRESS"
    set -gx EDITOR nvim
    set -gx VISUAL $EDITOR
end
```

A program-specific setting that names another editor, such as `$GIT_EDITOR`,
hides guise's `$EDITOR` in the same way; leave it unset or point it at
`$EDITOR`.

`:checkhealth guise` on Neovim and `:GuiseCheck` on Vim report whether your
shell keeps these variables. See `:help guise-shell`.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `g:guise_edit_opener` | `"tab drop"` | command that opens a forwarded file |
| `g:guise#disable_editor` | `0` | leave `$EDITOR` and `$VISUAL` untouched |
| `g:guise#disable_askpass` | `0` | leave `$SSH_ASKPASS`, `$SUDO_ASKPASS` and `$SSH_ASKPASS_REQUIRE` untouched |
| `g:guise#disable_vim` | `0` | let a Vim started in the terminal run nested |
| `g:guise#disable_neovim` | `0` | let a Neovim started in the terminal run nested |

guise sets `$SSH_ASKPASS_REQUIRE` to `force` unless it is already set, because
ssh ignores `$SSH_ASKPASS` without `$DISPLAY` otherwise. See `:help guise` for
every option and the details of askpass.

guise replaces [lambdalisue/askpass.vim](https://github.com/lambdalisue/askpass.vim).

## Development

```sh
make test       # Vim and Neovim
make test-vim   # Vim only
make test-nvim  # Neovim only
```

## Similar projects

- [thinca/vim-singleton](https://github.com/thinca/vim-singleton)
- [lambdalisue/edita.vim](https://github.com/lambdalisue/edita.vim)
- [mhinz/neovim-remote](https://github.com/mhinz/neovim-remote)
- [kyoh86/vim-editerm](https://github.com/kyoh86/vim-editerm)
- https://qiita.com/tennashi/items/a1a7a08ceb69d2768158

## License

MIT. See [LICENSE](LICENSE). Contributions are accepted under the same license.
