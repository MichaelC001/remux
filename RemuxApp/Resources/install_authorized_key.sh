#!/bin/sh
set -eu

cd
umask 077
authorized_key_file=".ssh/authorized_keys"
authorized_key_directory=".ssh"

mkdir -p "${authorized_key_directory}"
if [ -s "${authorized_key_file}" ] &&
   [ -n "$(tail -c 1 "${authorized_key_file}" 2>/dev/null)" ]; then
  printf '\n' >> "${authorized_key_file}"
fi
cat >> "${authorized_key_file}"

if command -v restorecon >/dev/null 2>&1; then
  restorecon -F "${authorized_key_directory}" "${authorized_key_file}"
fi
