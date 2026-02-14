#!/usr/bin/env python3
"""
Headless control-plane gateway for the Backlight product.

Features:
- Local-only web console for setup/actions/dashboard (served at *.local)
- Device authorization flow endpoints
- Google OAuth callback/token exchange
- Telegram payload verification
- Anonymous diagnostics ingest with PII key redaction
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
SUBJECT_SALT = os.getenv("AUTH_SUBJECT_SALT", "change-me").strip()
DIAGNOSTICS_API_KEY = os.getenv("DIAGNOSTICS_INGEST_API_KEY", "").strip()
APP_REDIRECT_BASE = os.getenv("APP_REDIRECT_BASE", "").strip()
AUTH_DEVICE_SESSION_TTL_SEC = int(os.getenv("AUTH_DEVICE_SESSION_TTL_SEC", "300"))
LOCAL_DASHBOARD_NAME = os.getenv("LOCAL_DASHBOARD_NAME", "backlight").strip() or "backlight"

DIAGNOSTICS_DIR = DATA_DIR / "diagnostics"
PROFILE_DIR = DATA_DIR / "profiles"
PROFILE_MANIFEST_PATH = PROFILE_DIR / "manifest.json"
RUNTIME_CONFIG_PATH = DATA_DIR / "runtime_config.json"
RUNTIME_SHARED_DIR = pathlib.Path(os.getenv("RUNTIME_SHARED_DIR", "/runtime"))
QUICK_TUNNEL_LOG_PATH = pathlib.Path(
    os.getenv("QUICK_TUNNEL_LOG_PATH", str(RUNTIME_SHARED_DIR / "cloudflared.log"))
)

_ticket_store_lock = threading.Lock()
_auth_ticket_store: dict[str, dict[str, object]] = {}
_device_session_store_lock = threading.Lock()
_device_session_store: dict[str, dict[str, object]] = {}
_runtime_config_lock = threading.Lock()
_runtime_config_cache: dict[str, object] | None = None

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


def ensure_directories() -> None:
    DIAGNOSTICS_DIR.mkdir(parents=True, exist_ok=True)
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
    return {
        "dashboard_local_name": LOCAL_DASHBOARD_NAME,
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
        "google_enabled",
        "google_client_id",
        "google_client_secret",
        "google_redirect_uri",
        "google_auto_redirect_from_public_url",
        "google_scope",
        "google_prompt",
        "google_allowed_domain",
        "google_require_verified_email",
    }
    sanitized_patch: dict[str, object] = {}
    for key, value in patch.items():
        if key not in allowed_keys:
            continue
        if key in {
            "dashboard_local_name",
            "google_client_id",
            "google_client_secret",
            "google_redirect_uri",
            "google_scope",
            "google_prompt",
            "google_allowed_domain",
        }:
            text = str(value).strip()[:4096]
            if key == "dashboard_local_name":
                text = "".join(ch for ch in text.lower() if ch.isalnum() or ch == "-")
                text = text.strip("-") or LOCAL_DASHBOARD_NAME
            sanitized_patch[key] = text
            continue
        if key in {
            "google_enabled",
            "google_require_verified_email",
            "google_auto_redirect_from_public_url",
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

    if normalized_provider == "google":
        if not _google_config_ready():
            return False, "Google auth is not configured yet", None
        auth_url = _with_query("/auth/google/start", {"state": session_id})
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
    }
    with _device_session_store_lock:
        _device_session_store[session_id] = record
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
        return True


def _verify_telegram_payload(payload: dict) -> tuple[bool, str]:
    incoming_hash = payload.get("hash")
    if not isinstance(incoming_hash, str) or not incoming_hash:
        return False, "Missing hash field"
    if not TELEGRAM_BOT_TOKEN:
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

    secret_key = hashlib.sha256(TELEGRAM_BOT_TOKEN.encode("utf-8")).digest()
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


def _dashboard_status_payload() -> dict[str, object]:
    runtime = _get_runtime_config()
    google = _google_settings()
    device_stats = _device_session_stats()
    uptime_sec = int(time.time()) - STARTED_AT_UNIX
    local_name = str(runtime.get("dashboard_local_name", LOCAL_DASHBOARD_NAME)).strip() or LOCAL_DASHBOARD_NAME
    public_base_url = _quick_tunnel_public_base_url()
    google_redirect_hint = _google_redirect_hint_from_public_url(public_base_url)
    current_google_redirect = str(google["redirect_uri"]).strip()
    auto_redirect_enabled = bool(google["auto_redirect_from_public_url"])
    google_redirect_matches_hint = bool(
        google_redirect_hint
        and _normalize_redirect_uri(current_google_redirect)
        == _normalize_redirect_uri(google_redirect_hint)
    )

    google_ready = bool(
        google["enabled"]
        and google["client_id"]
        and google["client_secret"]
        and google["redirect_uri"]
    )

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
            "done": bool(public_base_url),
            "details": (
                f"Current URL: {public_base_url}"
                if public_base_url
                else "Quick tunnel URL not detected yet. Wait for cloudflared startup."
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
        },
        "auth": {
            "tickets_active": len(_auth_ticket_store),
            "device_sessions": device_stats,
            "google_configured": google_ready,
            "google_enabled": bool(google["enabled"]),
            "google_start_endpoint": "/auth/google/start",
            "google_callback_endpoint": "/auth/google/callback",
            "public_base_url": public_base_url,
            "google_redirect_hint": google_redirect_hint,
            "google_redirect_matches_hint": google_redirect_matches_hint,
            "google_auto_redirect_from_public_url": auto_redirect_enabled,
        },
        "setup_steps": steps,
        "runtime_config": {
            "dashboard_local_name": local_name,
            "google_enabled": bool(google["enabled"]),
            "google_client_id": str(google["client_id"]),
            "google_redirect_uri": str(google["redirect_uri"]),
            "google_scope": str(google["scope"]),
            "google_prompt": str(google["prompt"]),
            "google_allowed_domain": str(google["allowed_domain"]),
            "google_require_verified_email": bool(google["require_verified_email"]),
            "google_client_secret_configured": bool(google["client_secret"]),
            "public_base_url": public_base_url,
            "google_redirect_hint": google_redirect_hint,
            "google_redirect_matches_hint": google_redirect_matches_hint,
            "google_auto_redirect_from_public_url": auto_redirect_enabled,
        },
        "actions": [
            "Open /ui to complete setup actions in browser",
            "Run: sudo systemctl restart backlight-stack.service (apply env/hostname changes)",
            "Run: sudo systemctl enable --now backlight-hil.service (optional HIL mode)",
            "Use /auth/google/start to test Google login",
            "Use /health for probe checks",
            (
                f"Update Google OAuth Redirect URI to: {google_redirect_hint}"
                if google_redirect_hint and not google_redirect_matches_hint
                else "Google Redirect URI is synchronized with current public URL"
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
    @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Backlight Local Console</h1>
      <div id="headline" class="muted">Loading status...</div>
    </div>

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
      <h2>Google auth config</h2>
      <p class="muted">All required setup actions are available here. Save config, then test Google flow.</p>
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
          <label>Google Client Secret</label>
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
      </div>
      <div style="margin-top: 12px; display: flex; gap: 8px; flex-wrap: wrap;">
        <button id="saveBtn" type="button">Save config</button>
        <button id="refreshBtn" type="button">Refresh status</button>
        <button id="copyRedirectBtn" type="button">Copy current Redirect URI</button>
        <a id="googleStartLink" href="/auth/google/start" style="color:#93c5fd; align-self:center;">Start Google login test</a>
      </div>
      <div id="saveResult" class="muted" style="margin-top: 8px;"></div>
    </div>

    <div class="card">
      <h2>Endpoints</h2>
      <ul>
        <li><span class="mono">GET /health</span></li>
        <li><span class="mono">POST /auth/device/start</span></li>
        <li><span class="mono">GET /auth/device/status?session_id=...</span></li>
        <li><span class="mono">GET /auth/google/start</span></li>
        <li><span class="mono">GET /auth/google/callback</span></li>
        <li><span class="mono">POST /diagnostics/ingest</span></li>
      </ul>
    </div>
  </div>

  <script>
    let latestRedirectHint = '';

    async function fetchStatus() {
      const r = await fetch('/ui/api/status', { cache: 'no-store' });
      if (!r.ok) {
        throw new Error('Status request failed: ' + r.status);
      }
      return await r.json();
    }

    function renderSteps(steps) {
      const root = document.getElementById('steps');
      root.innerHTML = '';
      for (const step of steps || []) {
        const li = document.createElement('li');
        li.innerHTML = step.done
          ? `<span class="ok">[OK]</span> ${step.title} <div class="muted">${step.details || ''}</div>`
          : `<span class="warn">[TODO]</span> ${step.title} <div class="muted">${step.details || ''}</div>`;
        root.appendChild(li);
      }
    }

    function renderStatus(data) {
      document.getElementById('headline').textContent =
        `Host: ${data.dashboard_host} | Uptime: ${data.uptime_sec}s | UTC: ${data.time_utc}`;

      const auth = data.auth || {};
      const svc = data.service || {};
      const lines = [
        `device_sessions.total=${(auth.device_sessions || {}).total || 0}`,
        `device_sessions.pending=${(auth.device_sessions || {}).pending || 0}`,
        `device_sessions.completed=${(auth.device_sessions || {}).completed || 0}`,
        `google.configured=${auth.google_configured}`,
        `google.enabled=${auth.google_enabled}`,
        `public.base_url=${auth.public_base_url || '-'}`,
        `google.redirect_hint=${auth.google_redirect_hint || '-'}`,
        `diagnostics.count=${svc.diagnostics_count || 0}`,
      ];
      document.getElementById('status').textContent = lines.join('\\n');

      renderSteps(data.setup_steps || []);

      const cfg = data.runtime_config || {};
      document.getElementById('dashboardLocalName').value = cfg.dashboard_local_name || '';
      document.getElementById('googleClientId').value = cfg.google_client_id || '';
      document.getElementById('googleClientSecret').value = '';
      document.getElementById('googleRedirectUri').value = cfg.google_redirect_uri || '';
      document.getElementById('googleScope').value = cfg.google_scope || '';
      document.getElementById('googlePrompt').value = cfg.google_prompt || '';
      document.getElementById('googleAllowedDomain').value = cfg.google_allowed_domain || '';
      document.getElementById('googleEnabled').value = String(cfg.google_enabled || false);
      document.getElementById('googleAutoRedirect').value = String(cfg.google_auto_redirect_from_public_url !== false);
      document.getElementById('googleStartLink').href = '/auth/google/start';

      const hintEl = document.getElementById('publicUrlHint');
      const publicBase = cfg.public_base_url || '';
      const redirectHint = cfg.google_redirect_hint || '';
      latestRedirectHint = redirectHint;
      const redirectMatches = !!cfg.google_redirect_matches_hint;
      if (!publicBase) {
        hintEl.innerHTML = '<span class="warn">No public URL detected yet.</span> If this is a fresh start, wait 10-20s and press Refresh.';
      } else if (!redirectMatches) {
        hintEl.innerHTML = `<span class="warn">Public URL changed:</span> <span class="mono">${publicBase}</span><br/>Update Google Redirect URI to <span class="mono">${redirectHint}</span> in Google Console and here, then Save.`;
      } else {
        hintEl.innerHTML = `<span class="ok">Public URL active:</span> <span class="mono">${publicBase}</span><br/><span class="ok">Google Redirect URI is up to date.</span>`;
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
      } catch (e) {
        document.getElementById('headline').textContent = 'Status error: ' + e;
      }
    }

    async function saveConfig() {
      const payload = {
        dashboard_local_name: document.getElementById('dashboardLocalName').value,
        google_client_id: document.getElementById('googleClientId').value,
        google_client_secret: document.getElementById('googleClientSecret').value,
        google_redirect_uri: document.getElementById('googleRedirectUri').value,
        google_scope: document.getElementById('googleScope').value,
        google_prompt: document.getElementById('googlePrompt').value,
        google_allowed_domain: document.getElementById('googleAllowedDomain').value,
        google_enabled: (document.getElementById('googleEnabled').value || '').toLowerCase() === 'true',
        google_auto_redirect_from_public_url: (document.getElementById('googleAutoRedirect').value || '').toLowerCase() === 'true',
      };
      const r = await fetch('/ui/api/config/google', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await r.json();
      document.getElementById('saveResult').textContent = data.ok
        ? 'Saved. ' + (data.message || '')
        : 'Save failed: ' + (data.error || 'unknown');
      await refresh();
    }

    document.getElementById('saveBtn').addEventListener('click', () => { saveConfig().catch(console.error); });
    document.getElementById('refreshBtn').addEventListener('click', () => { refresh().catch(console.error); });
    document.getElementById('copyRedirectBtn').addEventListener('click', () => { copyCurrentRedirectHint().catch(console.error); });
    refresh().catch(console.error);
    setInterval(() => refresh().catch(console.error), 5000);
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
            effective = _get_runtime_config()
            local_name = str(effective.get("dashboard_local_name", LOCAL_DASHBOARD_NAME))
            public_base_url = _quick_tunnel_public_base_url()
            google_redirect_hint = _google_redirect_hint_from_public_url(public_base_url)
            current_redirect_uri = str(effective.get("google_redirect_uri", "")).strip()
            google_redirect_matches_hint = bool(
                google_redirect_hint
                and _normalize_redirect_uri(current_redirect_uri)
                == _normalize_redirect_uri(google_redirect_hint)
            )
            message = (
                f"Configuration saved. Dashboard host is http://{local_name}.local "
                "(if hostname/mdns are configured on host OS)."
            )
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "message": message,
                    "runtime_config": {
                        "dashboard_local_name": local_name,
                        "google_enabled": _parse_bool(effective.get("google_enabled", False), False),
                        "google_client_id": str(effective.get("google_client_id", "")),
                        "google_redirect_uri": current_redirect_uri,
                        "google_scope": str(effective.get("google_scope", "")),
                        "google_prompt": str(effective.get("google_prompt", "")),
                        "google_allowed_domain": str(effective.get("google_allowed_domain", "")),
                        "google_auto_redirect_from_public_url": _parse_bool(
                            effective.get("google_auto_redirect_from_public_url", True),
                            True,
                        ),
                        "google_client_secret_configured": bool(
                            str(effective.get("google_client_secret", "")).strip()
                        ),
                        "public_base_url": public_base_url,
                        "google_redirect_hint": google_redirect_hint,
                        "google_redirect_matches_hint": google_redirect_matches_hint,
                    },
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
