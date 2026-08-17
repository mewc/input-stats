# Input Stats Cloud

Sync backend for the [Input Stats](../README.md) macOS app. Next.js (App Router)
+ BetterAuth (Google-only sign-in) + Postgres (Drizzle). Deploys to Railway,
git-driven from `main` with the service root directory set to `cloud/`.

## What it does

- **Google sign-in** in the browser (BetterAuth) — the only auth method.
- Mints a **per-device token** and hands it to the Mac app via the
  `inputstats://` URL scheme; the app exchanges it for a **per-device HMAC
  signing secret** over HTTPS.
- `GET/POST /api/sync` store **one merged `SyncData` blob per user** (same JSON
  shape the app already writes to iCloud). POSTs must carry the device bearer
  token and a `X-Signature` HMAC, and are validated against plausibility limits.

### On tamper-resistance (read this)

The signing secret lives on the client, so the HMAC proves a payload came from a
device holding that secret and wasn't altered **in transit** — it does **not**
prove the counts are truthful. The legitimate account owner can always extract
their key and sign forged numbers; that's inherent to an untrusted client. The
real forgery deterrent is server-side **plausibility clamping** in
`src/lib/syncdata.ts` (`sanitizeSyncData`).

## Endpoints

| Route                     | Auth                     | Purpose                                        |
| ------------------------- | ------------------------ | ---------------------------------------------- |
| `/connect`                | browser session          | Google sign-in → handoff to the app            |
| `/api/device/connect`     | browser session cookie   | Mint device token, 302 to `inputstats://`      |
| `/api/device/provision`   | `Bearer <deviceToken>`   | Return the device's HMAC signing secret        |
| `GET /api/sync`           | `Bearer <deviceToken>`   | Return the user's merged blob                  |
| `POST /api/sync`          | `Bearer` + `X-Signature` | Validate + merge this device's blob            |
| `/api/health`             | none                     | Health check                                   |

## Local dev

```bash
cp .env.example .env      # fill DATABASE_URL, BETTER_AUTH_*, GOOGLE_*
npm install
npm run db:push           # or: node scripts/migrate.mjs
npm run dev
```

## Env vars

See `.env.example`. On Railway: attach the Postgres plugin (provides
`DATABASE_URL`), then set `BETTER_AUTH_URL` (the service's public URL),
`BETTER_AUTH_SECRET` (`openssl rand -base64 32`), `GOOGLE_CLIENT_ID`,
`GOOGLE_CLIENT_SECRET`, and optionally `APP_URL_SCHEME` (defaults `inputstats`).

Google OAuth authorized redirect URI must be:
`<BETTER_AUTH_URL>/api/auth/callback/google`.

## Migrations

`drizzle-kit generate` writes SQL to `drizzle/`. `scripts/migrate.mjs` applies
it and runs as Railway's start command before `npm run start`
(see `railway.json`).
