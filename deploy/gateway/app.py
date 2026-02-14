#!/usr/bin/env python3
"""
Minimal privacy-first gateway for:
- OAuth callback relay
- Telegram auth payload verification
- Anonymous diagnostics ingest

No external dependencies required.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import pathlib
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, parse_qsl, urlencode, urlparse, urlunparse


HOST = os.getenv("GATEWAY_HOST", "0.0.0.0")
PORT = int(os.getenv("GATEWAY_PORT", "8080"))
DATA_DIR = pathlib.Path(os.getenv("DATA_DIR", "/data"))
MAX_BODY_BYTES = int(os.getenv("MAX_BODY_BYTES", "1048576"))

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
SUBJECT_SALT = os.getenv("AUTH_SUBJECT_SALT", "change-me").strip()
DIAGNOSTICS_API_KEY = os.getenv("DIAGNOSTICS_INGEST_API_KEY", "").strip()
APP_REDIRECT_BASE = os.getenv("APP_REDIRECT_BASE", "").strip()
AUTH_DEVICE_SESSION_TTL_SEC = int(os.getenv("AUTH_DEVICE_SESSION_TTL_SEC", "300"))

DIAGNOSTICS_DIR = DATA_DIR / "diagnostics"
PROFILE_DIR = DATA_DIR / "profiles"
PROFILE_MANIFEST_PATH = PROFILE_DIR / "manifest.json"

_ticket_store_lock = threading.Lock()
_auth_ticket_store: dict[str, dict[str, object]] = {}
_device_session_store_lock = threading.Lock()
_device_session_store: dict[str, dict[str, object]] = {}

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


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def ensure_directories() -> None:
    DIAGNOSTICS_DIR.mkdir(parents=True, exist_ok=True)
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)


def write_json(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2), encoding="utf-8")


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


def add_auth_ticket(provider: str, had_code: bool, error: str | None) -> str:
    ticket = str(uuid.uuid4())
    expires_at = int(time.time()) + 300
    with _ticket_store_lock:
        _auth_ticket_store[ticket] = {
            "provider": provider,
            "had_code": had_code,
            "error": error,
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


def _start_device_session(provider: str, external_auth_url: str | None) -> dict[str, object]:
    session_id = str(uuid.uuid4())
    created_at_unix = int(time.time())
    expires_at_unix = created_at_unix + AUTH_DEVICE_SESSION_TTL_SEC

    normalized_provider = (provider or "unknown").strip().lower()
    auth_url = ""
    if external_auth_url and external_auth_url.strip():
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
    return record


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


def verify_telegram_payload(payload: dict) -> tuple[bool, str]:
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


class GatewayHandler(BaseHTTPRequestHandler):
    server_version = "BacklightGateway/0.1"

    def _json_response(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _require_diagnostics_key_if_enabled(self) -> tuple[bool, str]:
        if not DIAGNOSTICS_API_KEY:
            return True, "ok"
        received = self.headers.get("X-API-Key", "")
        if hmac.compare_digest(received, DIAGNOSTICS_API_KEY):
            return True, "ok"
        return False, "Invalid diagnostics API key"

    def log_message(self, format_str, *args):
        """
        Override default HTTP logging to avoid dumping query params/body.
        """
        safe_message = {
            "ts_utc": utc_now_iso(),
            "remote": self.client_address[0] if self.client_address else "unknown",
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
                },
            )
            return

        if path == "/auth/callback":
            provider = str(query.get("provider", ["unknown"])[0])
            code = str(query.get("code", [""])[0])
            state = str(query.get("state", [""])[0])
            error = str(query.get("error", [""])[0]) or None
            subject_seed = code or state or str(uuid.uuid4())
            subject = hash_subject(provider, subject_seed)
            ticket = add_auth_ticket(provider=provider, had_code=bool(code), error=error)

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
                response["next_hint"] = (
                    f"{APP_REDIRECT_BASE}?ticket={ticket}&provider={provider}"
                )
            self._json_response(HTTPStatus.OK, response)
            return

        if path == "/auth/ticket":
            ticket = str(query.get("ticket", [""])[0])
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
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "ticket": ticket,
                    "record": record,
                },
            )
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
                    {
                        "ok": False,
                        "error": "manifest not found",
                    },
                )
                return
            try:
                payload = json.loads(PROFILE_MANIFEST_PATH.read_text(encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001
                self._json_response(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": f"manifest read error: {exc}"},
                )
                return
            self._json_response(HTTPStatus.OK, payload)
            return

        self._json_response(
            HTTPStatus.NOT_FOUND,
            {"ok": False, "error": "Not found"},
        )

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/auth/device/start":
            try:
                payload = parse_json_body(self)
            except ValueError as exc:
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": str(exc)},
                )
                return

            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "JSON body must be an object"},
                )
                return

            provider = str(payload.get("provider", "unknown")).strip().lower()
            external_auth_url = str(payload.get("external_auth_url", "")).strip()
            session_record = _start_device_session(
                provider=provider,
                external_auth_url=external_auth_url,
            )
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
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": str(exc)},
                )
                return

            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "JSON body must be an object"},
                )
                return

            ok, reason = verify_telegram_payload(payload)
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
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": str(exc)},
                )
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

        self._json_response(
            HTTPStatus.NOT_FOUND,
            {"ok": False, "error": "Not found"},
        )


def run() -> None:
    ensure_directories()
    server = ThreadingHTTPServer((HOST, PORT), GatewayHandler)
    print(
        json.dumps(
            {
                "ts_utc": utc_now_iso(),
                "msg": "gateway started",
                "host": HOST,
                "port": PORT,
                "data_dir": str(DATA_DIR),
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
