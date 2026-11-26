"""List the accounts saved for a site WITHOUT reading any password.

Used by the apple-passwords zsh plugin with the apwcli backend: Apple's helper can answer a
"ghost search" (names only), so a picker can be shown before a single password is fetched.
Runs on apwcli's own Python (it imports apwlib). Prints apwcli-style JSON; exits with the
protocol status. Never pairs on its own (no hidden prompts) — unpaired exits 9.

usage: python apwz-accounts.py <site>
"""

import json
import sys

from apwlib import ApplePasswords, ApwError
from apwlib import _protocol as protocol


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1]:
        print(json.dumps({"error": "usage: apwz-accounts.py <site>", "status": 2, "results": []}), file=sys.stderr)
        return 2
    url = sys.argv[1]
    message = {
        "cmd": 4,  # GET_LOGIN_NAMES_FOR_URL
        "qid": "CmdGetLoginNames4URL",
        "tabId": 1,
        "frameId": 1,
        "url": url,
        "body": {"ACT": protocol.Action.GHOST_SEARCH, "URL": url},
    }
    try:
        raw = ApplePasswords(auto_start=False)._payload(message)
    except ApwError as exc:
        print(json.dumps({"error": str(exc), "status": int(exc.status), "results": []}), file=sys.stderr)
        return int(exc.status)
    results = []
    for entry in raw:
        sites = entry.get("sites") or []
        results.append({"username": entry.get("USR", ""), "domain": sites[0] if sites else "", "sites": sites})
    print(json.dumps({"results": results, "status": 0}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
