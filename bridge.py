#!/usr/bin/env python3
"""Hermes Agent Widget Bridge — serves usage and provider balances to the
Hermes Agent Omarchy bar widget.

GET /hermes.json  -> usage record (balance, model usage, daily breakdown)
GET /models       -> available models + current model
GET /health       -> {"ok": true, "model": ..., "provider": ...}
POST /model       -> switch model
GET /             -> endpoint index

All endpoints require HERMES_WIDGET_TOKEN when the bridge is network-reachable.
Loopback-only Local mode does not require a token.

Reads:
  ~/.hermes/state.db    (session_model_usage, read-only)
  ~/.hermes/config.yaml (current model)

State files (balance tracking, OpenRouter pricing cache):
  ~/.local/state/hermes-agent-widget/

Auto-started by the Hermes Agent Widget via QML Process.
"""

import hmac
import json
import os
import re
import sqlite3
import subprocess
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
STATE_ROOT = os.environ.get("XDG_STATE_HOME", os.path.join(HOME, ".local", "state"))
STATE_DIR = os.path.join(STATE_ROOT, "hermes-agent-widget")
DB = os.path.join(HOME, ".hermes", "state.db")
CFG = os.path.join(HOME, ".hermes", "config.yaml")
DEEPSEEK_SQL = "billing_base_url LIKE '%deepseek.com%'"
ALL_SQL = "1=1"
# ECHO_USAGE_* remains accepted for a transition from pre-marketplace builds.
HOST = os.environ.get(
    "HERMES_WIDGET_HOST", os.environ.get("ECHO_USAGE_HOST", "127.0.0.1")
).strip() or "127.0.0.1"
TOKEN = os.environ.get("HERMES_WIDGET_TOKEN", os.environ.get("ECHO_USAGE_TOKEN", ""))
PORT = int(os.environ.get("HERMES_WIDGET_PORT", os.environ.get("ECHO_USAGE_PORT", "8643")))
MAX_REQUEST_BYTES = 64 * 1024


def validate_bind_security(host, token):
    """Refuse network-reachable listeners that have no access token."""
    if host not in {"127.0.0.1", "localhost", "::1"} and not token:
        raise ValueError("Refusing non-loopback bridge bind without HERMES_WIDGET_TOKEN")

# Curated switchable models (same provider/base_url — DeepSeek family).
# Cross-provider switching (qwen via OpenRouter etc.) is a later extension.
MODELS = [
    # DeepSeek direct
    {"id": "deepseek-v4-flash", "name": "DeepSeek V4 Flash", "provider": "deepseek"},
    {"id": "deepseek-v4-flash-vision-exp", "name": "DeepSeek V4 Flash Vision (experimental)", "provider": "deepseek"},
    {"id": "deepseek-chat", "name": "DeepSeek Chat", "provider": "deepseek"},
    {"id": "deepseek-reasoner", "name": "DeepSeek Reasoner", "provider": "deepseek"},
    # OpenRouter (routed; ids as OpenRouter lists them)
    {"id": "deepseek/deepseek-v4-flash", "name": "DeepSeek V4 Flash (via OpenRouter)", "provider": "openrouter"},
    {"id": "deepseek/deepseek-v4-flash-vision-exp", "name": "DeepSeek V4 Flash Vision (via OpenRouter)", "provider": "openrouter"},
    {"id": "qwen/qwen3.7-flash", "name": "Qwen 3.7 Flash (via OpenRouter)", "provider": "openrouter"},
    {"id": "anthropic/claude-haiku-4.5", "name": "Claude Haiku 4.5 (via OpenRouter)", "provider": "openrouter"},
    {"id": "google/gemini-2.5-flash", "name": "Gemini 2.5 Flash (via OpenRouter)", "provider": "openrouter"},
]
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}$")

# Provider registry: sql scope, balance fetcher, ledger state file, pricing
# kind, display label, and the base_url the model switcher writes.
OR_CACHE_FILE = os.path.join(STATE_DIR, "or_models.json")
OR_CACHE_MAX_AGE = 86400  # refresh the pricing catalogue daily

PROVIDER_CONFIGS = {
    "deepseek": {
        "sql": "billing_base_url LIKE '%deepseek.com%'",
        "state_file": os.path.join(STATE_DIR, "balance_epoch.json"),
        "pricing": "hardcoded",
        "label": "DeepSeek",
        "base_url": "https://api.deepseek.com/v1",
    },
    "openrouter": {
        "sql": "billing_base_url LIKE '%openrouter.ai%'",
        "state_file": os.path.join(STATE_DIR, "balance_epoch.openrouter.json"),
        "pricing": "catalogue",
        "label": "OpenRouter",
        "base_url": "https://openrouter.ai/api/v1",
    },
}


def provider_label(provider):
    cfg = PROVIDER_CONFIGS.get(provider)
    return cfg["label"] if cfg else (provider or "Unknown").title()


def provider_sql(provider):
    cfg = PROVIDER_CONFIGS.get(provider)
    return cfg["sql"] if cfg else ALL_SQL


# ---------------------------------------------------------------- helpers


def int0(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return 0


def money(v):
    try:
        return round(float(v), 4)
    except (TypeError, ValueError):
        return 0.0


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def db_rows(sql, params=()):
    if not os.path.isfile(DB):
        return []
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=3)
        con.row_factory = sqlite3.Row
        rows = [dict(r) for r in con.execute(sql, params)]
        con.close()
        return rows
    except sqlite3.Error:
        return []


def current_model():
    """(model_id, provider) parsed from config.yaml's top-level model section."""
    try:
        with open(CFG) as fh:
            lines = fh.read().splitlines()
    except OSError:
        return "", ""
    model, provider, in_model = "", "", False
    for line in lines:
        if re.match(r"^model\s*:", line):
            in_model = True
            continue
        if in_model:
            if line and line[0] not in " \t":
                break  # left the model block
            m = re.match(r"^\s*(default|provider)\s*:\s*([^\s#]+)", line)
            if m:
                value = m.group(2).strip("'\"")
                if m.group(1) == "default":
                    model = value
                else:
                    provider = value
    return model, provider


def dashboard_port(cfg=CFG):
    """Read the Hermes dashboard port from config.yaml."""
    try:
        with open(cfg) as fh:
            lines = fh.read().splitlines()
    except OSError:
        return 9119
    port = 9119
    in_dash = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if re.match(r"^dashboard\s*:", line):
            in_dash = True
            continue
        if in_dash:
            # A line that starts at column 0 (no leading whitespace) ends the section
            if line and line[0] not in " \t":
                break
            m = re.match(r"^\s*port\s*:\s*(.+)$", line)
            if m:
                val = m.group(1).strip().strip("'\"")
                # Strip trailing comments (YAML allows "# comment" after a value)
                hash_idx = val.find(" #")
                if hash_idx >= 0:
                    val = val[:hash_idx].strip()
                try:
                    port = int(val)
                except ValueError:
                    pass
    return port


def set_model(model_id, cfg=CFG):
    """Switch model.default + provider + base_url in config.yaml (atomic)."""
    if not SAFE_ID.match(model_id):
        return None, "invalid model id"
    entry = next((m for m in MODELS if m["id"] == model_id), None)
    if entry is None:
        return None, "unknown model"
    provider = entry["provider"]
    pcfg = PROVIDER_CONFIGS.get(provider)
    if pcfg is None:
        return None, "unknown provider"
    base_url = pcfg["base_url"]
    try:
        with open(cfg) as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        return None, f"cannot read config: {exc}"
    out, in_model, model_idx = [], False, -1
    rewrote = {"default": False, "provider": False, "base_url": False}
    for line in lines:
        if re.match(r"^model\s*:", line):
            in_model = True
            model_idx = len(out)
        elif in_model and line and line[0] not in " \t":
            in_model = False
        if in_model:
            m = re.match(r"^  (default|provider|base_url)(\s*:\s*)[^\s#]+(\s*(?:#.*)?)$", line)
            if m:
                key = m.group(1)
                value = model_id if key == "default" else (provider if key == "provider" else base_url)
                line = f"  {key}{m.group(2)}{value}{m.group(3)}"
                rewrote[key] = True
        out.append(line)
    missing = [k for k in ("default", "provider", "base_url") if not rewrote[k]]
    if missing and model_idx < 0:
        return None, "model block not found in config.yaml"
    for key in reversed(missing):
        value = model_id if key == "default" else (provider if key == "provider" else base_url)
        out.insert(model_idx + 1, f"  {key}: {value}")
    tmp = cfg + ".tmp"
    try:
        with open(tmp, "w") as fh:
            fh.write("\n".join(out) + "\n")
        os.replace(tmp, cfg)
    except OSError as exc:
        return None, f"cannot write config: {exc}"
    return entry, None


_balance_cache = {"at": 0.0, "data": None}

# DeepSeek pricing, USD per 1M tokens (deepseek-v4-flash family) — from
# https://api-docs.deepseek.com/quick_start/pricing (fetched 2026-08-25).
P_IN_MISS_PEAK, P_IN_MISS_OFF = 0.44, 0.22
P_IN_HIT_PEAK, P_IN_HIT_OFF = 0.014, 0.007
P_OUT_PEAK, P_OUT_OFF = 1.32, 0.66


def _is_peak(ts_unix):
    t = time.gmtime(int0(ts_unix))
    if t.tm_wday > 4:  # Sat/Sun
        return False
    return (1 <= t.tm_hour <= 4) or (6 <= t.tm_hour <= 10)


def row_cost(inp, cache_hit, out, reas, peak):
    if peak:
        return (inp * P_IN_MISS_PEAK + cache_hit * P_IN_HIT_PEAK
                + (out + reas) * P_OUT_PEAK) / 1e6
    return (inp * P_IN_MISS_OFF + cache_hit * P_IN_HIT_OFF
            + (out + reas) * P_OUT_OFF) / 1e6


def estimated_costs(where, days=None, provider="deepseek"):
    """({date: est_cost}, {model: est_cost}, total_est) over the window."""
    sql = (
        "SELECT first_seen, model, input_tokens AS inp, cache_read_tokens AS ch, "
        "output_tokens AS out, reasoning_tokens AS reas "
        f"FROM session_model_usage WHERE {where}"
    )
    params = ()
    if days:
        sql += " AND first_seen >= strftime('%s','now',?)"
        params = (f"-{days} days",)
    prices = openrouter_prices() if provider == "openrouter" else None
    by_day, by_model, total = {}, {}, 0.0
    for r in db_rows(sql, params):
        inp = int0(r.get("inp"))
        ch = int0(r.get("ch"))
        out = int0(r.get("out"))
        reas = int0(r.get("reas"))
        if prices is not None:
            p = prices.get(r.get("model") or "")
            if not p:
                continue
            c = inp * p["prompt"] + ch * p["cache_read"] + (out + reas) * p["completion"]
        else:
            c = row_cost(inp, ch, out, reas, _is_peak(r.get("first_seen")))
        day = time.strftime("%Y-%m-%d", time.localtime(int0(r.get("first_seen"))))
        by_day[day] = by_day.get(day, 0.0) + c
        m = r.get("model") or ""
        by_model[m] = by_model.get(m, 0.0) + c
        total += c
    return by_day, by_model, total


def deepseek_balance():
    """(remaining, funded, granted) or None. 60s cache. Never logs the key."""
    now = time.time()
    if now - _balance_cache["at"] < 60 and _balance_cache["data"] is not None:
        return _balance_cache["data"]
    key = ""
    env_path = os.path.join(HOME, ".hermes", ".env")
    try:
        with open(env_path) as fh:
            for line in fh:
                if line.strip().startswith("DEEPSEEK_API_KEY="):
                    key = line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    if not key:
        return None
    try:
        req = urllib.request.Request(
            "https://api.deepseek.com/user/balance",
            headers={"Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        total = float(data.get("total_balance", 0))
        for info in data.get("balance_infos", []):
            if str(info.get("currency", "")).upper() == "USD":
                total = float(info.get("total_balance", total))
                break
        result = {
            "remaining": round(total, 2),
            "funded": round(total, 2),
            "spent": 0.0,
            "currency": "USD",
            "estimated": False,
        }
        _balance_cache.update(at=now, data=result)
        return result
    except Exception:
        return None


def _env_key(name):
    """Read an API key from ~/.hermes/.env (never logs it)."""
    env_path = os.path.join(HOME, ".hermes", ".env")
    try:
        with open(env_path) as fh:
            for line in fh:
                if line.strip().startswith(name + "="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


_or_balance_cache = {"at": 0.0, "data": None}


def openrouter_balance():
    """(funded, spent, remaining) from /credits — exact, 60s cache."""
    now = time.time()
    if now - _or_balance_cache["at"] < 60 and _or_balance_cache["data"] is not None:
        return _or_balance_cache["data"]
    key = _env_key("OPENROUTER_API_KEY")
    if not key:
        return None
    try:
        req = urllib.request.Request(
            "https://openrouter.ai/api/v1/credits",
            headers={"Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode()).get("data", {})
        total_credits = float(data.get("total_credits", 0))
        total_usage = float(data.get("total_usage", 0))
        result = {
            "remaining": round(max(0.0, total_credits - total_usage), 2),
            "funded": round(total_credits, 2),
            "spent": round(total_usage, 2),
            "currency": "USD",
            "estimated": False,
        }
        _or_balance_cache.update(at=now, data=result)
        return result
    except Exception:
        return None


def openrouter_prices():
    """{model_id: {...}} pricing from /models catalogue, cached 24h on disk."""
    cache = {}
    try:
        with open(OR_CACHE_FILE) as fh:
            cache = json.load(fh)
    except (OSError, ValueError):
        pass
    if (cache.get("fetched") or 0) < time.time() - OR_CACHE_MAX_AGE:
        key = _env_key("OPENROUTER_API_KEY")
        try:
            req = urllib.request.Request(
                "https://openrouter.ai/api/v1/models",
                headers={"Authorization": f"Bearer {key}"} if key else {},
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode()).get("data", [])
            prices = {}
            for m in data:
                p = m.get("pricing") or {}
                mid = m.get("id", "")
                if not mid:
                    continue
                prices[mid] = {
                    "prompt": float(p.get("prompt") or 0),
                    "cache_read": float(p.get("input_cache_read") or 0),
                    "completion": float(p.get("completion") or 0),
                }
            cache = {"fetched": time.time(), "prices": prices}
            tmp = OR_CACHE_FILE + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(cache, fh)
            os.replace(tmp, OR_CACHE_FILE)
        except Exception:
            pass  # keep serving the stale cache
    return cache.get("prices", {})


def provider_ledger(provider):
    """Uniform ledger dict per provider: funded/remaining/spent + day snapshots."""
    if provider == "openrouter":
        return _openrouter_ledger()
    return _deepseek_ledger()


def _load_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save_state(path, state):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, path)
    except OSError:
        pass


def _deepseek_ledger():
    bal = deepseek_balance()
    if bal is None:
        return None
    remaining = float(bal["remaining"])
    path = PROVIDER_CONFIGS["deepseek"]["state_file"]
    state = _load_state(path)
    funded = float(state.get("funded", 0) or 0)
    last = state.get("last_remaining")
    if last is not None:
        delta = remaining - float(last)
        if delta > 0:
            funded += delta
    else:
        funded = max(funded, remaining)
    days = dict(state.get("days") or {})
    today = time.strftime("%Y-%m-%d", time.localtime())
    last_day = state.get("last_day")
    if last_day is not None and today != last_day:
        days[today] = remaining
    state.update(funded=funded, last_remaining=remaining, last_day=today, days=days)
    _save_state(path, state)
    return {
        "funded": funded,
        "remaining": remaining,
        "spent": max(0.0, funded - remaining),
        "days": days,
        "today": today,
        "spent_ascending": False,
    }


def _openrouter_ledger():
    bal = openrouter_balance()
    if bal is None:
        return None
    usage = float(bal["spent"])
    path = PROVIDER_CONFIGS["openrouter"]["state_file"]
    state = _load_state(path)
    days = dict(state.get("days") or {})
    today = time.strftime("%Y-%m-%d", time.localtime())
    last_day = state.get("last_day")
    if last_day is not None and today != last_day:
        days[today] = usage
    state.update(last_day=today, days=days)
    _save_state(path, state)
    return {
        "funded": bal["funded"],
        "remaining": bal["remaining"],
        "spent": bal["spent"],
        "days": days,
        "today": today,
        "spent_ascending": True,
    }


def _day_exact_cost(d, days, current, today, spent_ascending=False):
    if not days or d not in days:
        return None
    ts = time.mktime(time.strptime(d, "%Y-%m-%d"))
    nd = time.strftime("%Y-%m-%d", time.localtime(ts + 86400))
    if nd in days:
        delta = days[nd] - days[d] if spent_ascending else days[d] - days[nd]
        return max(0.0, delta)
    if d == today:
        delta = current - days[d] if spent_ascending else days[d] - current
        return max(0.0, delta)
    return None


# ------------------------------------------------------------- usage build


def usage_rows(where, days_sql=None, days_param=None):
    """Aggregate rows: total tokens/cost/calls, per-day, per-model."""
    base = (
        "SELECT SUM(input_tokens) AS inp, SUM(output_tokens) AS out, "
        "SUM(cache_read_tokens) AS cache, SUM(estimated_cost_usd) AS cost, "
        "COUNT(*) AS calls "
        f"FROM session_model_usage WHERE {where}"
    )
    totals = {"inp": 0, "out": 0, "cache": 0, "cost": 0.0, "calls": 0}
    for row in db_rows(base):
        for k in totals:
            if k == "cost":
                totals[k] += float(row.get(k) or 0)
            else:
                totals[k] += int0(row.get(k))
    by_day = []
    now = time.time()
    for i in range(6, -1, -1):
        day = time.strftime("%Y-%m-%d", time.localtime(now - i * 86400))
        rows = db_rows(
            "SELECT SUM(input_tokens) AS inp, SUM(output_tokens) AS out, "
            "SUM(cache_read_tokens) AS cache, SUM(estimated_cost_usd) AS cost "
            f"FROM session_model_usage WHERE {where} AND "
            "date(first_seen,'unixepoch','localtime') = ?",
            (day,),
        )
        r = rows[0] if rows else {}
        toks = int0(r.get("inp")) + int0(r.get("out")) + int0(r.get("cache"))
        by_day.append({"date": day, "tokens": toks, "cost": money(r.get("cost"))})
    by_model = {}
    for row in db_rows(
        "SELECT model AS model, SUM(input_tokens) AS inp, SUM(output_tokens) AS out, "
        "SUM(cache_read_tokens) AS cache, SUM(estimated_cost_usd) AS cost "
        f"FROM session_model_usage WHERE {where} AND "
        "first_seen >= strftime('%s','now','-30 days') GROUP BY model",
    ):
        toks = int0(row.get("inp")) + int0(row.get("out")) + int0(row.get("cache"))
        if toks == 0 and money(row.get("cost")) == 0:
            continue
        by_model[row["model"]] = {
            "input": int0(row.get("inp")),
            "output": int0(row.get("out")),
            "cache": int0(row.get("cache")),
            "tokens": toks,
            "cost": money(row.get("cost")),
        }
    return totals, by_day, by_model


def build_record():
    model_id, provider = current_model()
    where = provider_sql(provider)
    label = provider_label(provider)
    totals, by_day, by_model = usage_rows(where)
    today = by_day[-1] if by_day else {"tokens": 0}
    est_day, est_model, _ = estimated_costs(where, 30, provider)
    _, _, est_all = estimated_costs(where, None, provider)

    ledger = provider_ledger(provider)
    if ledger is not None:
        funded, remaining, spent = ledger["funded"], ledger["remaining"], ledger["spent"]
        days, today_s = ledger["days"], ledger["today"]
        spent_ascending = ledger.get("spent_ascending", False)
        balance = {
            "remaining": round(remaining, 2),
            "funded": round(funded, 2),
            "spent": round(spent, 2),
            "currency": "USD",
            "estimated": False,
        }
        current = spent if spent_ascending else remaining
    else:
        # Unknown provider — show usage data without balance
        balance = None
        days, today_s = {}, time.strftime("%Y-%m-%d", time.localtime())
        spent_ascending = False
        current = 0.0

    now = time.time()
    series = []
    exact_days30 = 0
    for i in range(29, -1, -1):
        day = time.strftime("%Y-%m-%d", time.localtime(now - i * 86400))
        exact = _day_exact_cost(day, days, current, today_s, spent_ascending)
        if exact is not None:
            series.append({"date": day, "cost": round(exact, 4), "exact": True})
            exact_days30 += 1
        else:
            series.append({"date": day, "cost": money(est_day.get(day, 0.0)), "exact": False})
    cost_by_date = {s["date"]: s for s in series}

    for d in by_day:
        s = cost_by_date.get(d["date"])
        if s is not None:
            d["cost"] = s["cost"]
            d["costExact"] = s["exact"]
        else:
            d["costExact"] = False

    tokens30_rows = db_rows(
        "SELECT SUM(input_tokens) AS inp, SUM(output_tokens) AS out, SUM(cache_read_tokens) AS cache "
        f"FROM session_model_usage WHERE {where} "
        "AND first_seen >= strftime('%s','now','-30 days')"
    )
    tokens30 = 0
    if tokens30_rows:
        r = tokens30_rows[0]
        tokens30 = int0(r.get("inp")) + int0(r.get("out")) + int0(r.get("cache"))
    cost30 = round(sum(s["cost"] for s in series), 4)

    limits = []
    if balance and float(balance.get("funded") or 0) > 0:
        f_ = float(balance["funded"])
        s_ = float(balance.get("spent") or 0)
        r_ = float(balance.get("remaining") or 0)
        limits = [{
            "label": "Credits · ${:.2f} left".format(r_),
            "percent": round(min(1.0, max(0.0, s_ / f_)), 4),
            "resetsAt": "",
            "title": "Topped-up balance",
        }]

    today_by_model = {}
    for row in db_rows(
        "SELECT model AS model, SUM(input_tokens) AS inp, SUM(output_tokens) AS out, "
        "SUM(cache_read_tokens) AS cache FROM session_model_usage "
        f"WHERE {where} AND date(first_seen,'unixepoch','localtime') = date('now','localtime') "
        "GROUP BY model",
    ):
        today_by_model[row["model"]] = (
            int0(row.get("inp")) + int0(row.get("out")) + int0(row.get("cache"))
        )

    today_calls_rows = db_rows(
        f"SELECT COUNT(*) AS n FROM session_model_usage WHERE {where} "
        "AND date(first_seen,'unixepoch','localtime') = date('now','localtime')"
    )
    today_prompts = int0(today_calls_rows[0].get("n")) if today_calls_rows else 0

    active_rows = db_rows(
        "SELECT DISTINCT date(first_seen,'unixepoch','localtime') AS d "
        f"FROM session_model_usage WHERE {where} AND "
        "first_seen >= strftime('%s','now','-30 days')"
    )
    active_dates = sorted(r["d"] for r in active_rows if r.get("d"))

    session_rows = db_rows(
        f"SELECT COUNT(DISTINCT session_id) AS n FROM session_model_usage WHERE {where}"
    )
    total_sessions = int0(session_rows[0].get("n")) if session_rows else 0
    today_session_rows = db_rows(
        f"SELECT COUNT(DISTINCT session_id) AS n FROM session_model_usage WHERE {where} "
        "AND date(first_seen,'unixepoch','localtime') = date('now','localtime')"
    )
    today_sessions = int0(today_session_rows[0].get("n")) if today_session_rows else 0

    usage_by_model = {}
    for model, r in by_model.items():
        usage_by_model[model] = {
            "inputTokens": r["input"],
            "outputTokens": r["output"],
            "cacheReadInputTokens": r["cache"],
            "cacheCreationInputTokens": 0,
            "cost": money(est_model.get(model, 0.0)),
        }

    status, auth = "", ""
    if balance is None:
        known = PROVIDER_CONFIGS.get(provider)
        if known:
            key = "OPENROUTER_API_KEY" if provider == "openrouter" else "DEEPSEEK_API_KEY"
            status = f"{known['label']} balance unavailable"
            auth = f"Set {key} in ~/.hermes/.env"
        else:
            status = "Connected"
            auth = ""

    agent_stats = {
        "model": model_id,
        "provider": provider,
        "tokensAllTime": totals["inp"] + totals["out"] + totals["cache"],
        "costToday": round(by_day[-1]["cost"], 4) if by_day else 0.0,
        "costWeek": round(sum(d["cost"] for d in by_day), 4),
        "tokens30": tokens30,
        "cost30": cost30,
        "exactDays30": exact_days30,
        "costAllTime": round(float(balance.get("spent", est_all)), 4)
        if balance
        else round(est_all, 4),
        "costEstimatedTotal": round(est_all, 4),
        "updated": iso_now(),
    }

    return {
        "schemaVersion": 1,
        "id": "hermes",
        "name": "Hermes · " + label,
        "updatedAt": iso_now(),
        "ready": True,
        "hasLocalStats": True,
        "scope": "account",
        "tierLabel": label,
        "usageStatusText": status,
        "authHelpText": auth,
        "todayPrompts": today_prompts,
        "todaySessions": today_sessions,
        "todayTotalTokens": today["tokens"],
        "todayTokensByModel": today_by_model,
        "recentDays": [{"date": d["date"], "messageCount": d["tokens"], "cost": d["cost"], "costExact": d.get("costExact", False)} for d in by_day],
        "totalPrompts": 0,
        "totalSessions": total_sessions,
        "activeDays": len(active_dates),
        "activeDates": active_dates,
        "modelUsage": usage_by_model,
        "limits": limits,
        "balance": balance,
        "dashboardPort": dashboard_port(),
        "agent": agent_stats,
        # Compatibility for widgets installed before the marketplace rename.
        "echo": agent_stats,
    }


# ---------------------------------------------------------------- chat proxy


class _ChatClient:
    """Session-aware chat proxy via ``hermes chat -q -Q --resume``.

    ``-Q`` emits a session ID on the first call. Subsequent calls resume that
    session so the conversation remains continuous; ``new_session`` clears
    the tracked ID and starts the next request in a fresh context.
    """

    _BIN = os.path.join(HOME, ".hermes", "hermes-agent", "venv", "bin", "hermes")

    def __init__(self):
        self._session_id: str | None = None

    def query(self, message: str) -> tuple[str, str] | None:
        """Return ``(response_text, session_id)`` or ``None``."""
        if not message or not os.path.exists(self._BIN):
            return None
        try:
            cmd = [self._BIN, "chat", "-q", message, "-Q"]
            if self._session_id:
                cmd += ["--resume", self._session_id]
            proc = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=120,
                cwd="/",
                env={**os.environ, "TERM": "dumb"},
            )
            out = (proc.stdout or "") + (proc.stderr or "")
            sid = None
            for line in out.splitlines():
                match = re.match(r"^session_id:\s*(\S+)", line.strip())
                if match:
                    sid = match.group(1)
                    self._session_id = sid
                    break
            m = re.search(r"╭[─╴][^╮]+╮\n(.+?)\n╰", out, re.DOTALL)
            if m:
                return m.group(1).strip(), sid or ""
            for prefix in ("Query:", "Initializing agent", "Resume this session",
                           "session_id:", "↻ Resumed session"):
                lines = [line for line in out.splitlines() if prefix not in line]
                out = "\n".join(lines)
            cleaned = out.strip()[:2000]
            return (cleaned, sid or "") if cleaned else None
        except subprocess.TimeoutExpired:
            return None
        except OSError:
            return None

    def new_session(self):
        self._session_id = None

    @property
    def session_id(self) -> str | None:
        return self._session_id

    def close(self):
        pass


_CHAT = _ChatClient()


# ---------------------------------------------------------------- http


class Handler(BaseHTTPRequestHandler):
    def _authed(self):
        if not TOKEN:
            return True
        hdr = self.headers.get("Authorization", "")
        alt = self.headers.get("X-Hermes-Widget-Token", "")
        legacy_alt = self.headers.get("X-Echo-Token", "")
        return (
            hmac.compare_digest(hdr, f"Bearer {TOKEN}")
            or hmac.compare_digest(alt, TOKEN)
            or hmac.compare_digest(legacy_alt, TOKEN)
        )

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)
        path = self.path.split("?")[0]
        if path == "/hermes.json":
            try:
                return self._json(build_record())
            except Exception as exc:
                return self._json({"error": str(exc)}, 500)
        if path == "/models":
            model_id, provider = current_model()
            return self._json({"current": model_id, "currentProvider": provider, "models": MODELS})
        if path == "/health":
            model_id, provider = current_model()
            return self._json({"ok": True, "model": model_id, "provider": provider})
        if path == "/session":
            return self._json({"session_id": _CHAT.session_id or ""})
        return self._json({
            "service": "hermes-agent-widget-bridge",
            "endpoints": ["/hermes.json", "/models", "/health"],
        })

    def do_POST(self):
        if not self._authed():
            return self._json({"error": "unauthorized"}, 401)
        path = self.path.split("?")[0]
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0 or length > MAX_REQUEST_BYTES:
                return self._json({"error": "request body too large"}, 413)
            body = json.loads(self.rfile.read(length).decode()) if length else {}
        except Exception:
            return self._json({"error": "bad json"}, 400)

        if path == "/chat":
            message = str(body.get("message", "")).strip()
            if not message:
                return self._json({"error": "missing message"}, 400)
            result = _CHAT.query(message)
            if result:
                text, sid = result
                return self._json({"response": text, "session_id": sid})
            return self._json({"error": "Hermes agent not reachable"}, 503)

        if path == "/chat/new":
            _CHAT.new_session()
            return self._json({"ok": True, "session": "new"})

        if path == "/session":
            return self._json({"session_id": _CHAT.session_id or ""})

        if path != "/model":
            return self._json({"error": "not found"}, 404)
        model_id = str(body.get("model", "")).strip()
        if not model_id:
            return self._json({"error": "missing model"}, 400)
        old_model, _ = current_model()
        entry, err = set_model(model_id)
        if err:
            return self._json({"error": err}, 400)
        return self._json({"ok": True, "model": entry["id"], "provider": entry["provider"], "previous": old_model})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    try:
        validate_bind_security(HOST, TOKEN)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    except OSError:
        # Port already in use — another bridge instance is running, or
        # the user has a standalone bridge. Nothing to do.
        pass
