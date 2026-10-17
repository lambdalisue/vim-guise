"""Run a command on a terminal of its own and type keys once it prompts.

Usage: python3 -I test/pty_run.py MODE PROMPT KEYS OUT COMMAND [ARG]...

MODE is "cooked" or "raw", the mode the terminal is left in before COMMAND
starts, as Vim leaves it for a shell command. KEYS are typed once COMMAND
writes PROMPT to the terminal. The stdout of COMMAND goes to OUT, apart from
what it writes to the terminal. The exit status is that of COMMAND.
"""

import os
import pty
import sys
import tty

mode, prompt, keys, out, *command = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    if mode == "raw":
        tty.setraw(0)
    os.dup2(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 1)
    os.execvp(command[0], command)
written = b""
typed = False
while True:
    try:
        chunk = os.read(fd, 1024)
    except OSError:
        break
    if not chunk:
        break
    written += chunk
    if not typed and prompt.encode() in written:
        os.write(fd, keys.encode())
        typed = True
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
