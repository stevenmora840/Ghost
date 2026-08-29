# Ghost

A privacy-first VPN with two faces: a one-tap **Simple** mode for everyone
and a dense **Advanced** mode for technical users — one app, one visual
system, switched with a single toggle.

## Repository layout

| Path | What |
|---|---|
| `backend/` | Go control plane (`ghostd`): auth, device registration + WireGuard config issuance, server catalog. [README](backend/README.md) |
| `ios/` | SwiftUI iOS app (Simple + Advanced modes) with a WireGuardKit packet-tunnel extension. [README](ios/README.md) |
| `docs/` | Product research: features & priorities, infrastructure, cost minimization, development recommendations |

## Quick start (development)

```sh
# Terminal 1 — control plane with a seeded demo catalog
cd backend && GHOST_SEED_DEV=1 go run ./cmd/ghostd

# Terminal 2 (on a Mac) — generate and open the iOS project
cd ios && xcodegen generate && open Ghost.xcodeproj
```

The app runs fully against the local backend (auth, devices, servers) with a
simulated tunnel; `ios/README.md` covers enabling the real WireGuard tunnel
(Apple Network Extension entitlement + a live server).

## Tiers

| Free | Ghost Plus |
|---|---|
| Dedicated static IP · DNS threat & ad blocking · full Simple/Advanced app | Priority low-load server pool · Panic wipe · Custom multi-hop chain builder |

Billing isn't built yet — run ghostd with `GHOST_ALLOW_TIER_OVERRIDE=1` to
exercise paid features. See [docs/vpn-premium-features.md](docs/vpn-premium-features.md).

## Design principles (from `docs/`)

- **No-logs by construction** — the backend schema cannot record connection
  activity; it holds accounts, devices, and the server catalog only.
- **Keys stay on-device** — WireGuard private keys are generated on the
  phone and never sent to the control plane.
- **Reliability of the basics first** — connect fast, stay connected, never
  leak; advanced features layer on after.
