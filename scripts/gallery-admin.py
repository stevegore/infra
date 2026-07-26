#!/usr/bin/env python3
"""Small hide-list API for the static Instagram gallery."""

import json
import os
import pathlib
import re
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


STATE_DIR = pathlib.Path(os.environ.get("GALLERY_STATE_DIR", "/state"))
HIDDEN_PATH = STATE_DIR / "hidden.txt"
CSS_PATH = STATE_DIR / "hidden.css"
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
AUTH_HEADER = "X-Gallery-Auth"
AUTH_VALUE = "ok"
WATCH_INTERVAL = 5
LOCK = threading.Lock()


def atomic_write(path, content):
    """Replace path atomically, keeping temporary files in the same directory."""
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            os.fchmod(handle.fileno(), 0o644)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def read_text():
    return HIDDEN_PATH.read_text(encoding="utf-8")


def hidden_ids(content=None):
    """Return unique, valid IDs while ignoring comments and blank lines."""
    if content is None:
        content = read_text()
    result = []
    seen = set()
    for line in content.splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        if not ID_RE.fullmatch(value):
            print(f"ignoring invalid id in {HIDDEN_PATH}: {value!r}", flush=True)
            continue
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def css_for(ids):
    if not ids:
        return "/* No hidden gallery items. */\n"
    selectors = ",\n".join(f'[data-id="{media_id}"]' for media_id in ids)
    return f"{selectors} {{ display: none !important; }}\n"


def regenerate_css(content=None):
    """Regenerate CSS only; callers handling hand edits must not touch hidden.txt."""
    if content is None:
        content = read_text()
    atomic_write(CSS_PATH, css_for(hidden_ids(content)))


def set_hidden(media_id, hide):
    """Add or remove one ID while preserving comments and blank lines."""
    with LOCK:
        content = read_text()
        lines = content.splitlines(keepends=True)
        current = set(hidden_ids(content))

        if hide and media_id not in current:
            if content and not content.endswith(("\n", "\r")):
                lines.append("\n")
            lines.append(f"{media_id}\n")
            content = "".join(lines)
            atomic_write(HIDDEN_PATH, content)
        elif not hide and media_id in current:
            content = "".join(
                line for line in lines if line.strip() != media_id
            )
            atomic_write(HIDDEN_PATH, content)

        regenerate_css(content)
        ids = hidden_ids(content)
        return media_id in ids, len(ids)


def initialise_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK:
        if not HIDDEN_PATH.exists():
            atomic_write(
                HIDDEN_PATH,
                "# One gallery media id per line. Blank lines and comments are kept.\n",
            )
        regenerate_css()


def watch_hidden_file():
    """Refresh CSS after hidden.txt is edited by hand."""
    try:
        signature = (HIDDEN_PATH.stat().st_mtime_ns, HIDDEN_PATH.stat().st_size)
    except OSError:
        signature = None

    while True:
        time.sleep(WATCH_INTERVAL)
        try:
            stat = HIDDEN_PATH.stat()
            new_signature = (stat.st_mtime_ns, stat.st_size)
            if new_signature == signature:
                continue
            with LOCK:
                regenerate_css()
            signature = new_signature
            print("regenerated hidden.css after hidden.txt changed", flush=True)
        except OSError as exc:
            print(f"hidden-list watcher error: {exc}", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "gallery-admin"

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def not_found(self):
        self.send_json(404, {"error": "not found"})

    def authorised(self):
        return self.headers.get(AUTH_HEADER) == AUTH_VALUE

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            self.send_json(200, {"status": "ok"})
            return
        if path != "/api/hidden" or not self.authorised():
            self.not_found()
            return
        with LOCK:
            ids = hidden_ids()
        self.send_json(200, {"hidden": ids, "count": len(ids)})

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/api/hide" or not self.authorised():
            self.not_found()
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > 4096:
            self.send_json(400, {"error": "invalid request body"})
            return

        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_json(400, {"error": "invalid JSON"})
            return

        media_id = payload.get("id") if isinstance(payload, dict) else None
        hide = payload.get("hidden") if isinstance(payload, dict) else None
        if not isinstance(media_id, str) or not ID_RE.fullmatch(media_id):
            self.send_json(400, {"error": "invalid id"})
            return
        if not isinstance(hide, bool):
            self.send_json(400, {"error": "hidden must be a boolean"})
            return

        try:
            effective, count = set_hidden(media_id, hide)
        except OSError as exc:
            print(f"state write failed: {exc}", flush=True)
            self.send_json(500, {"error": "state write failed"})
            return
        self.send_json(
            200, {"id": media_id, "hidden": effective, "count": count}
        )

    def do_HEAD(self):
        if urlsplit(self.path).path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)


def main():
    initialise_state()
    watcher = threading.Thread(
        target=watch_hidden_file, name="hidden-list-watcher", daemon=True
    )
    watcher.start()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
    print(f"gallery admin listening on :8080; state in {STATE_DIR}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
