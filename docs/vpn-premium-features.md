# Elite / Premium-Tier Features

What's actually worth charging for on top of the v1 app, and what to skip.
Builds on the P2/P3 tiers in `vpn-features-priorities.md`.

## What competitors charge extra for (2026)

- **NordVPN**: post-quantum encryption (now free/standard across all apps),
  Threat Protection (DNS-level ad/malware blocking), password manager,
  identity theft protection on higher tiers.
- **ExpressVPN**: 2026 tiered pricing — Advanced/Pro add a password manager,
  identity monitoring, and a dedicated IP.
- **Surfshark**: multi-hop, post-quantum encryption, built-in ad blocking,
  plus antivirus and identity monitoring bundled into one dashboard.

The clear 2026 trend: **post-quantum encryption and independently audited
no-logs have moved from differentiator to baseline expectation** — providers
now compete on identity/threat "privacy suite" bundles instead.

## Recommended build order

**Ship first — cheap, high perceived value, no new trust surface:**

1. **Dedicated static IP.** Backend already assigns tunnel IPs per device
   (`10.64.0.0/16` pool in `backend/internal/store`); a paid tier just
   reserves one instead of round-robining. Clear demand: remote access,
   avoiding CAPTCHAs/allowlisting, gaming.
2. **DNS-level threat protection** (ad/malware/tracker blocking). Ghost
   already runs its own DNS resolvers (`vpn-infrastructure.md`) — this is a
   blocklist on top of infrastructure that exists regardless. No new user
   data collected, fits the no-logs positioning cleanly.
3. **Priority server pool.** A subscriber-only pool of low-load PoPs. The
   Advanced dashboard already surfaces server load % — this turns an
   existing stat into an upsell hook rather than new engineering.

**Ship second — genuine differentiators, not "catch up to incumbents":**

4. **Panic wipe.** One tap wipes the on-device WireGuard private key
   (`WireGuardKeys` in the iOS app) and re-provisions a fresh identity —
   cheap given the keys are already device-local and never sent to the
   server. Not offered by mainstream commercial VPNs (it's a Tor/Tails-style
   pattern); a real fit for journalists/activists rather than a me-too
   feature.
5. **Custom multi-hop chain builder.** The multi-hop toggle already
   scaffolded in `ServerConfigView` picks one fixed entry/exit pair; let
   Advanced-mode users choose 2-3 hop countries themselves. Builds on
   existing UI rather than new architecture.

**Ship free, not paywalled:**

- **Post-quantum encryption** (NIST ML-KEM hybrid over WireGuard). NordVPN,
  ExpressVPN, and Surfshark all shipped this as standard in 2026 — charging
  for it now would read as behind, not elite. Worth building, but as a
  universal upgrade to the existing WireGuard tunnel, not a paid tier.

**Deliberately skip (for now):**

- Bundled password manager, antivirus, encrypted cloud storage. This is the
  "become a privacy suite" move the big players are making to pad ARPU — it
  multiplies support and trust surface for features unrelated to the VPN
  itself and dilutes focus from the core loop.
- Dark-web/breach identity monitoring. High perceived value, but it
  necessarily processes user email against breach databases — real
  engineering to do privacy-safely (k-anonymity/hashed lookups, no stored
  PII) and a new data-processing surface to defend under audit. Revisit
  once the core paid tiers are proven, not before.

## Sources

- [The 8 Best VPN Services for Post-Quantum Security in 2026 — Atlantic.net](https://www.atlantic.net/managed-services/top-vpn-services-in-your-guide-to-the-best-options-available/)
- [NordVPN launches post-quantum encryption across all its applications — Nord Security](https://nordsecurity.com/press-area/nordvpn-launches-post-quantum-encryption-across-all-its-applications)
- [Quantum-Safe VPNs: Complete Guide to Post-Quantum Cryptography in 2026 — Symlex VPN](https://symlexvpn.com/quantum-safe-vpn-post-quantum-cryptography/)
