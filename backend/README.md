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
| `GHOST_SEED_DEV` | off | `1` seeds a demo server catalog |

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
