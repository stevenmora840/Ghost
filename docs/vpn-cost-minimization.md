# Minimizing VPN Cost to First Principles

Follow-up to `vpn-infrastructure.md`: given that infrastructure, what would
actually drive marginal cost per user toward zero, and is a free or
near-free tier realistic without repeating the trust-breaking shortcuts
(ad injection, data-selling) that cheap "free VPNs" typically rely on.

## First principles: what actually costs money, per user

For a VPN, cost scales almost entirely with **bandwidth delivered**, not
with number of users signed up. Breaking a $/user/month down to its real
components:

| Cost component | Retail/naive approach | True first-principles floor | Lever |
|---|---|---|---|
| Bandwidth | Cloud egress: $0.05–0.09/GB | Bulk IP transit at volume: falls to **cents-per-Mbps**, i.e. roughly $0.001–0.01/GB delivered | Buy transit in bulk / peer directly at IXPs, never meter on cloud egress pricing |
| Compute | 1 VM per handful of users, generic kernel networking | WireGuard + eBPF/XDP fast path cuts packet-processing overhead ~40% vs. iptables, so **one box serves far more concurrent tunnels** | Kernel-space WireGuard, XDP-accelerated data plane, ARM/perf-per-watt hardware |
| IP addresses | 1 IPv4 per exit, leased at ~$0.30–0.50+/IP/month and rising | Shared exit IPs (many users behind one IPv4) + IPv6-first | Heavier IP sharing per server, IPv6 where clients support it |
| Server/rack | Cloud VM markup | Bare-metal colocation at IXPs, diskless boot (no storage line item) | Own or co-locate hardware once volume justifies it |

An average consumer VPN user moves roughly 20–50 GB/month. At true bulk
wholesale bandwidth pricing (not cloud egress rates), that's on the order of
**$0.10–0.50/user/month** in raw bandwidth — the dominant cost — before
compute and IP costs, which are smaller if the fast-path techniques above
are used. That's the realistic floor for a centrally-operated network. Nobody
gets meaningfully below that while still owning and paying for every server
themselves.

## Where "free" VPNs actually get free from

Four real-world models already exist, and only some are compatible with the
privacy-first positioning in `vpn-features-priorities.md`:

1. **Ride existing amortized infrastructure — Cloudflare WARP.** WARP is
   free because it runs over Cloudflare's already-built, already-paid-for
   global anycast network (330+ data centers) — the VPN traffic is a
   marginal add-on to infrastructure that exists for other reasons.
   Ghost has no equivalent sunk network to ride on, so this model isn't
   directly available — but the principle transfers: **don't build a
   dedicated global PoP network before you need one; ride bulk transit and
   IXP peering that would be cheap regardless of VPN traffic volume.**
2. **Decentralized bandwidth marketplace — Mysterium, Orchid, Sentinel.**
   Individual node operators share their own unused bandwidth/compute (on a
   home connection, a Raspberry Pi, a VPS) in exchange for token
   micropayments. The company running the network never pays for that
   bandwidth — the marginal cost is borne by whoever's node just routed the
   traffic, priced by the market. This is the most genuinely
   "cutting-edge, cost-to-first-principles" model available today.
   **Trade-off:** a stranger's node is now in the path, so it only stays
   trustworthy with **multi-hop encryption where no single relay sees both
   the user's identity and destination** (Orchid's design) — that's real
   engineering work, not a free lunch.
3. **Sponsorship-subsidized — Psiphon.** Free to users, funded by media
   orgs and NGOs who want their content reachable in censored regions.
   Psiphon *also* funds itself partly by selling user data to advertisers —
   that's the part to explicitly avoid; it's the exact trust failure a
   no-logs, audited positioning is built to be different from.
4. **Grant/donation-funded nonprofit — Tor.** Not a subscription business
   at all; funded by government/foundation grants and individual donors.
   Only works as a mission-driven nonprofit, not as Ghost's structure.

**Conclusion: model 2 (decentralized relay) is the only one that gets a
for-profit, privacy-first VPN meaningfully toward "free" without selling
user data or running ads.** Models 1 and 4 aren't structurally available to
Ghost; model 3's ad/data half should be ruled out on principle.

## A concrete cost-minimized architecture

**Core layer (paid tier, funds everything):** bare-metal servers at major
IXPs with negotiated bulk transit, WireGuard + eBPF/XDP data plane, diskless
boot, IPv6-first with shared IPv4 pools. This is the "own infrastructure"
model from `vpn-infrastructure.md`, just built for maximum throughput per
dollar using the fast-path techniques above.

**Free/minimal-price tier, two viable paths — pick based on how much
engineering risk you want to take on:**

- **Cross-subsidized freemium (lower risk, ship first):** free tier is
  capped (e.g. bandwidth or speed limited), served from the same
  cost-minimized core infrastructure, funded by premium subscribers. This
  is the Proton VPN Free / Windscribe model — no new architecture, just
  disciplined unit economics on the core network above. Realistic once
  bandwidth cost per free user is pushed down to the ~$0.10–0.50/month
  range above and a modest premium conversion rate covers it.
- **Opt-in decentralized relay layer (cutting-edge, higher engineering
  cost, bigger payoff at scale):** let users donate idle upload bandwidth
  from their own device (in exchange for free months, credits, or nothing
  more than a cooperative model) to extend network capacity and location
  coverage without Ghost paying for that bandwidth at all. This needs
  multi-hop, no-single-node-sees-both-ends routing to keep the trust model
  intact — it's a genuine differentiator, not a shortcut, and it's the
  actual answer to "minimize cost to first principles": the marginal cost
  of serving one more free user drops toward the cost of one more
  participant's spare upstream bandwidth, which is close to zero.

**Micropayment alternative for "minimal price" rather than "free":**
Lightning-Network-style micropayments (the mechanism Orchid already uses)
let you charge close to the true wholesale cost per MB instead of a flat
subscription — a light user could pay well under $1/month, priced almost
exactly to marginal cost, with no cross-subsidy needed at all.

## What this means for sequencing

1. Ship the paid core network first, built cost-efficiently (bulk transit,
   eBPF/XDP, diskless, IP sharing) — this is the same v1 infrastructure
   from `vpn-infrastructure.md`, just don't skip the throughput-per-dollar
   work.
2. Launch a capped free tier funded by that paid base once unit economics
   are proven — cheap to build, no new trust model required.
3. Treat the decentralized opt-in relay layer as a **post-PMF differentiator**,
   not a v1 requirement — it's the real "cutting edge" answer to this
   question, but it only pays off once there's a large enough user base to
   have meaningful spare capacity to pool, and it needs the multi-hop
   trust architecture built correctly before it touches real user traffic.
4. Never fund "free" with ads or data-selling — it's cheap in the wrong
   sense: it directly undermines the no-logs/audited positioning that's
   the whole basis for why someone would pick Ghost over an existing free
   option.

## Sources

- [What is a Decentralized VPN? How They Work — Tech Review](https://tech-review.com/what-is-a-decentralized-vpn.html)
- [Orchid VPN by Orchid Labs — QuickNode Builders Guide](https://www.quicknode.com/builders-guide/tools/orchid-vpn-by-orchid-labs?category=web3-infrastructure)
- [Mysterium Network by Mysterium Foundation — QuickNode Builders Guide](https://www.quicknode.com/builders-guide/tools/mysterium-network-by-mysterium-foundation)
- [How Much Does IP Transit Cost? 2026 Price Guide — Shift Hosting](https://shifthosting.com/blog/article/how-much-does-ip-transit-cost-a-complete-guide-to-ip-transit-price-and-billing-models)
- [Demystifying performance of eBPF network applications — APNIC Blog](https://blog.apnic.net/2026/03/25/demystifying-performance-of-ebpf-network-applications/)
- [What Is Cloudflare WARP? Should You Use It? — MakeUseOf](https://www.makeuseof.com/what-is-cloudflare-warp/)
- [Free VPN with Cloudflare Tunnel + WARP: Full 2026 Setup Guide — Orthogonal](https://orthogonal.info/free-vpn-cloudflare-tunnel-warp-zero-trust-guide/)
- [Psiphon Review 2026 — Techno360](https://techno360.in/psiphon-review-2026/)
- [Who funds Tor? — Tor Project Support](https://support.torproject.org/misc/misc-3/)
