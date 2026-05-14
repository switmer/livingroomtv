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
| A8 | **mDNS-broken fallback for Apple TV discovery/pairing** *(detailed spec below)* | Real bug hit 2026-05-13. `pyatv` multicast unreliable on macOS 26; commands die when cache empties + IP shifts. | 1–2 sessions |
| A9 | **Local Network permission diagnostics + app-owned discovery process** *(detailed spec below)* | Apps that scan via Python in `~/.local/share/uv/` get unpredictable permission attribution. Long-term fix is owning the binary identity macOS sees. | 2–3 sessions |

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

## A8 — mDNS-broken fallback for Apple TV discovery/pairing

### Problem

On macOS 26, `pyatv`'s multicast mDNS scanning can return zero devices or fail silently with `Errno 51 Network is unreachable` on every interface — even when macOS Bonjour (`dns-sd`) clearly sees the Apple TV. The Apple TV is reachable by *direct host scan*; the issue is specifically the multicast path.

`Errno 51` here is *consistent with* Local Network permission / multicast routing problems on newer macOS — but the cause set is broader (VPN/filtering, IPv6 weirdness, pyatv socket behavior). The architectural lesson: **treat mDNS as unreliable, not assume one exact cause.**

### Current behavior

Fresh install:
1. `tv discover` uses multicast scan
2. `pyatv` returns no configs
3. User sees "no devices found"
4. Pairing cannot proceed unless `addresses.json` is manually populated

After cache exists:
1. Adapter skips mDNS via the fast-path
2. Uses cached host/IP
3. Commands succeed

When cache empties (auto-clear, Apple TV IP shift, Private MAC rotation):
- Same dead end as fresh install

### Desired behavior — split between commands and pairing

> **Commands: cache fallback automatically. Pairing: require explicit `--host` when discovery fails. Don't silently pair against stale cache.**

#### Scope

**Adapter (commands):**
- When `apple_tv.scan()` returns zero configs AND `~/.config/tv/addresses.json` contains a cached host for the requested identifier:
  - Retry with `hosts=[cached_host]`
  - If that succeeds, refresh the cache entry's `last_seen` timestamp
  - Proceed with the command

**CLI (pairing):**
- Add `tv pair --host <ip-or-hostname>`
- Bypasses multicast entirely; pyatv `scan(hosts=[host])`
- On success: writes device metadata to `addresses.json`
- Do *not* fall back to stale cached hosts during pairing (cache could point at a different physical device)

**CLI error messaging:**
- When broadcast scan returns zero devices, the error now suggests:
  - `tv pair --host <apple-tv-ip>`
  - `dns-sd -B _airplay._tcp local` to find the IP via Bonjour
  - System Settings → Privacy & Security → Local Network

### Non-goals

- Do not replace pyatv discovery entirely
- Do not build custom Bonjour parsing yet
- Do not require users to understand network interfaces

### Acceptance criteria

- Fresh user can pair Apple TV by IP without multicast discovery
- Existing cached users continue to work without mDNS
- If multicast scan fails but cache exists, `tv status`, `tv on`, `tv off` still work
- Failure message points to host-based fallback instead of dead-ending at "no devices found"

### Effort

1–2 sessions. Adapter change is ~30 lines; CLI flag is ~10 lines; error-message refactor is the longest part.

---

## A9 — Local Network permission diagnostics + app-owned discovery process

### Problem

macOS attributes Local Network permission to the **binary actually opening the multicast socket**, not the conceptual app. For LivingRoomTV today that's:

```
LivingRoomTV.app
  ↳ spawns Process(/Users/<u>/.local/bin/tv)
    ↳ which is a shim into /Users/<u>/.local/share/uv/tools/tv/bin/python
      ↳ which imports pyatv
        ↳ which opens the multicast socket — THIS is what macOS sees
```

That means permission UX is unpredictable: the prompt might appear under "python", "tv", a Python framework, or never appear at all. The user can't easily find what to toggle.

### Current behavior

- User sees "Disconnected" / "Away" with no actionable info
- `Errno 51` shows only in `--debug` output buried in pyatv logs
- No CLI/app surface that says "this looks like a Local Network permission issue, here's where to check"

### Desired behavior

Two pieces, ordered by effort:

#### A9a — diagnostics (quick win)

- `tv discover` (and adapter scan paths) catch `Errno 51` / `ENETUNREACH` socket errors
- On detection, emit a structured error pointing at:
  - **System Settings → Privacy & Security → Local Network** (with the path)
  - The actual binary likely needing permission (`/Users/<u>/.local/share/uv/tools/tv/bin/python` resolved via `sys.executable`)
  - The `dns-sd -B _airplay._tcp local` smoke test
- Mac app surfaces this as a banner inside the popup ("Local Network access may be denied — click for details") rather than the generic Reconnecting… state

#### A9b — app-owned discovery process (real fix)

- Bundle a helper executable (Swift or Go, statically linked) inside `LivingRoomTV.app/Contents/MacOS/` that does mDNS discovery
- The menu bar app invokes the bundled helper for discovery, not the uv-tools Python
- macOS attributes Local Network permission to `LivingRoomTV.app/Contents/MacOS/<helper>` — a stable, signed binary inside the .app bundle
- The Python `tv` CLI can still own pairing/control (where permission is less critical because we're talking direct host-to-host)

### Non-goals

- Don't try to "request" Local Network permission proactively. macOS gates this on actual socket usage; calling a hypothetical API to ask is a fragile pattern.
- Don't replace pyatv on the Python side — keep using it for pairing and control.

### Acceptance criteria

- App has a clear diagnostic when multicast scan fails
- User sees which executable likely needs Local Network permission
- CLI prints a next-action message when scan returns zero devices with `Errno 51`
- Menu bar app performs discovery from an app-owned helper binary where permission attribution is predictable
- Docs include the System Settings path to fix permission manually

### Effort

A9a: 1 session. A9b: 3–5 sessions (new bundled binary, Bonjour API integration, signing into the app bundle).

### Why this matters

A8 is product resilience — prevents today's dead end from happening again. A9 is permission observability + process ownership — prevents the *same class of bug* from becoming spooky in a year when someone hits it from a different angle. **Both belong in v0.1.x; A8 unblocks users immediately, A9 makes the network surface debuggable.**

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
