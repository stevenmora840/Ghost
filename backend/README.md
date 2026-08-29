# ghostd — Ghost control plane

Go service handling auth, device registration with WireGuard config
issuance, and the server catalog. It is **not** in the VPN data path —
tunnel traffic flows directly between clients and PoPs.

## Run

```sh
GHOST_SEED_DEV=1 go run ./cmd/ghostd
```

| Env var | Default | Purpose |
|---|---|---|
| `GHOST_ADDR` | `:8080` | Listen address |
| `GHOST_DB` | `ghost.db` | SQLite path |
| `GHOST_JWT_SECRET` | random/ephemeral | Access-token HMAC secret — set in production |
| `GHOST_APPLE_BUNDLE_ID` | `com.ghostvpn.ios` | Audience for Sign in with Apple tokens |
| `GHOST_SEED_DEV` | off | `1` seeds a demo server catalog (standard + priority pools, dedicated-IP pools) |
| `GHOST_ALLOW_TIER_OVERRIDE` | off | `1` exposes `POST /v1/account/tier` so paid features can be exercised before billing exists |

## API

All request/response bodies are JSON. Authenticated routes take
`Authorization: Bearer <access token>`.

| Route | Auth | Purpose |
|---|---|---|
| `GET /v1/health` | – | Liveness |
| `POST /v1/auth/register` | – | `{email, password}` → token pair |
| `POST /v1/auth/login` | – | `{email, password}` → token pair |
| `POST /v1/auth/apple` | – | `{identity_token}` (Sign in with Apple) → token pair |
| `POST /v1/auth/refresh` | – | `{refresh_token}` → new pair (single-use rotation) |
| `GET /v1/servers` | ✓ | Catalog incl. endpoint + public key for tunnel config |
| `GET /v1/account` | ✓ | Account + device count |
| `GET /v1/devices` | ✓ | Registered devices |
| `POST /v1/devices` | ✓ | `{name, public_key}` → assigned IP, DNS, allowed IPs |
| `DELETE /v1/devices/{id}` | ✓ | Remove a device |
| `GET/PUT /v1/dns-filter` | ✓ | DNS threat & ad blocking preferences (free) |
| `GET/POST/DELETE /v1/dedicated-ip` | ✓ | Dedicated exit address: read, claim, release (free) |
| `GET/PUT/DELETE /v1/multihop` | ✓ Plus | Custom 2–3 hop chain |
| `POST /v1/account/panic-wipe` | ✓ Plus | Revoke this identity, keep the account |
| `POST /v1/account/tier` | ✓ | Dev-only tier switch (see `GHOST_ALLOW_TIER_OVERRIDE`) |

## Tiers

Paid-only routes answer **402 Payment Required** with a `required_tier`
hint the client turns into an upgrade prompt rather than an error.

| Feature | Tier | Notes |
|---|---|---|
| Dedicated static IP | Free | One address per account, claimed per location; released addresses return to the pool. Priority *locations* still need Plus. |
| DNS threat & ad blocking | Free | Preferences map to a filtering resolver address (`internal/wg`), handed to the client in its tunnel config. No query logging is added. |
| Priority server pool | Plus | Low-load servers. Free accounts see them listed and marked `locked`, but `endpoint` and `public_key` are **withheld**, so a locked entry cannot be turned into a tunnel config. PoP-side peer authorization is the second half of this and lands with the PoP agent. |
| Panic wipe | Plus | Deletes every device (and tunnel address), all refresh tokens, the dedicated IP and the chain, in one transaction. The account and the caller's access token survive so the app can immediately re-register a freshly generated key — a new identity, not a sign-out. |
| Custom multi-hop chain | Plus | 2–3 distinct, existing servers, order preserved. Invalid writes are rejected without disturbing the stored chain. |

Billing is not built. `store.SetTier` is the seam a payment webhook will
call; until then the dev-only endpoint above is the way to flip tiers.

Access tokens are 15-minute HS256 JWTs; refresh tokens are opaque,
stored hashed, single-use (rotated on every refresh), 30-day TTL.
Passwords are argon2id. Device WireGuard **private keys never reach the
server** — clients send only public keys and get back an assigned tunnel
address (`10.64.0.0/16` pool), DNS, and allowed IPs.

## No-logs by construction

The schema (see `internal/store`) holds accounts, devices, refresh-token
hashes, and the server catalog — nothing else. There are no tables for
connection events, traffic, or client IPs, and handlers never log request
metadata. This is the data-flow constraint from `docs/vpn-infrastructure.md`
implemented at the storage layer, not a policy bolted on later.

## Test

```sh
go test ./...
```

Covers register/login/refresh rotation, device lifecycle + limit, server
catalog payloads, WireGuard key validation, and Sign in with Apple claim
verification (audience, expiry, account reuse) via an injected signing key.

Tier features are covered too: DNS preference persistence and resolver
mapping, dedicated-IP allocation/stability/exhaustion/release and the
priority-location gate, credential withholding on locked servers, multi-hop
tier gating and chain validation, panic-wipe blast radius (including that
re-provisioning yields a *different* tunnel address), and that the tier
override stays closed unless explicitly enabled.
