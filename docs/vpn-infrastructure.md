# Infrastructure for a Full Serviced VPN

Follow-up to `vpn-features-priorities.md`: what it actually takes to run a
commercial VPN service (not a personal WireGuard box) end to end. Grouped by
layer, with what's table stakes vs. what can wait.

## 1. Server / network layer

- **Global points of presence (PoPs):** servers in every country/region you
  advertise. Competitive VPNs run from dozens to 100+ locations; realistic
  launch target is a small set of high-demand locations (US, UK, EU hub,
  Japan/Singapore) rather than matching incumbents' full spread.
- **Bare metal, not shared cloud VMs, at scale.** Cloud VPS is fine to start,
  but bare metal in colocation gives predictable throughput and avoids
  "noisy neighbor" performance issues once you have real traffic.
- **RAM-only (diskless) servers.** Boot the OS and VPN daemon entirely into
  RAM via network boot/image; nothing is ever written to physical disk, so a
  reboot wipes all state. This is now the baseline trust signal — NordVPN,
  ExpressVPN, and Surfshark are all fully diskless.
- **Protocol: WireGuard as the default data plane.** 2-3x the throughput of
  OpenVPN due to kernel integration; keep OpenVPN available only as a
  fallback for restrictive networks. Layer an obfuscation wrapper (e.g.
  AmneziaWG-style) on top for anti-DPI/anti-censorship needs.
- **Control-plane / data-plane split at scale.** A central control plane
  (server list, auth, key distribution) stays cloud-hosted for easy updates;
  the data plane (actual tunnel endpoints) runs on the bare-metal PoPs. Don't
  bother with this split at launch — one config-managed fleet is enough
  until you're operating 20+ servers.
- **Datacenter/transit relationships.** You need contracts with datacenter
  and bandwidth providers in each PoP location; VPN traffic is
  bandwidth-heavy, so per-GB transit cost is a real line item, not an
  afterthought.

## 2. Client applications

- Apps for Windows, macOS, iOS, Android, Linux at minimum; router
  firmware/app and browser extensions are common P2 additions.
- Each client needs: connect/disconnect, kill switch enforcement, split
  tunneling, server selection, and secure local storage of session
  credentials/keys.
- Auto-update mechanism per platform (app stores handle mobile; desktop
  needs its own signed-update pipeline).

## 3. Backend / control plane

- **Auth & account service:** signup, login, session/device management,
  MFA. Should be decoupled from billing so account data itself stays
  minimal.
- **Key/config distribution:** issuing WireGuard keypairs or session tokens
  per device, rotating them, and revoking on logout/device removal.
- **Server selection API:** returns the best server per user (by location
  preference, latency, and current load) — needs live load data from every
  PoP without needing to log user-identifying connection data.
- **Billing/subscription system:** recurring payments (Stripe or similar),
  entitlement checks, device-limit enforcement, trial/refund handling.
- **Secure API design:** MFA/SSO for internal admin access, secrets/key
  management (e.g. a vault, not config files), regular penetration testing —
  this backend is the highest-value target for an attacker, more than any
  single tunnel server.

## 4. DNS

- **Private, VPN-operated DNS resolvers** at each PoP so DNS queries never
  leak to the user's ISP or a third party.
- **DNS + IPv6 leak protection** built into the client: block IPv6 traffic
  outside the tunnel by default, force all DNS through the tunnel, and
  bind the kill switch to both.

## 5. Security & anti-abuse

- **DDoS protection at the network edge**, not just the application — every
  PoP is a public UDP endpoint and a target. Needs upstream scrubbing or a
  provider with built-in DDoS mitigation.
- **Abuse handling / IP reputation management:** VPN exit IPs get used for
  abuse by a minority of users, which gets whole IP ranges blocklisted.
  Needs: dedicated IP pools segregated by use case, automated rotation when
  a complaint threshold is hit, and an abuse-report intake process.
- **Kill switch + auto-reconnect enforced at the OS network layer** on every
  client, not just in-app — a dropped tunnel must never silently fall back
  to the raw connection.

## 6. Trust / no-logs infrastructure

This is infrastructure in the same sense as servers — it's what makes the
"no-logs" claim credible rather than marketing copy:

- **Jurisdiction:** incorporate somewhere without mandatory data-retention
  laws (e.g. the pattern ExpressVPN/BVI, Proton/Switzerland, Mullvad/Sweden
  follow). This is a legal/structural decision made early — hard to change
  later without disrupting users.
- **Independent no-logs audit** from a recognized firm (Deloitte, PwC,
  Cure53 are the names competitors use), repeated periodically, not a
  one-time PR event.
- **Transparency report**, published on a schedule, disclosing legal
  requests received and the (ideally empty) data handed over.
- **Minimal logging by design:** architect the auth/billing/server-selection
  services so they structurally cannot correlate an account to browsing
  activity — this needs to be a data-flow decision at design time, not a
  policy promise layered on after.

## 7. Operations / DevOps

- **Infrastructure-as-code provisioning** (Ansible/Terraform-style) so new
  PoPs and server rebuilds are scripted, not manual — especially important
  for RAM-only servers, which need a fast, reliable re-provision-on-boot
  pipeline by design.
- **Monitoring that respects the no-logs boundary:** track server health,
  load, and uptime, not user activity. This distinction needs to be
  explicit in tooling choices, since generic APM/logging stacks default to
  capturing far more than a VPN can safely keep.
- **On-call/incident response** for PoP outages — users notice a dead
  server fast, and it's a top churn driver per the earlier research.

## 8. Business/legal infrastructure

- Payment processing (card + ideally a privacy-preserving option like
  crypto for users who want anonymous signup).
- Customer support tooling.
- Terms of service, privacy policy, and compliance review (GDPR if serving
  EU users, CCPA for California, etc.) — needed before charging money, not
  after.

---

## What to actually build first

Given Ghost is pre-launch, the realistic sequencing is:

1. **Minimum viable network:** a handful of bare-metal, RAM-only WireGuard
   PoPs in 3-5 high-demand locations, provisioned via IaC from day one so
   diskless doesn't become a later migration.
2. **Backend:** auth + billing + server-selection API, built with the
   no-logs data-flow constraint from the start (retrofitting "we don't log"
   onto an existing schema is how audits fail).
3. **One client platform** (pick the platform matching your first target
   users) with kill switch, DNS/IPv6 leak protection, and auto-reconnect
   non-negotiable from v1 — these are the features users notice the absence
   of immediately.
4. **Jurisdiction + ToS/privacy policy** locked in before any paid signup,
   since it's the hardest thing to change retroactively.
5. Everything else in this doc (multi-hop, obfuscation, router firmware,
   independent audit, transparency reports) layers on once the core loop
   — connect, stay connected, don't leak — is solid.

## Sources

- [Self-Hosted VPN in 2026: WireGuard, Headscale, NetBird and More Compared — DEV Community](https://dev.to/moksh/self-hosted-vpn-in-2026-wireguard-headscale-netbird-and-more-compared-5fln)
- [WireGuard Mesh Networking: Building Secure Overlay Networks in 2026 — Tunnel Picks](https://tunnelpicks.net/blog/wireguard-mesh-networking-2026-practical-guide)
- [RAM-Only VPN Servers – How do They Work and Why You Should Care — Privacy Affairs](https://www.privacyaffairs.com/ram-only-vpn/)
- [VPN No-Logs Policies: How to Verify Claims in 2026 — Medium](https://medium.com/@lachlanmooresec/vpn-no-logs-policies-how-to-verify-claims-in-2026-af701ed98cbe)
- [How to Protect Your Enterprise VPN from DDoS Attacks — NETSCOUT](https://www.netscout.com/blog/how-protect-your-enterprise-vpn-ddos-attacks)
- [How to Evaluate a VPN Development Service for Strong Security — Kolpolok](https://kolpolok.com/evaluate-vpn-development-service-security-standards/)
