# Product Roadmap and Implementation Checklist

This document captures the agreed scope for turning the project into a production-ready, multi-platform product.

## Product goals

- Support desktop and mobile platforms:
  - Windows
  - macOS
  - Linux
  - Android
  - iOS
- Support many BLE controller families (not only ELK-BLEDOM).
- Keep the UI simple by default and adaptive to device capabilities.
- Add a diagnostics pipeline for unsupported devices.
- Make new device support distributable to all users without app reinstallation.
- Avoid dedicated servers; rely on free-tier managed/serverless infrastructure.
- Support broad sign-in options (Google, Microsoft, Yandex, Telegram, others where feasible).
- Support low-power self-hosted deployment (Arch Linux, no dedicated IP).
- Monetize via ads with privacy-safe defaults (non-personalized first).
- Collect only anonymous analytics and diagnostics.

## Phase 0: Foundation (current iteration)

- [x] Define product-level roadmap and architecture direction.
- [ ] Implement domain abstractions:
  - [x] `BrightnessProvider`
  - [x] `BleAdapter`
  - [x] `DeviceProfile`
  - [x] `DeviceProfileMatcher`
  - [x] `UnknownDeviceDiagnosticsCollector`
- [x] Move ELK-BLEDOM logic into profile-based matching and command encoding.
- [x] Integrate capability-driven status layer in UI.

## Phase 1: MVP completion

- [x] Brightness-to-command synchronization pipeline.
- [x] Brightness smoothing and hysteresis to avoid BLE spam.
- [x] Stable reconnect and resume behavior.
- [x] Device selection and persistence of preferred device.
- [ ] Basic settings:
  - [x] polling interval
  - [x] min/max output brightness
  - [x] sync on/off
- [ ] System tray support and OS autostart.

## Phase 2: Multi-device and profile platform

- [ ] Introduce profile registry format (JSON-based profiles).
- [ ] Implement confidence-scored auto-detection.
- [ ] Show top profile candidates when confidence is low.
- [ ] Add profile capabilities:
  - [ ] power
  - [ ] brightness
  - [ ] RGB
  - [ ] CCT
  - [ ] effects
- [ ] Add profile override screen for advanced users.

## Phase 3: Diagnostics and profile growth loop

- [ ] Add opt-in "Help add my device" diagnostics flow.
- [ ] Capture:
  - [ ] advertisement data (where available)
  - [ ] services and characteristics
  - [ ] command attempts and responses/errors
  - [ ] app/platform versions
- [ ] Anonymize and sanitize diagnostic payloads.
- [ ] Upload diagnostics to profile backend.
- [ ] Generate profile drafts from diagnostics (human-reviewed).
- [ ] Publish validated profiles to all users via profile updates.

## Phase 3.5: Authentication and free cloud setup

- [x] Add cloud configuration model for no-dedicated-server deployments.
- [x] Add authentication provider abstraction and UI hooks.
- [x] Add device auth session flow (start + polling status).
- [x] Implement Google OAuth callback exchange and token verification on backend.
- [x] Add client-side session persistence/restore and re-auth prompts.
- [x] Add secure auth session storage with fallback.
- [x] Add auth onboarding UX controls (browser launch, cancel/retry, signed-in state).
- [ ] Wire provider entries for:
  - [x] Google
  - [x] Microsoft
  - [x] Yandex
  - [x] Telegram
  - [x] GitHub
  - [x] Apple
  - [x] VK
  - [x] Discord
  - [x] Email magic link
  - [x] Phone OTP
  - [x] Passkey/WebAuthn
  - [x] Anonymous guest
- [x] Add serverless diagnostics upload path (Cloudflare/Supabase/Firebase webhook).
- [x] Add profile registry remote manifest update flow.

## Phase 3.6: Arch Linux lightweight server mode

- [x] Add deployment template for Arch Linux (2c/16GB baseline).
- [x] Configure tunnel-first ingress (Cloudflare Tunnel preferred).
- [x] Expose stable OAuth callback URL behind tunnel hostname.
- [x] Add health checks and watchdog restart policy.
- [x] Keep server role minimal: auth callback, diagnostics ingest, manifest proxy.
- [x] Add local-only headless web console (`*.local`) for setup/actions/status dashboard.
- [x] Add one-button launch script for headless deployment.
- [x] Add HIL sidecar templates for same Arch host.

## Phase 4: Cross-platform implementation matrix

- [ ] Windows
  - [ ] brightness provider (replace PowerShell fallback with native APIs later)
  - [ ] BLE adapter hardening
- [ ] macOS
  - [ ] brightness provider
  - [ ] BLE adapter integration
- [ ] Linux
  - [ ] brightness provider fallback chain
  - [ ] BLE adapter integration
- [ ] Android
  - [ ] brightness provider
  - [ ] BLE adapter integration
  - [ ] runtime permissions flow
- [ ] iOS
  - [ ] brightness provider
  - [ ] BLE adapter integration
  - [ ] permission and background constraints handling

## Phase 5: Product quality and operations

- [ ] Architecture cleanup and modularization.
- [x] Unit tests for matcher, mapping, and command encoding.
- [ ] Integration tests with BLE mocks.
- [ ] CI matrix:
  - [x] analyze
  - [x] test
  - [ ] platform build smoke checks
- [ ] Installer/release pipeline and changelog.
- [x] In-app profile update mechanism with signatures.

## Phase 6: Monetization and privacy

- [x] Add ad stack integration (start with one network).
- [x] Keep non-personalized ads as default mode.
- [ ] Add consent UI for regions that require it.
- [x] Define anonymous analytics schema.
- [x] Add strict no-PII policy checks in telemetry pipeline.

## Notes on automation

Fully automatic onboarding of unknown devices is not realistic for all BLE controllers due to protocol variance and vendor-specific behavior. The target model is:

1. Automatic diagnostics capture (opt-in).
2. Automatic profile draft generation.
3. Lightweight human review.
4. Automatic global distribution to all users.

This keeps manual work minimal while maintaining safety and correctness.
