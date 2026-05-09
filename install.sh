#!/bin/bash
# LivingRoomTV installer — sets up the `tv` CLI on a new Mac.
# Idempotent: safe to re-run after updates.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

step() { printf "\n\033[1;36m==>\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!! \033[0m%s\n" "$1" >&2; }
ok()   { printf "\033[1;32m✓ \033[0m %s\n" "$1"; }

# 1. Homebrew
if ! command -v brew >/dev/null 2>&1; then
    step "Installing Homebrew (you'll be prompted for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon brew lives at /opt/homebrew; make sure it's on PATH for this shell
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    ok "Homebrew already installed"
fi

# 2. uv (ships its own Python — no need for `brew install python`)
if ! command -v uv >/dev/null 2>&1; then
    step "Installing uv"
    brew install uv
else
    ok "uv already installed"
fi

# 3. Install the `tv` CLI from this repo
step "Installing tv CLI"
uv tool install --force "$REPO_DIR"

# Make sure ~/.local/bin is on PATH for the rest of this script
export PATH="$HOME/.local/bin:$PATH"

if ! command -v tv >/dev/null 2>&1; then
    warn "tv CLI was installed but isn't on your PATH yet."
    warn "Add this to your ~/.zshrc and reopen Terminal:"
    warn '    export PATH="$HOME/.local/bin:$PATH"'
    exit 1
fi
ok "tv CLI installed at $(command -v tv)"

# 4. Discover + pair Apple TV (interactive — needs PINs from the TV)
step "Discovering Apple TVs on your network"
tv discover || warn "No devices found yet — make sure your Apple TV is on and on the same Wi-Fi"

echo ""
read -rp "Pair with the Apple TV now? You'll need to enter two 4-digit PINs from the TV screen. [Y/n] " reply
case "${reply:-Y}" in
    [Nn]*)
        warn "Skipping pairing. Run \`tv pair\` when you're ready."
        ;;
    *)
        tv pair || warn "Pairing failed. You can retry anytime with \`tv pair\`."
        ;;
esac

# 5. (Optional) LG TV
echo ""
read -rp "Pair with an LG WebOS TV too? [y/N] " lg_reply
case "${lg_reply:-N}" in
    [Yy]*)
        read -rp "  LG TV IP address (e.g. 192.168.1.42): " lg_ip
        if [ -n "$lg_ip" ]; then
            tv lg pair "$lg_ip" || warn "LG pairing failed. Retry with \`tv lg pair $lg_ip\`."
        fi
        ;;
esac

# 6. (Optional) AI key
echo ""
read -rp "Enable AI features? Requires an Anthropic API key. [y/N] " ai_reply
case "${ai_reply:-N}" in
    [Yy]*)
        echo "  Get a key at https://console.anthropic.com/settings/keys"
        tv ai-setup
        ;;
    *)
        ok "AI skipped — you can enable it later in the app's Settings."
        ;;
esac

echo ""
ok "Setup complete."
echo ""
echo "Next: download LivingRoomTV.app from the Releases page, drag to /Applications,"
echo "      and right-click → Open (first launch only)."
