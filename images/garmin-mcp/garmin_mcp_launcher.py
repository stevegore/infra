"""Run garmin-mcp with self-healing Garmin auth.

garminconnect only ever *refreshes* the DI OAuth token. Once Garmin rejects the
refresh token (it does, after a few months -- and the library swallows the
error at DEBUG), every tool call 401s until someone re-mints tokens by hand.
garmin_mcp's own "fall back to email/password" path never fires either:
Garmin.login() with no tokenstore falls back to $GARMINTOKENS, reloads the same
dead file, and fails again.

This wrapper:
  1. keeps the refresh token alive: a background thread refreshes the live
     client every KEEPALIVE_SECONDS (the token rotates on each use and died
     after ~3 idle months, 2026-07 -> 2026-10);
  2. patches Client._refresh_di_token so a failed refresh falls back to a full
     credential login; the caller (_refresh_session) persists the new tokens;
  3. bootstraps the tokenstore at startup before handing over to
     garmin_mcp.main().

Garmin may answer a credential login from the cluster with an MFA challenge
even on an MFA-less account (seen 2026-10-04). Credential attempts are
therefore rate-limited via a state file on the PVC, so a crash-looping pod
cannot spam logins/verification emails: 15 min between attempts, 24 h after an
MFA challenge.

Credentials come from GARMIN_EMAIL[_FILE] / GARMIN_PASSWORD[_FILE] -- the same
variables garmin_mcp reads.
"""

import json
import os
import sys
import threading
import time
import weakref
from pathlib import Path

from garminconnect import Garmin
from garminconnect.client import Client

TOKENSTORE = os.environ.get("GARMINTOKENS") or "~/.garminconnect"
TOKEN_DIR = Path(TOKENSTORE).expanduser()
RELOGIN_STATE = TOKEN_DIR / ".credential_login_state.json"
RELOGIN_COOLDOWN_SECONDS = 900
MFA_CHALLENGE_COOLDOWN_SECONDS = 24 * 3600
# DI access tokens last ~19 h; refresh well inside that.
KEEPALIVE_SECONDS = 12 * 3600


def _log(msg):
    print(f"[garmin-mcp-launcher] {msg}", file=sys.stderr, flush=True)


def _credential(name):
    path = os.environ.get(f"{name}_FILE")
    if path:
        return Path(path).read_text().strip()
    return os.environ.get(name)


EMAIL = _credential("GARMIN_EMAIL")
PASSWORD = _credential("GARMIN_PASSWORD")

# Serialises refreshes: the refresh token rotates on every use, so the
# keepalive thread and a request thread must not race on it.
_refresh_lock = threading.RLock()
_original_refresh_di_token = Client._refresh_di_token
_original_load = Client.load
_clients = weakref.WeakSet()


def _read_state():
    try:
        return json.loads(RELOGIN_STATE.read_text())
    except Exception:
        return {}


def _credential_login_allowed():
    state = _read_state()
    wait = MFA_CHALLENGE_COOLDOWN_SECONDS if state.get("mfa_challenged") else RELOGIN_COOLDOWN_SECONDS
    remaining = state.get("last_attempt", 0) + wait - time.time()
    if remaining > 0:
        _log(f"Credential login suppressed for another {int(remaining)}s ({RELOGIN_STATE})")
        return False
    return True


def _record_attempt(mfa_challenged):
    try:
        TOKEN_DIR.mkdir(parents=True, exist_ok=True)
        RELOGIN_STATE.write_text(json.dumps({"last_attempt": time.time(), "mfa_challenged": mfa_challenged}))
    except Exception as err:
        _log(f"Could not record login attempt: {err}")


def _refresh_di_token(self):
    with _refresh_lock:
        try:
            return _original_refresh_di_token(self)
        except Exception as err:
            if not (EMAIL and PASSWORD) or not _credential_login_allowed():
                raise
            _log(f"DI token refresh failed ({str(err)[:80]}); logging in with credentials")
            try:
                # No prompt_mfa: an MFA challenge raises instead of blocking.
                self.login(EMAIL, PASSWORD)
            except Exception as login_err:
                challenged = "MFA" in str(login_err)
                _record_attempt(mfa_challenged=challenged)
                _log(f"Credential login failed: {login_err}")
                if challenged:
                    _log("Garmin wants MFA: re-mint tokens with garmin-mcp-auth (README.md)")
                raise
            _record_attempt(mfa_challenged=False)
            _log("Credential login succeeded; tokens will be persisted")


def _load(self, path):
    _original_load(self, path)
    _clients.add(self)


Client._refresh_di_token = _refresh_di_token
Client.load = _load


def _keepalive():
    while True:
        time.sleep(KEEPALIVE_SECONDS)
        # Refresh the client(s) garmin_mcp is actually serving from, so its
        # in-memory refresh token stays the current one.
        for client in list(_clients):
            if not client.di_token:
                continue
            with _refresh_lock:
                before = client.di_token
                client._refresh_session()  # persists to the tokenstore on success
                ok = client.di_token != before
            _log("Keepalive refresh " + ("OK" if ok else "FAILED"))


def _bootstrap():
    """Make sure the tokenstore holds working tokens before garmin_mcp loads it."""
    if not (EMAIL and PASSWORD):
        _log("No GARMIN_EMAIL/GARMIN_PASSWORD; running on stored tokens only")
        return
    try:
        # Missing file -> credential login + dump; stale file -> refresh, which
        # falls back to a credential login via the patch above.
        Garmin(email=EMAIL, password=PASSWORD).login(TOKENSTORE)
        _log("Garmin auth OK")
    except Exception as err:
        _log(f"Startup auth failed: {err}")


if __name__ == "__main__":
    _bootstrap()
    _clients.clear()  # only keep garmin_mcp's own client alive
    threading.Thread(target=_keepalive, name="garmin-keepalive", daemon=True).start()
    from garmin_mcp import main

    main()
