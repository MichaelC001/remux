# Install SSH Public Key on Host

**Status:** Proposed
**Date:** 2026-07-24

## Summary

Remux will add an **Install on Host** action beside **Copy Public Key** in
server setup. The action will first try authenticating with the selected key.
If the key already works, Remux will report that it is installed without
asking for a password. If the server specifically rejects key
authentication, Remux will ask for a one-time password, append the public key
to the remote user's `~/.ssh/authorized_keys`, and verify the installation
with a fresh key-authenticated connection.

The private key never leaves the device. The one-time password is held only
for the active installation attempt and is never written to the connection
draft, profile repository, or Keychain.

This feature will reuse Remux's SSH root service, host-key validation, and
exec-channel handling. It will not introduce a second SSH implementation.

## Goals

- Install the selected public key on an ordinary Unix/OpenSSH host without
  requiring the user to switch to another device.
- Try key authentication before showing a password prompt.
- Preserve Remux's explicit SSH host-key trust behavior.
- Keep the password ephemeral and close the password-authenticated connection
  immediately after installation.
- Verify that the server accepts the key before reporting a successful
  installation.
- Make repeated use safe: an already-working key must not be appended again.
- Exercise the remote installer and SSH orchestration through behavioral
  tests rather than assertions over generated command text.

## Non-Goals

- Changing how Remux generates or stores private keys.
- Migrating generated keys to Secure Enclave-backed signing.
- Supporting keyboard-interactive authentication, two-factor prompts, or
  password changes.
- Supporting Windows hosts, NetScreen, OpenWrt and Haiku special paths,
  SFTP-only accounts, or a configurable authorized-keys path.
- Installing multiple keys in one operation.
- Removing, rotating, or auditing keys already present on the host.
- Using `sudo` or installing a key for a user other than the SSH login user.

## Current Context

The setup view can generate an ED25519 key, derive its public-key line, and
copy that line to the pasteboard. Remux already has:

- password and private-key authentication through Citadel and NIOSSH;
- explicit storage and validation of trusted SSH host keys;
- authenticated SSH root connections that can open session channels; and
- a tmux exec-channel handler that processes request replies, stdout, stderr,
  remote exit status, and channel completion.

The existing exec handler is coupled to tmux startup. It expects a long-lived
stream, requires first output within a timeout, and routes output directly
into the tmux transport. Public-key installation is a finite command that may
succeed without output. The shared SSH exec mechanics should therefore be
generalized, while the tmux-specific startup policy remains in the tmux
adapter.

Current generated ED25519 keys are exportable CryptoKit keys serialized as
OpenSSH PEM and stored in Keychain. They are not Secure Enclave keys. That
distinction is outside this feature: installation transmits only the public
key regardless of private-key storage.

## User Experience

### Availability

**Install on Host** appears with the actions for any valid selected private
key whose public key can be derived. The action becomes available when the
draft has a valid hostname, port, and username. Display name, tmux executable,
and session name are not installation inputs and do not block it.

### Key-first preflight

When the user taps **Install on Host**, Remux:

1. dismisses the keyboard and shows an in-progress state;
2. opens a fresh, dedicated SSH connection using the selected private key;
3. requests a non-interactive `exit 0` command; and
4. classifies the result.

The possible results are:

- **Authentication and command success:** show **Already installed**. Do not
  ask for a password.
- **Authentication success followed by command rejection or failure:** report
  that the key is accepted but the server could not run the compatibility
  check. Do not ask for a password because reinstalling the key cannot fix
  remote command policy.
- **Definite authentication rejection:** present the password sheet.
- **Host trust required:** present Remux's host-key confirmation, then retry
  the preflight only after explicit approval.
- **DNS, network, timeout, protocol, or local key failure:** show the actual
  failure. Do not reinterpret it as a missing key and do not ask for a
  password.

### Password installation

The password sheet identifies the target as `username@host`, contains a
secure password field, and offers **Install** and **Cancel**.

After **Install**, Remux opens a dedicated password-authenticated SSH
connection. A wrong password or disabled password authentication returns the
user to an empty password field with an actionable error. The password is
not copied into `TmuxConnectionDraft` or any persistence API.

The install operation:

1. opens a plain SSH exec session without a PTY;
2. requests a fixed POSIX shell installer;
3. sends exactly one public-key line plus a newline through channel stdin;
4. sends SSH EOF after the bytes have flushed;
5. completes after both remote input EOF and an explicit zero exit status,
   regardless of their order; and
6. closes the session and authenticated root immediately.

The UI remains cancellable. Cancellation closes any active channel and root,
discards the password reference, and returns to the selected-key view.

### Verification

After a zero install exit status, Remux opens another fresh, dedicated
connection with the private key and runs `exit 0`.

- On success, show **Installed on host** and dismiss the password sheet.
- If key authentication is still rejected, report **The public key was
  written, but the server did not accept it**. Do not attempt an automatic
  rollback because Remux cannot safely distinguish the newly appended line
  from an equivalent pre-existing authorization.
- Other verification failures retain their real category and message.

The normal **Connect** action remains separate. It saves the profile and
opens the tmux workspace using the selected key as it does today.

## Host-Key Trust

Installation must never bypass or weaken host-key validation.

A new-server draft will own a stable provisional `SavedServer.ID` for the
life of the setup flow. The validator and eventual saved server use that same
ID, so a host key accepted during preflight or installation remains the
trusted identity when the user connects.

For an existing server, installation uses its existing ID. Edit Server
snapshots that ID's exact trust record, including the absence of a record,
before setup begins. Explicitly accepted trust is persisted immediately so an
interrupted phase can retry. Canceling Edit Server restores the snapshot;
successfully saving the edit keeps the accepted trust. New Workspace and Edit
Workspace cancellation preserve any accepted trust.

For a new server, canceling setup removes any provisional trust record created
by this flow. An abrupt process termination can leave an unreachable trust
record, but the random provisional ID is never reused and therefore cannot
authorize another server.

Unknown and changed keys use the same challenge data and explicit confirmation
semantics as normal Remux connections. After approval, Remux retries only the
interrupted step. A host-key error must never fall through to the password
prompt.

## Architecture

### Stable setup identity

`TmuxConnectionDraft` will carry a stable server ID:

- a new draft creates the ID once;
- a draft created from a saved server uses the saved server's ID; and
- validation and saving preserve the draft's ID rather than generating a new
  ID each time validation runs.

This change affects only in-memory setup identity. It does not add a persisted
compatibility format.

### Shared SSH exec session

The reusable exec behavior currently embedded in the tmux transport will
become a generic SSH session-exec primitive. It will continue to use
`RemuxSSHRoot.openSessionChannel` and NIOSSH.

The generic primitive owns:

- sending an exec request and tracking its success or failure;
- streaming stdout and stderr to callbacks;
- recording the remote exit status;
- writing optional stdin and sending EOF;
- finishing exactly once on terminal completion, close, cancellation, or
  error; and
- returning structured completion rather than parsing log output.

The tmux transport will configure this primitive for streaming output and
retain its existing first-output timeout, viewport tracing, diagnostics, and
long-lived lifecycle. The public-key installer will configure the same
primitive as a finite command. A finite command completes and closes its child
channel once remote input EOF and an exit status have both arrived, without
waiting for the peer to close the channel. It buffers bounded output while
running and requires an observed zero exit status.

This refactoring must preserve the existing tmux transport behavior and tests.
The installer must not reuse the tmux transport abstraction or route command
output through Ghostty.

### Public-key installer

An `SSHPublicKeyInstaller` service will coordinate:

- key-authenticated preflight;
- password-authenticated installation;
- post-install key verification;
- dedicated SSH root acquisition and cleanup; and
- typed outcomes and errors for the setup model.

It receives the server endpoint, provisional server ID, public-key line,
authentication factories, and host-key validator through dependencies. It
does not read or write repositories.

Preflight, installation, and verification all use dedicated roots rather than
the shared tmux root pool. This guarantees prompt cleanup, prevents the
one-time password operation from being retained as an idle reusable
connection, and isolates setup failures from active tmux sessions.

### Setup state

`RemuxRootModel` coordinates installation intent and host-trust retry state.
The SwiftUI password field remains local to the password sheet. The model may
hold an active task and non-secret progress/error state, but it does not own
the password beyond the awaited installer call.

Swift strings cannot promise physical memory zeroization. The security
contract is therefore limited and explicit: Remux does not persist, log,
cache, or deliberately retain the password after the operation.

## Remote Installer

The default Unix path follows `ssh-copy-id` semantics:

- start from the remote user's home directory;
- set `umask 077`;
- create `.ssh` when absent;
- ensure an existing `authorized_keys` file ends with a newline before
  appending;
- append the public-key line received on stdin; and
- run `restorecon` on the directory and file when available.

The command invokes `exec sh -c` so it does not depend on the user's login
shell syntax. The public key is never interpolated into the command string.
The command itself contains no host, username, password, or key material.

The installer relies on key-authenticated preflight for idempotency, as
`ssh-copy-id` does. It does not append when the key already authenticates.

The command will be represented as an independently executable unit and
tested by running it against a temporary home directory. Tests will not
assert the generated command's full wording or ordering.

## Data and Logging

- The private key remains local and is used only by the existing
  authentication factory.
- Only the public-key line crosses the installation channel.
- The one-time password is passed directly to the authentication method and
  is never persisted.
- Neither the password nor public-key stdin is included in trace previews,
  errors, diagnostics, or logs.
- The password-authenticated append operation never places remote stdout or
  stderr in errors, model or UI state, logs, traces, or persistence. Its
  command failures retain only safe typed categories and an exit status when
  one was observed.
- The authenticated password root and all child channels close immediately
  after the finite operation.

## Error Handling

The feature distinguishes at least these cases:

- host-key trust required or host key changed;
- key already accepted;
- key authentication rejected;
- key authentication accepted but the compatibility command rejected or
  failed;
- password authentication rejected or unavailable;
- network, DNS, connect timeout, or SSH negotiation failure;
- exec request rejected;
- stdin write or EOF failure;
- remote installer nonzero exit, including home-directory and permission
  failures;
- missing remote exit status;
- installation completed but key verification failed; and
- cancellation.

Only a definite key-authentication rejection opens the password prompt.
Messages should identify the failed phase—checking, installing, or
verifying—without exposing credentials or raw command text.

## Testing

### Remote installer behavior

Run the installer with `/bin/sh` against temporary home directories and fake
public keys. Verify real filesystem behavior:

- creates `.ssh/authorized_keys` when absent;
- appends to an existing newline-terminated file;
- adds the missing separator newline before appending;
- preserves existing authorized keys;
- writes exactly one complete public-key line;
- fails when the target cannot be created or written; and
- returns the expected exit status.

These tests execute the installer. They do not match a rendered shell command
with regular expressions.

### SSH exec primitive

Use embedded NIO channels or the existing SSH channel test harness to verify:

- exec request success and failure;
- distinct stdout and stderr routing;
- stdin delivery followed by EOF;
- zero, nonzero, and missing exit statuses;
- exit-status then EOF and EOF then exit-status without a remote full close;
- remote close, local cancellation, and write failure; and
- exactly-once completion and child-channel close.

Run the existing tmux transport suite unchanged after generalizing the
handler.

### Installer orchestration

Use fake SSH-operation dependencies to verify:

- successful key preflight returns **already installed** without requesting a
  password;
- only authentication rejection requests a password;
- network and host-trust failures do not request a password;
- password success runs installation and then key verification;
- password or remote-command failure does not run verification;
- append output that reflects key, password, private-key, or passphrase
  sentinels is absent from returned errors and retained presentation state;
- verification failure returns the specific partial-success error; and
- every path closes its dedicated connection.

### Model and UI

Verify:

- a new draft keeps one stable server ID through validation and save;
- an existing-server draft keeps the saved ID;
- accepting host trust retries the interrupted phase;
- canceling new-server setup removes provisional trust;
- canceling Edit Server restores the exact prior trust identity or its
  absence;
- saving Edit Server retains accepted updated trust;
- canceling New Workspace or Edit Workspace preserves accepted trust;
- the action's enablement depends only on valid endpoint and key inputs;
- an already-installed key never presents the password sheet;
- password state is cleared after completion and cancellation; and
- progress, success, and actionable failure states are accessible.

### Live validation

Use a disposable Unix/OpenSSH account with password authentication enabled.
Keep its address and credentials in ignored local configuration.

Demonstrate:

1. unknown host trust is shown and can be accepted;
2. key preflight fails and the password sheet appears;
3. a wrong password fails without saving it;
4. the correct password installs the public key;
5. verification succeeds with the key;
6. a second installation attempt reports **Already installed** without a
   password prompt; and
7. the normal Remux connection opens the tmux workspace with the key.

## Acceptance Criteria

- The selected public key can be installed from server setup on a supported
  Unix/OpenSSH host.
- Remux tries key authentication before requesting a password.
- A working key produces **Already installed** and no password prompt.
- A one-time password is never persisted or logged.
- Host-key trust remains explicit and is reused by the saved server.
- The public key is delivered over SSH stdin, not interpolated into a remote
  command.
- Installation is not reported successful until a fresh key-authenticated
  verification succeeds.
- Existing tmux SSH behavior and focused test suites remain passing.
- Live validation covers first installation and the password-free repeated
  attempt.
