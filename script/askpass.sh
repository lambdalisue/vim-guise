#!/bin/sh
# Askpass program that guise exports through a wrapper the server generates.
#
# Usage: askpass.sh COMMAND [ARG]... PROMPT
#
# COMMAND runs a headless Vim/Neovim on script/askpass.vim, which asks the
# parent for PROMPT. It exits with 2 when the parent does not answer, which a
# parent waiting for a command it started synchronously (system(), :!) cannot.
# Such a command runs on the terminal of the parent, so ask there instead,
# following the rules of script/askpass.vim for $SSH_ASKPASS_PROMPT.

# The headless instance must not take the keys typed on a terminal.
"$@" </dev/null
status=$?
if [ "$status" -ne 2 ] || ! { true </dev/tty; } 2>/dev/null; then
  exit "$status"
fi

# Show {prompt} and read a line from the terminal, with "echo" or "-echo"
# given as {echo}. The mode is set before the prompt shows, so that keys typed
# at once are not echoed. Vim leaves the terminal raw for system() under
# ":silent", where Enter does not finish a line, so read it in the usual mode
# and restore the mode after.
read_line() {
  saved=$(stty -g </dev/tty) || return 1
  trap 'stty "$saved" </dev/tty; exit 1' HUP INT TERM
  if stty icanon icrnl isig opost "$2" </dev/tty; then
    printf '%s' "$1" >/dev/tty
    IFS= read -r answer </dev/tty
    read_status=$?
  else
    read_status=1
  fi
  stty "$saved" </dev/tty
  trap - HUP INT TERM
  return "$read_status"
}

for prompt; do :; done
case $SSH_ASKPASS_PROMPT in
none)
  printf '%s\r\n' "$prompt" >/dev/tty
  ;;
confirm)
  read_line "$prompt (yes/no) " echo || exit 1
  case $answer in
  [Yy][Ee][Ss]) echo yes ;;
  *) exit 1 ;;
  esac
  ;;
*)
  read_line "$prompt" -echo
  read_status=$?
  printf '\r\n' >/dev/tty
  [ "$read_status" -eq 0 ] || exit 1
  printf '%s\n' "$answer"
  ;;
esac
