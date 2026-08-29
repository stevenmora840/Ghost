# Ghost iOS App

SwiftUI app implementing the dual-mode design from `docs/` and the published
UI mockups: **Simple mode** (one-tap connect, plain-language status) and
**Advanced mode** (bento-grid dashboard, protocol/split-tunneling/multi-hop
controls), switched with a single persistent toggle.

## Layout

```
ios/
├── project.yml            XcodeGen project definition (generates Ghost.xcodeproj)
├── Ghost/                 Main app target
│   ├── GhostApp.swift     Entry point
│   ├── Theme/             Design tokens (colors from the mockups)
│   ├── Models/            API payloads + app state types
│   ├── Services/
│   │   ├── APIClient.swift        ghostd control-plane client (auto token refresh)
│   │   ├── AppState.swift         Central observable state
│   │   ├── AuthService → SignInView handles Sign in with Apple + email
│   │   ├── KeychainStore.swift    Tokens + WireGuard private key storage
│   │   ├── TunnelController.swift Tunnel protocol: Demo + System (NetworkExtension)
│   │   └── WireGuardKeys.swift    On-device Curve25519 keypair (private key never leaves)
│   └── Views/             Simple/, Advanced/, Auth/, Settings, Root
└── PacketTunnel/          Network extension target (WireGuardKit adapter)
```

## Build (on a Mac)

1. `brew install xcodegen`
2. `cd ios && xcodegen generate`
3. `open Ghost.xcodeproj`
4. Set your team: uncomment `DEVELOPMENT_TEAM` in `project.yml` (or pick a
   team in Xcode's Signing & Capabilities) and regenerate.
5. Run the backend on the same Mac:
   `cd backend && GHOST_SEED_DEV=1 GHOST_ALLOW_TIER_OVERRIDE=1 go run ./cmd/ghostd`
   (the tier override lets the in-app **Upgrade to Plus** button work
   before billing exists)
6. Build & run the **Ghost** scheme in the iOS Simulator. The simulator
   reaches ghostd at `http://localhost:8080` (see `APIClient.defaultBaseURL`).

Out of the box the app runs in **demo tunnel mode**: the full UI, auth,
device registration, and server catalog are real; the tunnel connection is
simulated (`DemoTunnelController`).

## Tier features in the app

| Feature | Tier | Where |
|---|---|---|
| Dedicated static IP | Free | Settings → Dedicated IP (claim by location, release); shown on the Advanced dashboard |
| DNS threat & ad blocking | Free | Settings → Threat Protection; state on the Advanced dashboard |
| Priority server pool | Plus | Every server list — locked entries show a **PLUS** chip and open the upgrade sheet instead of connecting |
| Panic wipe | Plus | Settings → Panic Wipe (two-step confirm, then re-provisions a new identity) |
| Custom multi-hop chain | Plus | Advanced → Server & Protocol → Multi-Hop Chain (`MultiHopBuilderView`) |

A 402 from the backend becomes `APIError.upgradeRequired`, which `AppState`
routes to the upgrade sheet rather than the error alert — a paid-feature
refusal should never read as a failure. `UpgradeSheet`'s button currently
calls the dev tier endpoint; replace it with the StoreKit purchase flow.

## Turning on the real tunnel

Everything is scaffolded; three external things gate it:

1. **Apple Developer Program membership** with the **Network Extension**
   capability granted to your bundle IDs (`com.ghostvpn.ios` and
   `com.ghostvpn.ios.PacketTunnel` — or change them in `project.yml`).
   Personal VPN + Network Extension must show in Signing & Capabilities.
2. **A live WireGuard server** whose endpoint + public key are in the
   ghostd catalog (replace the `GHOST_SEED_DEV` placeholder entries).
3. Flip `AppState.useSystemTunnel = true` in
   `Ghost/Services/AppState.swift`.

Also required for Sign in with Apple: the capability enabled on the App ID
and `GHOST_APPLE_BUNDLE_ID` set for ghostd (defaults to `com.ghostvpn.ios`).

Before shipping (tracked as known v1 gaps):
- Move the WireGuard private key handoff from `providerConfiguration` to a
  shared Keychain access group (the App Group is already declared).
- Real stats: wire `handleAppMessage` → `adapter.getRuntimeConfiguration`
  for live transfer counters instead of the demo ticker.
- Per-app split tunneling: populate the excluded-apps list from real rules
  and enforce them in the provider.
- HTTPS + certificate pinning for the control-plane connection; the
  local-networking ATS exception in `project.yml` is dev-only.
