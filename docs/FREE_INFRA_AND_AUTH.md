# Free Infrastructure and Authentication Strategy

This document defines how to run cloud features without a dedicated server while still supporting broad authentication providers.

## Constraints

- No dedicated server or paid backend maintenance.
- Prefer free-tier managed/serverless services.
- Need authentication options including:
  - Google
  - Microsoft
  - Yandex
  - Telegram
  - and other providers when possible

## Recommended architecture (no dedicated server)

### 1. Identity and session layer

Use a free-tier identity platform or serverless gateway:

- Primary options:
  - Supabase Auth (free tier) for mainstream OAuth providers.
  - Firebase Auth (Spark tier) for mainstream OAuth and OIDC flows.
  - Cloudflare Workers as a lightweight OAuth gateway for unsupported providers.

### 2. Unknown device diagnostics ingestion

- App writes local diagnostic snapshots first (always).
- If a diagnostics endpoint is configured, app additionally submits snapshots via HTTPS.
- Endpoint can be:
  - Cloudflare Worker (free tier)
  - Supabase Edge Function
  - Firebase HTTPS Function
  - Google Apps Script webhook

### 3. Device profile distribution to all users

- Keep public profile manifests in a free public location:
  - GitHub repository raw files
  - GitHub Releases assets
  - Cloudflare R2 public bucket
- App periodically pulls profile manifest updates.
- Optional signature verification can be added later for safety.

## Authentication provider notes

### Google and Microsoft

- Supported via regular OAuth2/OIDC on most BaaS providers.

### Yandex

- Use OIDC/OAuth2 custom provider through the selected auth backend or gateway.

### Telegram

- Telegram auth requires signature/hash verification.
- Verification must happen in a trusted serverless function (not on client).
- Cloudflare Worker is the preferred free option for this verification step.

## Security model

- Never ship provider client secrets in the app.
- Store only public configuration in client assets.
- Keep sensitive credentials in serverless environment secrets.
- Require explicit user opt-in for diagnostics upload.

## Operational model

1. User signs in with selected provider.
2. App syncs profile registry metadata.
3. Unknown devices are captured locally.
4. With consent, diagnostics are uploaded to serverless endpoint.
5. New profile drafts are created and reviewed.
6. Validated profiles are published and become available to all users.
