# Free/Low-Cost Infrastructure and Authentication Strategy

This document defines how to run cloud features without expensive dedicated infrastructure while still supporting broad authentication providers.

## Constraints

- No expensive dedicated server requirement.
- Prefer free-tier managed/serverless services.
- Need authentication options including:
  - Google
  - Microsoft
  - Yandex
  - Telegram
  - and other providers when possible
- Monetization is ad-based.
- Personal user data collection is out of scope; only anonymous data is allowed.

## Arch Linux low-power server scenario

If a low-power Arch Linux server is available (2 cores / 16 GB RAM) but without a dedicated public IP, use an outbound tunnel topology.

### Recommended connectivity options

1. Cloudflare Tunnel (preferred)
   - Stable HTTPS hostname without inbound ports.
   - Suitable for OAuth redirect endpoints and lightweight API.
2. Tailscale Funnel
   - Fast setup for internet exposure via WireGuard-based overlay.
3. Dynamic DNS + reverse proxy
   - Works, but less reliable under mobile-network NAT/CGNAT.

### Deployment notes for this server profile

- Keep services minimal:
  - Caddy or Nginx
  - lightweight API (Go/FastAPI/Node)
  - SQLite for small metadata (if needed)
- Keep auth verification and webhooks stateless where possible.
- Offload heavy jobs (if any) to serverless endpoints.
- Serve setup/dashboard UI on LAN-only mDNS hostname (`http://<name>.local`).

## Recommended architecture

### 1. Identity and session layer

Use a free-tier identity platform or a tunnel-backed lightweight gateway:

- Primary options:
  - Supabase Auth (free tier) for mainstream OAuth providers.
  - Firebase Auth (Spark tier) for mainstream OAuth and OIDC flows.
  - Cloudflare Workers as a lightweight OAuth gateway for unsupported providers.
  - Self-hosted lightweight OAuth bridge behind Cloudflare Tunnel.

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
- For headless mode, Google device-session polling flow is recommended.

### Yandex

- Use OIDC/OAuth2 custom provider through the selected auth backend or gateway.

### Telegram

- Telegram auth requires signature/hash verification.
- Verification must happen in a trusted serverless function (not on client).
- Cloudflare Worker is the preferred free option for this verification step.

### Additional high-conversion options

- GitHub
- Apple Sign-In (important for iOS audience)
- VK ID (regional relevance)
- Discord (tech/gaming audience)
- Email magic link (low-friction login)
- Phone OTP (where legally and economically feasible)
- Passkey/WebAuthn (secure and low-friction returning users)
- Anonymous guest session (instant entry and best top-of-funnel conversion)

Recommended funnel:

1. Let user start in anonymous guest mode.
2. Ask for sign-in only when cloud sync/backup/profile sharing is needed.
3. Keep 3-5 providers visible, move others into "More options".

## Security model

- Never ship provider client secrets in the app.
- Store only public configuration in client assets.
- Keep sensitive credentials in serverless environment secrets.
- Require explicit user opt-in for diagnostics upload.
- For ad monetization, default to non-personalized ads unless explicit consent policy allows otherwise.

## Operational model

1. User signs in with selected provider.
2. App syncs profile registry metadata.
3. Unknown devices are captured locally.
4. With consent, diagnostics are uploaded to serverless endpoint.
5. New profile drafts are created and reviewed.
6. Validated profiles are published and become available to all users.

## Ads and anonymous analytics policy

- Ads:
  - Prefer non-personalized ads by default.
  - Keep ad frequency conservative to avoid churn.
- Analytics:
  - Collect only anonymous product metrics.
  - No raw PII storage.
  - Prefer coarse events: feature usage, crashes, unknown-device profile misses.
