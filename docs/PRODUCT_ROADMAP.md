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
- [ ] Stable reconnect and resume behavior.
- [ ] Device selection and persistence of preferred device.
- [ ] Basic settings:
  - [ ] polling interval
  - [ ] min/max output brightness
  - [ ] sync on/off
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
- [ ] Unit tests for matcher, mapping, and command encoding.
- [ ] Integration tests with BLE mocks.
- [ ] CI matrix:
  - [ ] analyze
  - [ ] test
  - [ ] platform build smoke checks
- [ ] Installer/release pipeline and changelog.
- [ ] In-app profile update mechanism with signatures.

## Notes on automation

Fully automatic onboarding of unknown devices is not realistic for all BLE controllers due to protocol variance and vendor-specific behavior. The target model is:

1. Automatic diagnostics capture (opt-in).
2. Automatic profile draft generation.
3. Lightweight human review.
4. Automatic global distribution to all users.

This keeps manual work minimal while maintaining safety and correctness.
