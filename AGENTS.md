# guise

Guise lets a program started from a job or terminal of Vim/Neovim open files
and ask for passwords in that instance, instead of starting a nested one.

## How it is built

- **Test first.** Red → green → refactor. Write the failing test before the
  code that makes it pass.
- **Each layer holds one thing.** Put a fact in the one layer that owns it,
  and nowhere else.

  | Layer | Holds |
  | --- | --- |
  | `README.md` | what this is, for whom, and how to set it up |
  | `doc/guise.txt` | the behaviour users can rely on, and every option |
  | Tests | the details that pin the behaviour down |
  | Code | how it is done |
  | Commits | why a change was made |
  | Comments | why it is not done another way |

## Quality gate

Run `make test` before reporting a change as done. It runs the suite on Vim
and on Neovim; CI runs the same targets.

## Layout

| Path | What lives there |
| --- | --- |
| `plugin/` | startup: start the server in a parent, forward argv in a child |
| `autoload/guise.vim` | the child side: connect to the parent and forward requests |
| `autoload/guise/server.vim` | the Vim server: listen, export variables, serve requests |
| `lua/guise/server.lua` | the Neovim server, speaking the same protocol |
| `autoload/guise/health.vim`, `lua/guise/health.lua` | `:GuiseCheck` and `:checkhealth guise` |
| `script/` | entry points of the headless editor and askpass programs |
| `doc/` | Vim help |
| `test/` | the test suite and its helpers |
| `.github/` | CI |

## Language

- README, docs and commit messages: English
- Code comments, log and error messages: English

## Commits

Scoped Commits:

```
<scope>: <description>

<why this change is needed>
```

- The scope names where the change is, from the table below. Several scopes
  are joined with `, `; a change across the whole tree uses `treewide`.
- The description starts in lower case, has no trailing period, and stays
  within 72 characters.
- The body explains why. The code shows how; the tests show what.
- A release commit is `release: vX.Y.Z`.
- A breaking change says so in the body and carries a `BREAKING CHANGE:`
  trailer.

Commits before this convention use emoji prefixes (`:+1:`, `:bug:`, ...);
leave them as they are.

| Scope | Covers |
| --- | --- |
| `plugin` | `plugin/` |
| `client` | `autoload/guise.vim`, `script/` |
| `server` | `autoload/guise/server.vim`, `lua/guise/server.lua` |
| `health` | `autoload/guise/health.vim`, `lua/guise/health.lua` |
| `doc` | `doc/`, `README.md` |
| `test` | `test/` |
| `ci` | `.github/` |
| `build` | `Makefile` |
| `agents` | `AGENTS.md` |

Add a row when a new area appears.
