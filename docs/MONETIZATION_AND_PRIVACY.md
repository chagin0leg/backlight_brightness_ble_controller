# Monetization and Privacy Principles

## Business model

- Primary monetization: ads.
- No sale of personal data.

## Advertising policy

- Default to non-personalized ads.
- Keep ad load moderate to avoid retention loss.
- Delay first ad until user reaches product value.
- Runtime baseline is implemented with AdMob banner integration and platform-safe fallback on unsupported targets.

## Data policy

- Collect only anonymous technical/product telemetry.
- Avoid direct identifiers (email, phone, full name) in telemetry payloads.
- Use coarse event labels and aggregated counters.

## Allowed anonymous signals

- App version and platform
- Feature usage counters
- Unknown device detection and profile mismatch counts
- Crash and error classes (without personal payloads)

## User controls

- Explicit opt-in for diagnostics upload.
- Settings toggle for anonymous analytics.
- Clear explanation of why each data class exists.

## Compliance baseline

- Consent screen for regions that require it.
- Privacy policy page that explains anonymous-only collection.
- Minimal retention window for raw technical logs.
