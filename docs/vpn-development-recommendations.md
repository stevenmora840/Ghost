# Development Recommendations

Practices worth building in from the start — beyond the infra/cost work in
the other docs — covering engineering discipline and UI/UX for the
simple/advanced dual-mode design proposed in `vpn-features-priorities.md`.

## Engineering practices

- **Modular architecture from day one.** Separate the tunnel/networking
  layer, account/auth, and UI into independent modules with clear
  interfaces. A VPN's core promise (connect reliably, never leak) shouldn't
  be entangled with UI code — makes it possible to update the interface
  aggressively without touching the security-critical path.
- **Testing pyramid, not just end-to-end.** Heavy unit/integration coverage
  on the networking and kill-switch logic (these are the components where a
  silent regression is a real leak, not just a UI bug), with a thin layer of
  E2E tests on top. Shift-left (test on every commit) plus shift-right
  (canary releases, real-device validation) — don't ship a tunnel-handling
  change without both.
- **DevSecOps in CI/CD.** Static code scanning and dependency scanning on
  every PR; periodic penetration testing, not just at launch. OWASP MASVS is
  the relevant mobile security standard to test against. This matters more
  for Ghost than a typical app — the backend and clients are both
  higher-value attack targets given what they touch.
- **Real-device testing, not just simulators**, especially for
  network-drop and kill-switch behavior — simulators don't reliably
  reproduce real Wi-Fi/cellular handoff, which is exactly when a kill
  switch needs to work.
- **Crash/telemetry that respects the no-logs boundary.** Standard crash
  reporting SDKs (Sentry, Crashlytics, etc.) can capture more than intended
  by default — audit what's collected, strip IP/user-identifying fields,
  and document this the same way the no-logs policy is documented, since an
  audit will look at telemetry too.
- **Accessibility (WCAG 2.1) built in, not retrofitted.** Sufficient color
  contrast, scalable text, and screen-reader labels on every control —
  cheap to do now, expensive to add after the design is locked, and directly
  expands the addressable user base.

## UI/UX: designing the simple/advanced split

Building on the mode-toggle concept from `vpn-features-priorities.md`,
current mobile design trends (2026) reinforce that this split should be
architectural, not cosmetic — same underlying screens and data, two
different presentations of it.

### Simple mode — optimize for zero cognitive load

- **One primary action per screen.** A single large connect/disconnect
  control as the dominant visual element — trends toward oversized buttons
  and generous white space exist precisely because they remove hesitation
  for non-technical users.
- **Progressive disclosure everywhere.** Nothing below the top-level screen
  should introduce a term the user hasn't already seen — location picker
  shows city/country names only, never protocol or port.
- **Plain-language status, not jargon.** "Protected" / "Not protected" with
  color (not "Connected via WireGuard, NordLynx active").
- **Biometric unlock as the default auth**, not a buried option —
  passwordless/biometric auth is now the baseline expectation, not a
  premium feature, and reduces friction for exactly the user this mode
  targets.
- **Dark mode as a first-class option**, not an afterthought — it's now
  the expected default aesthetic for utility apps like this, and it
  reduces battery drain, which matters for an always-on VPN.

### Advanced mode — optimize for density and control, still clean

"Tailored for technical users" doesn't mean cluttered — it means exposing
real information without asking the user to hunt for it:

- **Bento-grid or dashboard-style layout** for the main screen: connection
  status, current server load/ping, protocol, and data usage visible at
  once instead of buried in submenus — the current design-trend pattern for
  giving power users density without chaos.
- **Inline, not modal, configuration.** Split tunneling, protocol choice,
  and multi-hop setup should be reachable in one or two taps from the main
  screen, not nested three modals deep — technical users churn on
  friction just as fast as simple-mode users do, just for different reasons.
- **Expose the numbers.** Server load %, ping, audit/transparency status per
  server, kill switch scope (app vs. system) — this audience specifically
  evaluates these before trusting a provider, per the earlier research.
- **Consistent visual language with simple mode.** Same color system, type
  scale, and iconography — only information density changes. A user
  switching modes should never feel like they're in a different app; that
  consistency is also what makes a single shared codebase for both modes
  maintainable.

### The mode toggle itself

- One switch, in an obvious but not intrusive location (settings, or a
  persistent small control) — never a separate app, separate login, or
  separate onboarding flow.
- Default to Simple mode for new accounts; let the app suggest Advanced mode
  only if it detects genuinely technical usage patterns (manual server
  selection, protocol changes) rather than asking upfront.
- Persist the toggle per device, not per account — a technical user's
  phone and laptop don't need to match.

## Sources

- [What are the Key Mobile App UI/UX Design Trends for 2026? — Elinext](https://www.elinext.com/services/ui-ux-design/trends/key-mobile-app-ui-ux-design-trends/)
- [Critical Mobile App UI UX Design Trends to Look for in 2026 — Mindinventory](https://www.mindinventory.com/blog/mobile-app-ui-ux-design-trends/)
- [Top 20+ Best Practices for Mobile App Development in 2026 — Evince Development](https://evincedev.com/blog/best-practices-for-mobile-app-development-guide/)
- [Mobile App Testing: Best Practices for 2026 — Momentic](https://momentic.ai/blog/mobile-app-testing-best-practices)
- [CI/CD for Mobile Apps: Complete 2026 Guide — GitNexa](https://www.gitnexa.com/blogs/ci-cd-for-mobile-apps)
