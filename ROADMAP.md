# LivingRoomTV Roadmap

**Status:** v0.1.0 shipped (notarized DMG + public repo + draft installer).
**Operating principle:** architecture multi-adapter, product single-adapter, until usage earns breadth.

---

## Now: v0.1.x — adoption polish + learning loop

Two parallel tracks. Don't conflate them: shipping fixes is **engineering**; deciding what's next is **validation**.

### Track A — close real friction (engineering)

These are the things a v0.1 user actually trips on. Sized so each is one focused session.

| # | Item | Why it blocks adoption | Rough effort |
|---|---|---|---|
| A1 | **In-app "`tv` CLI missing" detection + onboarding sheet** | A friend who installs only the `.app` opens it, sees `disconnected`, has no idea why. Single biggest friction point we identified. | 1–2 sessions |
| A2 | **First-run Apple TV pairing inside the app** | `tv pair` requires Terminal + two 4-digit PINs. Non-technical users won't do it. Replace with a SwiftUI sheet that drives pyatv pairing via daemon RPC. | 2–3 sessions |
| A3 | **AI key entry: validate the key before saving** | Currently `tv ai-setup` accepts any string. A typo'd key fails silently the first time `tv ai` runs. Quick `client.models.list()` check at save time. | 0.5 sessions |
| A4 | **Sparkle auto-update integration** | Without it, v0.1.x ships to no one. Users stay on whatever they downloaded. | 1 session |
| A5 | **Login-item polish** — wire `LoginItemService.swift` to a Settings toggle | Already half-implemented in the codebase. ~30 min to finish + test. | 0.5 sessions |
| A6 | **`install.sh` defensive checks** — verify Xcode CLT, network, give better error if `tv pair` fails | Currently fails with cryptic pyatv tracebacks. | 0.5 sessions |

### Track B — validation (no code)

The thing v0.1 can't tell us by reading the diff: **does anyone actually use this twice?**

| # | Item | Why |
|---|---|---|
| B1 | **Send to 2–3 friends with Apple TVs.** Even if your sample said 0/4 — the Mac-using cohort overlaps Apple-TV ownership more than a random text thread. Find them. | The friend sample is *not* your ICP. Find your actual ICP. |
| B2 | **Add lightweight telemetry** — opt-in, anonymous: did they launch, did any command fire, did the daemon survive >24h | "Did anyone use it twice?" is unanswerable without it. Use Sentry's free tier or just `~/.config/tv/usage.log` they can mail you. |
| B3 | **At day-14: Sean Ellis question** — "How would you feel if you could no longer use LivingRoomTV?" 40% "very disappointed" = product-market fit-ish. | Quantifies what "validation" actually means. |

### What's **not** in v0.1.x

- LG as primary adapter
- Any new platform
- AI hosted proxy
- Designed (non-procedural) icon

---

## Next: v0.2 — adapter refactor (decision-gated)

**Trigger:** ≥2 people from B1 say "I'd actually install this for my LG/Samsung/etc."

This is the 2–4 week refactor the [audit identified](#current-multi-adapter-readiness-30). **Do not start without the trigger.** Adding LG-as-primary on the current scaffolding creates compounding tech debt.

### Scope (in order)

1. **Define `TVAdapter` protocol** — `discover`, `pair`, `connect`, `send_command`, `get_state`, `get_capabilities`. Both `apple_tv.py` and `lg_webos.py` implement it.
2. **`DeviceCapabilities` model** — explicit booleans for `supports_power`, `supports_volume`, `supports_directional_nav`, `supports_text_input`, `supports_app_launch`, `supports_now_playing`, etc.
3. **Generic `TVStatus`** — kill `lgPowerState`, `volumeSource` as named fields. Replace with `platform: String` + `adapterState: [String: Any]` extension dict.
4. **Daemon RPCs gain `device_id`** — `play_pause` becomes `{cmd: "play_pause", device_id: "lg-living-room"}`.
5. **`StatusStore` keyed by `deviceId`** — `[deviceId: TVStatus]`, not a single `status`.
6. **Capability-gated UI rows** — RemotePad disappears when current device doesn't support directional nav. Volume row hides when no volume control.
7. **Scene execution dispatched through selected adapter** — `scenes.py` stops importing `apple_tv` directly; uses `adapter.wake()` instead.
8. **Device picker UI** — even if you only have one, the concept exists. Multi-device users get a sub-menu.

After this lands, *only then* does LG-as-primary actually work end-to-end.

---

## Explicitly deferred (until proven necessary)

These keep coming up. The answer is no, with reasons:

| Item | Why deferred |
|---|---|
| **Samsung Tizen** | Post-2018 API surface is hostile. Token rotation, deprecated SmartView, ~30% of what Apple TV can do. Only worth it for a paying customer asking directly. |
| **Roku** | ECP API is great, but no demand signal in our sample. Defer until asked. |
| **Fire TV** | ADB-based control. Users have to flip dev mode. Tarpit. |
| **Chromecast / Cast** | Different product (cast controller, not TV remote). Don't conflate. |
| **iOS / watchOS companion** | Out of scope for "Mac menu bar app." Different code path entirely. |
| **Hosted Anthropic proxy** | Adds infrastructure to maintain. Only worth it if AI is the wedge for adoption, which v0.1 hasn't proven. |
| **Designed (non-procedural) icon** | The current procedural icon now has shadow + highlight. Good enough for v0.1. Real icon = a designer's job, not engineering's. |
| **Tests + CI** | Smoke tests for `scenes.py` would help, but pyatv/aiowebostv mock surface is large. Defer until a regression bites. |

---

## Backlog (unprioritized, not committed)

If/when v0.1.x validates and v0.2 lands:

- **Homebrew tap** — `brew install switmer/tap/livingroomtv-cli` for one-command CLI install
- **Stream Deck plugin** — small but high-affinity user base
- **macOS Spotlight integration** — natural extension of AI commands
- **Apple Shortcuts deeper integration** — beyond the current `tv siri` entrypoint
- **Better AI system prompt** — `agent.py` could probably be 2× more reliable with iteration
- **Designed app icon** — replace procedural generator with a real `.icns` from a designer
- **Crash reporting** (Sentry self-hosted or similar) — once user count justifies maintenance

---

## How to use this doc

- Pick **one** Track A item per session. Ship, commit, move on.
- Run Track B in parallel — talking to friends doesn't block engineering.
- **Do not** start v0.2 without the trigger condition met.
- When something in "Deferred" gets asked about: link back here. Re-evaluate only on new evidence.
