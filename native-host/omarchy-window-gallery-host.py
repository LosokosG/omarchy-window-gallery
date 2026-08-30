#!/usr/bin/env python3
"""Native messaging bridge between Firefox and the Omarchy window gallery.

Firefox starts this with no arguments and speaks the native messaging protocol
over stdin/stdout (4-byte native-endian length prefix, then UTF-8 JSON). The
tab list is written to a file the gallery reads on open, and a Unix socket
accepts activation requests coming back the other way.

Run with --activate TABID WINDOWID to send one activation request to a
already-running host; that is the mode the gallery itself invokes.
"""

import json
import os
import socket
import struct
import sys
import threading

RUNTIME_DIR = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
    "omarchy-window-gallery",
)
TABS_PATH = os.path.join(RUNTIME_DIR, "tabs.json")
SOCKET_PATH = os.path.join(RUNTIME_DIR, "control.sock")

# One writer (this process) and many readers, so the file is replaced by
# rename rather than truncated in place: a reader either sees the whole old
# file or the whole new one, never a half-written list.
def write_tabs(tabs):
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    tmp = TABS_PATH + f".{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(tabs, handle)
    os.replace(tmp, TABS_PATH)


def read_message():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack("@I", header)
    payload = sys.stdin.buffer.read(length)
    if len(payload) < length:
        return None
    return json.loads(payload.decode("utf-8"))


_write_lock = threading.Lock()


def send_message(message):
    encoded = json.dumps(message).encode("utf-8")
    with _write_lock:
        sys.stdout.buffer.write(struct.pack("@I", len(encoded)))
        sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()


def serve_control_socket():
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    server.listen(8)

    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        with conn:
            data = conn.recv(4096).decode("utf-8", "replace").strip()
        parts = data.split()
        if len(parts) >= 2 and parts[0] == "activate":
            window_id = parts[2] if len(parts) > 2 else None
            send_message({
                "action": "activate",
                "tabId": int(parts[1]),
                "windowId": int(window_id) if window_id is not None else None,
            })


def run_host():
    threading.Thread(target=serve_control_socket, daemon=True).start()

    while True:
        message = read_message()
        if message is None:
            break
        if message.get("action") == "tabs":
            write_tabs(message.get("tabs", []))

    # Firefox closed the port: leave no stale tab list behind, or the gallery
    # would keep offering tabs that can no longer be focused.
    for path in (TABS_PATH, SOCKET_PATH):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def send_activation(tab_id, window_id):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.connect(SOCKET_PATH)
    except (FileNotFoundError, ConnectionRefusedError):
        return 1
    with client:
        client.sendall(f"activate {tab_id} {window_id}".encode("utf-8"))
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--activate":
        sys.exit(send_activation(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""))
    run_host()
