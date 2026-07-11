#!/usr/bin/env bash
set -euo pipefail

if [[ "${CONFIGURATION:-Release}" != "Release" ]]; then
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
xcframework="${GHOSTTYKIT_XCFRAMEWORK:-$repo_root/../ghostty-tmux-pane-store-refactor/macos/GhosttyKit.xcframework}"
macos_slice="$xcframework/macos-arm64_x86_64"
headers="$macos_slice/Headers"
library="$macos_slice/ghostty-internal.a"

if [[ ! -f "$headers/ghostty.h" || ! -f "$library" ]]; then
  printf 'Release builds require a complete GhosttyKit XCFramework at %s\n' "$xcframework" >&2
  printf 'Run scripts/build_release_ghosttykit.sh before building Remux Release.\n' >&2
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  printf 'xcrun is required to verify the GhosttyKit build mode.\n' >&2
  exit 127
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/remux-ghostty-build-mode.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
host_arch="$(uname -m)"

xcrun --sdk macosx clang \
  -target "$host_arch-apple-macos15.0" \
  -I "$headers" \
  -x c - \
  -x none "$library" \
  -lc++ \
  -framework Foundation \
  -framework AppKit \
  -framework Metal \
  -framework QuartzCore \
  -framework IOSurface \
  -framework Carbon \
  -o "$work_dir/build-mode" <<'SOURCE'
#include <stdio.h>
#include <ghostty.h>

int main(void) {
  printf("%d\n", (int)ghostty_info().build_mode);
  return 0;
}
SOURCE

actual_mode="$("$work_dir/build-mode")"
case "$actual_mode" in
  0) actual_name="Debug" ;;
  1) actual_name="ReleaseSafe" ;;
  2) actual_name="ReleaseFast" ;;
  3) actual_name="ReleaseSmall" ;;
  *) actual_name="unknown ($actual_mode)" ;;
esac

if [[ "$actual_mode" != "2" ]]; then
  printf 'Remux Release requires ReleaseFast GhosttyKit; detected %s at %s\n' \
    "$actual_name" \
    "$xcframework" >&2
  printf 'Run scripts/build_release_ghosttykit.sh before building or profiling Remux Release.\n' >&2
  exit 1
fi

printf 'Verified ReleaseFast GhosttyKit at %s\n' "$xcframework"
