#!/usr/bin/env python3
"""AI Sphere sync: CodexBar -> compact JSON -> your upload target (Bunny, S3/R2, SFTP, FTPS, WebDAV…).

Runs once and exits (launchd calls it every few minutes). Standard library only,
compatible with the system Python (/usr/bin/python3, 3.9).

Steps:
  1. Run `codexbar usage --format json` (or read --input FILE).
  2. Normalise every provider into the compact contract (see docs/json-contract.md),
     keeping only whitelisted fields: no emails, organisations, plans or tokens.
  3. Upload usage.json through the target in ~/.config/ai-sphere/publish.json (see targets.py and
     hosting/README.md); the older bunny.json is still accepted.

Secrets come from the macOS Keychain (or environment variables), never from files.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import math
import json
import logging
import logging.handlers
import os
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional

import targets  # sibling module: upload targets

SCHEMA_VERSION = 1

# Provider ids published as `p[].id`: CodexBar's own ids look like "codex" or "helmcode-credits".
PROVIDER_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,31}")

CONFIG_DIR = os.path.expanduser("~/.config/ai-sphere")
BUNNY_CONFIG = os.path.join(CONFIG_DIR, "bunny.json")      # older, Bunny-only config (still read)
PUBLISH_CONFIG = os.path.join(CONFIG_DIR, "publish.json")
SYNC_CONFIG = os.path.join(CONFIG_DIR, "sync.json")
STATE_DIR = os.path.expanduser("~/Library/Application Support/AI-Sphere")
STATE_FILE = os.path.join(STATE_DIR, "last-good.json")
LAST_PAYLOAD = os.path.join(STATE_DIR, "usage.json")
LOCK_FILE = os.path.join(STATE_DIR, "sync.lock")
LOG_DIR = os.path.expanduser("~/Library/Logs/AI-Sphere")
LOG_FILE = os.path.join(LOG_DIR, "sync.log")

DEFAULTS: Dict[str, Any] = {
    "codexbarPath": None,          # autodetect
    "codexbarTimeoutSeconds": 90,
    "maxWindowsPerProvider": 3,
    "exclude": [],                 # provider ids to leave out
    "names": {},                   # provider id -> short name shown on the watch
    "labels": {},                  # "provider/windowId" -> window label
    "labelLanguage": "en",         # window-length words: "en" (WK, MO, DAY) or "es" (SEM, MES, DÍA)
    "uploadRetries": 2,
    "missingGraceHours": 24,       # keep a provider that vanishes from CodexBar for this long
    # CodexBar 0.84.0 leaves user plugins out of `codexbar usage`; these are fetched one by one with
    # `codexbar plugins fetch <id> --json` and added as providers.
    "plugins": ["helmcode-credits"],
    # Secrets for our CodexBar plugins: env var CodexBar reads -> Keychain service that holds the value.
    "pluginSecrets": {
        "CODEXBAR_PLUGIN_HELMCODE_CREDITS_SESSION_COOKIE": "ai-sphere-helmcode-cookie",
    },
}

# Short names for the bezel (max ~7 characters).
KNOWN_NAMES = {
    "codex": "CODEX",
    "claude": "CLAUDE",
    "opencodego": "OC GO",
    "opencode": "OPENCD",
    "antigravity": "AGY",
    "helmcode": "HELM",
    "helmcode-credits": "HELM",   # our CodexBar plugin (mac/codexbar-plugins/)
    "gemini": "GEMINI",
    "copilot": "COPILOT",
    "cursor": "CURSOR",
    "openrouter": "OROUTER",
}

# Group words → abbreviations used in window labels.
GROUP_ABBREV = {
    "gemini": "GEM",
    "gemini 4 argon": "ARGON",
    "claude/gpt": "C/G",
    "claude and gpt": "C/G",
}

# Words that describe the duration or are generic; removed before building the group part.
NOISE_WORDS = re.compile(
    r"\b(5-hour|five-hour|hourly|daily|weekly|monthly|week|month|day|only|models?|quota|limit|usage|credits?)\b",
    re.IGNORECASE,
)

STANDARD_KEYS = ("primary", "secondary", "tertiary")

log = logging.getLogger("aisphere")


# --------------------------------------------------------------------------- normalisation

# Window-length words shown on the watch, per `labelLanguage` setting.
DURATION_WORDS = {
    "en": {"day": "DAY", "week": "WK", "month": "MO", "h": "H", "d": "D"},
    "es": {"day": "DÍA", "week": "SEM", "month": "MES", "h": "H", "d": "D"},
}


def duration_label(minutes: Optional[int], lang: str = "en") -> str:
    words = DURATION_WORDS.get(lang, DURATION_WORDS["en"])
    if not minutes:
        return ""
    if minutes == 300:
        return "5" + words["h"]
    if minutes == 1440:
        return words["day"]
    if minutes == 10080:
        return words["week"]
    if 40000 <= minutes <= 44700:
        return words["month"]
    if minutes < 1440:
        return f"{round(minutes / 60)}{words['h']}"
    return f"{round(minutes / 1440)}{words['d']}"


def group_label(text: Optional[str]) -> str:
    """Turn a CodexBar title such as 'Claude/GPT 5-hour' or 'deepseek-v4-flash' into 'C/G' or 'DEEPSE'."""
    if not text:
        return ""
    cleaned = NOISE_WORDS.sub(" ", text)
    cleaned = re.sub(r"\s+", " ", cleaned).strip().lower()
    if not cleaned:
        return ""
    if cleaned in GROUP_ABBREV:
        return GROUP_ABBREV[cleaned]
    first = re.split(r"[\s\-_]+", cleaned)[0]
    token = re.sub(r"[^0-9a-z/]", "", first)
    return token.upper()[:6]


def window_label(title: Optional[str], minutes: Optional[int], fallback_text: Optional[str] = None,
                 lang: str = "en") -> str:
    group = group_label(title)
    dur = duration_label(minutes, lang)
    if not group and not dur and isinstance(fallback_text, str):
        # e.g. HelmCode: title "Model quota", description "glm5.3-flash · 2,000 / 2,000 tokens".
        # Only a model-like token is used (letters, digits, . - _), never free text such as an e-mail.
        token = fallback_text.split("·")[0].strip()
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,39}", token):
            group = group_label(token)
    label = " ".join(part for part in (group, dur) if part)
    return label[:10] or "?"


def clamp_percent(value: Any) -> Optional[int]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(number):  # NaN, inf
        return None
    return int(max(0, min(100, int(number + 0.5))))


def iso_utc(value: Any) -> Optional[str]:
    """Normalise an ISO 8601 timestamp to 'YYYY-MM-DDTHH:MM:SSZ'. Returns None if unparsable."""
    if not isinstance(value, str) or not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        # Python 3.9 does not accept fractional seconds with other than 3/6 digits; trim them.
        text = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], text)
        try:
            parsed = dt.datetime.fromisoformat(text)
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def pace_block(raw: Any) -> Optional[Dict[str, Any]]:
    """Keep only CodexBar's pace facts: expected used %, will it last, seconds until it runs out."""
    if not isinstance(raw, dict):
        return None
    expected = clamp_percent(raw.get("expectedUsedPercent"))
    lasts = raw.get("willLastToReset")
    if expected is None or not isinstance(lasts, bool):
        return None
    block: Dict[str, Any] = {"e": expected, "ok": lasts}
    eta = raw.get("etaSeconds")
    if not lasts and isinstance(eta, (int, float)) and eta >= 0:
        block["eta"] = int(eta)
    return block


def window_minutes(value: Any) -> Optional[int]:
    """windowMinutes as a sane positive integer (up to a year), or None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return int(value) if 0 < value <= 527040 else None


def _window(raw: Any, label: str, pace: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    if not isinstance(raw, dict):
        return None
    used = clamp_percent(raw.get("usedPercent"))
    if used is None:
        return None
    out: Dict[str, Any] = {"l": label, "u": used}
    reset = iso_utc(raw.get("resetsAt"))
    if reset:
        out["r"] = reset
    minutes = window_minutes(raw.get("windowMinutes"))
    if minutes:
        out["m"] = minutes
    if pace:
        out["pc"] = pace
    return out


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _signature(raw: Dict[str, Any]) -> tuple:
    return (clamp_percent(raw.get("usedPercent")), iso_utc(raw.get("resetsAt")), window_minutes(raw.get("windowMinutes")))


def provider_windows(entry: Dict[str, Any], config: Dict[str, Any]) -> List[Dict[str, Any]]:
    provider_id = str(entry.get("provider", ""))
    usage = _dict(entry.get("usage"))
    labels = _dict(entry.get("rateWindowLabels"))
    paces = _dict(entry.get("pace"))
    overrides = _dict(config.get("labels"))
    lang = str(config.get("labelLanguage") or "en")

    extras = [x for x in (usage.get("extraRateWindows") or []) if isinstance(x, dict) and isinstance(x.get("window"), dict)]
    extra_signatures = {_signature(x["window"]) for x in extras}

    windows: List[Dict[str, Any]] = []
    for key in STANDARD_KEYS:
        raw = usage.get(key)
        if not isinstance(raw, dict):
            continue
        # Antigravity repeats some extra windows as primary/secondary: keep only the clearer extra one.
        if _signature(raw) in extra_signatures:
            continue
        label = overrides.get(f"{provider_id}/{key}") or window_label(
            labels.get(key), window_minutes(raw.get("windowMinutes")), raw.get("resetDescription"), lang)
        window = _window(raw, label, pace_block(paces.get(key)))
        if window:
            windows.append(window)

    for extra in extras:
        raw = extra["window"]
        window_id = str(extra.get("id", ""))
        label = overrides.get(f"{provider_id}/{window_id}") or window_label(
            extra.get("title"), window_minutes(raw.get("windowMinutes")), raw.get("resetDescription"), lang)
        window = _window(raw, label, pace_block(paces.get(window_id)))
        if window:
            windows.append(window)

    # Most used first (least remaining), then the one that resets sooner. Stable for ties.
    windows.sort(key=lambda w: (-w["u"], w.get("r") or "9999"))
    limit = int(config.get("maxWindowsPerProvider") or DEFAULTS["maxWindowsPerProvider"])
    return windows[:max(1, limit)]


def provider_failed(entry: Dict[str, Any]) -> bool:
    return bool(entry.get("error")) or not isinstance(entry.get("usage"), dict)


def _epoch(iso: Any) -> Optional[int]:
    text = iso_utc(iso)
    if not text:
        return None
    return int(dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp())


def normalise(raw: Any, config: Dict[str, Any], previous: Optional[Dict[str, Any]] = None,
              now: Optional[dt.datetime] = None) -> Dict[str, Any]:
    """Build the payload. `previous` is the last saved state, used when a provider fails or goes missing.

    Each provider carries an internal `_seen` (epoch of its last fresh data). It is kept in the local
    state file and stripped from the published JSON (see to_bytes).
    """
    if not isinstance(raw, list):
        raise ValueError("CodexBar output is not a list of providers")
    now = now or dt.datetime.now(dt.timezone.utc)
    now_epoch = int(now.timestamp())
    excluded = set(config.get("exclude") or [])
    disabled = set(config.get("_disabled") or [])  # filled at runtime from `codexbar config providers`
    names = config.get("names") or {}
    grace =float(config.get("missingGraceHours", DEFAULTS["missingGraceHours"])) * 3600
    prev_list = [p for p in (previous or {}).get("p", []) if isinstance(p, dict) and "id" in p and p.get("w")]
    prev_by_id = {p["id"]: p for p in prev_list}
    prev_time = _epoch((previous or {}).get("t")) or 0

    def last_seen(old: Dict[str, Any]) -> int:
        seen_at = old.get("_seen")
        return int(seen_at) if isinstance(seen_at, (int, float)) else prev_time

    def display_name(provider_id: str) -> str:
        return names.get(provider_id) or KNOWN_NAMES.get(provider_id) or provider_id.upper()[:7]

    providers: List[Dict[str, Any]] = []
    handled = set()
    for entry in raw:
        if not isinstance(entry, dict) or not entry.get("provider"):
            continue
        provider_id = str(entry["provider"])
        if not PROVIDER_ID.fullmatch(provider_id):
            log.warning("skipping a provider with an unexpected id (%d characters)", len(provider_id))
            continue
        if provider_id in excluded or provider_id in handled:
            continue
        handled.add(provider_id)

        try:
            windows = [] if provider_failed(entry) else provider_windows(entry, config)
        except Exception as exc:  # noqa: BLE001 - one odd provider must not stop the others
            log.warning("provider %s: unexpected data (%s); treating it as failed", provider_id, type(exc).__name__)
            windows = []
        if windows:
            providers.append({"id": provider_id, "n": display_name(provider_id), "w": windows, "_seen": now_epoch})
            continue

        # No usable data now: keep the last known windows, flagged, instead of inventing zeros.
        old = prev_by_id.get(provider_id)
        if old:
            providers.append({"id": provider_id, "n": display_name(provider_id), "w": old["w"], "err": 1,
                              "_seen": last_seen(old)})
            log.warning("provider %s has no data now; republishing last known values", provider_id)
        else:
            log.warning("provider %s has no data and no previous values; left out", provider_id)

    # Providers missing from this run (CodexBar sometimes drops one whose API is failing): keep them,
    # flagged and in their previous position, for `missingGraceHours`. After that they count as removed.
    for index, old in enumerate(prev_list):
        provider_id = old["id"]
        if provider_id in handled or provider_id in excluded:
            continue
        if provider_id in disabled:
            log.info("provider %s disabled in CodexBar; removed", provider_id)
            continue
        if now_epoch - last_seen(old) > grace:
            log.info("provider %s missing for more than %.0f h; removed", provider_id, grace / 3600)
            continue
        providers.insert(min(index, len(providers)), {
            "id": provider_id, "n": display_name(provider_id), "w": old["w"], "err": 1, "_seen": last_seen(old)})
        log.warning("provider %s missing from CodexBar; republishing last known values", provider_id)

    return {"v": SCHEMA_VERSION, "t": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "p": providers}


def to_bytes(payload: Dict[str, Any], public: bool = True) -> bytes:
    """Serialise compactly. The public form drops internal keys (those starting with '_')."""
    if public:
        payload = dict(payload, p=[{k: v for k, v in p.items() if not k.startswith("_")} for p in payload["p"]])
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# --------------------------------------------------------------------------- I/O

def load_json(path: str) -> Optional[Any]:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None


def write_atomic(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def load_config() -> Dict[str, Any]:
    config = dict(DEFAULTS)
    extra = load_json(SYNC_CONFIG)
    if isinstance(extra, dict):
        config.update(extra)
    return config


def find_codexbar(config: Dict[str, Any]) -> str:
    candidates = [config.get("codexbarPath"), shutil.which("codexbar"),
                  "/opt/homebrew/bin/codexbar", "/usr/local/bin/codexbar"]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise FileNotFoundError("codexbar CLI not found; set codexbarPath in ~/.config/ai-sphere/sync.json")


def jwt_expiry(value: str) -> Optional[int]:
    """Expiry (epoch) of the first JWT found in a cookie/header value, if any. Reads only `exp`."""
    import base64
    match = re.search(r"eyJ[\w-]+\.([\w-]+)\.[\w-]+", value)
    if not match:
        return None
    part = match.group(1) + "=" * (-len(match.group(1)) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(part))
    except (ValueError, json.JSONDecodeError):
        return None
    exp = claims.get("exp") if isinstance(claims, dict) else None
    if isinstance(exp, float) and not math.isfinite(exp):
        return None
    return int(exp) if isinstance(exp, (int, float)) else None


def plugin_environment(config: Dict[str, Any], plugin_id: str) -> Dict[str, str]:
    """Environment for `codexbar plugins fetch <plugin_id>`: only that plugin's secrets, from the Keychain.

    CodexBar reads them as CODEXBAR_PLUGIN_<ID>_<SECRET>; other codexbar calls never get them.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("CODEXBAR_PLUGIN_")}
    prefix = "CODEXBAR_PLUGIN_" + re.sub(r"[^A-Z0-9]", "_", plugin_id.upper()) + "_"
    for variable, service in _dict(config.get("pluginSecrets")).items():
        if not str(variable).startswith(prefix):
            continue
        try:
            value = keychain_secret(service)
        except RuntimeError:
            continue  # plugin not set up on this Mac
        env[variable] = value
        expires = jwt_expiry(value)
        if expires is not None:
            days = (expires - time.time()) / 86400
            if days <= 0:
                log.error("secret %s has expired; renew it (see mac/codexbar-plugins/README.md)", service)
            elif days < 3:
                log.warning("secret %s expires in %.1f days; renew it (see mac/codexbar-plugins/README.md)", service, days)
    return env


def run_codexbar(config: Dict[str, Any]) -> Any:
    binary = find_codexbar(config)
    timeout = int(config.get("codexbarTimeoutSeconds") or 90)
    started = time.monotonic()
    env = {k: v for k, v in os.environ.items() if not k.startswith("CODEXBAR_PLUGIN_")}
    proc = subprocess.run([binary, "usage", "--format", "json", "--no-color"],
                          capture_output=True, text=True, timeout=timeout, env=env)
    elapsed = time.monotonic() - started
    for line in (proc.stderr or "").splitlines():
        if " error " in line or "error:" in line.lower():
            log.info("codexbar: %s", line.strip()[:300])
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"codexbar exit {proc.returncode}, invalid JSON: {exc}") from exc
    log.info("codexbar ok in %.1fs (exit %s, %d providers)", elapsed, proc.returncode,
             len(data) if isinstance(data, list) else -1)
    config["_disabled"] = disabled_providers(binary, env)
    if isinstance(data, list):
        present = {entry.get("provider") for entry in data if isinstance(entry, dict)}
        for plugin_id in config.get("plugins") or []:
            if plugin_id not in present:
                entry = fetch_plugin(binary, plugin_id, plugin_environment(config, plugin_id), timeout)
                if entry:
                    data.append(entry)
    return data


def disabled_providers(binary: str, env: Dict[str, str]) -> List[str]:
    """Providers switched off in CodexBar. They leave the watch at once instead of after the grace period."""
    try:
        proc = subprocess.run([binary, "config", "providers", "--json"], capture_output=True, text=True,
                              timeout=30, env=env, stdin=subprocess.DEVNULL)
        items = json.loads(proc.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as exc:
        log.warning("could not read CodexBar provider settings: %s", exc)
        return []
    return [str(item["provider"]) for item in items if isinstance(item, dict)
            and item.get("provider") and item.get("enabled") is False]


def plugin_entry(plugin_id: str, snapshot: Any) -> Optional[Dict[str, Any]]:
    """Turn a `codexbar plugins fetch` snapshot into the shape of a `codexbar usage` provider entry."""
    if not isinstance(snapshot, dict):
        return None
    usage: Dict[str, Any] = {}
    labels: Dict[str, Any] = {}
    for key in STANDARD_KEYS:
        window = snapshot.get(key)
        if isinstance(window, dict):
            usage[key] = window
            if window.get("title"):
                labels[key] = window["title"]
    extras = snapshot.get("extraWindows") or snapshot.get("extraRateWindows")
    if isinstance(extras, list):
        usage["extraRateWindows"] = extras
    if not usage:
        return None
    entry: Dict[str, Any] = {"provider": plugin_id, "usage": usage, "rateWindowLabels": labels}
    if isinstance(snapshot.get("pace"), dict):
        entry["pace"] = snapshot["pace"]
    return entry


def fetch_plugin(binary: str, plugin_id: str, env: Dict[str, str], timeout: int) -> Optional[Dict[str, Any]]:
    try:
        proc = subprocess.run([binary, "plugins", "fetch", plugin_id, "--json"], capture_output=True, text=True,
                              timeout=timeout, env=env, stdin=subprocess.DEVNULL)
        entry = plugin_entry(plugin_id, json.loads(proc.stdout))
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        log.warning("plugin %s failed: %s %s", plugin_id, exc, (proc.stderr or "").strip()[:200] if 'proc' in locals() else "")
        return None
    if entry is None:
        log.warning("plugin %s returned no windows (exit %s): %s", plugin_id, proc.returncode,
                    (proc.stdout or proc.stderr or "").strip()[:200])
    else:
        log.info("plugin %s ok", plugin_id)
    return entry


def keychain_secret(service: str) -> str:
    proc = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-w"],
                          capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        raise RuntimeError(f"Keychain item '{service}' not found or not readable")
    return proc.stdout.strip()


# --------------------------------------------------------------------------- main

def setup_logging(verbose: bool) -> None:
    os.makedirs(LOG_DIR, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    file_handler = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=256 * 1024, backupCount=3, encoding="utf-8")
    file_handler.setFormatter(fmt)
    log.addHandler(file_handler)
    if verbose or sys.stderr.isatty():
        stream = logging.StreamHandler()
        stream.setFormatter(fmt)
        log.addHandler(stream)
    log.setLevel(logging.INFO)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Publish CodexBar quotas for the AI Sphere watch face.")
    parser.add_argument("--dry-run", action="store_true", help="print the payload; do not upload or save state")
    parser.add_argument("--input", help="read CodexBar JSON from this file instead of running codexbar")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--publish-config", metavar="PATH",
                        help=f"upload target config (default {PUBLISH_CONFIG}, or the older {BUNNY_CONFIG})")
    parser.add_argument("--public-url", action="store_true", help="print the URL the watch downloads and exit")
    parser.add_argument("--watch-key-ref", action="store_true", help="print the X-Key secret reference and exit")
    args = parser.parse_args(argv)

    if args.public_url or args.watch_key_ref:
        publish_cfg = targets.load_publish_config(CONFIG_DIR, args.publish_config)
        print(publish_cfg.get("publicUrl", "") if args.public_url else publish_cfg["watchKey"])
        return 0

    setup_logging(args.verbose)
    os.makedirs(STATE_DIR, exist_ok=True)

    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.info("another sync is running; skipping")
        return 0

    try:
        config = load_config()
        raw = load_json(args.input) if args.input else run_codexbar(config)
        previous = load_json(STATE_FILE)
        payload = normalise(raw, config, previous if isinstance(previous, dict) else None)
        data = to_bytes(payload)
        summary = ", ".join(f"{p['n']}:{100 - p['w'][0]['u']}%" for p in payload["p"])
        log.info("payload %d bytes, %d providers [%s]", len(data), len(payload["p"]), summary)

        if args.dry_run:
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0

        publish_cfg = targets.load_publish_config(CONFIG_DIR, args.publish_config)
        where = targets.publish(data, publish_cfg["target"], int(config.get("uploadRetries") or 0))
        log.info("uploaded %d bytes -> %s", len(data), where)

        # Flagged providers carry their old windows and old `_seen`, so the state never loses good data.
        write_atomic(STATE_FILE, to_bytes(payload, public=False))
        write_atomic(LAST_PAYLOAD, data)
        return 0
    except Exception as exc:  # noqa: BLE001 - one line in the log is the point
        log.error("sync failed: %s", exc)
        return 1
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


if __name__ == "__main__":
    sys.exit(main())
