#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty_root="${GHOSTTY_SOURCE_DIR:-$repo_root/../ghostty-tmux-pane-store-refactor}"
xcframework="$ghostty_root/macos/GhosttyKit.xcframework"

if [[ ! -f "$ghostty_root/build.zig" ]]; then
  printf 'Ghostty source checkout not found at %s\n' "$ghostty_root" >&2
  printf 'Set GHOSTTY_SOURCE_DIR to the checkout consumed by Remux.\n' >&2
  exit 2
fi

if ! command -v zig >/dev/null 2>&1; then
  printf 'zig is required to build GhosttyKit.\n' >&2
  exit 127
fi

printf 'Building ReleaseFast GhosttyKit from %s\n' "$ghostty_root"
(
  cd "$ghostty_root"
  zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Demit-macos-app=false
)

GHOSTTYKIT_XCFRAMEWORK="$xcframework" \
  "$repo_root/scripts/verify_ghosttykit_release_mode.sh"
