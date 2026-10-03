"""Run garmin-mcp with self-healing Garmin auth.

garminconnect only ever *refreshes* the DI OAuth token. Once Garmin rejects the
refresh token (it does, after a few months -- and the library swallows the
error at DEBUG), every tool call 401s until someone re-mints tokens by hand.
garmin_mcp's own "fall back to email/password" path never fires either:
Garmin.login() with no tokenstore falls back to $GARMINTOKENS, reloads the same
dead file, and fails again.

This wrapper:
  1. patches Client._refresh_di_token so a failed refresh falls back to a full
     credential login (MFA-less accounts only); the caller (_refresh_session)
     then persists the new tokens to the tokenstore as usual;
  2. bootstraps the tokenstore at startup (credential login if it is missing,
     refresh/re-login if it is stale) before handing over to garmin_mcp.main().

Credentials come from GARMIN_EMAIL[_FILE] / GARMIN_PASSWORD[_FILE] -- the same
variables garmin_mcp reads.
"""

import os
import sys
import threading
import time
from pathlib import Path

from garminconnect import Garmin
from garminconnect.client import Client

TOKENSTORE = os.environ.get("GARMINTOKENS") or "~/.garminconnect"
# Don't hammer Garmin SSO (and risk an account lock) if the password is wrong
# or SSO is blocking us: at most one credential login per cooldown window.
RELOGIN_COOLDOWN_SECONDS = 900


def _log(msg):
    print(f"[garmin-mcp-launcher] {msg}", file=sys.stderr, flush=True)


def _credential(name):
    path = os.environ.get(f"{name}_FILE")
    if path:
        return Path(path).read_text().strip()
    return os.environ.get(name)


EMAIL = _credential("GARMIN_EMAIL")
PASSWORD = _credential("GARMIN_PASSWORD")

_relogin_lock = threading.Lock()
_last_relogin = None
_original_refresh_di_token = Client._refresh_di_token


def _refresh_di_token(self):
    global _last_relogin
    try:
        return _original_refresh_di_token(self)
    except Exception as err:
        if not (EMAIL and PASSWORD):
            raise
        with _relogin_lock:
            now = time.monotonic()
            if _last_relogin is not None and now - _last_relogin < RELOGIN_COOLDOWN_SECONDS:
                raise
            _last_relogin = now
            _log(f"DI token refresh failed ({str(err)[:80]}); logging in with credentials")
            try:
                # No prompt_mfa: an MFA challenge raises instead of blocking.
                self.login(EMAIL, PASSWORD)
            except Exception as login_err:
                _log(f"Credential login failed: {login_err}")
                raise
            _log("Credential login succeeded; tokens will be persisted")


Client._refresh_di_token = _refresh_di_token


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
    from garmin_mcp import main

    main()
