"""Send lines to a Unix socket as they are and record what comes back.

Usage: python3 -I test/raw_request.py SOCKET OUT LINE...

Each LINE is sent with a trailing newline. What the server writes until it
closes the connection, or stays silent for a second, goes to OUT.
"""

import socket
import sys

path, out, *lines = sys.argv[1:]
received = b""
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(path)
    sock.settimeout(1)
    try:
        for line in lines:
            sock.sendall(line.encode() + b"\n")
        while True:
            chunk = sock.recv(1024)
            if not chunk:
                break
            received += chunk
    except (socket.timeout, OSError):
        pass
with open(out, "wb") as f:
    f.write(received)
