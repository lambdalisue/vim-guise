# 🎭 guise

[![Vim 9.2.0153 or above](https://img.shields.io/badge/Vim-Support%209.2.0153-yellowgreen.svg?logo=vim)](https://github.com/vim/vim/tree/v9.2.0153)
[![Neovim 0.10.0 or above](https://img.shields.io/badge/Neovim-Support%200.10.0-yellowgreen.svg?logo=neovim&logoColor=white)](https://github.com/neovim/neovim/tree/v0.10.0)

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![vim help](https://img.shields.io/badge/vim-%3Ah%20guise-orange.svg)](doc/guise.txt)
[![test](https://github.com/lambdalisue/vim-guise/actions/workflows/test.yml/badge.svg)](https://github.com/lambdalisue/vim-guise/actions/workflows/test.yml)

Guise is a Vim/Neovim plugin that opens a new tab page rather than
invokes a new nested instance when a user tried to open a new Vim/Neovim through
a job or terminal on the instance.

![Vim](https://user-images.githubusercontent.com/546312/130876263-5a5a8e29-1204-455a-84af-0070c8776b6f.gif)

![Neovim](https://user-images.githubusercontent.com/546312/130876219-629bef5f-6d0c-4482-906b-9fffa7326295.gif)

## Requirements

- Vim 9.2.0153 or above (for `ch_listen()`), or Neovim 0.10.0 or above

## Shell configuration

guise exports `$GUISE_ADDRESS`, `$EDITOR`, and `$VISUAL` to programs started
from the instance. A shell started in a terminal reads its startup files after
that, so a shell that assigns `$EDITOR` or `$VISUAL` unconditionally overwrites
the value guise exported, and programs in the terminal start their own editor
instead of opening a tab page in the parent.

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

See `:help guise-shell` for details.

## Similar projects

- [lambdalisue/askpass.vim](https://github.com/lambdalisue/askpass.vim)
- [thinca/vim-singleton](https://github.com/thinca/vim-singleton)
- [lambdalisue/edita.vim](https://github.com/lambdalisue/edita.vim)
- [mhinz/neovim-remote](https://github.com/mhinz/neovim-remote)
- [kyoh86/vim-editerm](https://github.com/kyoh86/vim-editerm)
- https://qiita.com/tennashi/items/a1a7a08ceb69d2768158

## License

The code in this repository follows MIT license, texted in [LICENSE](./LICENSE).
Contributors need to agree that any modifications sent in this repository follow
the license.
