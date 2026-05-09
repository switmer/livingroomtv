# LivingRoomTV

A tiny Mac menu bar remote for your living-room TV. Apple TV today, more soon.

Native SwiftUI app. Scenes, app launchers, transport, volume, now-playing — fast. Optional AI control as a power-user opt-in. LG WebOS works as a **companion** for power/volume sensing when paired alongside an Apple TV.

## Quick start

> Requires macOS 14+ on Apple Silicon. Intel Macs work but are not the primary target.

### 1. Install the `tv` CLI

```bash
git clone https://github.com/switmer/livingroomtv.git ~/.tv-src
cd ~/.tv-src
./install.sh
```

This installs Homebrew (if missing), `uv`, and the `tv` CLI to `~/.local/bin/tv`. Then it discovers your Apple TV and walks you through pairing.

### 2. Install the Mac app

Download `LivingRoomTV.app` from the latest [release](https://github.com/switmer/livingroomtv/releases), drag it to `/Applications`, and right-click → **Open** the first time (Gatekeeper).

If your release is notarized, just double-click. No right-click needed.

### 3. (Optional) Enable AI

AI is **off by default**. To turn it on:

- In the app: Settings → AI (optional) → paste your Anthropic key
- Or in Terminal: `tv ai-setup`

You pay for your own Anthropic usage. Without a key, every other feature still works.

## What works without AI

- Apple TV remote: directional pad, transport, volume, mute, sleep/wake
- Pre-built scenes (Movie, Bedtime, Kid Show, etc.) — runnable from menu bar
- App launchers for Netflix, Disney+, HBO, Hulu, Prime, etc.
- Now-playing card with artwork
- Status pill, "Away" detection (off home network)
- **LG WebOS companion** (optional, paired alongside Apple TV): TV-side power/volume/mute sensing — fills the HDMI-CEC blind spots the Apple TV can't see

## Roadmap

LivingRoomTV is designed to grow into more TV platforms. **v0.1 is Apple TV only as the primary control surface.** LG WebOS is a companion adapter today; standalone LG-only support, Samsung Tizen, Roku, etc. are deferred until validated by real demand.

## What AI adds (when key present)

- Natural-language control: "find Bluey", "turn the volume to 30 then play"
- AI-authored scenes: describe what you want, save the resulting plan as a reusable scene
- Siri Shortcut entrypoint (`tv siri "<phrase>"`)

## Troubleshooting

- **`tv: command not found`** — `~/.local/bin` isn't on your PATH. Run `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`
- **Pairing fails** — make sure the Apple TV is awake; re-run `tv pair`. The PIN appears on the TV.
- **Gatekeeper blocks the app** — right-click → **Open** (first launch only). Or wait for a notarized release.
- **App can't reach TV** — same Wi-Fi, no client isolation enabled on the router.

## For maintainers (release process)

Building a notarized release requires:

1. **Apple Developer ID Application certificate** in your login keychain
2. **App-specific password** for `notarytool`, stored once via:
   ```bash
   xcrun notarytool store-credentials AC_PASSWORD \
     --apple-id "you@example.com" \
     --team-id "<TEAM_ID>" \
     --password "<APP_SPECIFIC_PASSWORD>"
   ```
3. Environment variables when running `release.sh`:
   ```bash
   export APPLE_TEAM_ID="ABCD1234EF"
   export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (ABCD1234EF)"
   export NOTARY_PROFILE="AC_PASSWORD"
   ./mac/LivingRoomTV/scripts/release.sh
   ```

The release script produces `dist/LivingRoomTV-<version>.dmg` (universal binary, signed, notarized, stapled).

## License

Personal utility — not for commercial distribution.
