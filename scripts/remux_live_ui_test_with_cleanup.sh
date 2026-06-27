#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/remux_live_ui_test_with_cleanup.sh [--scheme <scheme>] [--xcconfig <path>] [--allow-provisioning-updates] --only-testing <test-id> [--only-testing <test-id> ...]
  scripts/remux_live_ui_test_with_cleanup.sh --dry-run-cleanup <manifest-file>

Runs selected Remux live SSH UI tests using /tmp/remux-live-ssh.json and
remotely removes only the exact allowlisted remux-latency-* tmux sessions that
the UI tests record in their cleanup manifest.

This script reads live SSH details from /tmp/remux-live-ssh.json but does not
store credentials in the repository or print secrets.
USAGE
}

config="/tmp/remux-live-ssh.json"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"
scheme="RemuxUIOnly"
xcconfig=""
allow_provisioning_updates=0
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
    --scheme)
      scheme="${2:-}"
      [[ -n "$scheme" ]] || { usage; exit 2; }
      shift 2
      ;;
    --xcconfig)
      xcconfig="${2:-}"
      [[ -n "$xcconfig" ]] || { usage; exit 2; }
      shift 2
      ;;
    --allow-provisioning-updates)
      allow_provisioning_updates=1
      shift
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

if [[ ! -f "$config" ]]; then
  printf 'Missing %s; cannot run live SSH UI tests.\n' "$config" >&2
  exit 2
fi

require_tool ruby
require_tool ssh
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

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/remux-live-ui-cleanup.XXXXXX")"
manifest="/tmp/remux-live-generated-sessions.txt"
expectations="/tmp/remux-live-tmux-expectations.txt"
harness_file="/tmp/remux-live-cleanup-harness.txt"
fixture_name_file="/tmp/remux-live-prepared-fixture.txt"
fixture_session_file="/tmp/remux-live-session-name-override.txt"
askpass="$work_dir/askpass.sh"
private_key_file="$work_dir/live_ssh_key"
log_dir=".local/logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
log="$log_dir/live-ui-cleanup-${stamp}.log"
result_bundle="$log_dir/live-ui-cleanup-${stamp}.xcresult"
cleanup_done=0

cleanup_local_files() {
  rm -rf "$work_dir"
  rm -f "$manifest"
  rm -f "$expectations"
  rm -f "$harness_file"
  rm -f "$fixture_name_file"
  rm -f "$fixture_session_file"
}

ssh_askpass_secret=""
declare -a ssh_auth_args=()
if [[ -n "$private_key" ]]; then
  printf '%s\n' "$private_key" >"$private_key_file"
  chmod 600 "$private_key_file"
  ssh_askpass_secret="$private_key_passphrase"
  ssh_auth_args=(
    -i "$private_key_file"
    -o IdentitiesOnly=yes
    -o PreferredAuthentications=publickey
  )
elif [[ -n "$password" ]]; then
  ssh_askpass_secret="$password"
  ssh_auth_args=(
    -o PreferredAuthentications=password,keyboard-interactive
  )
else
  printf '%s must include password or privateKeyPEM.\n' "$config" >&2
  exit 2
fi

finish_before_remote_cleanup() {
  local status=$?
  cleanup_local_files
  exit "$status"
}

cat >"$askpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$REMUX_LIVE_SSH_SECRET"
EOF
chmod 700 "$askpass"
rm -f "$manifest"
rm -f "$expectations"
rm -f "$harness_file"
rm -f "$fixture_name_file"
rm -f "$fixture_session_file"
printf 'pid=%s\nstartedAt=%s\n' "$$" "$(date +%s)" >"$harness_file"
trap finish_before_remote_cleanup EXIT

fixture_name=""
fixture_session=""
for target in "${only_testing[@]}"; do
  case "$target" in
    *testLiveSSHTmuxActionCycleWhenConfigured)
      fixture_session="remux-latency-action-${stamp}"
      ;;
    *testLiveDenseMixedTopologySelectsDeepPaneWhenConfigured)
      fixture_name="dense-mixed"
      fixture_session="remux-latency-dense-mixed-${stamp}"
      ;;
  esac
done

if [[ -n "$fixture_session" ]]; then
  printf '%s\n' "$fixture_session" >>"$manifest"
  printf '%s\n' "$fixture_session" >"$fixture_session_file"
fi

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
      sh -s -- "$session" <<'REMOTE'
set -eu
session="$1"
tmux_bin="$(command -v tmux 2>/dev/null || true)"
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

if [[ "$fixture_name" == "dense-mixed" ]]; then
  prepare_dense_mixed_fixture "$fixture_session"
  printf '%s\n' "$fixture_name" >"$fixture_name_file"
fi

cleanup_generated_sessions() {
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
    remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; \"\$tmux_bin\" kill-session -t \"\$session\" 2>/dev/null || true"

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
        remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; \"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' '"

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
        remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; window_id=\$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$window_id\" ]; then echo 'expected window index not found' >&2; exit 1; fi; \"\$tmux_bin\" list-panes -t \"\$window_id\" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' '"

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
        remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; count=0; for window_id in \$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null); do window_count=\$(\"\$tmux_bin\" list-panes -t \"\$window_id\" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' '); count=\$((count + window_count)); done; printf '%s\n' \"\$count\""

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
        remote_command="session=$session; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; pane_id=\$(\"\$tmux_bin\" list-panes -t \"\$session\" -F '#{pane_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$pane_id\" ]; then echo 'expected pane index not found' >&2; exit 1; fi; \"\$tmux_bin\" display-message -p -t \"\$pane_id\" '#{pane_in_mode}' 2>/dev/null"

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
      pane-index-contains)
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

        local capture_command
        capture_command="session=$session; marker=$arg2; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; pane_id=\$(\"\$tmux_bin\" list-panes -t \"\$session\" -F '#{pane_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$pane_id\" ]; then echo 'expected pane index not found' >&2; exit 1; fi; \"\$tmux_bin\" capture-pane -p -e -t \"\$pane_id\" 2>/dev/null | grep -F -- \"\$marker\" >/dev/null"

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
          printf 'tmux pane-index-contains expectation failed for %s pane %s marker %s\n' "$session" "$arg1" "$arg2" >&2
          status=1
        else
          printf 'Verified tmux pane-index-contains expectation for %s pane %s marker %s\n' "$session" "$arg1" "$arg2"
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
        capture_command="session=$session; marker=$arg2; tmux_bin=\$(command -v tmux 2>/dev/null || true); if [ -z \"\$tmux_bin\" ] && [ -x /opt/homebrew/bin/tmux ]; then tmux_bin=/opt/homebrew/bin/tmux; fi; if [ -z \"\$tmux_bin\" ]; then echo 'tmux not found on remote host' >&2; exit 127; fi; window_id=\$(\"\$tmux_bin\" list-windows -t \"\$session\" -F '#{window_id}' 2>/dev/null | sed -n '${arg1}p'); if [ -z \"\$window_id\" ]; then echo 'expected window index not found' >&2; exit 1; fi; pane_id=\$(\"\$tmux_bin\" display-message -p -t \"\$window_id\" '#{pane_id}' 2>/dev/null); if [ -z \"\$pane_id\" ]; then echo 'expected window active pane not found' >&2; exit 1; fi; \"\$tmux_bin\" capture-pane -p -e -t \"\$pane_id\" 2>/dev/null | grep -F -- \"\$marker\" >/dev/null"

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
            sh -s -- "$session" "$window_index" "$pane_index" "$arg2" <<'REMOTE_EXPECTATION'
set -eu
session="$1"
window_index="$2"
pane_index="$3"
marker="$4"

tmux_bin="$(command -v tmux 2>/dev/null || true)"
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

finish() {
  local status=$?
  if [[ "$cleanup_done" -eq 0 ]]; then
    cleanup_generated_sessions || status=$?
  fi
  cleanup_local_files
  exit "$status"
}
trap finish EXIT

declare -a xcode_args=(
  test
  -project Remux.xcodeproj
  -scheme "$scheme"
  -destination "$destination"
  -resultBundlePath "$result_bundle"
)

if [[ -n "$xcconfig" ]]; then
  xcode_args+=(-xcconfig "$xcconfig")
fi

if [[ "$allow_provisioning_updates" -eq 1 ]]; then
  xcode_args+=(-allowProvisioningUpdates)
fi

for target in "${only_testing[@]}"; do
  xcode_args+=("-only-testing:$target")
done

set +e
REMUX_LIVE_GENERATED_SESSION_MANIFEST="$manifest" \
REMUX_LIVE_TMUX_EXPECTATION_MANIFEST="$expectations" \
REMUX_LIVE_PREPARED_FIXTURE="$fixture_name" \
REMUX_LIVE_SESSION_NAME_OVERRIDE="$fixture_session" \
REMUX_TRACE_LATENCY=1 \
REMUX_TRACE_PERF=1 \
GHOSTTY_TRACE_SURFACE_INIT=1 \
xcodebuild "${xcode_args[@]}" 2>&1 | tee "$log"
xcode_status=$?
set -e

verify_status=0
if [[ "$xcode_status" -eq 0 ]]; then
  if [[ -n "$fixture_name" && ! -s "$expectations" ]]; then
    printf 'prepared fixture test recorded no tmux expectations; treating as failed instead of passed/skipped.\n' >&2
    verify_status=1
  else
    verify_tmux_expectations
    verify_status=$?
  fi
fi

cleanup_generated_sessions
cleanup_status=$?
cleanup_done=1
trap - EXIT
cleanup_local_files

printf 'live UI test log: %s\n' "$log"
printf 'live UI test result bundle: %s\n' "$result_bundle"

if [[ "$xcode_status" -ne 0 ]]; then
  exit "$xcode_status"
fi
if [[ "$verify_status" -ne 0 ]]; then
  exit "$verify_status"
fi
exit "$cleanup_status"
