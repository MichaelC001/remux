#!/usr/bin/env bash
set -euo pipefail

# Downloads the prebuilt ReleaseFast GhosttyKit.xcframework release asset and
# places it at the path configured in project.yml, so building Remux does not
# require Zig or a Ghostty checkout.

release_tag="ghosttykit-20260720"
asset_sha256="2b12e269554af29b08636f29a916fb8f8d3f0788c0623576755a6dc38cb8568c"
asset_url="https://github.com/h3nock/remux-ghostty/releases/download/${release_tag}/GhosttyKit.xcframework.zip"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Must match the framework path in project.yml.
framework_parent="$repo_root/../ghostty-remux-upstream-rebuild/macos"
framework_path="$framework_parent/GhosttyKit.xcframework"

force=0
if [[ "${1:-}" == "--force" ]]; then
  force=1
elif [[ -n "${1:-}" ]]; then
  echo "Usage: scripts/fetch_ghosttykit.sh [--force]" >&2
  exit 2
fi

if [[ -d "$framework_path" && "$force" -ne 1 ]]; then
  echo "GhosttyKit.xcframework already present at:"
  echo "  $framework_path"
  echo "Re-run with --force to replace it with release $release_tag."
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
zip_path="$workdir/GhosttyKit.xcframework.zip"

echo "Downloading GhosttyKit ($release_tag)..."
curl --fail --location --progress-bar --output "$zip_path" "$asset_url"

echo "Verifying checksum..."
actual_sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
if [[ "$actual_sha256" != "$asset_sha256" ]]; then
  echo "Checksum mismatch for downloaded GhosttyKit archive." >&2
  echo "  expected: $asset_sha256" >&2
  echo "  actual:   $actual_sha256" >&2
  exit 1
fi

echo "Installing to $framework_path"
mkdir -p "$framework_parent"
rm -rf "$framework_path"
ditto -x -k "$zip_path" "$framework_parent"

if [[ ! -d "$framework_path" ]]; then
  echo "Archive did not contain GhosttyKit.xcframework at its root." >&2
  exit 1
fi

echo "Done. Generate the project with 'xcodegen generate' and build."
