# LivingRoomTV — known issues & bugs

One-line-per-item bug/issue log. Add newest at top. Status: `P1` (ship-blocker),
`P2` (noticeable), `P3` (polish). Close with `✓` + date when fixed.

## Open

- **P1 — macOS 26 liquid-glass APIs all break MenuBarExtra hit testing**
  (2026-04-19) — `.glassEffect(_:in:)`, `GlassEffectContainer`,
  `.containerBackground(_:for: .window)`, and manual `NSVisualEffectView`
  all exhibit the same regression on Tahoe beta: clicks/scrolls in the top
  half of the MenuBarExtra popup are silently absorbed, intermittently or
  after some interaction. Likely the family bug from
  https://developer.apple.com/forums/thread/737584 persisting. Workaround:
  disabled all glass primitives (`glassShellBackground`,
  `glassPanelBackground`, `LiquidGlassGroup`); app uses plain
  `.ultraThinMaterial` / `.regularMaterial` until Apple fixes this.

- **P2 — `.containerBackground(.ultraThinMaterial, for: .window)` on
  MenuBarExtra breaks hit testing on macOS 26 beta** (2026-04-19)
  The Apple-sanctioned API for translucent MenuBarExtra(.window) popups
  (`.containerBackground(.ultraThinMaterial, for: .window)`) absorbs mouse
  clicks in the top half of the popup, same as manually installing
  NSVisualEffectView. The Tahoe beta appears to have the regression Apple
  Dev Forums flagged for Sonoma:
  https://developer.apple.com/forums/thread/737584
  Workaround: don't use it. Retry when macOS 26 ships.

- **P2 — Horizontal ScrollView + Button gesture swallowing** (2026-04-19)
  Known macOS SwiftUI foot-gun: pan gesture on `ScrollView(.horizontal)`
  swallows a click when the mouse drifts a pixel during down→up (common
  with trackpads). Affects apps row and scenes row. Not addressed yet —
  next move if "some clicks miss" persists after the logo-cache fix.
  Fix options: `.highPriorityGesture(TapGesture())` on each tile, or
  drop the scroll view entirely for the finite app set.

- **P3 — RPC returns are thrown away** (2026-04-19)
  `StatusStore.sendRPC` returns the daemon's confirmed result payload
  (e.g. new volume after `set_volume`), but every `TVCommandRunner`
  wrapper discards it and we wait for the next status push instead.
  Wasted round-trip; optimistic UI could reconcile immediately.

- **P1 — Popup "freezes" after some interaction** (2026-04-19)
  User reports: "scrolling for a bit…then freezes…gets stuck." Happens after
  the horizontal app/scene rows are used for a while, persists across the
  removal of the AskAI ScrollView. Likely suspects: stranded `Task`s in
  optimistic-update wrappers (VolumeRow `pendingClearTask`, TransportRow
  `pendingClearTask`), or a `pendingRPC` continuation leak in `StatusStore`
  when the daemon hiccups. Repro not yet nailed — next time it happens, grab a
  sample of `LivingRoomTV` with `sample $(pgrep LivingRoomTV) 5 -file /tmp/lr.txt`.

- **P2 — Shell still reads as "premium dark utility," not Apple glass** (2026-04-19)
  Design feedback: material behavior is under-expressed. The shell has to be
  `.glassEffect(.regular, in:)` with warm tint *inside* the material, not an
  opaque fill. Transport + Remote (+ Volume) needs `GlassEffectContainer` to
  feel like one liquid cluster. App tiles / scene pills / brand surfaces stay
  solid on purpose. Previous attempt with `NSVisualEffectView` broke hit
  testing; SwiftUI's `.glassEffect` on macOS 26 is the right primitive.

- **P3 — AI reply card truncates at 20 lines** (2026-04-19)
  Long replies get cut with `…`. Currently intentional (popup can't grow).
  Could add a "full reply" affordance (popover or expanding panel) if users
  hit this often.

## Closed

- ✓ 2026-04-20 — **Away state** — when the daemon is disconnected for 15+s,
  popup now renders an explicit "Away / Not on home network" card with a
  curated set of scene shortcut buttons routed via `shortcuts://run-shortcut`
  (Apple's iCloud relay works remotely for Shortcuts). Power pill disables.
  Removes the "looks frozen" failure mode when off home Wi-Fi.
- ✓ 2026-04-19 — **NowPlayingCard blurred backdrop absorbing clicks above/around
  it** — user spotted "works when Now Playing isn't showing". The
  `.scaleEffect(1.35) + .blur(radius: 44)` pair on the artwork image inside
  `.background(...)` was being promoted to an offscreen rasterized layer that
  on macOS 26 beta silently absorbed clicks — explaining the "top half dead"
  pattern where scenes/apps broke only when a track was playing. Marked the
  whole card `.allowsHitTesting(false)` (it's purely informational — no
  interactions) and the backdrop ZStack explicitly too. Belt-and-suspenders.
- ✓ 2026-04-19 — **Shell glass via Apple-sanctioned API** — dropped the
  NSWindow-poking + manual `.glassEffect` on the shell (kept breaking hit
  testing / made UI too dark). Switched to
  `.containerBackground(.ultraThinMaterial, for: .window)` on the
  MenuBarExtra content, which is the documented way to give a
  MenuBarExtra(.window) popup translucency on macOS 15+. Per-panel glass
  (Transport / Remote / Volume inside `GlassEffectContainer`) stays,
  since Apple's rule is "glass cannot sample other glass" — now there's
  only one level of glass sampling happening.
- ✓ 2026-04-19 — **RED synchronous disk I/O in view body** — `StreamingApp.logo`
  was reading + decoding a PNG from disk on every render of every app tile.
  Added a `@MainActor`-isolated static cache; disk is touched once per shortcut
  for the app's lifetime.
- ✓ 2026-04-19 — **Row-wide disable lockout** — tapping one app tile / scene
  pill was disabling the entire row. Switched both to `Set<String>` tracking
  of pending IDs; only the specific tile/pill that's in flight is disabled.
- ✓ 2026-04-19 — **P1 popup "freeze" (render starvation)** — NowPlayingCard's
  `repeatForever` EQ-bar animation on top of `.glassEffect` +
  `GlassEffectContainer` was keeping the main thread continuously in
  SwiftUI `renderDisplayList` / `NSHostingView.layout()`, which starved tap
  and scroll event processing. Diagnosed via `sample` — single main thread,
  no locks, just always busy. Static EQ bars instead of animated; no
  behavioral change visible, UI thread freed.
- ✓ 2026-04-19 — AI reply card body invisible (ScrollView collapsing to 0pt)
- ✓ 2026-04-19 — Apps/scenes top half not clickable (NSVisualEffectView absorbing hits)
- ✓ 2026-04-19 — Body shows off-state while header shows "On" during CEC wake (switched body to `displayOn`)
- ✓ 2026-04-19 — Header shows "On" while user just tapped sleep (optimistic `pendingPowerTarget` override)
- ✓ 2026-04-19 — Play/pause icon lags the status tick by up to 10s (optimistic `pendingPlayState`)
- ✓ 2026-04-19 — Status stale between ticks after RPC (daemon now pushes fresh status after every RPC)
- ✓ 2026-04-19 — AI reply in 1-line toast (promoted to dedicated card)
- ✓ 2026-04-19 — Volume buttons too small (bumped 26→38pt)
- ✓ 2026-04-19 — Empty AI reply rendering empty card (suppressed, falls through to `✓` toast)
