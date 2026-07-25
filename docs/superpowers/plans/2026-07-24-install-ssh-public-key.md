# Install SSH Public Key Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Install on Host flow that checks key authentication first, uses a one-time password only when necessary, appends the public key through SSH stdin, and verifies the result.

**Architecture:** Preserve one SSH stack by extracting a generic exec-session primitive from the tmux transport and running all installation phases on dedicated `RemuxSSHRoot` connections. Keep the remote installer as a bundled POSIX shell resource with host-side behavioral tests; keep password and flow presentation state local to setup UI while `RemuxRootModel` exposes typed operations over an injected `SSHPublicKeyInstaller`.

**Tech Stack:** Swift 6, SwiftUI, CryptoKit, Citadel, NIOSSH, SwiftNIO, XCTest, POSIX `sh`, XcodeGen, iOS 18.

## Global Constraints

- The deployment target remains iOS 18.0 and the Swift language version remains 6.0.
- Keep Citadel pinned at revision `1d0eadd81d0a521b00ede6663c8b3301f5fc252e`; do not add dependencies.
- Limit the first version to ordinary Unix/OpenSSH hosts with password authentication and `~/.ssh/authorized_keys`.
- Do not change private-key generation or storage and do not add Secure Enclave migration.
- Try key authentication first; only a definite key-authentication rejection may present the password prompt.
- Never auto-accept an unknown or changed host key. Use `TrustedHostStore` and the existing `SSHHostKeyTrustChallenge`.
- The password must never enter `TmuxConnectionDraft`, `SSHCredentialStore`, logs, traces, caches, or persisted state.
- Send exactly the public-key line plus `\n` over SSH channel stdin; never interpolate the key or password into the remote command.
- Preflight, append, and verification must use dedicated SSH roots and close them immediately.
- Report installation success only after a fresh key-authenticated `exit 0` succeeds.
- Tests must execute real behavior. Do not assert large rendered shell commands, HTML, or JSON with regexes.
- Follow strict RED-GREEN-REFACTOR for every production change and commit each task after focused tests pass.
- Regenerate `Remux.xcodeproj` with `xcodegen generate` after adding sources or resources; never hand-edit generated project entries.

---

## File Structure

### New production files

- `RemuxApp/Sources/SSH/RemuxSSHExecSession.swift` — generic SSH exec request, streaming callbacks, stdin/EOF, result capture, and connection lifecycle.
- `RemuxApp/Sources/SSH/SSHAuthenticationMethodFactory.swift` — shared conversion from `SSHCredential` to Citadel authentication.
- `RemuxApp/Sources/SSH/SSHPublicKeyInstaller.swift` — endpoint/request types, key-first classification, append, verification, and dedicated-root command runner.
- `RemuxApp/Sources/SSH/SSHPublicKeyRemoteInstaller.swift` — bundled script loading and safe shell-command quoting.
- `RemuxApp/Resources/install_authorized_key.sh` — exact POSIX remote installer executed by the host.
- `RemuxApp/Sources/App/SSHPublicKeyInstallSheet.swift` — password prompt and installation progress/error UI.

### New tests

- `RemuxAppTests/RemuxSSHExecSessionTests.swift`
- `RemuxAppTests/SSHPublicKeyInstallerTests.swift`
- `RemuxAppTests/SSHPublicKeyRemoteInstallerTests.swift`
- `scripts/test_install_authorized_key.sh`

### Existing files to modify

- `RemuxApp/Sources/Domain/TmuxConnectionTarget.swift`
- `RemuxApp/Sources/Tmux/SSHTmuxControlTransport.swift`
- `RemuxApp/Sources/Tmux/SSHTmuxControlChannelDataRouter.swift`
- `RemuxApp/Sources/Tmux/SSHTmuxControlChannelRequestTracker.swift`
- `RemuxApp/Sources/App/RemuxAppDependencies.swift`
- `RemuxApp/Sources/App/RemuxRootModel.swift`
- `RemuxApp/Sources/App/RootView.swift`
- `RemuxApp/Sources/Ghostty/GhosttySurfaceStatusOverlay.swift`
- `RemuxApp/Sources/Persistence/TrustedHostStore.swift`
- `RemuxAppTests/TmuxConnectionDraftValidatorTests.swift`
- `RemuxAppTests/SSHTmuxControlTransportTests.swift`
- `RemuxAppTests/RemuxRootModelTests.swift`
- `RemuxAppUITests/RemuxAppUITests.swift`
- `project.yml`
- `.github/workflows/ci.yml`
- `Remux.xcodeproj/project.pbxproj` (generated only)

---

### Task 1: Give setup drafts a stable server identity

**Files:**
- Modify: `RemuxApp/Sources/Domain/TmuxConnectionTarget.swift:364-405`
- Test: `RemuxAppTests/TmuxConnectionDraftValidatorTests.swift`

**Interfaces:**
- Produces: `TmuxConnectionDraft.serverID: SavedServer.ID`
- Produces: `TmuxConnectionDraft.init(serverID: SavedServer.ID = UUID())`
- Preserves: `TmuxConnectionDraftValidator.validateServer(_:existingServerID:)`

- [ ] **Step 1: Write failing tests for stable new and existing IDs**

Add:

```swift
func testNewDraftKeepsServerIDAcrossValidation() {
    var draft = validServerDraft()
    let expectedID = draft.serverID

    let first = TmuxConnectionDraftValidator.validateServer(
        draft,
        existingServerID: nil
    )
    draft.displayName = "Renamed"
    let second = TmuxConnectionDraftValidator.validateServer(
        draft,
        existingServerID: nil
    )

    guard case .valid(let firstServer) = first,
          case .valid(let secondServer) = second else {
        return XCTFail("expected valid server drafts")
    }
    XCTAssertEqual(firstServer.serverID, expectedID)
    XCTAssertEqual(secondServer.serverID, expectedID)
}

func testDraftFromSavedServerUsesSavedServerID() {
    let server = SavedServer(
        displayName: "Host",
        host: "host.example",
        username: "demo",
        identityID: UUID()
    )
    let workspace = SavedWorkspace(serverID: server.id, sessionName: "main")

    let draft = TmuxConnectionDraft(server: server, workspace: workspace)

    XCTAssertEqual(draft.serverID, server.id)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/TmuxConnectionDraftValidatorTests
```

Expected: compilation fails because `TmuxConnectionDraft.serverID` does not exist.

- [ ] **Step 3: Add stable draft identity**

Change the draft initializer shape to:

```swift
struct TmuxConnectionDraft: Equatable, Sendable {
    let serverID: SavedServer.ID
    // existing mutable fields

    init(serverID: SavedServer.ID = UUID()) {
        self.serverID = serverID
    }

    init(server: SavedServer, workspace: SavedWorkspace) {
        self.init(serverID: server.id)
        // existing field copies
    }
}
```

In the credential initializer, continue delegating to
`init(server:workspace:)`. In `validateServer`, replace the generated ID with:

```swift
let serverID = existingServerID ?? draft.serverID
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all
`TmuxConnectionDraftValidatorTests` pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add RemuxApp/Sources/Domain/TmuxConnectionTarget.swift \
  RemuxAppTests/TmuxConnectionDraftValidatorTests.swift
git commit -m "keep setup server identity stable" \
  -m "Give each new connection draft one server ID and preserve saved server IDs so host trust established during key installation applies to the eventual profile."
```

---

### Task 2: Extract a reusable SSH exec session

**Files:**
- Create: `RemuxApp/Sources/SSH/RemuxSSHExecSession.swift`
- Create: `RemuxAppTests/RemuxSSHExecSessionTests.swift`
- Modify: `RemuxApp/Sources/Tmux/SSHTmuxControlTransport.swift:60-90,529-950`
- Modify: `RemuxApp/Sources/Tmux/SSHTmuxControlChannelDataRouter.swift`
- Modify: `RemuxApp/Sources/Tmux/SSHTmuxControlChannelRequestTracker.swift`
- Modify: `RemuxAppTests/SSHTmuxControlTransportTests.swift:1111-1275`
- Generated: `Remux.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:

```swift
struct RemuxSSHExecResult: Equatable, Sendable {
    let exitStatus: Int
    let stdout: Data
    let stderr: Data
}

enum RemuxSSHExecSessionError: Error, Equatable, LocalizedError {
    case requestFailed
    case missingExitStatus
    case outputTooLarge
}

final class RemuxSSHExecConnection: @unchecked Sendable {
    func write(_ data: Data) async throws
    func finishInput() async throws
    func close(disposition: RemuxSSHRootLeaseDisposition) async
}

enum RemuxSSHExecSession {
    static func open(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        trace: RemuxTransportStartupTrace,
        onData: @escaping @Sendable (SSHChannelData.DataType, Data) -> Void,
        onFinish: @escaping @Sendable (Int?, Error?) -> Void
    ) async throws -> RemuxSSHExecConnection

    static func run(
        using claimedRoot: RemuxSSHClaimedRoot,
        command: String,
        stdin: Data?,
        trace: RemuxTransportStartupTrace
    ) async throws -> RemuxSSHExecResult
}
```

- Preserves: tmux first-output timeout, viewport tracing, diagnostics,
  `receivedBytes`, exit-status mapping, and root reuse behavior.

- [ ] **Step 1: Write failing generic handler and finite-run tests**

Cover:

```swift
func testRoutesStdoutAndStderrSeparately()
func testExecRequestFailureCompletesWithRequestFailed()
func testFiniteResultRequiresExitStatus()
func testFiniteResultReturnsZeroStatusAndCapturedStreams()
func testFiniteResultRejectsMoreThanSixtyFourKiBPerStream()
func testFinishInputClosesOnlyChannelOutput()
func testCompletionFiresExactlyOnceForErrorThenClose()
```

Use `EmbeddedChannel` and a recording outbound handler. For EOF, assert the
recording handler observes `.output` close after the public-key data write;
do not assert raw rendered SSH packets.

- [ ] **Step 2: Run the new suite and verify RED**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSSHExecSessionTests
```

Expected: compilation fails because the exec-session types do not exist.

- [ ] **Step 3: Implement the generic exec handler and connection**

Move request reply tracking, data-type routing, exit-status recording, and
exactly-once completion out of tmux naming and into
`RemuxSSHExecSession.swift`. Use:

```swift
try await sessionChannel.writeAndFlush(
    SSHChannelData(type: .channel, data: .byteBuffer(buffer))
)
try await sessionChannel.close(mode: .output)
```

Set `ChannelOptions.allowRemoteHalfClosure` to `true`. The finite `run`
collector must cap stdout and stderr independently at:

```swift
private static let maximumCapturedStreamBytes = 64 * 1024
```

It must require both remote input EOF and an explicit exit status, in either
order. Once both are observed it completes exactly once and closes the child
channel without waiting for remote full close. A true full close without an
exit status still reports `missingExitStatus`. The run releases the claimed
root on every success, error, and cancellation path. Long-lived tmux `open`
does not use the finite EOF-plus-status completion policy.

- [ ] **Step 4: Migrate tmux to the generic session**

Replace `SSHTmuxControlChannelHandler` with `RemuxSSHExecSession.open`.
Keep tmux-only behavior in closures owned by
`SSHTmuxControlBootstrap.activateControlSession`:

```swift
onData: { type, data in
    switch router.route(type: type, data: data) {
    case .stdout(let reportFirstOutput):
        if reportFirstOutput { firstOutputGate.succeed() }
        onOutput(data)
    case .stderr, .extendedData:
        break
    }
},
onFinish: { exitStatus, error in
    if let exitStatus {
        completionState.recordExitStatus(exitStatus)
    }
    guard let completion = completionState.finish(
        error,
        diagnostics: router.diagnostics
    ) else {
        return
    }
    onFinish(completion.failure)
}
```

Add a private `Result<Void, Error>.failure` adapter in the tmux file (or use
the equivalent explicit switch) so the generic session callback preserves the
existing `onFinish(Error?)` contract.

Preserve the existing tmux payload tracing in the tmux adapter; generic exec
stdin must not log payload previews.

- [ ] **Step 5: Regenerate the project and run RED-to-GREEN tests**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSSHExecSessionTests \
  -only-testing:RemuxTests/SSHTmuxControlTransportTests
```

Expected: both suites pass with no warnings, and the existing tmux tests
prove behavior was preserved.

- [ ] **Step 6: Commit**

```bash
git add RemuxApp/Sources/SSH/RemuxSSHExecSession.swift \
  RemuxApp/Sources/Tmux/SSHTmuxControlTransport.swift \
  RemuxApp/Sources/Tmux/SSHTmuxControlChannelDataRouter.swift \
  RemuxApp/Sources/Tmux/SSHTmuxControlChannelRequestTracker.swift \
  RemuxAppTests/RemuxSSHExecSessionTests.swift \
  RemuxAppTests/SSHTmuxControlTransportTests.swift \
  Remux.xcodeproj/project.pbxproj
git commit -m "extract reusable SSH exec sessions" \
  -m "Share exec request, stream, exit-status, stdin, EOF, and completion handling between finite SSH commands and the long-lived tmux adapter without changing tmux policy."
```

---

### Task 3: Add and execute the POSIX authorized-keys installer

**Files:**
- Create: `RemuxApp/Resources/install_authorized_key.sh`
- Create: `scripts/test_install_authorized_key.sh`
- Create: `RemuxApp/Sources/SSH/SSHPublicKeyRemoteInstaller.swift`
- Create: `RemuxAppTests/SSHPublicKeyRemoteInstallerTests.swift`
- Modify: `project.yml`
- Modify: `.github/workflows/ci.yml`
- Generated: `Remux.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:

```swift
enum SSHPublicKeyRemoteInstallerError: Error, Equatable {
    case missingResource
    case unreadableResource
}

enum SSHPublicKeyRemoteInstaller {
    static func command(bundle: Bundle = .main) throws -> String
}
```

- [ ] **Step 1: Write the failing host-side behavior test**

`scripts/test_install_authorized_key.sh` must create isolated temporary homes,
pipe fake public-key lines to the production resource, and verify:

```sh
test -f "${test_home}/.ssh/authorized_keys"
test "$(cat "${test_home}/.ssh/authorized_keys")" = "${expected_key}"
```

Add separate cases for absent file, existing newline, missing trailing
newline, preserving an existing key, and unwritable target. The test invokes:

```sh
HOME="${test_home}" /bin/sh RemuxApp/Resources/install_authorized_key.sh
```

Do not inspect or regex-match the script source.

- [ ] **Step 2: Run the host test and verify RED**

Run:

```bash
scripts/test_install_authorized_key.sh
```

Expected: failure because the production installer resource does not exist.

- [ ] **Step 3: Implement the minimal production script**

Create:

```sh
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
```

Make both scripts executable. The script reads only the public-key line from
stdin and contains no interpolated endpoint or credential data.

- [ ] **Step 4: Verify the real script passes**

Run:

```bash
scripts/test_install_authorized_key.sh
```

Expected: every filesystem behavior case passes.

- [ ] **Step 5: Add bundle loading and minimal Swift smoke tests**

Add the resource to `project.yml`:

```yaml
      - path: RemuxApp/Resources/install_authorized_key.sh
        buildPhase: resources
```

`command(bundle:)` must load the exact resource and quote it as the sole
argument to:

```text
exec sh -c '<single-quote-escaped script>'
```

Swift tests cover missing resource and confirm a fixture resource produces
an `exec sh -c` command. They must not assert the whole rendered script.

- [ ] **Step 6: Add the host behavior test to CI**

Add an app-job step before simulator creation:

```yaml
      - name: Test authorized-key installer
        shell: bash
        run: scripts/test_install_authorized_key.sh
```

- [ ] **Step 7: Regenerate, test, and commit**

Run:

```bash
xcodegen generate
scripts/test_install_authorized_key.sh
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/SSHPublicKeyRemoteInstallerTests
```

Expected: shell and Swift tests pass with no warnings.

Commit:

```bash
git add RemuxApp/Resources/install_authorized_key.sh \
  scripts/test_install_authorized_key.sh \
  RemuxApp/Sources/SSH/SSHPublicKeyRemoteInstaller.swift \
  RemuxAppTests/SSHPublicKeyRemoteInstallerTests.swift \
  project.yml .github/workflows/ci.yml Remux.xcodeproj/project.pbxproj
git commit -m "add POSIX public key installer" \
  -m "Bundle and behaviorally test the remote authorized_keys installer, load it as a safely quoted fixed command, and run its filesystem contract in CI."
```

---

### Task 4: Implement key-first installation over dedicated SSH roots

**Files:**
- Create: `RemuxApp/Sources/SSH/SSHAuthenticationMethodFactory.swift`
- Create: `RemuxApp/Sources/SSH/SSHPublicKeyInstaller.swift`
- Create: `RemuxAppTests/SSHPublicKeyInstallerTests.swift`
- Modify: `RemuxApp/Sources/App/RemuxAppDependencies.swift:174-289`
- Modify: `RemuxAppTests/RemuxRootModelTests.swift` test dependency construction
- Generated: `Remux.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:

```swift
struct SSHPublicKeyInstallTarget: Equatable, Sendable {
    let serverID: SavedServer.ID
    let host: String
    let port: Int
    let username: String
    let privateKey: SSHPrivateKeyCredential
    let publicKeyLine: String
}

enum SSHPublicKeyPreflightOutcome: Equatable, Sendable {
    case alreadyInstalled
    case passwordRequired
}

enum SSHPublicKeyInstallerError: Error, Equatable, LocalizedError {
    case keyAcceptedButProbeFailed
    case passwordRejected
    case installationCommandFailed(exitStatus: Int, diagnostic: String?)
    case verificationRejected
    case verificationCommandFailed(exitStatus: Int, diagnostic: String?)
}

struct SSHPublicKeyInstaller: Sendable {
    func preflight(_ target: SSHPublicKeyInstallTarget) async throws
        -> SSHPublicKeyPreflightOutcome
    func append(_ target: SSHPublicKeyInstallTarget, password: String) async throws
    func verify(_ target: SSHPublicKeyInstallTarget) async throws
}
```

- Produces:

```swift
enum SSHAuthenticationMethodFactory {
    static func make(
        username: String,
        credential: SSHCredential
    ) throws -> SSHAuthenticationMethod
}
```

- [ ] **Step 1: Write failing orchestration tests**

Use an injected command-running closure and assert outcomes, not the closure
itself:

```swift
func testPreflightReturnsAlreadyInstalledAfterZeroKeyProbe()
func testPreflightRequestsPasswordOnlyForAllAuthenticationOptionsFailed()
func testPreflightRequestsPasswordWhenPublicKeyAuthenticationIsUnsupported()
func testPreflightDoesNotConvertHostTrustOrNetworkErrorsToPasswordRequired()
func testPreflightReportsAcceptedKeyWhenExecProbeFails()
func testAppendUsesPasswordAndSendsOnlyPublicKeyLineWithNewline()
func testAppendMapsPasswordAuthenticationFailure()
func testVerifyMapsKeyAuthenticationFailure()
func testEveryLiveCommandUsesDedicatedRootAndClosesIt()
```

The input assertion for append is exactly:

```swift
XCTAssertEqual(recordedCommand.stdin, Data("\(target.publicKeyLine)\n".utf8))
```

No test may assert the full remote command.

- [ ] **Step 2: Run the focused suite and verify RED**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/SSHPublicKeyInstallerTests
```

Expected: compilation fails because the installer types do not exist.

- [ ] **Step 3: Extract the shared authentication factory**

Move the existing password and private-key switch from
`RemuxAppDependencies.authenticationMethod(for:)` into
`SSHAuthenticationMethodFactory.make(username:credential:)`. Adapt existing
tmux and SFTP configuration to call:

```swift
try SSHAuthenticationMethodFactory.make(
    username: auth.username,
    credential: {
        switch auth.credential {
        case .password(let password):
            .password(password)
        case .privateKey(let privateKey):
            .privateKey(privateKey)
        }
    }()
)
```

Do not change supported key types or decryption behavior.

- [ ] **Step 4: Implement typed installer orchestration**

Inject this command boundary:

```swift
typealias CommandRunner = @Sendable (
    SSHPublicKeyInstallTarget,
    SSHCredential,
    String,
    Data?
) async throws -> RemuxSSHExecResult
```

The live runner must wrap failures thrown after the root has been claimed in
an internal `SSHPublicKeyCommandExecutionError`; authentication, host-trust,
DNS, network-connect, and claim failures remain unwrapped. This stage marker
lets preflight distinguish “the key authenticated but exec failed” from “the
connection never authenticated” without guessing from error text.

Preflight and verify run `exit 0` with `.privateKey(target.privateKey)`.
Preflight returns `.passwordRequired` only for Citadel
`SSHClientError.allAuthenticationOptionsFailed` or
`.unsupportedPrivateKeyAuthentication`. If authentication has already
succeeded and the exec probe fails or returns nonzero, throw
`.keyAcceptedButProbeFailed`.

Append runs the bundled installer with `.password(password)` and:

```swift
Data("\(target.publicKeyLine)\n".utf8)
```

Map password authentication rejection to `.passwordRejected`; map
an append command's nonzero status to `.installationCommandFailed`, and map
post-append key rejection to `.verificationRejected`. A verification command
that authenticates but exits nonzero maps to `.verificationCommandFailed`.
The password-authenticated append boundary discards remote stdout and stderr
for every command-result failure, retaining only the exit status when one was
observed. It converts post-claim command execution diagnostics to a generic
typed installation failure. Verification may use bounded UTF-8 stderr,
falling back to stdout, as its optional diagnostic. Pass
`TrustedHostStoreError` and all pre-authentication network/protocol errors
through unchanged, and preserve cancellation and password rejection as typed
outcomes.

- [ ] **Step 5: Implement the live dedicated command runner**

Build `RemuxSSHRootConfiguration` from the target, shared authentication
factory, and `trustedHostStore.validator(for:)`. For each invocation:

```swift
let prepared = RemuxSSHPreparedRoot.dedicated(
    configuration: configuration,
    trace: trace
)
let root: RemuxSSHRoot
do {
    root = try await prepared.sshRoot()
} catch {
    await prepared.cancelAndCleanup()
    throw error
}
let claimed: RemuxSSHClaimedRoot
do {
    claimed = try await prepared.claim(root, trace: trace)
} catch {
    await prepared.cancelAndCleanup()
    throw error
}
do {
    return try await RemuxSSHExecSession.run(
        using: claimed,
        command: command,
        stdin: stdin,
        trace: trace
    )
} catch {
    throw SSHPublicKeyCommandExecutionError(underlying: error)
}
```

`RemuxSSHExecSession.run` owns cleanup after claim, including its error and
cancellation paths; `cancelAndCleanup` handles only authentication or claim
failure. Do not supply a pool key.

- [ ] **Step 6: Regenerate, run focused suites, and commit**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/SSHPublicKeyInstallerTests \
  -only-testing:RemuxTests/SSHTmuxControlTransportTests \
  -only-testing:RemuxTests/SSHPrivateKeyInspectorTests
```

Expected: all focused suites pass with no warnings.

Commit:

```bash
git add RemuxApp/Sources/SSH/SSHAuthenticationMethodFactory.swift \
  RemuxApp/Sources/SSH/SSHPublicKeyInstaller.swift \
  RemuxApp/Sources/App/RemuxAppDependencies.swift \
  RemuxAppTests/SSHPublicKeyInstallerTests.swift \
  RemuxAppTests/RemuxRootModelTests.swift \
  Remux.xcodeproj/project.pbxproj
git commit -m "install public keys over dedicated SSH" \
  -m "Add key-first preflight, password append, fresh verification, strict authentication classification, and immediate dedicated-root cleanup while sharing Remux's existing authentication and exec machinery."
```

---

### Task 5: Expose setup operations and preserve host trust

**Files:**
- Modify: `RemuxApp/Sources/App/RemuxAppDependencies.swift`
- Modify: `RemuxApp/Sources/App/RemuxRootModel.swift`
- Modify: `RemuxApp/Sources/Persistence/TrustedHostStore.swift`
- Modify: `RemuxAppTests/RemuxRootModelTests.swift`

**Interfaces:**
- Produces:

```swift
enum SSHPublicKeyInstallDraftError: Error, Equatable, LocalizedError {
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidPrivateKey
}

extension RemuxRootModel {
    func publicKeyInstallTarget(
        for draft: TmuxConnectionDraft
    ) throws -> SSHPublicKeyInstallTarget
    func preflightPublicKeyInstallation(
        _ draft: TmuxConnectionDraft
    ) async throws -> SSHPublicKeyPreflightOutcome
    func appendPublicKey(
        _ draft: TmuxConnectionDraft,
        password: String
    ) async throws
    func verifyPublicKeyInstallation(
        _ draft: TmuxConnectionDraft
    ) async throws
    func trustSetupHostKey(_ challenge: SSHHostKeyTrustChallenge) throws
    func cancelSetup() async
}
```

- [ ] **Step 1: Write failing model tests**

Cover:

```swift
func testInstallTargetUsesDraftStableIDAndNormalizedEndpoint()
func testInstallTargetIgnoresDisplayNameSessionAndTmuxValidation()
func testInstallTargetRejectsMissingEndpointOrInvalidKey()
func testPreflightPassesTargetToInstaller()
func testAppendDoesNotWritePasswordToDraftOrCredentialStore()
func testTrustSetupHostKeyStoresChallengeForDraftServerID()
func testCancelNewServerRemovesProvisionalTrust()
func testCancelEditServerRestoresExactPriorTrustIdentity()
func testCancelEditServerRestoresOriginalTrustAbsence()
func testSuccessfulEditServerRetainsAcceptedUpdatedTrust()
func testWorkspaceSetupCancellationPreservesAcceptedTrust()
```

Use an installer test double only at the external SSH-operation boundary.
Assert returned model behavior and real `TrustedHostStore` contents; do not
assert that a fake method merely exists.

- [ ] **Step 2: Run the model suite and verify RED**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxRootModelTests
```

Expected: compilation fails because setup installation methods do not exist.

- [ ] **Step 3: Implement request validation and installer delegation**

Normalize hostname and username with
`.trimmingCharacters(in: .whitespacesAndNewlines)`, require port
`1...65_535`, inspect the private key with `SSHPrivateKeyInspector`, and
construct the target with `draft.serverID`.

Add the live `SSHPublicKeyInstaller` to `RemuxAppDependencies`; add an
injectable installer parameter for tests and deterministic UI testing.
Delegate preflight, append, and verify without changing `model.state` and
without copying the password into model fields.

- [ ] **Step 4: Implement setup trust and cancellation cleanup**

`trustSetupHostKey` delegates to `TrustedHostStore.trustHostKey`. When Edit
Server begins, snapshot the exact `TrustedHostIdentity` for that server ID,
including absence. Explicit trust remains persisted during setup so the
interrupted phase can retry. On successful Edit Server save, discard the
snapshot and keep the accepted trust. On Edit Server cancellation, restore the
snapshot with the store's smallest exact replacement API.

For `.newServer`, delete the provisional identity before returning to the
library:

```swift
if case .setup(let draft, _, .newServer) = state {
    try? dependencies.trustedHostStore.deleteIdentity(for: draft.serverID)
}
await showLibrary()
```

New Workspace and Edit Workspace cancellation preserve accepted trust.

- [ ] **Step 5: Run focused tests and commit**

Run the Step 2 command. Expected: all `RemuxRootModelTests` pass with no
warnings.

Commit:

```bash
git add RemuxApp/Sources/App/RemuxAppDependencies.swift \
  RemuxApp/Sources/App/RemuxRootModel.swift \
  RemuxApp/Sources/Persistence/TrustedHostStore.swift \
  RemuxAppTests/RemuxRootModelTests.swift
git commit -m "coordinate key installation from setup" \
  -m "Validate installation targets independently of tmux fields, delegate finite SSH phases without retaining passwords, reuse explicit host trust, and clean provisional trust when new-server setup is canceled."
```

---

### Task 6: Add the Install on Host UI and end-to-end app coverage

**Files:**
- Create: `RemuxApp/Sources/App/SSHPublicKeyInstallSheet.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift:1360-2230`
- Modify: `RemuxApp/Sources/App/RootView.swift:150-170`
- Modify: `RemuxApp/Sources/Ghostty/GhosttySurfaceStatusOverlay.swift:248-299`
- Modify: `RemuxAppUITests/RemuxAppUITests.swift:97-119`
- Generated: `Remux.xcodeproj/project.pbxproj`

**Interfaces:**
- Accessibility identifiers:
  - `connection.private-key.install`
  - `connection.private-key.install-password`
  - `connection.private-key.install-confirm`
  - `connection.private-key.install-cancel`
  - `connection.private-key.install-status`
  - `connection.private-key.host-trust-confirm`
- `ConnectionSetupView` receives typed callbacks accepting the current draft:
  - `canInstallPublicKey: (TmuxConnectionDraft) -> Bool`
  - `preflightPublicKeyInstallation: (TmuxConnectionDraft) async throws -> SSHPublicKeyPreflightOutcome`
  - `appendPublicKey: (TmuxConnectionDraft, String) async throws -> Void`
  - `verifyPublicKeyInstallation: (TmuxConnectionDraft) async throws -> Void`
  - `trustSetupHostKey: (SSHHostKeyTrustChallenge) throws -> Void`

- [ ] **Step 1: Write the failing deterministic UI test**

Extend the private-key setup test to fill only host, port, and username,
generate a key, and assert:

```swift
let install = app.buttons["connection.private-key.install"]
XCTAssertTrue(install.waitForExistence(timeout: 2))
install.tap()

let password = app.secureTextFields["connection.private-key.install-password"]
XCTAssertTrue(password.waitForExistence(timeout: 2))
password.tap()
password.typeText("one-time-password")
app.buttons["connection.private-key.install-confirm"].tap()

XCTAssertTrue(
    app.staticTexts["connection.private-key.install-status"]
        .waitForExistence(timeout: 5)
)
XCTAssertEqual(
    app.staticTexts["connection.private-key.install-status"].label,
    "Installed on host"
)
```

Add a `REMUX_UI_TEST_PUBLIC_KEY_INSTALL_OUTCOME` launch environment read only
by `RemuxAppDependencies.uiTesting()`. For `passwordRequired`, its deterministic
installer returns `.passwordRequired`, accepts append, and passes
verification. Add
`testAlreadyInstalledPublicKeySkipsPasswordPrompt`, launch with
`alreadyInstalled`, tap the same action, assert the status is
**Already installed**, and assert the secure password field does not exist.
The environment selects outcomes only; production control flow remains in the
real sheet and model.

- [ ] **Step 2: Run the UI test and verify RED**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxUITests/RemuxAppUITests/testPrivateKeyAuthenticationFlowShowsActionsUntilKeySelected
```

Expected: failure because `connection.private-key.install` does not exist.

- [ ] **Step 3: Add the selected-key action and password sheet**

Place **Install on Host** after **Copy Public Key** and before **Change Key**.
Disable it unless `canInstallPublicKey(draft)` is true.

The sheet owns:

```swift
@State private var password = ""
@State private var phase: SSHPublicKeyInstallPhase = .idle
@State private var pendingTrust: PendingTrust?
```

Its sequence is:

```swift
preflight
  -> .alreadyInstalled: show "Already installed"
  -> .passwordRequired: present password field
append(password)
  -> verify
  -> show "Installed on host"
```

Clear `password` after cancellation, password rejection, append failure,
and success. A host-key challenge retains the password only while its
confirmation is active and retries exactly the phase recorded by
`PendingTrust` (`preflight`, `append`, or `verify`).

- [ ] **Step 4: Reuse host-key verification presentation**

Extract the current SHA256 fingerprint calculation from
`GhosttySurfaceStatusOverlay` into a shared extension on
`SSHHostKeyTrustChallenge`. Use that property in both the terminal overlay
and setup confirmation. Setup confirmation text must distinguish unknown
from changed keys and present **Trust Server** or **Update Trust**.

On confirmation:

```swift
try onTrustHostKey(challenge)
await retry(pendingTrust.phase)
```

On rejection, dismiss the challenge without retrying or prompting for a
password.

- [ ] **Step 5: Wire model callbacks and cancel cleanup**

`RemuxWorkspaceShell` passes the model's typed installation methods into
`ConnectionSetupView` and replaces:

```swift
Task { await model.showLibrary() }
```

with:

```swift
Task { await model.cancelSetup() }
```

- [ ] **Step 6: Regenerate and run focused UI/unit tests**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/SSHPublicKeyInstallerTests \
  -only-testing:RemuxTests/RemuxRootModelTests
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxUITests/RemuxAppUITests/testPrivateKeyAuthenticationFlowShowsActionsUntilKeySelected \
  -only-testing:RemuxUITests/RemuxAppUITests/testAlreadyInstalledPublicKeySkipsPasswordPrompt
```

Expected: focused unit and UI tests pass with no warnings.

- [ ] **Step 7: Commit**

```bash
git add RemuxApp/Sources/App/SSHPublicKeyInstallSheet.swift \
  RemuxApp/Sources/App/RootView.swift \
  RemuxApp/Sources/Ghostty/GhosttySurfaceStatusOverlay.swift \
  RemuxAppUITests/RemuxAppUITests.swift \
  Remux.xcodeproj/project.pbxproj
git commit -m "add Install on Host setup flow" \
  -m "Add key-first setup UI, one-time password entry, phase-specific host-trust retry, explicit success and failure states, provisional-trust cleanup, and deterministic UI coverage."
```

---

### Task 7: Run full verification and live OpenSSH validation

**Files:**
- Modify only if a failing behavioral test exposes a defect.

**Interfaces:**
- Consumes all preceding task interfaces.
- Produces no new product API.

- [ ] **Step 1: Verify generated project and shell behavior**

Run:

```bash
xcodegen generate
git diff --exit-code -- Remux.xcodeproj
scripts/test_install_authorized_key.sh
```

Expected: generated project has no diff and every shell case passes.

- [ ] **Step 2: Run the complete unit suite**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

Expected: all unit tests pass with zero failures and no warnings.

- [ ] **Step 3: Run the deterministic private-key UI flow**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxUITests/RemuxAppUITests/testPrivateKeyAuthenticationFlowShowsActionsUntilKeySelected
```

Expected: the install action, password prompt, and verified success state pass.

- [ ] **Step 4: Run live validation when a disposable host is available**

Use ignored `.local/` configuration and a disposable Unix/OpenSSH account.
Demonstrate in order:

1. unknown host trust is shown and explicitly accepted;
2. key preflight fails and opens the password sheet;
3. a wrong password fails and is cleared;
4. the correct password appends the key;
5. fresh key verification succeeds;
6. a second attempt reports **Already installed** without a password; and
7. normal Remux Connect opens the tmux workspace.

If no disposable password-enabled host is available, record this gate as
unverified rather than claiming end-to-end success.

- [ ] **Step 5: Check the final diff**

Run:

```bash
git status --short
git diff --check
git diff --stat "$(git merge-base main HEAD)"..HEAD
```

Expected: no uncommitted product changes, no whitespace errors, and only
spec/plan/feature/test/CI files are present.

- [ ] **Step 6: Commit any verification-driven fixes**

For each defect, first add a failing regression test, run it RED, implement
the smallest fix, run it GREEN, then commit only the covering files. If no
defects are found, create no empty commit.
