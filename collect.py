#!/usr/bin/env python3
"""Relay for the Echo usage bridge. Fetches usage data from a Hermes agent
and writes it to stats.json for the echo.model widget, and to the
built-in Omarchy Agents tab.

The bridge URL is read from the widget's settings in shell.json, or
falls back to the ECHO_BRIDGE_BASE environment variable, or to
http://localhost:8643.
"""
import json
import os
import time
import urllib.request

HOME = os.path.expanduser("~")
STATE_ROOT = os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local", "state"))
OUT_DIR = os.path.join(STATE_ROOT, "echo-model")
OUT = os.path.join(OUT_DIR, "stats.json")
AGENTS_USAGE = os.path.join(STATE_ROOT, "omarchy", "agents", "usage")
BRIDGE = os.environ.get("ECHO_BRIDGE_BASE", "http://localhost:8643")
TIMEOUT = 10


def fetch(path):
    req = urllib.request.Request(BRIDGE + path)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def money(v):
    try:
        return round(float(v), 4)
    except (TypeError, ValueError):
        return 0.0


def int0(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def atomic_dump(obj, dest):
    tmp = dest + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh)
    os.replace(tmp, dest)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(AGENTS_USAGE, exist_ok=True)
    try:
        rec = fetch("/hermes.json")
        models = fetch("/models")
        ok = True
    except Exception:
        rec, models, ok = {}, {}, False

    bal = rec.get("balance") or {}
    remaining = money(bal.get("remaining"))
    funded = money(bal.get("funded"))
    used = money(bal.get("spent"))
    current = models.get("current", "") if isinstance(models, dict) else ""

    by_model = []
    for model, m in (rec.get("modelUsage") or {}).items():
        inp = int0(m.get("inputTokens"))
        out = int0(m.get("outputTokens"))
        cache = int0(m.get("cacheReadInputTokens"))
        by_model.append({
            "model": model,
            "tokens": inp + out + cache,
            "input": inp,
            "output": out,
            "cache": cache,
            "cost": money(m.get("cost")),
        })
    by_model.sort(key=lambda r: -r["tokens"])

    by_day = [{
        "date": d.get("date", ""),
        "tokens": int0(d.get("messageCount")),
        "cost": money(d.get("cost")),
        "costExact": bool(d.get("costExact")),
    } for d in (rec.get("recentDays") or [])]

    all_time = int0((rec.get("echo") or {}).get("tokensAllTime"))
    today_tokens = int0(rec.get("todayTotalTokens"))
    ech = rec.get("echo") or {}
    cost_today = money(ech.get("costToday"))
    cost_week = money(ech.get("costWeek"))
    cost_all = money(ech.get("costAllTime"))
    tokens30 = int0(ech.get("tokens30"))
    cost30 = money(ech.get("cost30"))

    stats = {
        "schemaVersion": 1,
        "updated": iso_now(),
        "api": {
            "configured": True,
            "ok": ok,
            "total": funded,
            "used": used,
            "remaining": remaining,
            "keyUsage": None,
            "keyCount": 1,
            "keyUsageComplete": False,
        },
        "hermes": {
            "home": "remote://192.168.2.41",
            "db": BRIDGE + "/hermes.json",
            "config": "model.default via POST /model",
            "model": current,
            "provider": str(ech.get("provider") or "deepseek"),
            "profileCount": 1,
            "profiles": ["remote"],
        },
        "usage": {
            "today": {"tokens": today_tokens, "cost": cost_today, "calls": int0(rec.get("todayPrompts"))},
            "week": {"tokens": sum(d["tokens"] for d in by_day), "cost": cost_week, "calls": 0},
            "month30": {"tokens": tokens30, "cost": cost30, "calls": 0},
            "allTime": {"tokens": all_time, "cost": cost_all, "calls": 0},
            "byDay": by_day,
            "byModel": by_model,
            "recentSessions": [],
        },
        "models": [
            {
                "id": m["id"],
                "name": m.get("name", m["id"]),
                "provider": m.get("provider", ""),
                "context": 0,
                "prompt": "",
                "completion": "",
            }
            for m in (models.get("models") or [])
            if isinstance(m, dict) and m.get("id")
        ],
    }
    atomic_dump(stats, OUT)

    # Pass the agents record through so the built-in Agents tab keeps working
    # even without the separate fetch timer.
    if rec:
        atomic_dump(rec, os.path.join(AGENTS_USAGE, "hermes.json"))


if __name__ == "__main__":
    main()
