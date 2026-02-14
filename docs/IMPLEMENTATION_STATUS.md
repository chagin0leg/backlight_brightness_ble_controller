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
- Auth provider model and UI hooks are implemented.
- Guest mode auth session shortcut is implemented.
- Device auth polling loop is implemented in client auth controller.
- Client now supports browser launch, pending-session control, and polling retry guardrails.
- Session persistence, restoration after restart, and expiry-based re-auth prompts are implemented.
- Main app screen now uses grouped sections (cloud/auth/device/diagnostics/ads) with clearer onboarding actions.
- Basic AdMob banner runtime integration is implemented with platform-safe fallback.

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
- Ads integration exists, but monetization tuning (placement strategy, frequency, consent UX) is pending.
- No full settings UX with durable preferences beyond auth session yet.
- No mature reconnect orchestration and fallback strategy yet.
- No automated tests/CI coverage for new flows yet.
- No signed profile update pipeline yet.

## Bottom line

The project already has a **real working technical core**, but it is still in **early productization stage**.

In short:
- Not "just a plan" anymore.
- Not yet a finished consumer product release.
