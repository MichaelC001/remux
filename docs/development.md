# Development

Remux uses XcodeGen. The checked-in project definition is `project.yml`.

## Requirements

- Xcode with iOS 18 SDK support
- XcodeGen on `PATH`
- terminal-renderer XCFramework at the relative path configured in
  [project.yml](../project.yml)

## Generate Project

```bash
xcodegen generate
```

Run this after changing [project.yml](../project.yml).

## Build

```bash
xcodebuild build \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'generic/platform=iOS Simulator'
```

## Test

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

## Local Files

Keep developer-only notes, live validation configuration, and machine-specific
working files in `.local/`. The directory is ignored by Git.

Do not commit local credentials, live SSH host details, machine-specific result
bundles, or generated build products.

## Debug Seeding

Debug builds can seed one saved connection from launch environment variables.

```bash
REMUX_DEBUG_SEED_CONNECTION=1
REMUX_DEBUG_SERVER_NAME="Example Server"
REMUX_DEBUG_SERVER_HOST="server.example.com"
REMUX_DEBUG_SERVER_PORT=22
REMUX_DEBUG_SERVER_USERNAME="demo"
REMUX_DEBUG_SERVER_PASSWORD="<password>"
REMUX_DEBUG_TMUX_SESSION="base"
```

Live validation should stay opt-in and local. Keep any real host, username,
password, or test-control files out of the tracked repository.

When running generated live UI tests, use the tracked host-side wrapper so the
app runs with ephemeral debug storage, the test records the exact disposable
`remux-latency-*` tmux sessions it creates, and the wrapper removes only those
allowlisted sessions after the run:

```bash
scripts/remux_live_ui_test_with_cleanup.sh \
  --only-testing RemuxUITests/RemuxAppUITests/testLiveSSHTmuxActionCycleWhenConfigured
```
