#!/usr/bin/env python3
"""
Headless control-plane gateway for the Backlight product.

Features:
- Local-only web console for setup/actions/dashboard (served at *.local)
- Device authorization flow endpoints
- Google OAuth callback/token exchange
- Telegram payload verification
- Anonymous diagnostics ingest with PII key redaction
- Anonymous analytics ingest and dashboard KPI aggregation
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import ipaddress
import json
import os
import pathlib
import re
import threading
import time
import urllib.error
import urllib.request
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, parse_qsl, urlencode, urlparse, urlunparse


STARTED_AT_UNIX = int(time.time())
HOST = os.getenv("GATEWAY_HOST", "0.0.0.0")
PORT = int(os.getenv("GATEWAY_PORT", "8080"))
DATA_DIR = pathlib.Path(os.getenv("DATA_DIR", "/data"))
MAX_BODY_BYTES = int(os.getenv("MAX_BODY_BYTES", "1048576"))

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_BOT_USERNAME = os.getenv("TELEGRAM_BOT_USERNAME", "").strip().lstrip("@")
SUBJECT_SALT = os.getenv("AUTH_SUBJECT_SALT", "change-me").strip()
DIAGNOSTICS_API_KEY = os.getenv("DIAGNOSTICS_INGEST_API_KEY", "").strip()
APP_REDIRECT_BASE = os.getenv("APP_REDIRECT_BASE", "").strip()
AUTH_DEVICE_SESSION_TTL_SEC = int(os.getenv("AUTH_DEVICE_SESSION_TTL_SEC", "300"))
LOCAL_DASHBOARD_NAME = os.getenv("LOCAL_DASHBOARD_NAME", "backlight").strip() or "backlight"

DIAGNOSTICS_DIR = DATA_DIR / "diagnostics"
ANALYTICS_DIR = DATA_DIR / "analytics"
PROFILE_DIR = DATA_DIR / "profiles"
PROFILE_MANIFEST_PATH = PROFILE_DIR / "manifest.json"
RUNTIME_CONFIG_PATH = DATA_DIR / "runtime_config.json"
RUNTIME_SHARED_DIR = pathlib.Path(os.getenv("RUNTIME_SHARED_DIR", "/runtime"))
QUICK_TUNNEL_LOG_PATH = pathlib.Path(
    os.getenv("QUICK_TUNNEL_LOG_PATH", str(RUNTIME_SHARED_DIR / "cloudflared.log"))
)
ANALYTICS_API_KEY = os.getenv("ANALYTICS_INGEST_API_KEY", "").strip()
ANALYTICS_MAX_EVENTS_PER_REQUEST = int(
    os.getenv("ANALYTICS_MAX_EVENTS_PER_REQUEST", "250")
)
METRICS_WINDOW_HOURS = int(os.getenv("METRICS_WINDOW_HOURS", "24"))
METRICS_CACHE_TTL_SEC = int(os.getenv("METRICS_CACHE_TTL_SEC", "10"))
METRICS_MAX_FILES_SCANNED = int(os.getenv("METRICS_MAX_FILES_SCANNED", "5000"))

_ticket_store_lock = threading.Lock()
_auth_ticket_store: dict[str, dict[str, object]] = {}
_device_session_store_lock = threading.Lock()
_device_session_store: dict[str, dict[str, object]] = {}
_runtime_config_lock = threading.Lock()
_runtime_config_cache: dict[str, object] | None = None
_telegram_updates_lock = threading.Lock()
_telegram_update_offset = 0
_telegram_last_poll_unix = 0
_metrics_cache_lock = threading.Lock()
_metrics_cache_payload: dict[str, object] | None = None
_metrics_cache_expires_unix = 0

PII_KEYS = {
    "email",
    "phone",
    "mobile",
    "firstname",
    "lastname",
    "middlename",
    "fullname",
    "username",
    "userid",
    "address",
    "ip",
    "ipaddress",
    "location",
    "lat",
    "lng",
    "gps",
    "token",
    "session",
    "cookie",
}
MAX_STRING_VALUE_LEN = 2048
TRYCLOUDFLARE_URL_RE = re.compile(
    r"https://[a-z0-9-]+\.trycloudflare\.com",
    re.IGNORECASE,
)
TELEGRAM_LOGIN_CODE_RE = re.compile(r"^[A-Z0-9]{6,32}$")
ANALYTICS_EVENT_NAME_RE = re.compile(r"[^a-z0-9._-]+")


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _parse_bool(raw_value: object, default_value: bool = False) -> bool:
    if isinstance(raw_value, bool):
        return raw_value
    if isinstance(raw_value, (int, float)):
        return raw_value != 0
    if isinstance(raw_value, str):
        normalized = raw_value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default_value


def _normalize_setup_mode(raw_value: object) -> str:
    mode = str(raw_value).strip().lower()
    if mode in {"stable_domain", "quick_tunnel"}:
        return mode
    return "quick_tunnel"


def _normalize_public_base_url(raw_value: object) -> str:
    raw = str(raw_value).strip()
    if not raw:
        return ""
    candidate = raw
    if not candidate.startswith("http://") and not candidate.startswith("https://"):
        candidate = f"https://{candidate}"
    parsed = urlparse(candidate)
    scheme = parsed.scheme.strip().lower()
    netloc = parsed.netloc.strip().lower()
    if scheme not in {"http", "https"} or not netloc:
        return ""
    return f"{scheme}://{netloc}".rstrip("/")


def ensure_directories() -> None:
    DIAGNOSTICS_DIR.mkdir(parents=True, exist_ok=True)
    ANALYTICS_DIR.mkdir(parents=True, exist_ok=True)
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def write_json(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2), encoding="utf-8")


def _default_runtime_config() -> dict[str, object]:
    google_client_id = os.getenv("GOOGLE_CLIENT_ID", "").strip()
    google_client_secret = os.getenv("GOOGLE_CLIENT_SECRET", "").strip()
    google_redirect_uri = os.getenv("GOOGLE_REDIRECT_URI", "").strip()
    google_enabled_env = os.getenv("GOOGLE_AUTH_ENABLED", "")
    google_enabled = (
        _parse_bool(google_enabled_env, False)
        if google_enabled_env.strip()
        else bool(google_client_id and google_client_secret and google_redirect_uri)
    )
    telegram_bot_token = TELEGRAM_BOT_TOKEN
    telegram_bot_username = TELEGRAM_BOT_USERNAME
    telegram_enabled_env = os.getenv("TELEGRAM_AUTH_ENABLED", "")
    telegram_enabled = (
        _parse_bool(telegram_enabled_env, False)
        if telegram_enabled_env.strip()
        else bool(telegram_bot_token and telegram_bot_username)
    )
    return {
        "dashboard_local_name": LOCAL_DASHBOARD_NAME,
        "setup_mode": _normalize_setup_mode(os.getenv("SETUP_MODE", "quick_tunnel")),
        "stable_public_base_url": _normalize_public_base_url(
            os.getenv("STABLE_PUBLIC_BASE_URL", "")
        ),
        "setup_completed": _parse_bool(os.getenv("SETUP_COMPLETED", "0"), False),
        "setup_completed_at_utc": "",
        "google_enabled": google_enabled,
        "google_client_id": google_client_id,
        "google_client_secret": google_client_secret,
        "google_redirect_uri": google_redirect_uri,
        "google_auto_redirect_from_public_url": _parse_bool(
            os.getenv("GOOGLE_AUTO_REDIRECT_FROM_PUBLIC_URL", "1"),
            True,
        ),
        "google_scope": os.getenv("GOOGLE_SCOPE", "openid email profile").strip()
        or "openid email profile",
        "google_prompt": os.getenv("GOOGLE_PROMPT", "consent").strip() or "consent",
        "google_allowed_domain": os.getenv("GOOGLE_ALLOWED_DOMAIN", "").strip(),
        "google_require_verified_email": _parse_bool(
            os.getenv("GOOGLE_REQUIRE_VERIFIED_EMAIL", "1"),
            True,
        ),
        "telegram_enabled": telegram_enabled,
        "telegram_bot_username": telegram_bot_username,
        "telegram_bot_token": telegram_bot_token,
    }


def _load_runtime_config() -> dict[str, object]:
    global _runtime_config_cache
    with _runtime_config_lock:
        if _runtime_config_cache is not None:
            return dict(_runtime_config_cache)

        config = _default_runtime_config()
        if RUNTIME_CONFIG_PATH.exists():
            try:
                loaded = json.loads(RUNTIME_CONFIG_PATH.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    config.update(loaded)
            except Exception:
                pass

        _runtime_config_cache = dict(config)
        write_json(RUNTIME_CONFIG_PATH, _runtime_config_cache)
        return dict(_runtime_config_cache)


def _update_runtime_config(patch: dict[str, object]) -> dict[str, object]:
    allowed_keys = {
        "dashboard_local_name",
        "setup_mode",
        "stable_public_base_url",
        "setup_completed",
        "setup_completed_at_utc",
        "google_enabled",
        "google_client_id",
        "google_client_secret",
        "google_redirect_uri",
        "google_auto_redirect_from_public_url",
        "google_scope",
        "google_prompt",
        "google_allowed_domain",
        "google_require_verified_email",
        "telegram_enabled",
        "telegram_bot_username",
        "telegram_bot_token",
    }
    sanitized_patch: dict[str, object] = {}
    for key, value in patch.items():
        if key not in allowed_keys:
            continue
        if key in {
            "dashboard_local_name",
            "setup_mode",
            "stable_public_base_url",
            "setup_completed_at_utc",
            "google_client_id",
            "google_client_secret",
            "google_redirect_uri",
            "google_scope",
            "google_prompt",
            "google_allowed_domain",
            "telegram_bot_username",
            "telegram_bot_token",
        }:
            text = str(value).strip()[:4096]
            if key == "dashboard_local_name":
                text = "".join(ch for ch in text.lower() if ch.isalnum() or ch == "-")
                text = text.strip("-") or LOCAL_DASHBOARD_NAME
            if key == "setup_mode":
                text = _normalize_setup_mode(text)
            if key == "stable_public_base_url":
                text = _normalize_public_base_url(text)
            if key == "telegram_bot_username":
                text = text.lstrip("@")
                text = "".join(ch for ch in text if ch.isalnum() or ch == "_")
            sanitized_patch[key] = text
            continue
        if key in {
            "google_enabled",
            "google_require_verified_email",
            "google_auto_redirect_from_public_url",
            "telegram_enabled",
            "setup_completed",
        }:
            sanitized_patch[key] = _parse_bool(value, False)

    with _runtime_config_lock:
        global _runtime_config_cache
        if _runtime_config_cache is None:
            current = _default_runtime_config()
            if RUNTIME_CONFIG_PATH.exists():
                try:
                    loaded = json.loads(RUNTIME_CONFIG_PATH.read_text(encoding="utf-8"))
                    if isinstance(loaded, dict):
                        current.update(loaded)
                except Exception:
                    pass
            _runtime_config_cache = dict(current)

        current = dict(_runtime_config_cache)
        current.update(sanitized_patch)
        write_json(RUNTIME_CONFIG_PATH, current)
        _runtime_config_cache = dict(current)
        return dict(current)


def _get_runtime_config() -> dict[str, object]:
    loaded = _load_runtime_config()
    return _maybe_sync_google_redirect_with_public_url(loaded)


def hash_subject(provider: str, raw_subject: str) -> str:
    base = f"{provider}:{raw_subject}:{SUBJECT_SALT}"
    return hashlib.sha256(base.encode("utf-8")).hexdigest()


def normalize_key(key: str) -> str:
    result_chars = []
    for ch in key.lower():
        if ch.isalnum():
            result_chars.append(ch)
    return "".join(result_chars)


def is_sensitive_key(key: str) -> bool:
    normalized = normalize_key(key)
    if not normalized:
        return False
    for pii_key in PII_KEYS:
        if pii_key in normalized:
            return True
    return False


def sanitize_payload(value):
    if isinstance(value, dict):
        output = {}
        for key, nested_value in value.items():
            if is_sensitive_key(str(key)):
                output[key] = "[REDACTED]"
            else:
                output[key] = sanitize_payload(nested_value)
        return output
    if isinstance(value, list):
        return [sanitize_payload(item) for item in value]
    if isinstance(value, str):
        if len(value) > MAX_STRING_VALUE_LEN:
            return value[:MAX_STRING_VALUE_LEN] + "...[TRUNCATED]"
        return value
    return value


def parse_json_body(handler: BaseHTTPRequestHandler):
    raw_len = handler.headers.get("Content-Length", "0").strip()
    if not raw_len.isdigit():
        raise ValueError("Content-Length header is required")
    content_len = int(raw_len)
    if content_len <= 0:
        raise ValueError("Request body is empty")
    if content_len > MAX_BODY_BYTES:
        raise ValueError("Request body exceeds MAX_BODY_BYTES")
    payload_raw = handler.rfile.read(content_len)
    try:
        return json.loads(payload_raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON body: {exc}") from exc


def _invalidate_metrics_cache() -> None:
    global _metrics_cache_payload
    global _metrics_cache_expires_unix
    with _metrics_cache_lock:
        _metrics_cache_payload = None
        _metrics_cache_expires_unix = 0


def _sanitize_metric_key(raw_key: object) -> str:
    normalized = str(raw_key).strip().lower()
    if not normalized:
        return ""
    result_chars = []
    for ch in normalized:
        if ch.isalnum() or ch in {"_", "-", "."}:
            result_chars.append(ch)
        else:
            result_chars.append("_")
    return "".join(result_chars).strip("_-.")[:64]


def _sanitize_analytics_event_name(raw_name: object) -> str:
    normalized = str(raw_name).strip().lower()
    if not normalized:
        return ""
    compact = ANALYTICS_EVENT_NAME_RE.sub("_", normalized).strip("_-.")
    return compact[:120]


def _parse_timestamp_unix(raw_value: object, fallback_unix: int | None = None) -> int:
    fallback = fallback_unix if fallback_unix is not None else int(time.time())
    try:
        if isinstance(raw_value, (int, float)):
            value = int(raw_value)
            if value <= 0:
                return fallback
            return value
        if isinstance(raw_value, str):
            text = raw_value.strip()
            if not text:
                return fallback
            if text.isdigit():
                value = int(text)
                if value <= 0:
                    return fallback
                return value
            normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
            parsed = dt.datetime.fromisoformat(normalized)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return int(parsed.astimezone(dt.timezone.utc).timestamp())
    except Exception:
        return fallback
    return fallback


def _iso_from_unix(ts_unix: int) -> str:
    return dt.datetime.fromtimestamp(ts_unix, tz=dt.timezone.utc).isoformat()


def _normalize_analytics_events_payload(payload: object) -> tuple[list[dict[str, object]], int, str]:
    if not isinstance(payload, dict):
        return [], 0, "JSON body must be an object"
    raw_events = payload.get("events")
    if not isinstance(raw_events, list):
        return [], 0, "events field must be an array"
    if not raw_events:
        return [], 0, "events array is empty"

    accepted: list[dict[str, object]] = []
    dropped = 0
    now_unix = int(time.time())
    for raw_event in raw_events[:ANALYTICS_MAX_EVENTS_PER_REQUEST]:
        if not isinstance(raw_event, dict):
            dropped += 1
            continue
        name = _sanitize_analytics_event_name(raw_event.get("name"))
        if not name:
            dropped += 1
            continue
        timestamp_unix = _parse_timestamp_unix(raw_event.get("timestamp_utc"), now_unix)
        params_raw = raw_event.get("params", {})
        params: dict[str, object]
        if isinstance(params_raw, dict):
            sanitized_params = sanitize_payload(params_raw)
            params = sanitized_params if isinstance(sanitized_params, dict) else {}
        else:
            params = {}
        accepted.append(
            {
                "name": name,
                "timestamp_unix": timestamp_unix,
                "timestamp_utc": _iso_from_unix(timestamp_unix),
                "params": params,
            }
        )
    if len(raw_events) > ANALYTICS_MAX_EVENTS_PER_REQUEST:
        dropped += len(raw_events) - ANALYTICS_MAX_EVENTS_PER_REQUEST
    if not accepted:
        return [], dropped, "no valid events in request"
    return accepted, dropped, ""


def add_auth_ticket(provider: str, had_code: bool, error: str | None, subject: str = "") -> str:
    ticket = str(uuid.uuid4())
    expires_at = int(time.time()) + 300
    with _ticket_store_lock:
        _auth_ticket_store[ticket] = {
            "provider": provider,
            "had_code": had_code,
            "error": error,
            "subject": subject,
            "created_at_utc": utc_now_iso(),
            "expires_at_unix": expires_at,
        }
    return ticket


def get_auth_ticket(ticket: str):
    with _ticket_store_lock:
        record = _auth_ticket_store.get(ticket)
        if record is None:
            return None
        if int(record.get("expires_at_unix", 0)) < int(time.time()):
            _auth_ticket_store.pop(ticket, None)
            return None
        return record


def _with_query(base_url: str, params: dict[str, str]) -> str:
    parsed = urlparse(base_url)
    query_pairs = parse_qsl(parsed.query, keep_blank_values=True)
    query = dict(query_pairs)
    query.update(params)
    next_query = urlencode(query)
    return urlunparse(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path,
            parsed.params,
            next_query,
            parsed.fragment,
        )
    )


def _google_settings() -> dict[str, object]:
    cfg = _get_runtime_config()
    return {
        "enabled": _parse_bool(cfg.get("google_enabled", False), False),
        "client_id": str(cfg.get("google_client_id", "")).strip(),
        "client_secret": str(cfg.get("google_client_secret", "")).strip(),
        "redirect_uri": str(cfg.get("google_redirect_uri", "")).strip(),
        "auto_redirect_from_public_url": _parse_bool(
            cfg.get("google_auto_redirect_from_public_url", True),
            True,
        ),
        "scope": str(cfg.get("google_scope", "openid email profile")).strip()
        or "openid email profile",
        "prompt": str(cfg.get("google_prompt", "consent")).strip() or "consent",
        "allowed_domain": str(cfg.get("google_allowed_domain", "")).strip(),
        "require_verified_email": _parse_bool(
            cfg.get("google_require_verified_email", True),
            True,
        ),
    }


def _telegram_settings() -> dict[str, object]:
    cfg = _get_runtime_config()
    username = str(cfg.get("telegram_bot_username", "")).strip().lstrip("@")
    token = str(cfg.get("telegram_bot_token", "")).strip()
    return {
        "enabled": _parse_bool(cfg.get("telegram_enabled", False), False),
        "bot_username": username,
        "bot_token": token,
    }


def _telegram_config_ready(settings: dict[str, object] | None = None) -> bool:
    cfg = settings if settings is not None else _telegram_settings()
    return bool(cfg["enabled"] and cfg["bot_username"] and cfg["bot_token"])


def _google_config_ready() -> bool:
    g = _google_settings()
    return bool(
        g["enabled"] and g["client_id"] and g["client_secret"] and g["redirect_uri"]
    )


def _tail_text(path: pathlib.Path, max_bytes: int = 131072) -> str:
    if not path.exists() or not path.is_file():
        return ""
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - max_bytes), os.SEEK_SET)
            raw = handle.read()
        return raw.decode("utf-8", errors="replace")
    except Exception:
        return ""


def _quick_tunnel_public_base_url() -> str:
    text = _tail_text(QUICK_TUNNEL_LOG_PATH)
    if not text:
        return ""
    matches = TRYCLOUDFLARE_URL_RE.findall(text)
    if not matches:
        return ""
    return matches[-1].rstrip("/")


def _normalize_redirect_uri(raw: str) -> str:
    return raw.strip().rstrip("/")


def _telegram_login_code_from_text(text: str) -> str:
    raw = text.strip()
    if not raw:
        return ""
    payload = raw
    if raw.startswith("/start"):
        parts = raw.split(maxsplit=1)
        payload = parts[1].strip() if len(parts) > 1 else ""
    if payload.lower().startswith("login_"):
        payload = payload[6:]
    code = payload.strip().upper()
    if TELEGRAM_LOGIN_CODE_RE.fullmatch(code):
        return code
    return ""


def _new_telegram_login_code() -> str:
    return uuid.uuid4().hex[:8].upper()


def _telegram_bot_link(bot_username: str, login_code: str) -> str:
    safe_username = bot_username.strip().lstrip("@")
    return f"https://t.me/{safe_username}?start=login_{login_code}"


def _apply_telegram_login_code(login_code: str, raw_user_id: str) -> bool:
    target_session_id = ""
    with _device_session_store_lock:
        now_unix = int(time.time())
        for session_id, record in _device_session_store.items():
            if str(record.get("provider", "")).strip().lower() != "telegram":
                continue
            if str(record.get("status", "")) != "pending":
                continue
            if int(record.get("expires_at_unix", 0)) < now_unix:
                continue
            expected_code = str(record.get("telegram_login_code", "")).strip().upper()
            if expected_code != login_code:
                continue
            target_session_id = session_id
            break
    if not target_session_id:
        return False
    subject = hash_subject("telegram", raw_user_id)
    return _update_device_session_from_event(
        session_id=target_session_id,
        provider="telegram",
        ok=True,
        error=None,
        subject=subject,
    )


def _poll_telegram_login_updates() -> tuple[bool, str, int]:
    settings = _telegram_settings()
    if not _telegram_config_ready(settings):
        return False, "Telegram auth is not configured yet", 0

    global _telegram_last_poll_unix
    global _telegram_update_offset
    with _telegram_updates_lock:
        now_unix = int(time.time())
        # Do not hammer Telegram API while client polls status.
        if now_unix - _telegram_last_poll_unix < 2:
            return True, "skip", 0
        _telegram_last_poll_unix = now_unix
        offset = _telegram_update_offset

    body = urlencode(
        {
            "offset": offset,
            "timeout": 0,
            "allowed_updates": json.dumps(["message"]),
        }
    ).encode("utf-8")
    status, payload, raw = _json_request(
        url=f"https://api.telegram.org/bot{settings['bot_token']}/getUpdates",
        method="POST",
        payload=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=10,
    )
    if status < 200 or status >= 300 or payload is None:
        return False, f"Telegram getUpdates failed: {status} {raw}", 0
    if not bool(payload.get("ok")):
        return False, f"Telegram getUpdates error: {raw}", 0

    updates = payload.get("result")
    if not isinstance(updates, list):
        return True, "ok", 0

    max_update_id = offset - 1
    matched = 0
    for update in updates:
        if not isinstance(update, dict):
            continue
        try:
            update_id = int(update.get("update_id", 0))
        except Exception:
            update_id = 0
        if update_id > max_update_id:
            max_update_id = update_id

        message = update.get("message")
        if not isinstance(message, dict):
            continue
        text = str(message.get("text", ""))
        login_code = _telegram_login_code_from_text(text)
        if not login_code:
            continue
        sender = message.get("from")
        if not isinstance(sender, dict):
            continue
        raw_user_id = str(sender.get("id", "")).strip()
        if not raw_user_id:
            continue
        if _apply_telegram_login_code(login_code, raw_user_id):
            matched += 1

    with _telegram_updates_lock:
        if max_update_id >= _telegram_update_offset:
            _telegram_update_offset = max_update_id + 1
    return True, "ok", matched


def _google_redirect_hint_from_public_url(public_base_url: str) -> str:
    base = public_base_url.strip().rstrip("/")
    if not base:
        return ""
    return f"{base}/auth/google/callback"


def _maybe_sync_google_redirect_with_public_url(
    config: dict[str, object],
) -> dict[str, object]:
    auto_sync = _parse_bool(
        config.get("google_auto_redirect_from_public_url", True),
        True,
    )
    if not auto_sync:
        return dict(config)

    setup_mode = _normalize_setup_mode(config.get("setup_mode", "quick_tunnel"))
    if setup_mode == "stable_domain":
        public_base_url = _normalize_public_base_url(
            config.get("stable_public_base_url", "")
        )
    else:
        public_base_url = _quick_tunnel_public_base_url()
    redirect_hint = _google_redirect_hint_from_public_url(public_base_url)
    if not redirect_hint:
        return dict(config)

    current_redirect = str(config.get("google_redirect_uri", "")).strip()
    if _normalize_redirect_uri(current_redirect) == _normalize_redirect_uri(redirect_hint):
        return dict(config)

    with _runtime_config_lock:
        global _runtime_config_cache
        current = dict(_runtime_config_cache or config)
        if not _parse_bool(
            current.get("google_auto_redirect_from_public_url", True),
            True,
        ):
            return dict(current)
        current["google_redirect_uri"] = redirect_hint
        write_json(RUNTIME_CONFIG_PATH, current)
        _runtime_config_cache = dict(current)
        return dict(current)


def _build_google_start_url(*, state: str) -> str:
    g = _google_settings()
    params = {
        "client_id": str(g["client_id"]),
        "redirect_uri": str(g["redirect_uri"]),
        "response_type": "code",
        "scope": str(g["scope"]),
        "state": state,
        "access_type": "offline",
        "include_granted_scopes": "true",
        "prompt": str(g["prompt"]),
    }
    return f"https://accounts.google.com/o/oauth2/v2/auth?{urlencode(params)}"


def _json_request(
    *,
    url: str,
    method: str,
    payload: bytes | None,
    headers: dict[str, str] | None = None,
    timeout: int = 12,
) -> tuple[int, dict | None, str]:
    request = urllib.request.Request(
        url=url,
        method=method,
        data=payload,
        headers=headers or {},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            raw = response.read().decode("utf-8", errors="replace")
            parsed = None
            try:
                parsed_candidate = json.loads(raw)
                if isinstance(parsed_candidate, dict):
                    parsed = parsed_candidate
            except Exception:
                parsed = None
            return int(response.status), parsed, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        parsed = None
        try:
            parsed_candidate = json.loads(raw)
            if isinstance(parsed_candidate, dict):
                parsed = parsed_candidate
        except Exception:
            parsed = None
        return int(exc.code), parsed, raw
    except Exception as exc:  # noqa: BLE001
        return 0, None, str(exc)


def _exchange_google_code(code: str) -> tuple[bool, dict[str, object], str]:
    g = _google_settings()
    body = urlencode(
        {
            "code": code,
            "client_id": str(g["client_id"]),
            "client_secret": str(g["client_secret"]),
            "redirect_uri": str(g["redirect_uri"]),
            "grant_type": "authorization_code",
        }
    ).encode("utf-8")
    status, payload, raw = _json_request(
        url="https://oauth2.googleapis.com/token",
        method="POST",
        payload=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    if status < 200 or status >= 300 or payload is None:
        return False, {}, f"Google token exchange failed: {status} {raw}"
    return True, payload, "ok"


def _verify_google_id_token(id_token: str) -> tuple[bool, dict[str, object], str]:
    status, payload, raw = _json_request(
        url=f"https://oauth2.googleapis.com/tokeninfo?{urlencode({'id_token': id_token})}",
        method="GET",
        payload=None,
    )
    if status < 200 or status >= 300 or payload is None:
        return False, {}, f"Google tokeninfo failed: {status} {raw}"

    g = _google_settings()
    aud = str(payload.get("aud", ""))
    sub = str(payload.get("sub", ""))
    email = str(payload.get("email", ""))
    email_verified = str(payload.get("email_verified", "false")).lower() == "true"
    hd = str(payload.get("hd", ""))

    if not sub:
        return False, {}, "Google token has no subject"
    if aud != str(g["client_id"]):
        return False, {}, "Google token audience mismatch"
    if _parse_bool(g["require_verified_email"], True) and not email_verified:
        return False, {}, "Google email is not verified"
    allowed_domain = str(g["allowed_domain"])
    if allowed_domain and email and not email.endswith(f"@{allowed_domain}"):
        return False, {}, "Google account domain is not allowed"
    if allowed_domain and hd and hd != allowed_domain:
        return False, {}, "Google hosted domain mismatch"

    return (
        True,
        {
            "sub": sub,
            "email": email,
        },
        "ok",
    )


def _start_device_session(provider: str, external_auth_url: str | None) -> tuple[bool, str, dict[str, object] | None]:
    session_id = str(uuid.uuid4())
    created_at_unix = int(time.time())
    expires_at_unix = created_at_unix + AUTH_DEVICE_SESSION_TTL_SEC
    normalized_provider = (provider or "unknown").strip().lower()
    telegram_login_code = ""
    telegram_bot_link = ""
    telegram_bot_username = ""

    if normalized_provider == "google":
        if not _google_config_ready():
            return False, "Google auth is not configured yet", None
        auth_url = _with_query("/auth/google/start", {"state": session_id})
    elif normalized_provider == "telegram":
        telegram = _telegram_settings()
        if not _telegram_config_ready(telegram):
            return False, "Telegram auth is not configured yet", None
        telegram_login_code = _new_telegram_login_code()
        telegram_bot_username = str(telegram["bot_username"]).strip()
        telegram_bot_link = _telegram_bot_link(
            bot_username=telegram_bot_username,
            login_code=telegram_login_code,
        )
        auth_url = _with_query("/auth/telegram/start", {"state": session_id})
    elif external_auth_url and external_auth_url.strip():
        auth_url = _with_query(
            external_auth_url.strip(),
            {
                "provider": normalized_provider,
                "state": session_id,
            },
        )
    else:
        auth_url = f"/auth/callback?provider={normalized_provider}&state={session_id}&code=demo"

    record: dict[str, object] = {
        "session_id": session_id,
        "provider": normalized_provider,
        "status": "pending",
        "created_at_utc": utc_now_iso(),
        "created_at_unix": created_at_unix,
        "expires_at_unix": expires_at_unix,
        "auth_url": auth_url,
        "subject": "",
        "error": "",
        "updated_at_utc": utc_now_iso(),
        "telegram_login_code": telegram_login_code,
        "telegram_bot_link": telegram_bot_link,
        "telegram_bot_username": telegram_bot_username if normalized_provider == "telegram" else "",
    }
    with _device_session_store_lock:
        _device_session_store[session_id] = record
    _invalidate_metrics_cache()
    return True, "ok", record


def _get_device_session(session_id: str) -> dict[str, object] | None:
    with _device_session_store_lock:
        record = _device_session_store.get(session_id)
        if record is None:
            return None
        now_unix = int(time.time())
        expires_at_unix = int(record.get("expires_at_unix", 0))
        if now_unix > expires_at_unix and str(record.get("status", "")) == "pending":
            record["status"] = "expired"
            record["error"] = "session expired"
            record["updated_at_utc"] = utc_now_iso()
        return dict(record)


def _update_device_session_from_event(
    *,
    session_id: str,
    provider: str,
    ok: bool,
    error: str | None,
    subject: str,
) -> bool:
    with _device_session_store_lock:
        record = _device_session_store.get(session_id)
        if record is None:
            return False

        if int(record.get("expires_at_unix", 0)) < int(time.time()):
            record["status"] = "expired"
            record["error"] = "session expired"
            record["updated_at_utc"] = utc_now_iso()
            return False

        record["provider"] = provider
        record["status"] = "completed" if ok else "failed"
        record["subject"] = subject
        record["error"] = error or ""
        record["updated_at_utc"] = utc_now_iso()
        if ok:
            record["telegram_login_code"] = ""
        _invalidate_metrics_cache()
        return True


def _verify_telegram_payload(payload: dict) -> tuple[bool, str]:
    incoming_hash = payload.get("hash")
    if not isinstance(incoming_hash, str) or not incoming_hash:
        return False, "Missing hash field"
    telegram = _telegram_settings()
    token = str(telegram.get("bot_token", "")).strip()
    if not token:
        return False, "Server TELEGRAM_BOT_TOKEN is not configured"

    auth_date_raw = payload.get("auth_date")
    try:
        auth_date = int(auth_date_raw)
    except (TypeError, ValueError):
        return False, "Invalid auth_date"

    now_unix = int(time.time())
    max_age_sec = 180
    if auth_date > now_unix + 10:
        return False, "auth_date is from the future"
    if now_unix - auth_date > max_age_sec:
        return False, "Telegram payload is too old"

    pairs = []
    for key in sorted(payload.keys()):
        if key == "hash":
            continue
        val = payload[key]
        if val is None:
            continue
        pairs.append(f"{key}={val}")
    check_string = "\n".join(pairs)

    secret_key = hashlib.sha256(token.encode("utf-8")).digest()
    computed = hmac.new(secret_key, check_string.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(computed, incoming_hash):
        return False, "Invalid Telegram hash"
    return True, "ok"


def _diagnostics_file_count() -> int:
    count = 0
    if not DIAGNOSTICS_DIR.exists():
        return 0
    for _ in DIAGNOSTICS_DIR.rglob("*.json"):
        count += 1
        if count >= 500000:
            return count
    return count


def _analytics_file_count() -> int:
    count = 0
    if not ANALYTICS_DIR.exists():
        return 0
    for _ in ANALYTICS_DIR.rglob("*.json"):
        count += 1
        if count >= 500000:
            return count
    return count


def _device_session_stats() -> dict[str, int]:
    with _device_session_store_lock:
        stats = {"pending": 0, "completed": 0, "failed": 0, "expired": 0, "total": 0}
        now = int(time.time())
        for record in _device_session_store.values():
            status = str(record.get("status", "pending"))
            if status == "pending" and int(record.get("expires_at_unix", 0)) < now:
                status = "expired"
            if status not in stats:
                status = "failed"
            stats[status] += 1
            stats["total"] += 1
        return stats


def _device_session_stats_window(window_hours: int) -> dict[str, int]:
    threshold_unix = int(time.time()) - max(1, int(window_hours)) * 3600
    now_unix = int(time.time())
    with _device_session_store_lock:
        stats = {"pending": 0, "completed": 0, "failed": 0, "expired": 0, "total": 0}
        for record in _device_session_store.values():
            created_at_unix = int(record.get("created_at_unix", 0))
            if created_at_unix <= 0 or created_at_unix < threshold_unix:
                continue
            status = str(record.get("status", "pending"))
            if status == "pending" and int(record.get("expires_at_unix", 0)) < now_unix:
                status = "expired"
            if status not in stats:
                status = "failed"
            stats[status] += 1
            stats["total"] += 1
        return stats


def _window_day_keys(window_hours: int) -> list[str]:
    hours = max(1, int(window_hours))
    now = dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(hours=hours)
    cursor = dt.datetime(start.year, start.month, start.day, tzinfo=dt.timezone.utc)
    end = dt.datetime(now.year, now.month, now.day, tzinfo=dt.timezone.utc)
    keys: list[str] = []
    while cursor <= end:
        keys.append(cursor.strftime("%Y-%m-%d"))
        cursor += dt.timedelta(days=1)
    return keys


def _top_counts(source: dict[str, int], limit: int = 10) -> list[dict[str, object]]:
    items = sorted(source.items(), key=lambda item: (-item[1], item[0]))
    return [{"key": key, "count": count} for key, count in items[: max(1, limit)]]


def _aggregate_analytics_metrics(window_hours: int) -> dict[str, object]:
    now_unix = int(time.time())
    normalized_window_hours = max(1, int(window_hours))
    window_start_unix = now_unix - normalized_window_hours * 3600
    one_hour_start_unix = now_unix - 3600

    event_counts: dict[str, int] = {}
    auth_provider_starts: dict[str, int] = {}
    files_scanned = 0
    batches_scanned = 0
    events_scanned = 0
    events_last_window = 0
    events_last_hour = 0
    app_starts_last_window = 0
    auth_starts_last_window = 0
    auth_start_failed_last_window = 0
    ble_connected_last_window = 0
    unknown_saved_last_window = 0
    unknown_uploaded_last_window = 0
    scan_truncated = False

    day_keys = _window_day_keys(normalized_window_hours)
    for day_key in day_keys:
        day_dir = ANALYTICS_DIR / day_key
        if not day_dir.exists() or not day_dir.is_dir():
            continue
        for path in sorted(day_dir.glob("*.json")):
            if files_scanned >= METRICS_MAX_FILES_SCANNED:
                scan_truncated = True
                break
            files_scanned += 1
            try:
                parsed = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(parsed, dict):
                continue
            batches_scanned += 1
            events = parsed.get("events")
            if not isinstance(events, list):
                continue
            for event in events:
                if not isinstance(event, dict):
                    continue
                event_name = _sanitize_analytics_event_name(event.get("name"))
                if not event_name:
                    continue
                event_ts_unix = _parse_timestamp_unix(
                    event.get("timestamp_unix", event.get("timestamp_utc")),
                    now_unix,
                )
                events_scanned += 1
                if event_ts_unix >= one_hour_start_unix:
                    events_last_hour += 1
                if event_ts_unix < window_start_unix:
                    continue

                events_last_window += 1
                event_counts[event_name] = event_counts.get(event_name, 0) + 1

                if event_name == "usage.app_start":
                    app_starts_last_window += 1
                elif event_name == "usage.auth_start":
                    auth_starts_last_window += 1
                    params = event.get("params")
                    if isinstance(params, dict):
                        provider = _sanitize_metric_key(params.get("provider", ""))
                        if provider:
                            auth_provider_starts[provider] = (
                                auth_provider_starts.get(provider, 0) + 1
                            )
                elif event_name == "usage.auth_start_failed":
                    auth_start_failed_last_window += 1
                elif event_name == "usage.ble_connected":
                    ble_connected_last_window += 1
                elif event_name == "usage.unknown_device_saved":
                    unknown_saved_last_window += 1
                elif event_name == "usage.unknown_device_uploaded":
                    unknown_saved_last_window += 1
                    unknown_uploaded_last_window += 1

        if scan_truncated:
            break

    return {
        "window_hours": normalized_window_hours,
        "files_scanned": files_scanned,
        "batches_scanned": batches_scanned,
        "events_scanned": events_scanned,
        "events_last_1h": events_last_hour,
        "events_last_window": events_last_window,
        "app_starts_last_window": app_starts_last_window,
        "auth_starts_last_window": auth_starts_last_window,
        "auth_start_failed_last_window": auth_start_failed_last_window,
        "ble_connected_last_window": ble_connected_last_window,
        "unknown_saved_last_window": unknown_saved_last_window,
        "unknown_uploaded_last_window": unknown_uploaded_last_window,
        "auth_provider_starts_last_window": auth_provider_starts,
        "top_events_last_window": _top_counts(event_counts, limit=10),
        "scan_truncated": scan_truncated,
    }


def _dashboard_metrics_payload() -> dict[str, object]:
    global _metrics_cache_payload
    global _metrics_cache_expires_unix
    now_unix = int(time.time())
    with _metrics_cache_lock:
        if (
            _metrics_cache_payload is not None
            and _metrics_cache_expires_unix > now_unix
        ):
            return dict(_metrics_cache_payload)

    window_hours = max(1, METRICS_WINDOW_HOURS)
    analytics = _aggregate_analytics_metrics(window_hours)
    auth_window = _device_session_stats_window(window_hours)
    auth_started = int(auth_window.get("total", 0))
    auth_completed = int(auth_window.get("completed", 0))
    auth_conversion_percent = round(
        (auth_completed * 100.0 / auth_started) if auth_started > 0 else 0.0,
        2,
    )
    payload = {
        "ok": True,
        "time_utc": utc_now_iso(),
        "window_hours": window_hours,
        "kpi": {
            "events_last_1h": int(analytics.get("events_last_1h", 0)),
            "events_last_window": int(analytics.get("events_last_window", 0)),
            "app_starts_last_window": int(analytics.get("app_starts_last_window", 0)),
            "auth_starts_last_window": int(analytics.get("auth_starts_last_window", 0)),
            "auth_start_failed_last_window": int(
                analytics.get("auth_start_failed_last_window", 0)
            ),
            "auth_sessions_started_last_window": auth_started,
            "auth_sessions_completed_last_window": auth_completed,
            "auth_conversion_percent_last_window": auth_conversion_percent,
            "ble_connected_last_window": int(
                analytics.get("ble_connected_last_window", 0)
            ),
            "unknown_saved_last_window": int(
                analytics.get("unknown_saved_last_window", 0)
            ),
            "unknown_uploaded_last_window": int(
                analytics.get("unknown_uploaded_last_window", 0)
            ),
            "diagnostics_files_total": _diagnostics_file_count(),
            "analytics_batches_total": _analytics_file_count(),
        },
        "analytics": analytics,
        "auth_sessions": {"window_hours": window_hours, "stats": auth_window},
    }
    with _metrics_cache_lock:
        _metrics_cache_payload = dict(payload)
        _metrics_cache_expires_unix = now_unix + max(1, METRICS_CACHE_TTL_SEC)
    return payload


def _dashboard_status_payload() -> dict[str, object]:
    runtime = _get_runtime_config()
    google = _google_settings()
    telegram = _telegram_settings()
    if bool(telegram["enabled"]):
        _poll_telegram_login_updates()
    device_stats = _device_session_stats()
    uptime_sec = int(time.time()) - STARTED_AT_UNIX
    local_name = str(runtime.get("dashboard_local_name", LOCAL_DASHBOARD_NAME)).strip() or LOCAL_DASHBOARD_NAME
    setup_mode = _normalize_setup_mode(runtime.get("setup_mode", "quick_tunnel"))
    quick_public_base_url = _quick_tunnel_public_base_url()
    stable_public_base_url = _normalize_public_base_url(
        runtime.get("stable_public_base_url", "")
    )
    effective_public_base_url = (
        stable_public_base_url if setup_mode == "stable_domain" else quick_public_base_url
    )
    google_redirect_hint = _google_redirect_hint_from_public_url(effective_public_base_url)
    current_google_redirect = str(google["redirect_uri"]).strip()
    auto_redirect_enabled = bool(google["auto_redirect_from_public_url"])
    telegram_ready = _telegram_config_ready(telegram)
    telegram_bot_username = str(telegram["bot_username"])
    google_redirect_matches_hint = bool(
        google_redirect_hint
        and _normalize_redirect_uri(current_google_redirect)
        == _normalize_redirect_uri(google_redirect_hint)
    )

    google_ready_base = bool(
        google["enabled"]
        and google["client_id"]
        and google["client_secret"]
        and google["redirect_uri"]
    )
    google_ready = bool(
        google_ready_base
        and (not google_redirect_hint or google_redirect_matches_hint)
    )
    google_enabled = bool(google["enabled"])
    telegram_enabled = bool(telegram["enabled"])
    telegram_provider_ready = bool(telegram_enabled and telegram_ready)
    google_provider_ready = bool(google_enabled and google_ready)
    provider_ready = bool(telegram_provider_ready or google_provider_ready)

    required_steps = [
        {
            "id": "setup-mode",
            "title": "Setup mode selected",
            "done": setup_mode in {"quick_tunnel", "stable_domain"},
            "details": (
                "Dynamic URL (quick tunnel)"
                if setup_mode == "quick_tunnel"
                else "Stable domain"
            ),
        },
        {
            "id": "public-url",
            "title": "Public URL for selected mode is available",
            "done": bool(effective_public_base_url),
            "details": (
                f"Using stable URL: {stable_public_base_url}"
                if setup_mode == "stable_domain"
                else (
                    f"Using quick URL: {quick_public_base_url}"
                    if quick_public_base_url
                    else "Waiting for quick tunnel URL"
                )
            ),
        },
        {
            "id": "provider-ready",
            "title": "At least one auth provider is fully configured",
            "done": provider_ready,
            "details": (
                "Google or Telegram is ready"
                if provider_ready
                else "Configure and enable Google and/or Telegram"
            ),
        },
        {
            "id": "google-ready",
            "title": "Google auth readiness",
            "done": (not google_enabled) or google_provider_ready,
            "details": (
                "Google disabled (optional)"
                if not google_enabled
                else (
                    "Google enabled and redirect is in sync"
                    if google_provider_ready
                    else "Google enabled but credentials/redirect are incomplete"
                )
            ),
        },
        {
            "id": "telegram-ready",
            "title": "Telegram auth readiness",
            "done": (not telegram_enabled) or telegram_provider_ready,
            "details": (
                "Telegram disabled (optional)"
                if not telegram_enabled
                else (
                    "Telegram enabled and bot config is ready"
                    if telegram_provider_ready
                    else "Telegram enabled but bot username/token are incomplete"
                )
            ),
        },
    ]
    required_total = len(required_steps)
    required_done = sum(1 for item in required_steps if bool(item.get("done")))
    setup_ready = required_done == required_total
    setup_completed = _parse_bool(runtime.get("setup_completed", False), False)
    setup_completed_at_utc = str(runtime.get("setup_completed_at_utc", "")).strip()

    steps = [
        {
            "id": "mdns-name",
            "title": "Local dashboard hostname is configured",
            "done": bool(local_name),
            "details": f"Expected URL: http://{local_name}.local",
        },
        {
            "id": "google-client-id",
            "title": "Google Client ID is set",
            "done": bool(google["client_id"]),
            "details": "Add Google OAuth Client ID in web console config",
        },
        {
            "id": "google-client-secret",
            "title": "Google Client Secret is set",
            "done": bool(google["client_secret"]),
            "details": "Add Google OAuth Client Secret in web console config",
        },
        {
            "id": "google-redirect",
            "title": "Google Redirect URI is configured",
            "done": bool(current_google_redirect)
            and (not google_redirect_hint or google_redirect_matches_hint),
            "details": (
                f"Expected now: {google_redirect_hint}"
                if google_redirect_hint
                else "Should match OAuth app settings exactly"
            ),
        },
        {
            "id": "google-enabled",
            "title": "Google auth is enabled",
            "done": bool(google["enabled"]),
            "details": "Enable Google flow after filling all credentials",
        },
        {
            "id": "telegram-bot-username",
            "title": "Telegram bot username is set",
            "done": bool(telegram_bot_username),
            "details": "Set bot username (without @) in local dashboard config",
        },
        {
            "id": "telegram-bot-token",
            "title": "Telegram bot token is set",
            "done": bool(telegram["bot_token"]),
            "details": "Set bot token from BotFather in local dashboard config",
        },
        {
            "id": "telegram-enabled",
            "title": "Telegram auth is enabled",
            "done": bool(telegram["enabled"]),
            "details": "Enable Telegram auth in local dashboard config",
        },
        {
            "id": "google-auto-redirect",
            "title": "Google redirect follows current public URL automatically",
            "done": auto_redirect_enabled,
            "details": (
                "Enabled: gateway updates redirect URI when trycloudflare URL changes"
                if auto_redirect_enabled
                else "Disabled: update Google Redirect URI manually in dashboard when URL changes"
            ),
        },
        {
            "id": "quick-tunnel",
            "title": "Temporary public URL is active",
            "done": bool(quick_public_base_url),
            "details": (
                f"Current URL: {quick_public_base_url}"
                if quick_public_base_url
                else "Quick tunnel URL not detected yet. Wait for cloudflared startup."
            ),
        },
        {
            "id": "stable-domain",
            "title": "Stable domain URL is configured",
            "done": bool(stable_public_base_url),
            "details": (
                f"Stable URL: {stable_public_base_url}"
                if stable_public_base_url
                else "Set stable domain URL in setup wizard if you use stable mode"
            ),
        },
    ]

    return {
        "ok": True,
        "time_utc": utc_now_iso(),
        "uptime_sec": uptime_sec,
        "dashboard_host": f"{local_name}.local",
        "service": {
            "host": HOST,
            "port": PORT,
            "diagnostics_count": _diagnostics_file_count(),
            "analytics_batches_count": _analytics_file_count(),
        },
        "auth": {
            "tickets_active": len(_auth_ticket_store),
            "device_sessions": device_stats,
            "google_configured": google_ready,
            "google_enabled": google_enabled,
            "telegram_configured": telegram_ready,
            "telegram_enabled": telegram_enabled,
            "telegram_bot_username": telegram_bot_username,
            "google_start_endpoint": "/auth/google/start",
            "telegram_start_endpoint": "/auth/telegram/start",
            "google_callback_endpoint": "/auth/google/callback",
            "public_base_url": effective_public_base_url,
            "quick_tunnel_public_base_url": quick_public_base_url,
            "stable_public_base_url": stable_public_base_url,
            "google_redirect_hint": google_redirect_hint,
            "google_redirect_matches_hint": google_redirect_matches_hint,
            "google_auto_redirect_from_public_url": auto_redirect_enabled,
        },
        "setup_steps": steps,
        "setup": {
            "mode": setup_mode,
            "ready": setup_ready,
            "completed": setup_completed,
            "completed_at_utc": setup_completed_at_utc,
            "required_done": required_done,
            "required_total": required_total,
            "required_steps": required_steps,
        },
        "runtime_config": {
            "dashboard_local_name": local_name,
            "setup_mode": setup_mode,
            "stable_public_base_url": stable_public_base_url,
            "setup_completed": setup_completed,
            "setup_completed_at_utc": setup_completed_at_utc,
            "google_enabled": google_enabled,
            "google_client_id": str(google["client_id"]),
            "google_redirect_uri": str(google["redirect_uri"]),
            "google_scope": str(google["scope"]),
            "google_prompt": str(google["prompt"]),
            "google_allowed_domain": str(google["allowed_domain"]),
            "google_require_verified_email": bool(google["require_verified_email"]),
            "google_client_secret_configured": bool(google["client_secret"]),
            "telegram_enabled": telegram_enabled,
            "telegram_bot_username": telegram_bot_username,
            "telegram_bot_token_configured": bool(telegram["bot_token"]),
            "public_base_url": effective_public_base_url,
            "quick_tunnel_public_base_url": quick_public_base_url,
            "stable_public_base_url": stable_public_base_url,
            "google_redirect_hint": google_redirect_hint,
            "google_redirect_matches_hint": google_redirect_matches_hint,
            "google_auto_redirect_from_public_url": auto_redirect_enabled,
        },
        "actions": [
            "Open /ui to complete setup actions in browser",
            "Run: sudo systemctl restart backlight-stack.service (apply env/hostname changes)",
            "Run: sudo systemctl enable --now backlight-hil.service (optional HIL mode)",
            "Use /auth/google/start to test Google login",
            (
                f"Use Telegram bot link: https://t.me/{telegram_bot_username}"
                if telegram_bot_username
                else "Set Telegram bot username in dashboard to enable Telegram auth flow"
            ),
            "Use /health for probe checks",
            "Use /ui/api/metrics for aggregated product KPIs",
            (
                f"Update Google OAuth Redirect URI to: {google_redirect_hint}"
                if google_redirect_hint and not google_redirect_matches_hint
                else "Google Redirect URI is synchronized with current public URL"
            ),
            (
                "Wizard can be completed when required setup steps are all green"
                if setup_ready
                else "Finish required setup steps in wizard mode"
            ),
        ],
    }


def _render_dashboard_html() -> str:
    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Backlight Local Console</title>
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Arial, sans-serif; background: #111827; color: #e5e7eb; }
    .wrap { max-width: 980px; margin: 0 auto; padding: 20px; }
    .card { background: #1f2937; border: 1px solid #374151; border-radius: 10px; padding: 16px; margin-bottom: 14px; }
    h1, h2, h3 { margin: 0 0 10px 0; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    label { display: block; font-size: 12px; margin-bottom: 4px; color: #9ca3af; }
    input[type=text], input[type=password] { width: 100%; background: #111827; color: #e5e7eb; border: 1px solid #4b5563; border-radius: 8px; padding: 8px; box-sizing: border-box; }
    button { background: #2563eb; color: white; border: 0; border-radius: 8px; padding: 9px 12px; cursor: pointer; }
    .muted { color: #9ca3af; font-size: 13px; }
    .ok { color: #34d399; }
    .warn { color: #fbbf24; }
    .bad { color: #f87171; }
    ul { margin: 6px 0; padding-left: 20px; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
    .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 10px; }
    .kpi-card { background: #111827; border: 1px solid #374151; border-radius: 8px; padding: 10px; }
    .kpi-label { color: #9ca3af; font-size: 12px; margin-bottom: 6px; }
    .kpi-value { color: #e5e7eb; font-size: 20px; font-weight: 700; }
    @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Backlight Local Console</h1>
      <div id="headline" class="muted">Loading status...</div>
    </div>

    <div id="wizardRoot" style="display:none;">
      <div class="card">
        <h2>First-run setup wizard</h2>
        <div id="wizardProgress" class="muted">Loading setup state...</div>
      </div>

      <div class="card" id="wizardModeStep">
        <h3>Step 1/3: Connectivity scenario</h3>
        <p class="muted">Action -> result: select scenario and save mode.</p>
        <div style="display:flex; gap:14px; flex-wrap:wrap; margin:10px 0;">
          <label style="display:flex; align-items:center; gap:8px; font-size:14px;">
            <input type="radio" name="setupMode" id="setupModeQuick" value="quick_tunnel" checked />
            Dynamic URL (quick tunnel, changes are expected)
          </label>
          <label style="display:flex; align-items:center; gap:8px; font-size:14px;">
            <input type="radio" name="setupMode" id="setupModeStable" value="stable_domain" />
            Stable domain (recommended for Google + Telegram widget)
          </label>
        </div>
        <div>
          <label>Stable public base URL (used only for stable domain mode)</label>
          <input id="stablePublicBaseUrl" type="text" placeholder="https://auth.example.com" />
        </div>
        <div style="margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap;">
          <button id="wizardModeSaveBtn" type="button">Save mode</button>
          <button id="wizardModeNextBtn" type="button">Continue to auth config</button>
        </div>
        <div id="wizardModeResult" class="muted" style="margin-top: 8px;"></div>
      </div>

      <div class="card" id="wizardAuthStep" style="display:none;">
        <h3>Step 2/3: Auth providers config</h3>
        <p class="muted">Action -> result: fill fields, click Save config, then check result/status.</p>
        <div id="publicUrlHint" class="muted" style="margin-bottom: 10px;"></div>
        <div class="grid">
          <div>
            <label>Dashboard name (.local)</label>
            <input id="dashboardLocalName" type="text" placeholder="backlight" />
          </div>
          <div>
            <label>Google Client ID</label>
            <input id="googleClientId" type="text" />
          </div>
          <div>
            <label>Google Client Secret (leave empty to keep current)</label>
            <input id="googleClientSecret" type="password" />
          </div>
          <div>
            <label>Google Redirect URI</label>
            <input id="googleRedirectUri" type="text" />
          </div>
          <div>
            <label>Google Scope</label>
            <input id="googleScope" type="text" />
          </div>
          <div>
            <label>Google Prompt</label>
            <input id="googlePrompt" type="text" />
          </div>
          <div>
            <label>Allowed Google domain (optional)</label>
            <input id="googleAllowedDomain" type="text" />
          </div>
          <div>
            <label>Google enabled (true/false)</label>
            <input id="googleEnabled" type="text" />
          </div>
          <div>
            <label>Auto-update Redirect URI from current public URL (true/false)</label>
            <input id="googleAutoRedirect" type="text" />
          </div>
          <div>
            <label>Telegram enabled (true/false)</label>
            <input id="telegramEnabled" type="text" />
          </div>
          <div>
            <label>Telegram bot username (without @)</label>
            <input id="telegramBotUsername" type="text" />
          </div>
          <div>
            <label>Telegram bot token (leave empty to keep current)</label>
            <input id="telegramBotToken" type="password" />
          </div>
        </div>
        <div style="margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap;">
          <button id="saveBtn" type="button">Save config</button>
          <button id="refreshBtn" type="button">Refresh status</button>
          <button id="copyRedirectBtn" type="button">Copy current Redirect URI</button>
          <a id="googleStartLink" href="/auth/google/start" style="color:#93c5fd; align-self:center;">Start Google login test</a>
        </div>
        <div id="saveResult" class="muted" style="margin-top: 8px;"></div>
        <div style="margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap;">
          <button id="wizardAuthBackBtn" type="button">Back</button>
          <button id="wizardAuthNextBtn" type="button">Continue to validation</button>
        </div>
      </div>

      <div class="card" id="wizardValidateStep" style="display:none;">
        <h3>Step 3/3: Validation and finish</h3>
        <p class="muted">Action -> result: refresh validation, ensure required steps are [OK], then finish setup.</p>
        <ul id="requiredSteps"></ul>
        <div id="wizardValidationSummary" class="muted" style="margin-top: 8px;"></div>
        <div style="margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap;">
          <button id="wizardValidateBackBtn" type="button">Back</button>
          <button id="wizardRefreshBtn" type="button">Refresh validation</button>
          <button id="wizardCompleteBtn" type="button">Finish setup</button>
        </div>
        <div id="wizardCompleteResult" class="muted" style="margin-top: 8px;"></div>
      </div>
    </div>

    <div id="dashboardRoot" style="display:none;">
      <div class="grid">
        <div class="card">
          <h2>Setup checklist</h2>
          <ul id="steps"></ul>
        </div>
        <div class="card">
          <h2>Runtime status</h2>
          <div id="status" class="mono"></div>
        </div>
      </div>

      <div class="card">
        <h2>Product dashboard</h2>
        <div id="dashboardActions" class="mono"></div>
        <div style="margin-top:12px;">
          <button id="reopenWizardBtn" type="button">Reopen setup wizard</button>
        </div>
      </div>

      <div class="card">
        <h2>Product KPI (last <span id="metricsWindowHours">24</span>h)</h2>
        <div id="kpiGrid" class="kpi-grid"></div>
        <div id="metricsDetails" class="mono" style="margin-top:10px;"></div>
      </div>

      <div class="card">
        <h2>Endpoints</h2>
        <ul>
          <li><span class="mono">GET /health</span></li>
          <li><span class="mono">GET /ui/api/metrics</span></li>
          <li><span class="mono">POST /auth/device/start</span></li>
          <li><span class="mono">GET /auth/device/status?session_id=...</span></li>
          <li><span class="mono">GET /auth/google/start</span></li>
          <li><span class="mono">GET /auth/google/callback</span></li>
          <li><span class="mono">GET /auth/telegram/start?state=...</span></li>
          <li><span class="mono">POST /analytics/ingest</span></li>
          <li><span class="mono">POST /diagnostics/ingest</span></li>
        </ul>
      </div>
    </div>
  </div>

  <script>
    let latestRedirectHint = '';
    let latestStatusData = null;
    let latestMetricsData = null;
    let currentWizardStep = 1;

    async function fetchStatus() {
      const r = await fetch('/ui/api/status', { cache: 'no-store' });
      if (!r.ok) {
        throw new Error('Status request failed: ' + r.status);
      }
      return await r.json();
    }

    async function fetchMetrics() {
      const r = await fetch('/ui/api/metrics', { cache: 'no-store' });
      if (!r.ok) {
        throw new Error('Metrics request failed: ' + r.status);
      }
      return await r.json();
    }

    async function postJson(url, payload) {
      const r = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload || {}),
      });
      const data = await r.json();
      return { ok: r.ok, data };
    }

    function renderStepList(rootId, steps) {
      const root = document.getElementById(rootId);
      if (!root) {
        return;
      }
      root.innerHTML = '';
      for (const step of steps || []) {
        const li = document.createElement('li');
        li.innerHTML = step.done
          ? `<span class="ok">[OK]</span> ${step.title} <div class="muted">${step.details || ''}</div>`
          : `<span class="warn">[TODO]</span> ${step.title} <div class="muted">${step.details || ''}</div>`;
        root.appendChild(li);
      }
    }

    function selectedSetupMode() {
      const stable = document.getElementById('setupModeStable');
      return stable && stable.checked ? 'stable_domain' : 'quick_tunnel';
    }

    function applySetupModeToControls(mode) {
      const normalized = (mode || '').toLowerCase() === 'stable_domain' ? 'stable_domain' : 'quick_tunnel';
      const quick = document.getElementById('setupModeQuick');
      const stable = document.getElementById('setupModeStable');
      if (quick) quick.checked = normalized === 'quick_tunnel';
      if (stable) stable.checked = normalized === 'stable_domain';
    }

    function setWizardStep(step) {
      currentWizardStep = Math.max(1, Math.min(3, Number(step) || 1));
      const step1 = document.getElementById('wizardModeStep');
      const step2 = document.getElementById('wizardAuthStep');
      const step3 = document.getElementById('wizardValidateStep');
      if (step1) step1.style.display = currentWizardStep === 1 ? '' : 'none';
      if (step2) step2.style.display = currentWizardStep === 2 ? '' : 'none';
      if (step3) step3.style.display = currentWizardStep === 3 ? '' : 'none';
      const progress = document.getElementById('wizardProgress');
      if (progress) {
        progress.textContent = `Step ${currentWizardStep}/3`;
      }
    }

    function renderDashboard(data) {
      const auth = data.auth || {};
      const svc = data.service || {};
      const lines = [
        `device_sessions.total=${(auth.device_sessions || {}).total || 0}`,
        `device_sessions.pending=${(auth.device_sessions || {}).pending || 0}`,
        `device_sessions.completed=${(auth.device_sessions || {}).completed || 0}`,
        `google.configured=${auth.google_configured}`,
        `google.enabled=${auth.google_enabled}`,
        `telegram.configured=${auth.telegram_configured}`,
        `telegram.enabled=${auth.telegram_enabled}`,
        `telegram.bot=@${auth.telegram_bot_username || '-'}`,
        `public.base_url=${auth.public_base_url || '-'}`,
        `google.redirect_hint=${auth.google_redirect_hint || '-'}`,
        `diagnostics.count=${svc.diagnostics_count || 0}`,
        `analytics.batches=${svc.analytics_batches_count || 0}`,
      ];
      document.getElementById('status').textContent = lines.join('\\n');
      renderStepList('steps', data.setup_steps || []);

      const actions = data.actions || [];
      const dashboardActions = document.getElementById('dashboardActions');
      if (dashboardActions) {
        dashboardActions.textContent = actions.join('\\n');
      }
    }

    function clearMetricsView() {
      const grid = document.getElementById('kpiGrid');
      const details = document.getElementById('metricsDetails');
      if (grid) {
        grid.innerHTML = '';
      }
      if (details) {
        details.textContent = '';
      }
    }

    function renderMetrics(data) {
      latestMetricsData = data || null;
      const kpi = (data && data.kpi) || {};
      const analytics = (data && data.analytics) || {};
      const authSessions = ((data && data.auth_sessions) || {}).stats || {};
      const windowHours = Number((data && data.window_hours) || 24);
      const windowEl = document.getElementById('metricsWindowHours');
      if (windowEl) {
        windowEl.textContent = String(windowHours);
      }

      const cards = [
        { label: 'Events 24h/window', value: Number(kpi.events_last_window || 0) },
        { label: 'Events 1h', value: Number(kpi.events_last_1h || 0) },
        { label: 'App starts', value: Number(kpi.app_starts_last_window || 0) },
        { label: 'Auth starts', value: Number(kpi.auth_starts_last_window || 0) },
        { label: 'Auth conversion %', value: Number(kpi.auth_conversion_percent_last_window || 0).toFixed(2) },
        { label: 'BLE connected', value: Number(kpi.ble_connected_last_window || 0) },
        { label: 'Unknown uploaded', value: Number(kpi.unknown_uploaded_last_window || 0) },
        { label: 'Diagnostics files', value: Number(kpi.diagnostics_files_total || 0) },
      ];
      const grid = document.getElementById('kpiGrid');
      if (grid) {
        grid.innerHTML = '';
        for (const card of cards) {
          const node = document.createElement('div');
          node.className = 'kpi-card';
          node.innerHTML = `<div class="kpi-label">${card.label}</div><div class="kpi-value">${card.value}</div>`;
          grid.appendChild(node);
        }
      }

      const topEvents = Array.isArray(analytics.top_events_last_window) ? analytics.top_events_last_window : [];
      const providerStarts = analytics.auth_provider_starts_last_window || {};
      const detailLines = [
        `window_hours=${windowHours}`,
        `auth_sessions.total=${Number(authSessions.total || 0)}`,
        `auth_sessions.completed=${Number(authSessions.completed || 0)}`,
        `auth_sessions.failed=${Number(authSessions.failed || 0)}`,
        `auth_sessions.expired=${Number(authSessions.expired || 0)}`,
        `analytics.files_scanned=${Number(analytics.files_scanned || 0)}`,
        `analytics.batches_scanned=${Number(analytics.batches_scanned || 0)}`,
        `analytics.events_scanned=${Number(analytics.events_scanned || 0)}`,
        `analytics.scan_truncated=${Boolean(analytics.scan_truncated)}`,
        `auth_provider_starts=${JSON.stringify(providerStarts)}`,
        `top_events=${JSON.stringify(topEvents)}`,
      ];
      const details = document.getElementById('metricsDetails');
      if (details) {
        details.textContent = detailLines.join('\\n');
      }
    }

    function renderCommonConfigFields(cfg) {
      document.getElementById('dashboardLocalName').value = cfg.dashboard_local_name || '';
      document.getElementById('googleClientId').value = cfg.google_client_id || '';
      document.getElementById('googleClientSecret').value = '';
      document.getElementById('googleRedirectUri').value = cfg.google_redirect_uri || '';
      document.getElementById('googleScope').value = cfg.google_scope || '';
      document.getElementById('googlePrompt').value = cfg.google_prompt || '';
      document.getElementById('googleAllowedDomain').value = cfg.google_allowed_domain || '';
      document.getElementById('googleEnabled').value = String(cfg.google_enabled || false);
      document.getElementById('googleAutoRedirect').value = String(cfg.google_auto_redirect_from_public_url !== false);
      document.getElementById('telegramEnabled').value = String(cfg.telegram_enabled || false);
      document.getElementById('telegramBotUsername').value = cfg.telegram_bot_username || '';
      document.getElementById('telegramBotToken').value = '';
      document.getElementById('googleStartLink').href = '/auth/google/start';
      document.getElementById('stablePublicBaseUrl').value = cfg.stable_public_base_url || '';
      applySetupModeToControls(cfg.setup_mode || 'quick_tunnel');
    }

    function renderPublicUrlHint(cfg) {
      const hintEl = document.getElementById('publicUrlHint');
      const publicBase = cfg.public_base_url || '';
      const redirectHint = cfg.google_redirect_hint || '';
      latestRedirectHint = redirectHint;
      const redirectMatches = !!cfg.google_redirect_matches_hint;
      if (!hintEl) {
        return;
      }
      if (!publicBase) {
        hintEl.innerHTML = '<span class="warn">No public URL detected for selected mode yet.</span> Save mode/config and press Refresh.';
      } else if (!redirectMatches) {
        hintEl.innerHTML = `<span class="warn">Public URL changed:</span> <span class="mono">${publicBase}</span><br/>Update Google Redirect URI to <span class="mono">${redirectHint}</span> in Google Console and here, then Save.`;
      } else {
        hintEl.innerHTML = `<span class="ok">Public URL active:</span> <span class="mono">${publicBase}</span><br/><span class="ok">Google Redirect URI is up to date.</span>`;
      }
    }

    function renderWizard(data) {
      const setup = data.setup || {};
      renderStepList('requiredSteps', setup.required_steps || []);
      const summary = document.getElementById('wizardValidationSummary');
      if (summary) {
        const done = Number(setup.required_done || 0);
        const total = Number(setup.required_total || 0);
        const ready = !!setup.ready;
        summary.innerHTML = ready
          ? `<span class="ok">Validation passed: ${done}/${total} required steps done.</span>`
          : `<span class="warn">Validation pending: ${done}/${total} required steps done.</span>`;
      }
      const modeResult = document.getElementById('wizardModeResult');
      if (modeResult) {
        const mode = (setup.mode || 'quick_tunnel') === 'stable_domain'
          ? 'stable domain mode'
          : 'dynamic quick tunnel mode';
        modeResult.textContent = `Current mode: ${mode}`;
      }
    }

    function renderStatus(data) {
      latestStatusData = data;
      document.getElementById('headline').textContent =
        `Host: ${data.dashboard_host} | Uptime: ${data.uptime_sec}s | UTC: ${data.time_utc}`;

      const cfg = data.runtime_config || {};
      renderCommonConfigFields(cfg);
      renderPublicUrlHint(cfg);

      const setup = data.setup || {};
      const setupDone = !!setup.completed && !!setup.ready;
      const wizardRoot = document.getElementById('wizardRoot');
      const dashboardRoot = document.getElementById('dashboardRoot');
      if (wizardRoot) wizardRoot.style.display = setupDone ? 'none' : '';
      if (dashboardRoot) dashboardRoot.style.display = setupDone ? '' : 'none';

      if (setupDone) {
        renderDashboard(data);
      } else {
        renderWizard(data);
        setWizardStep(currentWizardStep);
        clearMetricsView();
      }
    }

    async function copyCurrentRedirectHint() {
      const outputEl = document.getElementById('saveResult');
      if (!latestRedirectHint) {
        outputEl.textContent = 'Redirect URI hint is not available yet. Press Refresh in a few seconds.';
        return;
      }

      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          await navigator.clipboard.writeText(latestRedirectHint);
          outputEl.textContent = 'Copied Redirect URI: ' + latestRedirectHint;
          return;
        }
      } catch (e) {
        // Fallback below.
      }

      const helper = document.createElement('textarea');
      helper.value = latestRedirectHint;
      helper.setAttribute('readonly', 'readonly');
      helper.style.position = 'absolute';
      helper.style.left = '-10000px';
      document.body.appendChild(helper);
      helper.select();
      helper.setSelectionRange(0, helper.value.length);
      let copied = false;
      try {
        copied = document.execCommand('copy');
      } catch (_) {
        copied = false;
      }
      document.body.removeChild(helper);
      outputEl.textContent = copied
        ? 'Copied Redirect URI: ' + latestRedirectHint
        : 'Copy failed. Redirect URI: ' + latestRedirectHint;
    }

    async function refresh() {
      try {
        const data = await fetchStatus();
        renderStatus(data);
        const setup = data.setup || {};
        const setupDone = !!setup.completed && !!setup.ready;
        if (setupDone) {
          try {
            const metrics = await fetchMetrics();
            renderMetrics(metrics);
          } catch (metricsError) {
            const details = document.getElementById('metricsDetails');
            if (details) {
              details.textContent = 'Metrics error: ' + metricsError;
            }
          }
        } else {
          latestMetricsData = null;
        }
      } catch (e) {
        document.getElementById('headline').textContent = 'Status error: ' + e;
      }
    }

    async function saveSetupMode() {
      const payload = {
        setup_mode: selectedSetupMode(),
        stable_public_base_url: document.getElementById('stablePublicBaseUrl').value,
      };
      const result = await postJson('/ui/api/config/google', payload);
      const out = document.getElementById('wizardModeResult');
      out.textContent = result.data && result.data.ok
        ? 'Mode saved successfully.'
        : 'Failed to save mode: ' + ((result.data && result.data.error) || 'unknown');
      await refresh();
    }

    async function saveConfig() {
      const payload = {
        dashboard_local_name: document.getElementById('dashboardLocalName').value,
        setup_mode: selectedSetupMode(),
        stable_public_base_url: document.getElementById('stablePublicBaseUrl').value,
        google_client_id: document.getElementById('googleClientId').value,
        google_redirect_uri: document.getElementById('googleRedirectUri').value,
        google_scope: document.getElementById('googleScope').value,
        google_prompt: document.getElementById('googlePrompt').value,
        google_allowed_domain: document.getElementById('googleAllowedDomain').value,
        google_enabled: (document.getElementById('googleEnabled').value || '').toLowerCase() === 'true',
        google_auto_redirect_from_public_url: (document.getElementById('googleAutoRedirect').value || '').toLowerCase() === 'true',
        telegram_enabled: (document.getElementById('telegramEnabled').value || '').toLowerCase() === 'true',
        telegram_bot_username: document.getElementById('telegramBotUsername').value,
      };
      const googleSecret = (document.getElementById('googleClientSecret').value || '').trim();
      if (googleSecret) {
        payload.google_client_secret = googleSecret;
      }
      const telegramToken = (document.getElementById('telegramBotToken').value || '').trim();
      if (telegramToken) {
        payload.telegram_bot_token = telegramToken;
      }
      const result = await postJson('/ui/api/config/google', payload);
      document.getElementById('saveResult').textContent = result.data && result.data.ok
        ? 'Saved. ' + (result.data.message || '')
        : 'Save failed: ' + ((result.data && result.data.error) || 'unknown');
      await refresh();
    }

    async function completeSetup() {
      const result = await postJson('/ui/api/setup/complete', {});
      const out = document.getElementById('wizardCompleteResult');
      out.textContent = result.data && result.data.ok
        ? (result.data.message || 'Setup completed.')
        : 'Cannot complete setup: ' + ((result.data && result.data.error) || 'unknown');
      await refresh();
    }

    async function reopenSetup() {
      const result = await postJson('/ui/api/setup/reset', {});
      const dashboardActions = document.getElementById('dashboardActions');
      if (dashboardActions) {
        dashboardActions.textContent = result.data && result.data.ok
          ? 'Setup wizard reopened.'
          : 'Failed to reopen wizard.';
      }
      currentWizardStep = 1;
      await refresh();
    }

    document.getElementById('saveBtn').addEventListener('click', () => { saveConfig().catch(console.error); });
    document.getElementById('refreshBtn').addEventListener('click', () => { refresh().catch(console.error); });
    document.getElementById('copyRedirectBtn').addEventListener('click', () => { copyCurrentRedirectHint().catch(console.error); });
    document.getElementById('wizardModeSaveBtn').addEventListener('click', () => { saveSetupMode().catch(console.error); });
    document.getElementById('wizardModeNextBtn').addEventListener('click', () => { setWizardStep(2); });
    document.getElementById('wizardAuthBackBtn').addEventListener('click', () => { setWizardStep(1); });
    document.getElementById('wizardAuthNextBtn').addEventListener('click', () => { setWizardStep(3); });
    document.getElementById('wizardValidateBackBtn').addEventListener('click', () => { setWizardStep(2); });
    document.getElementById('wizardRefreshBtn').addEventListener('click', () => { refresh().catch(console.error); });
    document.getElementById('wizardCompleteBtn').addEventListener('click', () => { completeSetup().catch(console.error); });
    document.getElementById('reopenWizardBtn').addEventListener('click', () => { reopenSetup().catch(console.error); });

    setWizardStep(1);
    refresh().catch(console.error);
    setInterval(() => refresh().catch(console.error), 5000);
  </script>
</body>
</html>
"""


def _render_telegram_start_html(
    *,
    session_id: str,
    bot_username: str,
    bot_link: str,
    login_code: str,
) -> str:
    safe_session = session_id[:64]
    safe_username = bot_username[:64]
    safe_link = bot_link[:2048]
    safe_code = login_code[:64]
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Telegram login</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 0; background: #111827; color: #e5e7eb; }}
    .wrap {{ max-width: 720px; margin: 0 auto; padding: 20px; }}
    .card {{ background: #1f2937; border: 1px solid #374151; border-radius: 10px; padding: 16px; margin-bottom: 14px; }}
    .mono {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }}
    .ok {{ color: #34d399; }}
    .warn {{ color: #fbbf24; }}
    .bad {{ color: #f87171; }}
    a.button {{ display:inline-block; padding:10px 14px; border-radius:8px; background:#2563eb; color:white; text-decoration:none; }}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h2>Telegram sign-in</h2>
      <p>Session: <span class="mono">{safe_session}</span></p>
      <p>Bot: <span class="mono">@{safe_username}</span></p>
      <p>One-time login code: <span class="mono">{safe_code}</span></p>
      <p>Open bot and press Start (or send /start login_{safe_code}).</p>
      <p><a class="button" href="{safe_link}" target="_blank" rel="noopener">Open Telegram bot</a></p>
      <p id="status" class="warn">Waiting for Telegram confirmation...</p>
    </div>
  </div>
  <script>
    async function poll() {{
      try {{
        const r = await fetch('/auth/device/status?session_id={safe_session}', {{ cache: 'no-store' }});
        if (!r.ok) {{
          document.getElementById('status').textContent = 'Status request failed: ' + r.status;
          return;
        }}
        const data = await r.json();
        const status = (data.status || '').toLowerCase();
        if (status === 'completed') {{
          document.getElementById('status').innerHTML = '<span class="ok">Success. You can return to the app.</span>';
          return;
        }}
        if (status === 'failed' || status === 'expired') {{
          document.getElementById('status').innerHTML = '<span class="bad">Sign-in failed: ' + (data.error || status) + '</span>';
          return;
        }}
        document.getElementById('status').innerHTML = '<span class="warn">Waiting for Telegram confirmation...</span>';
        setTimeout(poll, 2500);
      }} catch (e) {{
        document.getElementById('status').textContent = 'Status error: ' + e;
        setTimeout(poll, 3000);
      }}
    }}
    poll();
  </script>
</body>
</html>
"""


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "BacklightGateway/0.3"

    def _json_response(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _html_response(self, status: int, body: str) -> None:
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _redirect_response(self, location: str, status: int = 302) -> None:
        self.send_response(status)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _client_ip(self) -> str:
        xff = self.headers.get("X-Forwarded-For", "").strip()
        if xff:
            return xff.split(",")[0].strip()
        if self.client_address:
            return str(self.client_address[0])
        return "unknown"

    def _is_local_client(self) -> bool:
        raw_ip = self._client_ip()
        try:
            addr = ipaddress.ip_address(raw_ip)
        except Exception:
            return False
        return addr.is_loopback or addr.is_private or addr.is_link_local

    def _require_local_ui(self) -> bool:
        if self._is_local_client():
            return True
        if self.path.startswith("/ui/api/"):
            self._json_response(
                HTTPStatus.FORBIDDEN,
                {"ok": False, "error": "UI is available only from local network"},
            )
            return False
        self._html_response(
            HTTPStatus.FORBIDDEN,
            "<h1>403</h1><p>UI is available only from local network.</p>",
        )
        return False

    def _require_diagnostics_key_if_enabled(self) -> tuple[bool, str]:
        if not DIAGNOSTICS_API_KEY:
            return True, "ok"
        received = self.headers.get("X-API-Key", "")
        if hmac.compare_digest(received, DIAGNOSTICS_API_KEY):
            return True, "ok"
        return False, "Invalid diagnostics API key"

    def _require_analytics_key_if_enabled(self) -> tuple[bool, str]:
        if not ANALYTICS_API_KEY:
            return True, "ok"
        received = self.headers.get("X-API-Key", "")
        if hmac.compare_digest(received, ANALYTICS_API_KEY):
            return True, "ok"
        return False, "Invalid analytics API key"

    def _google_callback_html(self, *, ok: bool, message: str, subject: str = "") -> str:
        status_label = "SUCCESS" if ok else "FAILED"
        color = "#34d399" if ok else "#f87171"
        safe_subject = subject[:48]
        return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Google auth callback</title></head>
<body style="font-family:Arial,sans-serif;background:#111827;color:#e5e7eb;padding:24px;">
  <h2 style="color:{color};">Google sign-in {status_label}</h2>
  <p>{message}</p>
  <p style="font-family:monospace;">subject: {safe_subject}</p>
  <p>You can close this tab and return to the app/dashboard.</p>
</body></html>"""

    def log_message(self, format_str, *args):
        safe_message = {
            "ts_utc": utc_now_iso(),
            "remote": self._client_ip(),
            "method": self.command,
            "path": self.path.split("?", 1)[0],
            "msg": format_str % args,
        }
        print(json.dumps(safe_message, ensure_ascii=True), flush=True)

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health":
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": "gateway",
                    "time_utc": utc_now_iso(),
                    "uptime_sec": int(time.time()) - STARTED_AT_UNIX,
                },
            )
            return

        if path in {"/", "/ui"}:
            if not self._require_local_ui():
                return
            if path == "/":
                self._redirect_response("/ui")
                return
            self._html_response(HTTPStatus.OK, _render_dashboard_html())
            return

        if path == "/ui/api/status":
            if not self._require_local_ui():
                return
            self._json_response(HTTPStatus.OK, _dashboard_status_payload())
            return

        if path == "/ui/api/metrics":
            if not self._require_local_ui():
                return
            self._json_response(HTTPStatus.OK, _dashboard_metrics_payload())
            return

        if path == "/auth/google/start":
            state = str(query.get("state", [str(uuid.uuid4())])[0]).strip() or str(uuid.uuid4())
            mode = str(query.get("mode", ["redirect"])[0]).strip().lower()

            if not _google_config_ready():
                error_payload = {"ok": False, "error": "Google auth is not configured"}
                if mode == "json":
                    self._json_response(HTTPStatus.BAD_REQUEST, error_payload)
                else:
                    self._html_response(
                        HTTPStatus.BAD_REQUEST,
                        "<h1>Google auth is not configured</h1><p>Open /ui and fill Google config.</p>",
                    )
                return

            auth_url = _build_google_start_url(state=state)
            if mode == "json":
                self._json_response(
                    HTTPStatus.OK,
                    {
                        "ok": True,
                        "provider": "google",
                        "auth_url": auth_url,
                        "state": state,
                    },
                )
                return
            self._redirect_response(auth_url)
            return

        if path == "/auth/google/callback":
            state = str(query.get("state", [""])[0]).strip()
            code = str(query.get("code", [""])[0]).strip()
            error = str(query.get("error", [""])[0]).strip()

            if error:
                if state:
                    _update_device_session_from_event(
                        session_id=state,
                        provider="google",
                        ok=False,
                        error=error,
                        subject="",
                    )
                add_auth_ticket("google", bool(code), error, "")
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    self._google_callback_html(ok=False, message=f"Google error: {error}"),
                )
                return

            if not code:
                if state:
                    _update_device_session_from_event(
                        session_id=state,
                        provider="google",
                        ok=False,
                        error="missing code",
                        subject="",
                    )
                add_auth_ticket("google", False, "missing code", "")
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    self._google_callback_html(ok=False, message="Missing OAuth code"),
                )
                return

            exchanged_ok, token_payload, exchange_message = _exchange_google_code(code)
            if not exchanged_ok:
                if state:
                    _update_device_session_from_event(
                        session_id=state,
                        provider="google",
                        ok=False,
                        error=exchange_message,
                        subject="",
                    )
                add_auth_ticket("google", True, exchange_message, "")
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    self._google_callback_html(ok=False, message=exchange_message),
                )
                return

            id_token = str(token_payload.get("id_token", "")).strip()
            if not id_token:
                message = "Google token response has no id_token"
                if state:
                    _update_device_session_from_event(
                        session_id=state,
                        provider="google",
                        ok=False,
                        error=message,
                        subject="",
                    )
                add_auth_ticket("google", True, message, "")
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    self._google_callback_html(ok=False, message=message),
                )
                return

            verify_ok, user_payload, verify_message = _verify_google_id_token(id_token)
            if not verify_ok:
                if state:
                    _update_device_session_from_event(
                        session_id=state,
                        provider="google",
                        ok=False,
                        error=verify_message,
                        subject="",
                    )
                add_auth_ticket("google", True, verify_message, "")
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    self._google_callback_html(ok=False, message=verify_message),
                )
                return

            subject = hash_subject("google", str(user_payload.get("sub", "")))
            add_auth_ticket("google", True, None, subject)
            if state:
                _update_device_session_from_event(
                    session_id=state,
                    provider="google",
                    ok=True,
                    error=None,
                    subject=subject,
                )

            self._html_response(
                HTTPStatus.OK,
                self._google_callback_html(ok=True, message="Google sign-in completed", subject=subject),
            )
            return

        if path == "/auth/telegram/start":
            state = str(query.get("state", [""])[0]).strip()
            if not state:
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    "<h1>Telegram auth session id is required</h1><p>Missing state query parameter.</p>",
                )
                return

            _poll_telegram_login_updates()
            session_record = _get_device_session(state)
            if session_record is None:
                self._html_response(
                    HTTPStatus.NOT_FOUND,
                    "<h1>Session not found</h1><p>Telegram auth session was not found or has expired.</p>",
                )
                return
            if str(session_record.get("provider", "")).strip().lower() != "telegram":
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    "<h1>Invalid provider</h1><p>This session is not a Telegram auth session.</p>",
                )
                return

            if str(session_record.get("status", "")).strip().lower() == "completed":
                self._html_response(
                    HTTPStatus.OK,
                    "<h1>Telegram sign-in already completed</h1><p>You can close this tab and return to the app.</p>",
                )
                return

            telegram = _telegram_settings()
            bot_username = str(session_record.get("telegram_bot_username", "")).strip()
            if not bot_username:
                bot_username = str(telegram.get("bot_username", "")).strip()
            bot_link = str(session_record.get("telegram_bot_link", "")).strip()
            if not bot_link and bot_username:
                login_code = str(session_record.get("telegram_login_code", "")).strip().upper()
                if login_code:
                    bot_link = _telegram_bot_link(bot_username, login_code)
            login_code = str(session_record.get("telegram_login_code", "")).strip().upper()
            if not bot_username or not login_code:
                self._html_response(
                    HTTPStatus.BAD_REQUEST,
                    "<h1>Telegram auth is not configured</h1><p>Open /ui and fill Telegram bot config first.</p>",
                )
                return
            if not bot_link:
                bot_link = f"https://t.me/{bot_username}"

            self._html_response(
                HTTPStatus.OK,
                _render_telegram_start_html(
                    session_id=state,
                    bot_username=bot_username,
                    bot_link=bot_link,
                    login_code=login_code,
                ),
            )
            return

        if path == "/auth/callback":
            provider = str(query.get("provider", ["unknown"])[0]).strip()
            code = str(query.get("code", [""])[0]).strip()
            state = str(query.get("state", [""])[0]).strip()
            error = str(query.get("error", [""])[0]).strip() or None
            subject_seed = code or state or str(uuid.uuid4())
            subject = hash_subject(provider, subject_seed)
            ticket = add_auth_ticket(provider=provider, had_code=bool(code), error=error, subject=subject)

            if state:
                _update_device_session_from_event(
                    session_id=state,
                    provider=provider,
                    ok=(error is None and bool(code)),
                    error=error,
                    subject=subject,
                )

            response = {
                "ok": error is None,
                "provider": provider,
                "ticket": ticket,
                "code_received": bool(code),
                "state_received": bool(state),
                "error": error,
                "subject": subject,
                "expires_in_sec": 300,
            }
            if APP_REDIRECT_BASE:
                response["next_hint"] = f"{APP_REDIRECT_BASE}?ticket={ticket}&provider={provider}"
            self._json_response(HTTPStatus.OK, response)
            return

        if path == "/auth/ticket":
            ticket = str(query.get("ticket", [""])[0]).strip()
            if not ticket:
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "ticket query parameter is required"},
                )
                return
            record = get_auth_ticket(ticket)
            if record is None:
                self._json_response(
                    HTTPStatus.NOT_FOUND,
                    {"ok": False, "error": "ticket not found or expired"},
                )
                return
            self._json_response(HTTPStatus.OK, {"ok": True, "ticket": ticket, "record": record})
            return

        if path == "/auth/device/status":
            session_id = str(query.get("session_id", [""])[0]).strip()
            if not session_id:
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "session_id query parameter is required"},
                )
                return

            session_record = _get_device_session(session_id)
            if session_record is None:
                self._json_response(
                    HTTPStatus.NOT_FOUND,
                    {"ok": False, "error": "session not found"},
                )
                return

            if (
                str(session_record.get("provider", "")).strip().lower() == "telegram"
                and str(session_record.get("status", "")).strip().lower() == "pending"
            ):
                _poll_telegram_login_updates()
                refreshed = _get_device_session(session_id)
                if refreshed is not None:
                    session_record = refreshed

            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "session_id": session_id,
                    "provider": session_record.get("provider"),
                    "status": session_record.get("status"),
                    "subject": session_record.get("subject"),
                    "error": session_record.get("error"),
                    "message": "session status",
                },
            )
            return

        if path == "/profiles/manifest":
            if not PROFILE_MANIFEST_PATH.exists():
                self._json_response(
                    HTTPStatus.NOT_FOUND,
                    {"ok": False, "error": "manifest not found"},
                )
                return
            try:
                payload = json.loads(PROFILE_MANIFEST_PATH.read_text(encoding="utf-8"))
                if not isinstance(payload, dict) and not isinstance(payload, list):
                    raise ValueError("invalid manifest payload")
            except Exception as exc:  # noqa: BLE001
                self._json_response(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": f"manifest read error: {exc}"},
                )
                return
            self._json_response(HTTPStatus.OK, {"ok": True, "manifest": payload})
            return

        self._json_response(HTTPStatus.NOT_FOUND, {"ok": False, "error": "Not found"})

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/ui/api/config/google":
            if not self._require_local_ui():
                return
            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
                return
            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "JSON body must be an object"},
                )
                return

            _update_runtime_config(payload)
            status_payload = _dashboard_status_payload()
            runtime_cfg = status_payload.get("runtime_config", {})
            local_name = str(runtime_cfg.get("dashboard_local_name", LOCAL_DASHBOARD_NAME))
            message = (
                f"Configuration saved. Dashboard host is http://{local_name}.local "
                "(if hostname/mdns are configured on host OS)."
            )
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "message": message,
                    "runtime_config": runtime_cfg,
                    "setup": status_payload.get("setup", {}),
                },
            )
            return

        if path == "/ui/api/setup/complete":
            if not self._require_local_ui():
                return
            status_payload = _dashboard_status_payload()
            setup = status_payload.get("setup", {})
            if not isinstance(setup, dict) or not bool(setup.get("ready")):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {
                        "ok": False,
                        "error": "Setup is not ready yet",
                        "setup": setup,
                    },
                )
                return
            _update_runtime_config(
                {
                    "setup_completed": True,
                    "setup_completed_at_utc": utc_now_iso(),
                }
            )
            updated_status = _dashboard_status_payload()
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "message": "Setup completed. Dashboard mode is now active.",
                    "setup": updated_status.get("setup", {}),
                    "runtime_config": updated_status.get("runtime_config", {}),
                },
            )
            return

        if path == "/ui/api/setup/reset":
            if not self._require_local_ui():
                return
            _update_runtime_config(
                {
                    "setup_completed": False,
                    "setup_completed_at_utc": "",
                }
            )
            updated_status = _dashboard_status_payload()
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "message": "Setup wizard has been reopened.",
                    "setup": updated_status.get("setup", {}),
                    "runtime_config": updated_status.get("runtime_config", {}),
                },
            )
            return

        if path == "/auth/device/start":
            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
                return

            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "JSON body must be an object"},
                )
                return

            provider = str(payload.get("provider", "unknown")).strip().lower()
            external_auth_url = str(payload.get("external_auth_url", "")).strip()
            start_ok, start_message, session_record = _start_device_session(
                provider=provider,
                external_auth_url=external_auth_url,
            )
            if not start_ok or session_record is None:
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": start_message},
                )
                return

            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "message": "device auth session started",
                    "session_id": session_record["session_id"],
                    "provider": session_record["provider"],
                    "status": session_record["status"],
                    "auth_url": session_record["auth_url"],
                    "telegram_bot_link": session_record.get("telegram_bot_link", ""),
                    "expires_in_sec": AUTH_DEVICE_SESSION_TTL_SEC,
                },
            )
            return

        if path == "/auth/telegram/verify":
            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
                return

            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "JSON body must be an object"},
                )
                return

            ok, reason = _verify_telegram_payload(payload)
            if not ok:
                self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": reason})
                return

            raw_user_id = str(payload.get("id", ""))
            subject = hash_subject("telegram", raw_user_id)
            auth_date = int(payload.get("auth_date"))
            age_sec = int(time.time()) - auth_date
            session_state = str(payload.get("state", "")).strip()
            if session_state:
                _update_device_session_from_event(
                    session_id=session_state,
                    provider="telegram",
                    ok=True,
                    error=None,
                    subject=subject,
                )

            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "provider": "telegram",
                    "subject": subject,
                    "auth_age_sec": age_sec,
                    "time_utc": utc_now_iso(),
                },
            )
            return

        if path == "/analytics/ingest":
            key_ok, key_message = self._require_analytics_key_if_enabled()
            if not key_ok:
                self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": key_message})
                return

            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
                return

            events, dropped, error = _normalize_analytics_events_payload(payload)
            if error:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": error})
                return
            batch_id = str(uuid.uuid4())
            now_unix = int(time.time())
            schema = "anonymous_analytics_v1"
            if isinstance(payload, dict):
                schema_raw = str(payload.get("schema", "")).strip()
                if schema_raw:
                    schema = schema_raw[:120]
            batch = {
                "batch_id": batch_id,
                "received_at_utc": utc_now_iso(),
                "received_at_unix": now_unix,
                "schema": schema,
                "events": events,
                "events_count": len(events),
                "dropped_events": dropped,
            }
            day = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
            out_dir = ANALYTICS_DIR / day
            out_path = out_dir / f"{now_unix}_{batch_id}.json"
            try:
                write_json(out_path, batch)
                _invalidate_metrics_cache()
            except Exception as exc:  # noqa: BLE001
                self._json_response(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": f"write error: {exc}"},
                )
                return

            self._json_response(
                HTTPStatus.ACCEPTED,
                {
                    "ok": True,
                    "batch_id": batch_id,
                    "accepted_events": len(events),
                    "dropped_events": dropped,
                    "stored": True,
                    "stored_path_hint": str(out_path.relative_to(DATA_DIR)),
                },
            )
            return

        if path == "/diagnostics/ingest":
            key_ok, key_message = self._require_diagnostics_key_if_enabled()
            if not key_ok:
                self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False, "error": key_message})
                return

            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(HTTPStatus.BAD_REQUEST, {"ok": False, "error": str(exc)})
                return

            sanitized = sanitize_payload(payload)
            event_id = str(uuid.uuid4())
            event = {
                "event_id": event_id,
                "received_at_utc": utc_now_iso(),
                "schema_version": 1,
                "payload": sanitized,
            }
            day = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
            out_dir = DIAGNOSTICS_DIR / day
            out_path = out_dir / f"{event_id}.json"

            try:
                write_json(out_path, event)
                _invalidate_metrics_cache()
            except Exception as exc:  # noqa: BLE001
                self._json_response(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": f"write error: {exc}"},
                )
                return

            self._json_response(
                HTTPStatus.ACCEPTED,
                {
                    "ok": True,
                    "event_id": event_id,
                    "stored": True,
                    "stored_path_hint": str(out_path.relative_to(DATA_DIR)),
                },
            )
            return

        self._json_response(HTTPStatus.NOT_FOUND, {"ok": False, "error": "Not found"})


def run() -> None:
    ensure_directories()
    _load_runtime_config()
    server = ThreadingHTTPServer((HOST, PORT), GatewayHandler)
    print(
        json.dumps(
            {
                "ts_utc": utc_now_iso(),
                "msg": "gateway started",
                "host": HOST,
                "port": PORT,
                "data_dir": str(DATA_DIR),
                "dashboard_hint": f"http://{LOCAL_DASHBOARD_NAME}.local",
                "quick_tunnel_log_path": str(QUICK_TUNNEL_LOG_PATH),
            },
            ensure_ascii=True,
        ),
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    run()
