#!/bin/zsh
# Resolve the destination shared by this checkout's simulator scripts.
set -eu
local_file="${0:A:h}/Simulator.local"
if [[ -n "${MEOWVERSE_SIM:-}" ]]; then
  print -r -- "$MEOWVERSE_SIM"
elif [[ -s "$local_file" ]]; then
  cat "$local_file"
elif [[ "${1:-}" == --store-shots ]]; then
  xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name=="iPhone 18 Pro Max")][0].udid // empty'
else
  xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid // empty'
fi
