#!/usr/bin/env python3
"""Native messaging bridge between Firefox and the Omarchy window gallery.

Firefox starts this with no arguments and speaks the native messaging protocol
over stdin/stdout (4-byte native-endian length prefix, then UTF-8 JSON). The
tab list is written to a file the gallery reads on open, and a Unix socket
accepts activation requests coming back the other way.

Run with --activate TABID WINDOWID to send one activation request to a
already-running host; that is the mode the gallery itself invokes.
"""

import base64
import json
import os
import shutil
import socket
import struct
import sys
import threading

RUNTIME_DIR = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}",
    "omarchy-window-gallery",
)
TABS_PATH = os.path.join(RUNTIME_DIR, "tabs.json")
THUMB_DIR = os.path.join(RUNTIME_DIR, "thumbs")


# AF_UNIX paths are capped near 107 bytes, and exceeding it raises at bind()
# rather than anywhere obvious. An unusual XDG_RUNTIME_DIR is enough to trip
# it, so fall back to a short path instead. Both the host and the --activate
# client compute this the same way, so they always agree.
def _socket_path():
    preferred = os.path.join(RUNTIME_DIR, "control.sock")
    if len(preferred.encode("utf-8")) <= 100:
        return preferred
    return f"/tmp/omarchy-window-gallery-{os.getuid()}.sock"


SOCKET_PATH = _socket_path()

# One writer (this process) and many readers, so the file is replaced by
# rename rather than truncated in place: a reader either sees the whole old
# file or the whole new one, never a half-written list.
def write_tabs(tabs):
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    tmp = TABS_PATH + f".{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(tabs, handle)
    os.replace(tmp, TABS_PATH)


# Thumbnails live under XDG_RUNTIME_DIR, which is tmpfs: they never touch the
# disk and vanish on reboot. Written by rename for the same reason as the tab
# list -- the gallery must never load a half-written image.
def write_thumb(tab_id, encoded):
    os.makedirs(THUMB_DIR, exist_ok=True)
    path = os.path.join(THUMB_DIR, f"{int(tab_id)}.jpg")
    tmp = path + f".{os.getpid()}.tmp"
    with open(tmp, "wb") as handle:
        handle.write(base64.b64decode(encoded))
    os.replace(tmp, path)


def drop_thumb(tab_id):
    try:
        os.unlink(os.path.join(THUMB_DIR, f"{int(tab_id)}.jpg"))
    except (FileNotFoundError, ValueError):
        pass


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
    try:
        _serve_control_socket()
    except OSError as error:
        # No control socket means tabs cannot be activated, but the tab list
        # still works. Say so once on stderr rather than dying in a thread.
        print(f"omarchy-window-gallery: control socket unavailable: {error}",
              file=sys.stderr, flush=True)


def _serve_control_socket():
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
        if parts and parts[0] == "reload":
            send_message({"action": "reload"})
            continue
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
        action = message.get("action")
        if action == "tabs":
            write_tabs(message.get("tabs", []))
        elif action == "thumb":
            try:
                write_thumb(message["tabId"], message["data"])
            except (KeyError, ValueError, TypeError):
                pass
        elif action == "dropThumb":
            drop_thumb(message.get("tabId"))

    # Firefox closed the port: leave no stale tab list behind, or the gallery
    # would keep offering tabs that can no longer be focused.
    for path in (TABS_PATH, SOCKET_PATH):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
    shutil.rmtree(THUMB_DIR, ignore_errors=True)


def send_command(command):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.connect(SOCKET_PATH)
    except (FileNotFoundError, ConnectionRefusedError):
        return 1
    with client:
        client.sendall(command.encode("utf-8"))
    return 0


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
    if len(sys.argv) >= 2 and sys.argv[1] == "--reload":
        sys.exit(send_command("reload"))
    if len(sys.argv) >= 3 and sys.argv[1] == "--activate":
        sys.exit(send_activation(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""))
    run_host()
