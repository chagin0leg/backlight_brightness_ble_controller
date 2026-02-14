# Current Implementation Status

This document is a plain status snapshot of what is already implemented versus what is still pending.

## What is already implemented

## Core product flow (working baseline)

- BLE scan/connect/pair/disconnect flow exists.
- Profile-based device matching exists (instead of hardcoded single path).
- ELK-BLEDOM profile is included as JSON profile.
- Brightness-to-command sync pipeline exists.
- Basic anti-spam threshold on brightness writes exists.

## Unknown device handling

- Unknown profile detection exists.
- Local diagnostics snapshot generation exists.
- Optional diagnostics upload endpoint integration exists (opt-in).

## Configuration and cloud scaffolding

- Runtime cloud config file is supported (`assets/runtime/app_cloud_config.json`).
- Remote profile manifest loading path exists.
- Signed remote profile manifest verification (Ed25519 envelope) is implemented.
- Auth provider model and UI hooks are implemented.
- Guest mode is disabled by product policy.
- Device auth polling loop is implemented in client auth controller.
- Client now supports browser launch, pending-session control, and polling retry guardrails.
- Session persistence, restoration after restart, and expiry-based re-auth prompts are implemented.
- Auth session storage now uses secure storage when available, with safe fallback for unsupported environments.
- Main app screen now uses grouped sections (cloud/auth/device/diagnostics/ads) with clearer onboarding actions.
- Basic AdMob banner runtime integration is implemented with platform-safe fallback.
- Consent UX gate for non-personalized ads is implemented when required by cloud config.
- Persistent app settings are implemented (poll interval, sync on/off, min/max output brightness, diagnostics consent, anonymous analytics toggle).
- Preferred BLE device persistence and reconnect-focused scanning are implemented for Windows flow.
- Anonymous analytics event schema and client queue/flush pipeline are implemented.
- Telemetry payload sanitizer blocks common direct-identifier keys/values (email/phone/name/token/password).

## Self-hosted backend templates

- Minimal Python gateway implemented:
  - `/health`
  - `/ui`
  - `/ui/api/status`
  - `/ui/api/config/google`
  - `/auth/device/start`
  - `/auth/device/status`
  - `/auth/google/start`
  - `/auth/google/callback`
  - `/auth/callback`
  - `/auth/ticket`
  - `/auth/telegram/verify`
  - `/diagnostics/ingest`
  - `/profiles/manifest`
- Local dashboard now shows current temporary public URL (trycloudflare) and exact Google redirect hint.
- Local dashboard can auto-follow temporary public URL for Google redirect URI and provides one-click copy button.
- Telegram device auth flow is implemented via bot deep-link + one-time code polling (works with changing public URL).
- Gateway now supports anonymous analytics ingest (`/analytics/ingest`) with sanitized event persistence.
- Local dashboard now has aggregated product KPI feed via `GET /ui/api/metrics`.
- Deploy templates included:
  - Docker Compose
  - Caddy config
  - Cloudflared config template
  - systemd service templates
  - one-click Arch installer script
  - HIL sidecar compose/systemd templates

## What is not yet production-ready

- Cross-platform brightness providers are mostly stubs outside Windows.
- Google OAuth E2E is implemented, but multi-provider production hardening is still pending.
- Product-level visual polish and deeper settings/navigation UX are still pending.
- Ads integration exists, but monetization tuning (placement strategy, frequency) is still pending.
- Reconnect orchestration includes backoff retries and scan-timeout fallback, but still needs wider field tuning.
- Basic automated tests and CI analyze/test workflow are added, but coverage is still early-stage.

## Bottom line

The project already has a **real working technical core**, but it is still in **early productization stage**.

In short:
- Not "just a plan" anymore.
- Not yet a finished consumer product release.
