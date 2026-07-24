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

unwritable_home="${test_root}/unwritable-target"
unwritable_key="ssh-ed25519 AAAA-unwritable remux-test"
mkdir -p "${unwritable_home}/.ssh"
printf '%s\n' "${unwritable_key}" > "${unwritable_home}/.ssh/authorized_keys"
chmod u-w "${unwritable_home}/.ssh/authorized_keys"
if install_key "${unwritable_home}" "ssh-ed25519 AAAA-must-not-install remux-test" 2>/dev/null; then
  fail "installer wrote to an unwritable authorized_keys file"
fi
assert_authorized_key "${unwritable_home}" "${unwritable_key}"

printf 'PASS: authorized-key installer filesystem behavior\n'
