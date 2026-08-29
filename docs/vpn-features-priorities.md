# VPN Features & Priorities Research

Research into what top VPN apps offer today and what users actually say matters
most, done to inform Ghost's feature roadmap. Sources are linked inline.

## TL;DR

- The market leaders (NordVPN, ExpressVPN, Surfshark, Proton VPN, Mullvad) all
  now clear the same baseline bar: WireGuard by default, a kill switch,
  audited no-logs policies, and apps on every major platform. Differentiation
  happens above that bar — speed, price, anonymity guarantees, and how much
  control they hand a technical user.
- Users rank **servers, security, and speed** as the three things that matter
  most when picking a VPN, but **~80% cite "security" and 66% cite "protecting
  personal info"** as their core motivation — privacy is the emotional driver
  even when speed is the deciding factor day to day.
- VPN usage is actually declining (32% of Americans use one, down from 46% in
  2023), and the stated reasons are almost entirely UX failures, not privacy
  failures: slow speeds, streaming breakage, bugs, and free-tier ads/limits.
  **A VPN that is fast and simply works retains users better than one with a
  longer feature list.**
- The strongest product pattern for reconciling "simple" and "powerful" is a
  **beginner/advanced mode toggle** (the pattern you referenced from stock
  trading apps) — NordVPN and others already do a soft version of this. Ghost
  should build this explicitly rather than as an afterthought.

---

## 1. What the top VPN apps actually offer

| Feature | NordVPN | ExpressVPN | Surfshark | Proton VPN | Mullvad |
|---|---|---|---|---|---|
| Positioning | Fastest + most audited | Easiest to use | Cheapest, unlimited devices | Privacy-first, open source | Max anonymity |
| Protocol | WireGuard (NordLynx), 800+ Mbps | Lightway (proprietary WireGuard-based) | WireGuard | WireGuard, OpenVPN | WireGuard, OpenVPN |
| Server infra | 9,300+ RAM-only servers | RAM-only (TrustedServer) | RAM-only | RAM-only, 145 countries | RAM-only |
| No-logs audit | 6 independent audits (Deloitte, Dec 2025) | Independently audited | Independently audited | Open-source, audited | Independently audited |
| Kill switch | Yes (app + system level) | Yes | Yes | Yes | Yes |
| Split tunneling | Yes | Yes | Yes | Yes | Yes |
| Multi-hop / Double VPN | Yes | No | Yes ("MultiHop") | Yes ("Secure Core") | Yes |
| Obfuscation (anti-DPI) | Yes | Yes (automatic) | Yes ("Camouflage Mode") | Yes | Yes |
| Device limit | 10 | 8 | Unlimited | 10 | 5 |
| Anonymous signup/payment | Email required | Email required | Email required | Anonymous option | **No email, cash accepted** |
| Price (street) | ~$3–4/mo (multi-year) | ~$6–8/mo | **~$1.99–2.30/mo** | ~$4–5/mo | ~$5/mo flat, no tiers |
| Best for | Speed + trust signals | First-time / non-technical users | Budget + families | Privacy purists, transparency | Anonymity-obsessed users |

Emerging trends worth tracking rather than chasing yet: providers are
bundling "privacy suite" extras (email aliasing, identity monitoring,
AI-assisted privacy tools — e.g. ExpressVPN's 2026 expansion), and
router-level / always-on protection is moving from a power-user feature to a
baseline expectation.

## 2. What users say they actually want

From consumer surveys and usage research:

- **Top 3 decision factors:** server network breadth, security, speed — in
  roughly that order of research effort, though speed is the top *complaint*
  driver.
- **Motivation for using a VPN at all:** ~80% security, 66% protecting
  personal info, 37% reducing ad/social tracking, ~1 in 4 for streaming access
  to geo-blocked content.
- **Why people abandon VPNs:** slow speeds (reported by over half of users,
  worse on free tiers), broken streaming access, bugs, intrusive ads on free
  tiers, and limited server choice. Frustration with free VPNs specifically
  pushes people either to a paid plan or off VPNs entirely.
- **Business/work use is shrinking** (8% vs 13% in 2023) as organizations
  move toward zero-trust access instead of blanket VPN — worth noting if
  Ghost ever considers a business tier, but not a near-term priority for a
  consumer app.

**Implication:** the feature that wins retention isn't a rare advanced
capability — it's *reliability of the basics* (connects fast, stays
connected, doesn't break Netflix). Advanced features win trust and
word-of-mouth among the minority who evaluate deeply; basic reliability wins
the majority who churn silently.

## 3. Design pattern: Simple mode / Advanced mode

Applying the trading-app pattern you described (a single toggle that swaps a
minimal beginner view for a full technical one, without maintaining two
separate apps):

### Simple mode (default for new users)
- One-tap Connect/Disconnect with a single "recommended server" auto-pick
- A visible, plain-language status: "Protected" / "Not protected"
- Server picker limited to **location names** (countries/cities), not
  protocol or load metrics
- Kill switch **on by default**, not exposed as a setting
- One toggle: "Unblock streaming" (auto-selects optimized servers)

### Advanced mode (revealed by the toggle)
- Manual protocol selection (WireGuard / OpenVPN, port/obfuscation config)
- Split tunneling (per-app or per-domain routing)
- Multi-hop / double-VPN server chaining
- Kill switch configuration (app-level vs system-level, LAN exceptions)
- Custom DNS, obfuscation/anti-DPI toggle for restrictive networks
- Server load, ping, and audit/transparency info surfaced per server
- Auto-connect rules (per network/SSID, on untrusted Wi-Fi)

The toggle state should persist per-device and never gate the app's core
promise (fast, reliable connection) behind advanced mode — advanced mode adds
control, it shouldn't be required to get baseline protection.

## 4. Proposed priority tiers for Ghost

**P0 — table stakes (must ship before any public release):**
WireGuard protocol, kill switch (on by default), one-tap connect, no-logs
policy with a path to independent audit, apps for the core platforms, split
tunneling.

**P1 — retention drivers (ship soon after):**
Simple/Advanced mode toggle, "recommended server" auto-selection, streaming
unblock toggle, obfuscation mode for restrictive networks, transparent
server list with load/ping.

**P2 — differentiators (once core is solid):**
Multi-hop routing, anonymous signup/payment option, router-level or
always-on protection, per-network auto-connect rules.

**P3 — exploratory / long-term:**
Bundled privacy-suite extras (identity monitoring, email aliasing) —
validate demand before investing, since this is where competitors are
still experimenting rather than converging.

---

## Sources

- [The Best VPN Services of 2026 — Security.org](https://www.security.org/vpn/best/)
- [2025 VPN Trends, Statistics, and Consumer Opinions — Security.org](https://www.security.org/resources/vpn-consumer-report-annual/)
- [How to Choose a VPN in 2026 — CyberNews](https://cybernews.com/what-is-vpn/how-to-choose-a-vpn/)
- [Why Do People Use VPNs? (2026) — TheBestVPN](https://thebestvpn.com/statistics/why-do-people-use-vpns/)
- [Best No-Logs VPNs in 2026 — CyberInsider](https://cyberinsider.com/vpn/best/no-logs-vpn/)
- [VPN Internals Explained: Protocols, Leaks, and the Kill Switch — Latest Hacking News](https://latesthackingnews.com/2026/06/24/how-a-vpn-works-protocols-leaks/)
- [Which VPNs have the strongest independent audits, kill switches — Factually](https://factually.co/fact-checks/technology/best-vpns-independent-audits-kill-switches-anti-leak-protections-2026-51f8db)
- [VPN Statistics for 2026 — Swif](https://www.swif.ai/blog/vpn-statistics)
