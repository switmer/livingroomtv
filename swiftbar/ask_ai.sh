#!/bin/zsh
# Prompt for a natural-language request and run it through `tv ai`.
# Invoked from the SwiftBar plugin.

TV="${HOME}/.local/bin/tv"
PROMPT=$(/usr/bin/osascript -e 'tell application "System Events" to set theResult to text returned of (display dialog "Ask TV:" default answer "" with title "Living Room TV" buttons {"Cancel","Send"} default button "Send")' 2>/dev/null)

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

SUMMARY=$("$TV" ai "$PROMPT" 2>&1)

# Show the summary as a macOS notification
/usr/bin/osascript -e "display notification \"${SUMMARY//\"/\\\"}\" with title \"Living Room TV\"" 2>/dev/null

# Trigger plugin refresh
/usr/bin/open "swiftbar://refreshallplugins" 2>/dev/null
