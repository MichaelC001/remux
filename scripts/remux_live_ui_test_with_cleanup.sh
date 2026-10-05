#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/remux_live_ui_test_with_cleanup.sh [options] --only-testing <test-id> [--only-testing <test-id> ...]
  scripts/remux_live_ui_test_with_cleanup.sh --dry-run-cleanup <manifest-file>

Options:
  --config <path>              Live SSH configuration (default /tmp/remux-live-ssh.json)
  --destination <spec>         xcodebuild destination (default "platform=iOS Simulator,name=iPhone 17,OS=latest")
  --configuration Debug|Release
                               Build configuration (default Debug)
  --development-team <team-id> Sign with this team, with automatic provisioning
  --derived-data-path <path>   xcodebuild derived data path
  --only-testing <test-id>     Test to run, e.g. RemuxUITests/RemuxAppUITests/testLiveSSHTmuxActionCycleWhenConfigured
  --dry-run-cleanup <file>     Print the sessions a manifest would remove, then exit
  -h, --help                   Show this help

Runs selected Remux live SSH UI tests and remotely removes only the exact
allowlisted remux-latency-* tmux sessions that the UI tests record in their
cleanup manifest.

The tests are built once and run in one xcodebuild invocation, each in its own
tmux session, so no test inherits another test's windows, panes or running
programs. Most tests generate their own session; the harness prepares the
fixtures up front, each in its own session, and assigns them to their tests by
name. As soon as a test finishes, the harness verifies the tmux expectations
it recorded, whatever its outcome, and removes its sessions, so later tests
never see them.

The config is a JSON object with "host", "username", optional "port",
"displayName", "sessionName" and "tmuxExecutablePath", and either "password" or
"privateKeyPEM" with an optional "privateKeyPassphrase". The app reads the
credential from the config itself, and the harness keeps a private key only in
its own ssh-agent, so no copy of it is written anywhere else. Everything the
harness shares with the tests lives in a temporary directory of its own, so
runs do not share state.

An optional "tmuxExecutablePath" in the config is used by both the app and the
fixture/cleanup commands, e.g. a wrapper that runs `tmux -L <socket> "$@"` so
live tests never share a tmux server with real sessions.
USAGE
}

config="/tmp/remux-live-ssh.json"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"
configuration="Debug"
development_team=""
derived_data_path=""
declare -a only_testing=()
dry_run_manifest=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --config)
      config="${2:-}"
      [[ -n "$config" ]] || { usage; exit 2; }
      shift 2
      ;;
    --destination)
      destination="${2:-}"
      [[ -n "$destination" ]] || { usage; exit 2; }
      shift 2
      ;;
    --configuration)
      configuration="${2:-}"
      case "$configuration" in
        Debug|Release) ;;
        *) usage; exit 2 ;;
      esac
      shift 2
      ;;
    --development-team)
      development_team="${2:-}"
      [[ "$development_team" =~ ^[A-Za-z0-9]+$ ]] || { usage; exit 2; }
      shift 2
      ;;
    --derived-data-path)
      derived_data_path="${2:-}"
      [[ -n "$derived_data_path" ]] || { usage; exit 2; }
      shift 2
      ;;
    --only-testing)
      test_id="${2:-}"
      [[ -n "$test_id" ]] || { usage; exit 2; }
      only_testing+=("$test_id")
      shift 2
      ;;
    --dry-run-cleanup)
      dry_run_manifest="${2:-}"
      [[ -n "$dry_run_manifest" ]] || { usage; exit 2; }
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

# The tests and the app read the config from other working directories.
if [[ "$config" != /* ]]; then
  config="$PWD/$config"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

session_allowlist='^remux-latency-[A-Za-z0-9._-]+$'

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required tool: %s\n' "$1" >&2
    exit 127
  fi
}

validate_manifest() {
  local manifest="$1"
  local bad=0

  if [[ ! -f "$manifest" ]]; then
    printf 'missing generated-session manifest: %s\n' "$manifest" >&2
    return 1
  fi

  while IFS= read -r session || [[ -n "$session" ]]; do
    [[ -n "$session" ]] || continue
    if [[ ! "$session" =~ $session_allowlist ]]; then
      printf 'refusing non-allowlisted generated session: %s\n' "$session" >&2
      bad=1
    fi
  done <"$manifest"

  return "$bad"
}

manifest_sessions() {
  local manifest="$1"
  validate_manifest "$manifest" >/dev/null || return 1
  awk 'NF { print $0 }' "$manifest" | sort -u
}

if [[ -n "$dry_run_manifest" ]]; then
  validate_manifest "$dry_run_manifest"
  manifest_sessions "$dry_run_manifest" | sed 's/^/dry-run cleanup session: /'
  exit 0
fi

if [[ "${#only_testing[@]}" -eq 0 ]]; then
  echo "At least one --only-testing target is required." >&2
  usage
  exit 2
fi

if declare -p REMUX_PROFILE_PANE_SWITCH_COUNT >/dev/null 2>&1; then
  value="$REMUX_PROFILE_PANE_SWITCH_COUNT"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 || 10#$value > 1000 )); then
    printf 'REMUX_PROFILE_PANE_SWITCH_COUNT must be an integer from 1 through 1000; got %s.\n' "$value" >&2
    exit 1
  fi
fi
for name in REMUX_TRACE_FLOWS REMUX_TRACE_TMUX_VIEWPORT REMUX_TRACE_LATENCY REMUX_TRACE_PERF GHOSTTY_TRACE_SURFACE_INIT GHOSTTY_TRACE_FRAME_COMPLETION; do
  declare -p "$name" >/dev/null 2>&1 || continue
  value="${!name}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    printf '%s must be 0 or 1; got %s.\n' "$name" "$value" >&2
    exit 1
  fi
done

if [[ ! -f "$config" ]]; then
  printf 'Missing %s; cannot run live SSH UI tests.\n' "$config" >&2
  exit 2
fi

require_tool ruby
require_tool ssh
require_tool ssh-add
require_tool ssh-agent
require_tool ssh-keygen
require_tool xcodebuild

json_string() {
  ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.fetch(0)))
    value = data[ARGV.fetch(1)]
    if value.nil?
      exit(ARGV.fetch(2) == "optional" ? 0 : 2)
    end
    exit 1 unless value.is_a?(String)
    print value
  ' "$config" "$1" "${2:-required}"
}

host="$(json_string host)"
username="$(json_string username)"
password="$(json_string password optional)"
private_key="$(json_string privateKeyPEM optional)"
private_key_passphrase="$(json_string privateKeyPassphrase optional)"
port="$(json_string port optional)"
port="${port:-22}"
tmux_executable="$(json_string tmuxExecutablePath optional)"
if [[ -n "$tmux_executable" && ! "$tmux_executable" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  printf 'tmuxExecutablePath in %s must be an absolute path of [A-Za-z0-9._/-] characters.\n' "$config" >&2
  exit 2
fi
remote_tmux_env="REMUX_LIVE_TMUX=$tmux_executable"

known_host_lookup="$host"
if [[ "$port" != "22" ]]; then
  known_host_lookup="[$host]:$port"
fi
known_host_line="$(ssh-keygen -F "$known_host_lookup" 2>/dev/null | awk '!/^#/ { print; exit }')"
if [[ -z "$known_host_line" ]]; then
  printf 'No trusted OpenSSH host key found for %s; refusing automated Remux trust.\n' "$known_host_lookup" >&2
  exit 2
fi
expected_host_key_type="$(printf '%s\n' "$known_host_line" | awk '{ print $(NF - 1) }')"
expected_host_key_fingerprint="$(
  printf '%s\n' "$known_host_line" |
    ssh-keygen -lf - -E sha256 2>/dev/null |
    awk '{ print $2 }'
)"
if [[ -z "$expected_host_key_type" || -z "$expected_host_key_fingerprint" ]]; then
  printf 'Could not derive the trusted OpenSSH host fingerprint for %s.\n' "$known_host_lookup" >&2
  exit 2
fi
expected_host_key="$expected_host_key_type $expected_host_key_fingerprint"

if [[ -z "$private_key" && -z "$password" ]]; then
  printf '%s must include password or privateKeyPEM.\n' "$config" >&2
  exit 2
fi

# Everything this run shares with the tests lives here; its path reaches the
# test runner as TEST_RUNNER_REMUX_LIVE_RUN_DIR.
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/remux-live-ui.XXXXXX")"
# Each test records its generated sessions and tmux expectations here, in
# <test>.sessions and <test>.expectations.
records_dir="$run_dir/tests"
harness_file="$run_dir/harness.txt"
askpass="$run_dir/askpass.sh"
log_dir=".local/logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
build_log="$log_dir/live-ui-cleanup-${stamp}-build.log"
log="$log_dir/live-ui-cleanup-${stamp}.log"
result_bundle="$log_dir/live-ui-cleanup-${stamp}.xcresult"
cleanup_done=0
marker_refresh_pid=""
ssh_agent_pid=""

stop_harness_marker_refresh() {
  if [[ -n "$marker_refresh_pid" ]]; then
    kill "$marker_refresh_pid" 2>/dev/null || true
    wait "$marker_refresh_pid" 2>/dev/null || true
    marker_refresh_pid=""
  fi
}

cleanup_local_files() {
  stop_harness_marker_refresh
  if [[ -n "$ssh_agent_pid" ]]; then
    kill "$ssh_agent_pid" 2>/dev/null || true
    ssh_agent_pid=""
  fi
  rm -rf "$run_dir"
}

finish_before_remote_cleanup() {
  local status=$?
  cleanup_local_files
  exit "$status"
}
trap finish_before_remote_cleanup EXIT

mkdir "$records_dir"
cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$REMUX_LIVE_SSH_SECRET"
EOF
chmod 700 "$askpass"

ssh_askpass_secret=""
declare -a ssh_auth_args=()
if [[ -n "$private_key" ]]; then
  # The key goes into this run's own ssh-agent, not a file, so the config
  # stays its only copy.
  ssh_agent_socket="$run_dir/ssh-agent.sock"
  ssh_agent_pid="$(
    ssh-agent -a "$ssh_agent_socket" -s |
      sed -n 's/^SSH_AGENT_PID=\([0-9][0-9]*\);.*/\1/p'
  )"
  printf '%s\n' "$private_key" |
    SSH_AUTH_SOCK="$ssh_agent_socket" \
    REMUX_LIVE_SSH_SECRET="$private_key_passphrase" \
    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=remux \
    ssh-add -q -
  SSH_AUTH_SOCK="$ssh_agent_socket" ssh-add -L >"$run_dir/live_ssh_key.pub"
  ssh_auth_args=(
    -o "IdentityAgent=$ssh_agent_socket"
    -i "$run_dir/live_ssh_key.pub"
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
  )
else
  ssh_askpass_secret="$password"
  ssh_auth_args=(
    -o PreferredAuthentications=password,keyboard-interactive
  )
fi

# Tests that need a known session or a prepared fixture get their own, assigned
# here by test method name. Every other test generates a uniquely named session
# itself.
declare -a assigned_tests=()
declare -a assigned_sessions=()
declare -a assigned_fixtures=()
index=0
for target in "${only_testing[@]}"; do
  index=$((index + 1))
  session=""
  fixture=""
  case "$target" in
    *testLiveSSHTmuxActionCycleWhenConfigured)
      session="remux-latency-action-${stamp}-${index}"
      ;;
    *testLiveWindowNamesAndRenameWhenConfigured)
      session="remux-latency-window-names-${stamp}-${index}"
      ;;
    *testLiveDenseMixedTopologySelectsDeepPaneWhenConfigured)
      fixture="dense-mixed"
      session="remux-latency-dense-mixed-${stamp}-${index}"
      ;;
    *testLiveTerminalRelativeFilePreviewWhenConfigured)
      fixture="relative-file-preview"
      session="remux-latency-pv-${stamp}-${index}"
      ;;
  esac
  if [[ -n "$session" ]]; then
    assigned_tests+=("${target##*/}")
    assigned_sessions+=("$session")
    assigned_fixtures+=("$fixture")
  fi
done

# The marker tells the UI tests that this harness will clean up after them,
# where the config is and which host key to trust, and carries each assigned
# test's session and fixture as session.<test>=<session> and
# fixture.<test>=<fixture>. The tests treat a marker older than 30 minutes as
# stale, so it is refreshed while they run.
write_harness_marker() {
  local i
  {
    printf 'pid=%s\nstartedAt=%s\n' "$$" "$(date +%s)"
    printf 'config=%s\nexpectedHostKey=%s\n' "$config" "$expected_host_key"
    for name in \
      REMUX_LIVE_AGENT_TUI_SESSION \
      REMUX_PROFILE_PANE_SWITCH_COUNT \
      REMUX_TRACE_FLOWS \
      REMUX_TRACE_TMUX_VIEWPORT \
      REMUX_TRACE_LATENCY \
      REMUX_TRACE_PERF \
      GHOSTTY_TRACE_SURFACE_INIT \
      GHOSTTY_TRACE_FRAME_COMPLETION
    do
      if declare -p "$name" >/dev/null 2>&1; then
        printf '%s=%s\n' "$name" "${!name}"
      fi
    done
    for i in "${!assigned_tests[@]}"; do
      printf 'session.%s=%s\n' "${assigned_tests[$i]}" "${assigned_sessions[$i]}"
      if [[ -n "${assigned_fixtures[$i]}" ]]; then
        printf 'fixture.%s=%s\n' "${assigned_tests[$i]}" "${assigned_fixtures[$i]}"
      fi
    done
  } >"$harness_file.tmp"
  mv -f "$harness_file.tmp" "$harness_file"
}

# Runs in the background while the tests run, and stops on its own if the
# harness dies without its exit trap.
refresh_harness_marker() {
  while sleep 60 && kill -0 "$$" 2>/dev/null; do
    write_harness_marker
  done
}

write_harness_marker

prepare_dense_mixed_fixture() {
  local session="$1"

  if [[ ! "$session" =~ $session_allowlist ]]; then
    printf 'refusing non-allowlisted dense mixed fixture session: %s\n' "$session" >&2
    return 1
  fi

  printf 'Preparing dense mixed tmux fixture: %s\n' "$session"
  REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=remux \
    ssh \
      -p "$port" \
      -o BatchMode=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout=10 \
      "${ssh_auth_args[@]}" \
      "$username@$host" \
      "$remote_tmux_env" sh -s -- "$session" <<'REMOTE'
set -eu
session="$1"
tmux_bin="${REMUX_LIVE_TMUX:-$(command -v tmux 2>/dev/null || true)}"
if [ -z "$tmux_bin" ] && [ -x /opt/homebrew/bin/tmux ]; then
  tmux_bin=/opt/homebrew/bin/tmux
fi
if [ -z "$tmux_bin" ]; then
  echo 'tmux not found on remote host' >&2
  exit 127
fi

"$tmux_bin" kill-session -t "$session" 2>/dev/null || true
"$tmux_bin" new-session -d -s "$session" -n remuxw1

i=2
while [ "$i" -le 8 ]; do
  "$tmux_bin" new-window -d -t "$session:" -n "remuxw$i"
  i=$((i + 1))
done

win9="$("$tmux_bin" new-window -d -t "$session:" -P -F '#{window_id}' -n remuxw9)"
w9p1="$("$tmux_bin" list-panes -t "$win9" -F '#{pane_id}' | sed -n '1p')"
"$tmux_bin" split-window -d -h -t "$w9p1"
"$tmux_bin" split-window -d -v -t "$w9p1"

win10="$("$tmux_bin" new-window -d -t "$session:" -P -F '#{window_id}' -n remuxw10)"
w10p1="$("$tmux_bin" list-panes -t "$win10" -F '#{pane_id}' | sed -n '1p')"
w10p2="$("$tmux_bin" split-window -d -h -P -F '#{pane_id}' -t "$w10p1")"
"$tmux_bin" split-window -d -v -t "$w10p1"
"$tmux_bin" split-window -d -v -t "$w10p2"

pane4="$("$tmux_bin" list-panes -t "$win10" -F '#{pane_id}' | sed -n '4p')"
if [ -z "$pane4" ]; then
  echo 'dense mixed fixture did not create pane 4' >&2
  exit 1
fi
"$tmux_bin" send-keys -t "$pane4" "printf 'REMUX_DENSE_MIXED_READY_P4\n'" C-m
"$tmux_bin" select-window -t "$session:1"
REMOTE
}

prepare_relative_file_preview_fixture() {
  local session="$1"

  if [[ ! "$session" =~ $session_allowlist ]]; then
    printf 'refusing non-allowlisted relative file preview fixture session: %s\n' "$session" >&2
    return 1
  fi

  printf 'Preparing relative file preview tmux fixture: %s\n' "$session"
  REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
    SSH_ASKPASS="$askpass" \
    SSH_ASKPASS_REQUIRE=force \
    DISPLAY=remux \
    ssh \
      -p "$port" \
      -o BatchMode=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout=10 \
      "${ssh_auth_args[@]}" \
      "$username@$host" \
      "$remote_tmux_env" sh -s -- "$session" <<'REMOTE'
set -eu
session="$1"
fixture_suffix="${session#remux-latency-pv-}"
fixture_dir="/tmp/rpv-$fixture_suffix"
fixture_path="$fixture_dir/README.md"
html_path="$fixture_dir/index.html"
css_path="$fixture_dir/preview.css"
image_path="$fixture_dir/preview.svg"
script_path="$fixture_dir/preview.js"
tmux_bin="${REMUX_LIVE_TMUX:-$(command -v tmux 2>/dev/null || true)}"
if [ -z "$tmux_bin" ] && [ -x /opt/homebrew/bin/tmux ]; then
  tmux_bin=/opt/homebrew/bin/tmux
fi
if [ -z "$tmux_bin" ]; then
  echo 'tmux not found on remote host' >&2
  exit 127
fi

cleanup_failed_fixture() {
  status=$?
  if [ "$status" -ne 0 ]; then
    "$tmux_bin" kill-session -t "$session" 2>/dev/null || true
    if [ -f "$fixture_dir/server.pid" ]; then
      kill "$(cat "$fixture_dir/server.pid")" 2>/dev/null || true
    fi
    rm -f -- "$fixture_path" "$html_path" "$css_path" "$image_path" "$script_path" "$fixture_dir/server.pid"
    rmdir -- "$fixture_dir" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup_failed_fixture EXIT

"$tmux_bin" kill-session -t "$session" 2>/dev/null || true
rm -f -- "$fixture_path"
mkdir -p -- "$fixture_dir"
cat >"$fixture_path" <<'PREVIEW_FILE'
REMUX_PREVIEW_FILE_CONTENT_ALPHA
REMUX_PREVIEW_FILE_CONTENT_BETA
REMUX_PREVIEW_FILE_CONTENT_GAMMA
PREVIEW_FILE
cat >"$html_path" <<'PREVIEW_HTML'
<!doctype html>
<html>
<head>
<link rel="stylesheet" href="preview.css">
<script defer src="preview.js"></script>
</head>
<body><img src="preview.svg" alt="Relative preview resource loaded"></body>
</html>
PREVIEW_HTML
cat >"$script_path" <<'PREVIEW_JS'
document.addEventListener('DOMContentLoaded', function () {
  var reloadCount = Number(sessionStorage.getItem('remuxReloadCount') || '0') + 1;
  sessionStorage.setItem('remuxReloadCount', String(reloadCount));
  var banner = document.createElement('p');
  banner.textContent = 'Reload count ' + reloadCount;
  banner.style.color = '#f8fafc';
  banner.style.font = '600 20px -apple-system, sans-serif';
  document.body.appendChild(banner);
});
PREVIEW_JS

# Serve the same fixture over loopback HTTP so the live-localhost preview
# scenario exercises the direct-TCPIP forward end to end. The port is fixed
# because the UI test types the URL token verbatim.
live_server_port=18923
live_server_pid_path="$fixture_dir/server.pid"
if [ -f "$live_server_pid_path" ]; then
  kill "$(cat "$live_server_pid_path")" 2>/dev/null || true
  rm -f -- "$live_server_pid_path"
fi
(
  cd "$fixture_dir"
  nohup python3 -m http.server "$live_server_port" --bind 127.0.0.1 \
    >/dev/null 2>&1 &
  echo $! >"$live_server_pid_path"
)
cat >"$css_path" <<'PREVIEW_CSS'
html, body { margin: 0; min-height: 100%; background: #123047; }
body { display: grid; place-items: center; }
img { width: min(72vw, 420px); }
PREVIEW_CSS
cat >"$image_path" <<'PREVIEW_SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 240">
  <rect width="400" height="240" rx="28" fill="#14b8a6"/>
  <circle cx="100" cy="120" r="54" fill="#f59e0b"/>
  <path d="M190 72h150v32H190zm0 64h110v32H190z" fill="#f8fafc"/>
</svg>
PREVIEW_SVG

# Match normal shell output: the pane's current directory contains README.md,
# and `ls` prints only that bare filename at a stable top-row position. Each
# subsequent input line replaces it so the UI test can exercise other path
# forms at the same terminal coordinate without shell prompts or extra output.
"$tmux_bin" new-session -d -s "$session" -n preview -c "$fixture_dir" \
  "ls -1 README.md; while IFS= read -r token; do printf '\\033[2J\\033[H%s\\n' \"\$token\"; done"
REMOTE
}

assigned_fixture_for_session() {
  local i
  for i in "${!assigned_sessions[@]}"; do
    if [[ "${assigned_sessions[$i]}" == "$1" ]]; then
      printf '%s\n' "${assigned_fixtures[$i]}"
      return
    fi
  done
}

cleanup_generated_sessions() {
  local manifest="$1"
  local status=0

  if [[ ! -s "$manifest" ]]; then
    echo "No generated tmux sessions were recorded for cleanup."
    return 0
  fi

  if ! validate_manifest "$manifest"; then
    return 1
  fi

  while IFS= read -r session; do
    [[ -n "$session" ]] || continue
    printf 'Cleaning generated tmux session: %s\n' "$session"
    local remote_command
    remote_command="$remote_tmux_env; session=$session; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; \"\$tmux_bin\" kill-session -t \"\$session\" 2>/dev/null || true"
    if [[ "$(assigned_fixture_for_session "$session")" == "relative-file-preview" ]]; then
      remote_command+="; fixture_suffix=\${session#remux-latency-pv-}; fixture_dir=/tmp/rpv-\$fixture_suffix; if [ -f \"\$fixture_dir/server.pid\" ]; then kill \"\$(cat \"\$fixture_dir/server.pid\")\" 2>/dev/null || true; fi; rm -f -- \"\$fixture_dir/README.md\" \"\$fixture_dir/index.html\" \"\$fixture_dir/preview.css\" \"\$fixture_dir/preview.svg\" \"\$fixture_dir/preview.js\" \"\$fixture_dir/server.pid\"; rmdir -- \"\$fixture_dir\" 2>/dev/null || true"
    fi

    if ! REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
      SSH_ASKPASS="$askpass" \
      SSH_ASKPASS_REQUIRE=force \
      DISPLAY=remux \
      ssh \
        -p "$port" \
        -o BatchMode=no \
        -o NumberOfPasswordPrompts=1 \
        -o ConnectTimeout=10 \
        "${ssh_auth_args[@]}" \
        "$username@$host" \
        "$remote_command" </dev/null; then
      status=1
    fi
  done < <(manifest_sessions "$manifest")

  return "$status"
}

verify_tmux_expectations() {
  local expectations="$1"
  local status=0

  if [[ ! -s "$expectations" ]]; then
    return 0
  fi

  while IFS=$'\t' read -r kind session arg1 arg2 extra || [[ -n "${kind:-}" ]]; do
    [[ -n "${kind:-}" ]] || continue

    if [[ -n "${extra:-}" ]]; then
      printf 'invalid tmux expectation with extra fields: %s\n' "$kind" >&2
      status=1
      continue
    fi

    if [[ ! "$session" =~ $session_allowlist ]]; then
      printf 'refusing non-allowlisted expectation session: %s\n' "$session" >&2
      status=1
      continue
    fi

    case "$kind" in
      window-count)
        if [[ -n "${arg2:-}" ]]; then
          printf 'invalid window-count expectation with extra argument for %s\n' "$session" >&2
          status=1
          continue
        fi

        if [[ ! "$arg1" =~ ^[0-9]+$ ]]; then
          printf 'invalid expected window count for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        local remote_command
        remote_command="$remote_tmux_env; session=$session; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; \"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' '"

        local actual
        if ! actual="$(REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$remote_command" </dev/null)"; then
          printf 'failed to verify tmux window count for %s\n' "$session" >&2
          status=1
          continue
        fi

        if [[ "$actual" != "$arg1" ]]; then
          printf 'tmux window-count expectation failed for %s: expected %s, got %s\n' "$session" "$arg1" "$actual" >&2
          status=1
        else
          printf 'Verified tmux window-count expectation for %s: %s\n' "$session" "$arg1"
        fi
        ;;
      window-pane-count)
        if [[ ! "$arg1" =~ ^[0-9]+$ || "$arg1" -eq 0 ]]; then
          printf 'invalid window index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ ! "$arg2" =~ ^[0-9]+$ ]]; then
          printf 'invalid expected pane count for %s window %s: %s\n' "$session" "$arg1" "$arg2" >&2
          status=1
          continue
        fi

        local remote_command
        remote_command="$remote_tmux_env; session=$session; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; window_id=\$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$window_id\" ]; then echo 'expected window index not found' >&2; exit 1; fi; \"\$tmux_bin\" list-panes -t \"\$window_id\" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' '"

        local actual
        if ! actual="$(REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$remote_command" </dev/null)"; then
          printf 'failed to verify tmux window pane count for %s window %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ "$actual" != "$arg2" ]]; then
          printf 'tmux window-pane-count expectation failed for %s window %s: expected %s, got %s\n' "$session" "$arg1" "$arg2" "$actual" >&2
          status=1
        else
          printf 'Verified tmux window-pane-count expectation for %s window %s: %s\n' "$session" "$arg1" "$arg2"
        fi
        ;;
      pane-count)
        if [[ -n "${arg2:-}" ]]; then
          printf 'invalid pane-count expectation with extra argument for %s\n' "$session" >&2
          status=1
          continue
        fi

        if [[ ! "$arg1" =~ ^[0-9]+$ ]]; then
          printf 'invalid expected pane count for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        local remote_command
        remote_command="$remote_tmux_env; session=$session; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; count=0; for window_id in \$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null); do window_count=\$(\"\$tmux_bin\" list-panes -t \"\$window_id\" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' '); count=\$((count + window_count)); done; printf '%s\n' \"\$count\""

        local actual
        if ! actual="$(REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$remote_command" </dev/null)"; then
          printf 'failed to verify tmux pane count for %s\n' "$session" >&2
          status=1
          continue
        fi

        if [[ "$actual" != "$arg1" ]]; then
          printf 'tmux pane-count expectation failed for %s: expected %s, got %s\n' "$session" "$arg1" "$actual" >&2
          status=1
        else
          printf 'Verified tmux pane-count expectation for %s: %s\n' "$session" "$arg1"
        fi
        ;;
      pane-mode)
        if [[ ! "$arg1" =~ ^[0-9]+$ || "$arg1" -eq 0 ]]; then
          printf 'invalid pane index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ "$arg2" != "0" && "$arg2" != "1" ]]; then
          printf 'invalid expected pane mode for %s pane %s: %s\n' "$session" "$arg1" "$arg2" >&2
          status=1
          continue
        fi

        local remote_command
        remote_command="$remote_tmux_env; session=$session; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; pane_id=\$(\"\$tmux_bin\" list-panes -t \"\$session\" -F '#{pane_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$pane_id\" ]; then echo 'expected pane index not found' >&2; exit 1; fi; \"\$tmux_bin\" display-message -p -t \"\$pane_id\" '#{pane_in_mode}' 2>/dev/null"

        local actual
        if ! actual="$(REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$remote_command" </dev/null)"; then
          printf 'failed to verify tmux pane mode for %s pane %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ "$actual" != "$arg2" ]]; then
          printf 'tmux pane-mode expectation failed for %s pane %s: expected %s, got %s\n' "$session" "$arg1" "$arg2" "$actual" >&2
          status=1
        else
          printf 'Verified tmux pane-mode expectation for %s pane %s: %s\n' "$session" "$arg1" "$arg2"
        fi
        ;;
      pane-index-contains|pane-index-history-contains)
        if [[ ! "$arg1" =~ ^[0-9]+$ || "$arg1" -eq 0 ]]; then
          printf 'invalid pane index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ ! "$arg2" =~ ^[A-Za-z0-9._-]+$ ]]; then
          printf 'invalid pane marker for %s: %s\n' "$session" "$arg2" >&2
          status=1
          continue
        fi

        # pane-index-contains checks the screen as the test left it;
        # pane-index-history-contains also searches the pane's scrollback.
        local capture_range=""
        if [[ "$kind" == "pane-index-history-contains" ]]; then
          capture_range="-S - "
        fi

        local capture_command
        capture_command="$remote_tmux_env; session=$session; marker=$arg2; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; pane_id=\$(\"\$tmux_bin\" list-panes -t \"\$session\" -F '#{pane_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$pane_id\" ]; then echo 'expected pane index not found' >&2; exit 1; fi; capture=\$(\"\$tmux_bin\" capture-pane -p -e ${capture_range}-t \"\$pane_id\" 2>/dev/null); if printf \"%s\n\" \"\$capture\" | grep -F -- \"\$marker\" >/dev/null; then exit 0; fi; echo \"--- pane \$pane_id capture tail ---\" >&2; printf \"%s\n\" \"\$capture\" | grep -v \"^\$\" | tail -40 >&2; exit 1"

        if ! REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$capture_command" </dev/null; then
          printf 'tmux %s expectation failed for %s pane %s marker %s\n' "$kind" "$session" "$arg1" "$arg2" >&2
          status=1
        else
          printf 'Verified tmux %s expectation for %s pane %s marker %s\n' "$kind" "$session" "$arg1" "$arg2"
        fi
        ;;
      window-index-contains)
        if [[ ! "$arg1" =~ ^[0-9]+$ || "$arg1" -eq 0 ]]; then
          printf 'invalid window index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ ! "$arg2" =~ ^[A-Za-z0-9._-]+$ ]]; then
          printf 'invalid window marker for %s: %s\n' "$session" "$arg2" >&2
          status=1
          continue
        fi

        local capture_command
        capture_command="$remote_tmux_env; session=$session; marker=$arg2; tmux_bin=\${REMUX_LIVE_TMUX:-\$(command -v tmux 2>/dev/null || true)}; if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; window_id=\$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$window_id\" ]; then echo 'expected window index not found' >&2; exit 1; fi; pane_id=\$(\"\$tmux_bin\" display-message -p -t \"\$window_id\" '#{pane_id}' 2>/dev/null); if [ -z \"\$pane_id\" ]; then echo 'expected window active pane not found' >&2; exit 1; fi; \"\$tmux_bin\" capture-pane -p -e -t \"\$pane_id\" 2>/dev/null | grep -F -- \"\$marker\" >/dev/null"

        if ! REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$capture_command" </dev/null; then
          printf 'tmux window-index-contains expectation failed for %s window %s marker %s\n' "$session" "$arg1" "$arg2" >&2
          status=1
        else
          printf 'Verified tmux window-index-contains expectation for %s window %s marker %s\n' "$session" "$arg1" "$arg2"
        fi
        ;;
      window-pane-index-contains)
        if [[ ! "$arg1" =~ ^[0-9]+[.][0-9]+$ ]]; then
          printf 'invalid window.pane index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        local window_index="${arg1%%.*}"
        local pane_index="${arg1#*.}"
        if [[ "$window_index" -eq 0 || "$pane_index" -eq 0 ]]; then
          printf 'invalid window.pane index for %s: %s\n' "$session" "$arg1" >&2
          status=1
          continue
        fi

        if [[ ! "$arg2" =~ ^[A-Za-z0-9._-]+$ ]]; then
          printf 'invalid window pane marker for %s: %s\n' "$session" "$arg2" >&2
          status=1
          continue
        fi

        if ! REMUX_LIVE_SSH_SECRET="$ssh_askpass_secret" \
          SSH_ASKPASS="$askpass" \
          SSH_ASKPASS_REQUIRE=force \
          DISPLAY=remux \
          ssh \
            -p "$port" \
            -o BatchMode=no \
            -o NumberOfPasswordPrompts=1 \
            -o ConnectTimeout=10 \
            "${ssh_auth_args[@]}" \
            "$username@$host" \
            "$remote_tmux_env" sh -s -- "$session" "$window_index" "$pane_index" "$arg2" <<'REMOTE_EXPECTATION'
set -eu
session="$1"
window_index="$2"
pane_index="$3"
marker="$4"

tmux_bin="${REMUX_LIVE_TMUX:-$(command -v tmux 2>/dev/null || true)}"
if [ -z "$tmux_bin" ] && [ -x /opt/homebrew/bin/tmux ]; then
  tmux_bin=/opt/homebrew/bin/tmux
fi
if [ -z "$tmux_bin" ]; then
  echo 'tmux not found on remote host' >&2
  exit 127
fi

window_id="$("$tmux_bin" list-windows -t "$session" -F '#{window_id}' 2>/dev/null | sed -n "${window_index}p")"
if [ -z "$window_id" ]; then
  echo 'expected window index not found' >&2
  exit 1
fi

pane_id="$("$tmux_bin" list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null | sed -n "${pane_index}p")"
if [ -z "$pane_id" ]; then
  echo 'expected pane index not found' >&2
  exit 1
fi

if "$tmux_bin" capture-pane -p -e -t "$pane_id" 2>/dev/null | grep -F -- "$marker" >/dev/null; then
  exit 0
fi

echo "target marker not found in resolved tmux pane" >&2
echo "session=$session window_index=$window_index pane_index=$pane_index window_id=$window_id pane_id=$pane_id marker=$marker" >&2
echo '--- panes in resolved window ---' >&2
"$tmux_bin" list-panes -t "$window_id" -F 'pane_index=#{pane_index} pane_id=#{pane_id} left=#{pane_left} top=#{pane_top} active=#{pane_active}' >&2 || true
echo '--- target pane capture tail ---' >&2
"$tmux_bin" capture-pane -p -e -S -80 -t "$pane_id" 2>/dev/null | tail -40 >&2 || true
echo '--- marker scan across resolved window panes ---' >&2
"$tmux_bin" list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null | while IFS= read -r candidate_pane_id; do
  if "$tmux_bin" capture-pane -p -e -S -200 -t "$candidate_pane_id" 2>/dev/null | grep -F -- "$marker" >&2; then
    echo "marker found in pane $candidate_pane_id" >&2
  fi
done
exit 1
REMOTE_EXPECTATION
        then
          printf 'tmux window-pane-index-contains expectation failed for %s window %s pane %s marker %s\n' "$session" "$window_index" "$pane_index" "$arg2" >&2
          status=1
        else
          printf 'Verified tmux window-pane-index-contains expectation for %s window %s pane %s marker %s\n' "$session" "$window_index" "$pane_index" "$arg2"
        fi
        ;;
      *)
        printf 'unknown tmux expectation: %s\n' "$kind" >&2
        status=1
        ;;
    esac
  done <"$expectations"

  return "$status"
}

# Checks one finished test's tmux expectations, then removes its sessions.
finish_test() {
  local test="$1"
  local sessions="$records_dir/$test.sessions"
  local expectations="$records_dir/$test.expectations"
  local status=0
  local i

  if [[ ! -e "$sessions" && ! -e "$expectations" ]]; then
    return 0
  fi

  # Each test's expectations name only its own sessions, so they are checked
  # whatever the test's outcome; a failing test cannot hide its tmux checks.
  verify_tmux_expectations "$expectations" || status=1
  for i in "${!assigned_tests[@]}"; do
    if [[ "${assigned_tests[$i]}" == "$test" && -n "${assigned_fixtures[$i]}" && ! -s "$expectations" ]]; then
      printf '%s recorded no tmux expectations for its prepared fixture; treating it as failed instead of passed/skipped.\n' "$test" >&2
      status=1
    fi
  done

  cleanup_generated_sessions "$sessions" || status=1
  rm -f "$sessions" "$expectations"
  return "$status"
}

finish() {
  local status=$?
  local sessions
  if [[ "$cleanup_done" -eq 0 ]]; then
    for sessions in "$records_dir"/*.sessions; do
      [[ -e "$sessions" ]] || continue
      cleanup_generated_sessions "$sessions" || status=$?
    done
  fi
  cleanup_local_files
  exit "$status"
}
trap finish EXIT

declare -a common_args=(
  -project Remux.xcodeproj
  -scheme RemuxUIOnly
  -configuration "$configuration"
  -destination "$destination"
)
if [[ -n "$derived_data_path" ]]; then
  common_args+=(-derivedDataPath "$derived_data_path")
fi

declare -a build_args=(build-for-testing "${common_args[@]}")
if [[ "$configuration" == "Release" ]]; then
  build_args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) REMUX_LIVE_UI_TESTING')
fi
if [[ -n "$development_team" ]]; then
  build_args+=(
    "DEVELOPMENT_TEAM=$development_team"
    CODE_SIGN_STYLE=Automatic
    -allowProvisioningUpdates
  )
fi

set +e
xcodebuild "${build_args[@]}" 2>&1 | tee "$build_log"
build_status=$?
set -e
if [[ "$build_status" -ne 0 ]]; then
  printf 'live UI test build log: %s\n' "$build_log"
  exit "$build_status"
fi

# All selected tests run in one xcodebuild invocation, so every assigned
# session and fixture is prepared before it starts.
for i in "${!assigned_sessions[@]}"; do
  printf '%s\n' "${assigned_sessions[$i]}" >>"$records_dir/${assigned_tests[$i]}.sessions"
  case "${assigned_fixtures[$i]}" in
    dense-mixed)
      prepare_dense_mixed_fixture "${assigned_sessions[$i]}"
      ;;
    relative-file-preview)
      prepare_relative_file_preview_fixture "${assigned_sessions[$i]}"
      ;;
  esac
done

declare -a test_args=()
for target in "${only_testing[@]}"; do
  test_args+=("-only-testing:$target")
done

write_harness_marker
refresh_harness_marker >/dev/null 2>&1 &
marker_refresh_pid=$!

# Each test is checked and cleaned up as soon as xcodebuild reports it
# finished, so later tests never see an earlier test's sessions.
finished_test_pattern="^Test Case '-\[[^ ]+ ([A-Za-z0-9_]+)\]' (passed|failed|skipped)"

# No failure diagnostics: collecting them takes up to ten minutes per failure.
set +e
TEST_RUNNER_REMUX_LIVE_RUN_DIR="$run_dir" \
xcodebuild test-without-building "${common_args[@]}" \
  "${test_args[@]}" \
  -collect-test-diagnostics never \
  -resultBundlePath "$result_bundle" 2>&1 |
  tee "$log" |
  {
    status=0
    while IFS= read -r line; do
      printf '%s\n' "$line"
      if [[ "$line" =~ $finished_test_pattern ]]; then
        finish_test "${BASH_REMATCH[1]}" || status=1
      fi
    done
    exit "$status"
  }
pipeline_status=("${PIPESTATUS[@]}")
set -e
stop_harness_marker_refresh
xcode_status="${pipeline_status[0]}"
tmux_status="${pipeline_status[2]}"

# Tests xcodebuild never reported as finished, e.g. after a test runner crash.
for records in "$records_dir"/*.sessions "$records_dir"/*.expectations; do
  [[ -e "$records" ]] || continue
  test_name="${records##*/}"
  finish_test "${test_name%.*}" || tmux_status=1
done
cleanup_done=1

trap - EXIT
cleanup_local_files

overall_status="$xcode_status"
if [[ "$overall_status" -eq 0 ]]; then
  overall_status="$tmux_status"
fi

printf 'live UI test build log: %s\n' "$build_log"
printf 'live UI test log: %s\n' "$log"
grep -E "^Test Case '.*' (passed|failed|skipped)" "$log" | sed 's/^/live UI test result: /' || true
printf 'live UI test status: xcodebuild %s, tmux expectations and cleanup %s\n' "$xcode_status" "$tmux_status"
exit "$overall_status"
