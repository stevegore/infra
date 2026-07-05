#!/usr/bin/env python3
"""Verify the ttyd public-shell containment controls, live.

Drives a real session over the public WebSocket endpoint — exactly the path an
anonymous internet visitor takes — and asserts every hardening control defined
in apps/ttyd/ actually holds. This is a stronger check than `kubectl exec`,
which bypasses Caddy, the pod's iptables egress lockdown, and the securityContext
that only apply on the real ingress path.

Standard library only — no venv or pip install required:

    python3 scripts/verify-ttyd-hardening.py
    python3 scripts/verify-ttyd-hardening.py --url wss://stevegore.au/ws

Exit status is 0 if every control passes, 1 otherwise.

Controls asserted (see apps/ttyd/templates/deployment.yaml):
  - runs as non-root uid 222 (securityContext)
  - read-only root filesystem, with home still writable (emptyDir)
  - dnsPolicy None -> public resolvers, no CoreDNS
  - egress-lockdown iptables blocks OCI metadata / kube API / CoreDNS
  - public internet + DNS still reachable (shell stays usable)
  - visitor cannot flush the rules (no iptables) or escalate (no sudo)

Two ttyd/zsh gotchas are baked in and must not be "simplified" away:
  * The output markers are obfuscated (PROBE""HEAD) so they match the shell's
    real stdout, not the terminal's echo of the typed command.
  * Markers must not start with '=' — zsh's EQUALS expansion treats a leading
    '=' word as a command-path lookup and aborts the line.
"""

import argparse
import os
import re
import socket
import ssl
import struct
import sys
import time
from urllib.parse import urlparse

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b[=>]|\x07")


class WebSocket:
    """Minimal RFC 6455 client: TLS, masked text frames, ping/pong handling."""

    def __init__(self, host, port, path, origin, subproto="tty", timeout=1.0):
        raw = socket.create_connection((host, port), timeout=10)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        key = os.urandom(16).hex()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Protocol: {subproto}\r\n"
            f"Origin: {origin}\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        self._buf = b""
        status = self._read_handshake()
        if "101" not in status:
            raise RuntimeError(f"WebSocket handshake failed: {status!r}")
        self.sock.settimeout(timeout)

    def _read_handshake(self):
        self.sock.settimeout(10)
        while b"\r\n\r\n" not in self._buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            self._buf += chunk
        head, _, self._buf = self._buf.partition(b"\r\n\r\n")
        return head.split(b"\r\n", 1)[0].decode("latin-1")

    def send(self, text):
        payload = text.encode("utf-8")
        mask = os.urandom(4)
        n = len(payload)
        header = bytearray([0x81])  # FIN + text opcode
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        self.sock.sendall(
            bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        )

    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("connection closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def recv_frame(self):
        """Return (opcode, payload). Raises socket.timeout when idle."""
        b0, b1 = self._recv_exact(2)
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if b1 & 0x80 else None
        payload = self._recv_exact(length) if length else b""
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x9:  # ping -> pong
            self._send_control(0xA, payload)
        return opcode, payload

    def _send_control(self, opcode, payload=b""):
        mask = os.urandom(4)
        header = bytes([0x80 | opcode, 0x80 | len(payload)]) + mask
        self.sock.sendall(
            header + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        )

    def close(self):
        try:
            self._send_control(0x8)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


# The probe script. Markers are obfuscated (PROBE""HEAD renders as PROBEHEAD in
# stdout but not in the echoed keystrokes) and never start with '=' (zsh EQUALS).
PROBE = (
    'echo PROBE""HEAD; '
    "id; "
    'echo "[rootfs]"; touch /usr/local/.probe 2>&1 || echo rootfs_readonly; '
    'echo "[home]"; touch /home/visitor/.probe && echo home_ok; '
    'echo "[resolv]"; cat /etc/resolv.conf; '
    'echo "[metadata]"; timeout 4 bash -c "echo>/dev/tcp/169.254.169.254/80" 2>&1 || echo metadata_blocked; '
    'echo "[kubeapi]"; timeout 4 bash -c "echo>/dev/tcp/10.96.0.1/443" 2>&1 || echo kubeapi_blocked; '
    'echo "[coredns]"; timeout 4 bash -c "echo>/dev/tcp/10.96.0.10/53" 2>&1 || echo coredns_blocked; '
    'echo "[internet]"; timeout 6 bash -c "echo>/dev/tcp/1.1.1.1/443" && echo internet_ok; '
    'echo "[curl]"; timeout 8 curl -sI https://example.com 2>&1 | head -1; '
    'echo "[iptables]"; iptables -F 2>&1 || echo iptables_denied; '
    'echo "[sudo]"; sudo -n id 2>&1 || echo sudo_denied; '
    'echo PROBE""TAIL\n'
)

# (label, needle that must appear in the captured stdout segment).
CHECKS = [
    ("runs as non-root uid 222", "uid=222(visitor)"),
    ("read-only root filesystem", "rootfs_readonly"),
    ("home dir writable", "home_ok"),
    ("public resolvers (no CoreDNS)", "nameserver 1.1.1.1"),
    ("OCI metadata 169.254.169.254 blocked", "metadata_blocked"),
    ("kube API 10.96.0.1 blocked", "kubeapi_blocked"),
    ("CoreDNS 10.96.0.10 blocked", "coredns_blocked"),
    ("public internet reachable", "internet_ok"),
    ("outbound TLS/DNS works (curl)", "200"),
    ("no iptables (rules unflushable)", "iptables_denied"),
    ("no sudo (no escalation)", "sudo_denied"),
]


def run_session(url, settle=3.0, budget=25.0):
    u = urlparse(url)
    host = u.hostname
    port = u.port or (443 if u.scheme == "wss" else 80)
    path = u.path or "/ws"
    origin = f"https://{host}"

    ws = WebSocket(host, port, path, origin, timeout=1.0)
    ws.send('{"AuthToken":""}')  # ttyd handshake: first frame is the auth JSON
    ws.send("1" + '{"columns":140,"rows":45}')  # '1' = RESIZE

    chunks = []

    def pump(deadline, stop=None):
        while time.time() < deadline:
            try:
                opcode, payload = ws.recv_frame()
            except socket.timeout:
                continue
            except Exception:
                break
            if opcode == 0x8:  # server close
                break
            text = payload.decode("utf-8", "replace")
            if text and text[0] == "0":  # '0' = OUTPUT
                chunks.append(text[1:])
                if stop and stop in "".join(chunks):
                    return

    pump(time.time() + settle)          # let the MOTD / prompt settle
    ws.send("0" + PROBE)                 # '0' = INPUT
    pump(time.time() + budget, stop="PROBETAIL")
    ws.close()

    out = ANSI.sub("", "".join(chunks).replace("\r\n", "\n"))
    if "PROBEHEAD" in out and "PROBETAIL" in out:
        out = out.split("PROBEHEAD")[-1].split("PROBETAIL")[0]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="wss://stevegore.au/ws",
                    help="ttyd WebSocket URL (default: %(default)s)")
    ap.add_argument("--show-output", action="store_true",
                    help="print the raw captured shell output")
    args = ap.parse_args()

    print(f"Driving live ttyd session at {args.url} ...\n")
    try:
        out = run_session(args.url)
    except Exception as e:
        print(f"FAILED to run session: {e}", file=sys.stderr)
        return 2

    if args.show_output:
        print("--- captured output ---")
        print("\n".join(l.rstrip() for l in out.splitlines() if l.strip()))
        print("--- end ---\n")

    failures = 0
    for label, needle in CHECKS:
        ok = needle in out
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}")
        if not ok:
            failures += 1

    print()
    if failures:
        print(f"{failures}/{len(CHECKS)} controls FAILED — rerun with --show-output to inspect.")
        return 1
    print(f"All {len(CHECKS)} containment controls verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
