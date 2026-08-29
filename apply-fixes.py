#!/usr/bin/env python3
"""Apply security review fixes to bridge.py and Widget.qml.

Run from the repo root: python3 apply-fixes.py
"""
import re
import sys

def patch_file(path, patches):
    with open(path) as f:
        content = f.read()

    for label, old, new in patches:
        if old not in content:
            print(f"  WARN: '{label}' — pattern not found, skipping")
            continue
        content = content.replace(old, new, 1)
        print(f"  OK: {label}")

    with open(path, 'w') as f:
        f.write(content)
    print(f"  => {path} written ({len(content)} chars)")


# ── bridge.py patches ──
bridge_patches = [
    ("add hashlib import",
     "import hmac",
     "import hashlib\nimport hmac"),

    ("add SAFE_SESSION_ID regex",
     'SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$")\n',
     'SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$")\nSAFE_SESSION_ID = re.compile(r"^[a-zA-Z0-9_]+$")\n'),

    ("replace _authed() to always check",
     '''    def _authed(self):
        if not TOKEN:
            return True
        hdr = self.headers.get("Authorization", "")
        alt = self.headers.get("X-Hermes-Widget-Token", "")
        legacy_alt = self.headers.get("X-Echo-Token", "")
        return (
            hmac.compare_digest(hdr, f"Bearer {TOKEN}")
            or hmac.compare_digest(alt, TOKEN)
            or hmac.compare_digest(legacy_alt, TOKEN)
        )''',
     '''    def _authed(self):
        """All requests must carry the effective token.

        The one exception is ``GET /token`` which is how the widget
        bootstraps its local-mode authentication.
        """
        path = self.path.split("?")[0]
        if self.command == "GET" and path == "/token":
            return True
        hdr = self.headers.get("Authorization", "")
        alt = self.headers.get("X-Hermes-Widget-Token", "")
        legacy_alt = self.headers.get("X-Echo-Token", "")
        return (
            hmac.compare_digest(hdr, f"Bearer {_EFFECTIVE_TOKEN}")
            or hmac.compare_digest(alt, _EFFECTIVE_TOKEN)
            or hmac.compare_digest(legacy_alt, _EFFECTIVE_TOKEN)
        )'''),

    ("validate session_id in _ChatClient.query",
     '''            for line in out.splitlines():
                match = re.match(r"^session_id:\\s*(\\S+)", line.strip())
                if match:
                    sid = match.group(1)
                    self._session_id = sid
                    break''',
     '''            for line in out.splitlines():
                match = re.match(r"^session_id:\\s*(\\S+)", line.strip())
                if match and SAFE_SESSION_ID.match(match.group(1)):
                    sid = match.group(1)
                    self._session_id = sid
                    break'''),

    ("add Content-Type check to do_POST",
     '''    def do_POST(self):
        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)
        path = self.path.split("?")[0]''',
     '''    def do_POST(self):
        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)
        ct = (self.headers.get("Content-Type", "") or "").split(";")[0].strip()
        if ct and ct != "application/json":
            return self._json({"error": "unsupported content type"}, 415)
        path = self.path.split("?")[0]'''),

    ("add /token GET endpoint",
     '''        if path == "/session":
            return self._json({"session_id": _CHAT.session_id or ""})

        return self._json({''',
     '''        if path == "/session":
            return self._json({"session_id": _CHAT.session_id or ""})

        if path == "/token":
            return self._json({"token": _EFFECTIVE_TOKEN})

        return self._json({'''),
]

print("=== bridge.py ===")
patch_file("bridge.py", bridge_patches)


# ── Widget.qml patches ──
widget_patches = [
    ("add safeSessionId function",
     '''  function shortTime(iso) {
    var m = String(iso || "").match(/T(\\d\\d):(\\d\\d)/)
    return m ? m[1] + ":" + m[2] : ""
  }

  function fetchJson(url, onSuccess, onError, method, body) {''',
     '''  function shortTime(iso) {
    var m = String(iso || "").match(/T(\\d\\d):(\\d\\d)/)
    return m ? m[1] + ":" + m[2] : ""
  }

  function safeSessionId(val) {
    return String(val || "").replace(/[^a-zA-Z0-9_]/g, "")
  }

  function fetchLocalToken() {
    if (!root.localMode() || root.bridgeToken()) return
    root.fetchJson("http://localhost:8643/token", function(resp) {
      if (resp && resp.token) root.saveSetting("bridgeToken", resp.token)
    }, function() {}, "GET")
  }

  function fetchJson(url, onSuccess, onError, method, body) {'''),

    ("remove root.localMode() guard from token header",
     '''      var token = root.localMode() ? "" : root.bridgeToken()''',
     '''      var token = root.bridgeToken()'''),

    ("add safeSessionId to >_ button",
     '''              root.fetchJson(url + "/session", function(resp) {
                var sid = resp.session_id
                if (!sid) return
                if (root.localMode()) {''',
     '''              root.fetchJson(url + "/session", function(resp) {
                var raw = resp.session_id || ""
                var sid = root.safeSessionId(raw)
                if (!sid || sid !== raw) return
                if (root.localMode()) {'''),

    ("add fetchLocalToken to Component.onCompleted",
     '''  Component.onCompleted: {
    root.fetchFromBridge()
    startupRetry.start()''',
     '''  Component.onCompleted: {
    root.fetchFromBridge()
    if (root.localMode()) root.fetchLocalToken()
    startupRetry.start()'''),

    ("add fetchLocalToken retry to startupRetry",
     '''    onTriggered: {
      if (!root.stats || !root.api || !root.api.ok) root.fetchFromBridge()
    }''',
     '''    onTriggered: {
      if (!root.stats || !root.api || !root.api.ok) root.fetchFromBridge()
      if (root.localMode() && !root.bridgeToken()) root.fetchLocalToken()
    }'''),
]

print("\n=== Widget.qml ===")
patch_file("Widget.qml", widget_patches)

print("\nDone. Verify with: git diff --stat")