# Path to Live on the App Store

What's left after the v1 build (backend + iOS app + free/paid tier features).
Grouped by what actually blocks submission vs. what blocks a *good* launch.

## The two real blockers

**1. Real infrastructure.** Everything currently points at seeded
placeholders: `nyc1.dev.ghostvpn.example` isn't a real server, the DNS
filtering addresses (`10.64.0.1`–`.5`) aren't running resolvers, and the
dedicated-IP pool is four fake addresses per location. None of this is an
Apple problem — it's `vpn-infrastructure.md` and `vpn-cost-minimization.md`
turning into deployed servers. Nothing else on this list matters until at
least one real WireGuard PoP with a real DNS resolver exists.

**2. Apple In-App Purchase for Ghost Plus.** Apple requires subscriptions
unlocking app features to go through StoreKit — this is not optional for a
paid tier, and it's also a security hole as built: `POST
/v1/account/tier` currently flips a user to paid with no payment at all,
gated only by an env var meant for development. Before this ships:

- Configure an auto-renewable subscription product in App Store Connect.
- Replace `UpgradeSheet`'s dev-endpoint call with `StoreKit 2`
  (`Product.purchase()`), and validate the transaction/receipt.
- Add server-side receipt validation and handle **App Store Server
  Notifications V2** so `store.SetTier` is called by Apple's webhook, not
  the client — a client-only check is trivially bypassed.
- Remove `GHOST_ALLOW_TIER_OVERRIDE` from any production deployment
  entirely (keep it dev-only, which the code already gates — just don't
  set the env var in prod).

## iOS / Apple technical work

Good news from checking current policy: the **Network Extension
packet-tunnel entitlement is self-serve** (has been since 2016) — no
separate Apple approval request, just enabling the capability in Xcode and
letting automatic signing handle it. What's still required:

- **Apple Developer Program enrollment as an Organization**, not an
  Individual account — Apple's guidelines require VPN apps specifically to
  be submitted by an organization.
- Enable Network Extension + Personal VPN capability on both targets in
  Xcode, regenerate provisioning profiles.
- Flip `AppState.useSystemTunnel = true` once a real server exists to test
  against.
- Move the WireGuard private key handoff from `providerConfiguration` to
  the shared Keychain access group (the App Group is already declared in
  both entitlements files — this is a known gap flagged in `ios/README.md`).
- Real device testing: kill switch, DNS/IPv6 leak behavior, and
  Wi-Fi↔cellular handoff don't reproduce reliably in the simulator.
- HTTPS for the control-plane connection + remove the local-networking ATS
  exception in `project.yml` (it's explicitly commented as dev-only).
- App icon set, launch screen assets — currently generated placeholders.

## Legal & compliance

- **Privacy policy and Terms of Service**, published at real URLs. Apple
  requires the policy to state VPN apps don't sell/share/use traffic data
  for other purposes — this needs to *actually* match what the backend
  does (which, per `vpn-infrastructure.md`'s no-logs schema, it already
  does — the policy just needs to say so accurately).
- **Business entity + jurisdiction**, per `vpn-infrastructure.md`: pick a
  jurisdiction without mandatory data-retention laws before real signups,
  since it's disruptive to change later.
- **On-screen data-collection disclosure before purchase** — Apple
  requires this to appear in the app itself, not just the App Store
  listing.
- **Per-territory VPN licensing** — some countries require a VPN license
  to operate; if Ghost is available there, the license info goes in App
  Review's notes field. Check this before enabling those regions.
- Apple's standard EULA, or a custom one if terms differ.

## App Store Connect submission

- Screenshots for required device sizes, app preview video (optional but
  helps conversion for a security-positioned app).
- App Store description, keywords, category (Utilities or Productivity —
  not "Business" if you want organic discovery from consumer searches).
- **Export compliance declaration** — WireGuard's encryption almost
  certainly qualifies for the standard exemption, but the ITSAppUsesNonExemptEncryption
  question still has to be answered correctly in App Store Connect.
- Age rating questionnaire.
- Support URL and contact — needs to be a real, monitored channel before
  launch, not a placeholder.

## Testing before submission

- **TestFlight** with external testers on real devices, real networks
  (home Wi-Fi, cellular, and at least one restrictive/corporate network to
  exercise obfuscation).
- Leak testing once the real tunnel is live: DNS leak, IPv6 leak, kill
  switch under an actual dropped connection (not just backgrounding the
  app).
- Accessibility pass (VoiceOver, Dynamic Type) — flagged as a v1 practice
  in `vpn-development-recommendations.md`, worth verifying before
  submission rather than after.

## Ops, for the day it goes live

- Monitoring/alerting on the PoPs and ghostd — a dead server is the #1
  churn driver per `vpn-features-priorities.md`'s research, and it needs
  to be caught before users do.
- Backups for the account/device database.
- An abuse-report intake process (per `vpn-infrastructure.md`) — exit IPs
  will get used for abuse by a minority of users, and that needs handling
  before it becomes a blocklisting problem.
- Rate limiting on `/v1/auth/*` — not yet added.

## Suggested order

1. Stand up one real WireGuard PoP + one real DNS resolver. Nothing else
   can be honestly tested without this.
2. StoreKit integration + server-side receipt validation — do this before
   TestFlight, since testers should exercise the real purchase flow.
3. Organization developer account + entitlements + real-device testing
   against the one real PoP.
4. Legal (privacy policy, ToS, jurisdiction) — needs to be settled before
   any external TestFlight tester's data is even collected.
5. TestFlight round, leak testing, accessibility pass.
6. App Store Connect assets + submission.

Everything here is additive to what's built — no architecture changes,
just turning placeholders into the real thing and closing the one security
gap (client-controlled tier) that must not reach production.

## Sources

- [Personal VPN Entitlement — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.vpn.api)
- [App Review Guidelines — Apple Developer](https://developer.apple.com/app-store/review/guidelines/)
- [How to Get the Apple Network Extension (VPN) Entitlement — Newly](https://newly.app/how-to/network-extension-entitlement)
