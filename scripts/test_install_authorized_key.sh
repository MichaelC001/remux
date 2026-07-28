#!/usr/bin/env bash
set -euo pipefail

installer="RemuxApp/Resources/install_authorized_key.sh"
test_root="$(mktemp -d)"

cleanup() {
  chmod -R u+w "${test_root}" 2>/dev/null || true
  rm -rf "${test_root}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_authorized_key() {
  local test_home="$1"
  local expected_key="$2"

  test -f "${test_home}/.ssh/authorized_keys" || fail "missing authorized_keys"
  test "$(cat "${test_home}/.ssh/authorized_keys")" = "${expected_key}" || fail "unexpected authorized_keys contents"
}

assert_mode() {
  local path="$1"
  local expected_mode="$2"
  local actual_mode

  actual_mode="$(stat -f '%Lp' "${path}")"
  test "${actual_mode}" = "${expected_mode}" || fail "expected ${path} mode ${expected_mode}, got ${actual_mode}"
}

assert_key_occurrences() {
  local test_home="$1"
  local expected_key="$2"
  local expected_count="$3"
  local actual_count

  actual_count="$(grep -F -x -c -e "${expected_key}" "${test_home}/.ssh/authorized_keys" || true)"
  test "${actual_count}" = "${expected_count}" || fail "expected ${expected_count} copies of ${expected_key}, got ${actual_count}"
}

install_key() {
  local test_home="$1"
  local public_key="$2"

  printf '%s\n' "${public_key}" | HOME="${test_home}" /bin/sh "${installer}"
}

absent_home="${test_root}/absent"
absent_key="ssh-ed25519 AAAA-absent remux-test"
mkdir -p "${absent_home}"
install_key "${absent_home}" "${absent_key}"
assert_authorized_key "${absent_home}" "${absent_key}"

newline_home="${test_root}/existing-newline"
newline_existing_key="ssh-ed25519 AAAA-existing-newline remux-test"
newline_new_key="ssh-ed25519 AAAA-new-newline remux-test"
mkdir -p "${newline_home}/.ssh"
printf '%s\n' "${newline_existing_key}" > "${newline_home}/.ssh/authorized_keys"
install_key "${newline_home}" "${newline_new_key}"
assert_authorized_key "${newline_home}" "${newline_existing_key}
${newline_new_key}"

no_newline_home="${test_root}/missing-trailing-newline"
no_newline_existing_key="ssh-ed25519 AAAA-existing-no-newline remux-test"
no_newline_new_key="ssh-ed25519 AAAA-new-no-newline remux-test"
mkdir -p "${no_newline_home}/.ssh"
printf '%s' "${no_newline_existing_key}" > "${no_newline_home}/.ssh/authorized_keys"
install_key "${no_newline_home}" "${no_newline_new_key}"
assert_authorized_key "${no_newline_home}" "${no_newline_existing_key}
${no_newline_new_key}"

preserved_home="${test_root}/preserving-existing-content"
preserved_first_key="ssh-ed25519 AAAA-first-existing remux-test"
preserved_second_key="ssh-ed25519 AAAA-second-existing remux-test"
preserved_new_key="ssh-ed25519 AAAA-preserved-new remux-test"
mkdir -p "${preserved_home}/.ssh"
printf '%s\n%s\n' "${preserved_first_key}" "${preserved_second_key}" > "${preserved_home}/.ssh/authorized_keys"
install_key "${preserved_home}" "${preserved_new_key}"
assert_authorized_key "${preserved_home}" "${preserved_first_key}
${preserved_second_key}
${preserved_new_key}"

repeated_home="${test_root}/repeated-install"
repeated_key="ssh-ed25519 AAAA-repeated remux-test"
mkdir -p "${repeated_home}"
install_key "${repeated_home}" "${repeated_key}"
install_key "${repeated_home}" "${repeated_key}"
assert_authorized_key "${repeated_home}" "${repeated_key}"

permissive_home="${test_root}/permissive-target"
permissive_existing_key="ssh-ed25519 AAAA-permissive-existing remux-test"
permissive_new_key="ssh-ed25519 AAAA-permissive-new remux-test"
mkdir -p "${permissive_home}/.ssh"
printf '%s\n' "${permissive_existing_key}" > "${permissive_home}/.ssh/authorized_keys"
chmod 777 "${permissive_home}/.ssh"
chmod 666 "${permissive_home}/.ssh/authorized_keys"
install_key "${permissive_home}" "${permissive_new_key}"
assert_authorized_key "${permissive_home}" "${permissive_existing_key}
${permissive_new_key}"
assert_mode "${permissive_home}/.ssh" "700"
assert_mode "${permissive_home}/.ssh/authorized_keys" "600"

unusable_home="${test_root}/unusable-target"
mkdir -p "${unusable_home}/.ssh/authorized_keys"
if install_key "${unusable_home}" "ssh-ed25519 AAAA-must-not-install remux-test" 2>/dev/null; then
  fail "installer wrote to an unusable authorized_keys target"
fi
test -d "${unusable_home}/.ssh/authorized_keys" || fail "installer replaced the unusable target"

interrupted_home="${test_root}/interrupted-install"
interrupted_key="ssh-ed25519 AAAA-interrupted remux-test"
interrupted_input="${test_root}/interrupted-input"
interrupted_release="${test_root}/interrupted-release"
mkdir -p "${interrupted_home}"
mkfifo "${interrupted_input}" "${interrupted_release}"
(
  exec 8>"${interrupted_input}"
  read -r _ < "${interrupted_release}"
  printf '%s\n' "${interrupted_key}" >&8
) &
interrupted_writer_pid="$!"
HOME="${interrupted_home}" /bin/sh "${installer}" < "${interrupted_input}" &
interrupted_installer_pid="$!"
interrupted_lock="${interrupted_home}/.ssh/authorized_keys.remux-lock"
interrupted_lock_seen=false
for _ in {1..100}; do
  if [ -d "${interrupted_lock}" ]; then
    interrupted_lock_seen=true
    break
  fi
  sleep 0.01
done
if [ "${interrupted_lock_seen}" != true ]; then
  kill "${interrupted_installer_pid}" "${interrupted_writer_pid}" 2>/dev/null || true
  wait "${interrupted_installer_pid}" 2>/dev/null || true
  wait "${interrupted_writer_pid}" 2>/dev/null || true
  fail "interrupted installer did not acquire its lock"
fi
kill -TERM "${interrupted_installer_pid}"
printf 'release\n' > "${interrupted_release}"
wait "${interrupted_writer_pid}"
if wait "${interrupted_installer_pid}"; then
  fail "interrupted installer exited successfully"
fi
test ! -e "${interrupted_home}/.ssh/authorized_keys" ||
  fail "interrupted installer modified authorized_keys"
test ! -d "${interrupted_lock}" || fail "interrupted installer left its lock behind"

concurrent_home="${test_root}/concurrent-install"
concurrent_key="ssh-ed25519 AAAA-concurrent remux-test"
mkdir -p "${concurrent_home}"
concurrent_pids=()
for _ in {1..8}; do
  install_key "${concurrent_home}" "${concurrent_key}" &
  concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
  wait "${concurrent_pid}"
done
assert_key_occurrences "${concurrent_home}" "${concurrent_key}" "1"

printf 'PASS: authorized-key installer filesystem behavior\n'
