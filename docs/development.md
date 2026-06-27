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

For local latency profiling in debug builds, the seeded session can be opened
without UI automation:

```bash
REMUX_DEBUG_AUTO_OPEN_SESSION="base"
REMUX_DEBUG_LATENCY_PROBE="input"
```

`REMUX_DEBUG_AUTO_OPEN_SESSION=latest` opens the most recently used saved
workspace. Any other non-empty value is treated as a tmux session name.
`REMUX_DEBUG_LATENCY_PROBE` accepts `input`, `key-echo`, `new-window`,
`split-right`, `split-down`, `show-windows`, `show-panes`,
`show-windows-dismiss`, `show-panes-dismiss`, `select-window`, `select-pane`,
`close-window`, or `close-pane` after the terminal is running.

To collect repeated physical-device probe samples from an installed debug
build, run the batch helper with the connected device UDID. Prefer non-mutating
probes such as key echo and sheet presentation when profiling a real working
tmux session:

```bash
scripts/remux_physical_latency_probe_batch.py \
  --device <device-udid> \
  --session base \
  --probe key-echo \
  --probe show-windows \
  --probe show-windows-dismiss \
  --samples 5
```

For mutating probes such as `new-window` or `split-right`, use a disposable
tmux session and ephemeral app storage so the real working session is not
modified:

```bash
scripts/remux_physical_latency_probe_batch.py \
  --device <device-udid> \
  --seed-config /tmp/remux-live-ssh.json \
  --ephemeral-storage \
  --session-template 'remux-latency-{stamp}-{probe}-{index}' \
  --probe new-window \
  --probe split-right \
  --samples 3
```

Selection and close probes need a known tmux shape. Use `--fixture two-windows`
for `select-window` and `close-window`, or `--fixture two-panes` for
`select-pane` and `close-pane`. Fixture mode requires `--session-template`,
recreates only the disposable session for that sample, and removes it after the
sample unless `--keep-fixture-sessions` is passed:

```bash
scripts/remux_physical_latency_probe_batch.py \
  --device <device-udid> \
  --seed-config /tmp/remux-live-ssh.json \
  --ephemeral-storage \
  --session-template 'remux-latency-{stamp}-{probe}-{index}' \
  --fixture two-windows \
  --probe select-window \
  --probe close-window \
  --samples 3
```

When the profiling helper runs on the same Mac that owns those tmux sessions,
pass `--local-fixture` to prepare the disposable tmux sessions with the local
`tmux` command instead of opening a separate SSH control channel.

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

For physical-device UI tests, pass the local signing inputs explicitly:

```bash
scripts/remux_live_ui_test_with_cleanup.sh \
  --scheme Remux \
  --xcconfig .local/physical-uitest-signing.xcconfig \
  --allow-provisioning-updates \
  --destination 'platform=iOS,id=<device-udid>' \
  --only-testing RemuxUITests/RemuxAppUITests/testLiveSSHTmuxActionCycleWhenConfigured
```
