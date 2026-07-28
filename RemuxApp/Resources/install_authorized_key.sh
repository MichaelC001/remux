#!/bin/sh
set -eu

cd
umask 077
authorized_key_file=".ssh/authorized_keys"
authorized_key_directory=".ssh"
lock_directory="${authorized_key_file}.remux-lock"

mkdir -p "${authorized_key_directory}"
chmod 700 "${authorized_key_directory}"

lock_attempt=0
until mkdir "${lock_directory}" 2>/dev/null; do
  lock_attempt=$((lock_attempt + 1))
  if [ "${lock_attempt}" -ge 100 ]; then
    printf 'Timed out waiting to update %s\n' "${authorized_key_file}" >&2
    exit 1
  fi
  sleep 0.1
done
cleanup_lock() {
  rmdir "${lock_directory}" 2>/dev/null || true
}
trap cleanup_lock 0
trap 'exit 1' HUP INT TERM

public_key="$(cat)"
case "${public_key}" in
  "")
    printf 'No public key was provided\n' >&2
    exit 1
    ;;
  *"
"*)
    printf 'Expected exactly one public key line\n' >&2
    exit 1
    ;;
esac

touch "${authorized_key_file}"
chmod 600 "${authorized_key_file}"

if ! grep -F -x -q -e "${public_key}" "${authorized_key_file}"; then
  if [ -s "${authorized_key_file}" ] &&
     [ -n "$(tail -c 1 "${authorized_key_file}" 2>/dev/null)" ]; then
    printf '\n' >> "${authorized_key_file}"
  fi
  printf '%s\n' "${public_key}" >> "${authorized_key_file}"
fi

if command -v restorecon >/dev/null 2>&1; then
  restorecon -F "${authorized_key_directory}" "${authorized_key_file}"
fi
