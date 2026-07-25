# Key Installation Success UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dismiss the Install on Host sheet after either successful outcome and leave a target-scoped inline confirmation in the selected-private-key view.

**Architecture:** Represent terminal success as a small app-layer value and store a confirmation containing only the non-secret installation identity: host, port, username, and public key. The sheet reports success to `ConnectionSetupView`, which records the confirmation and dismisses the sheet. The selected-key row renders the confirmation only while it matches the current validated installation target.

**Tech Stack:** Swift 6, SwiftUI, XCTest, XCUITest, XcodeGen

## Global Constraints

- Limit this change to post-installation success presentation; do not change tmux session validation or connection behavior.
- Never copy or retain the private key, passphrase, or one-time password in the confirmation.
- Both `.alreadyInstalled` and `.installed` dismiss the sheet.
- Failures, password entry, progress, and host-key trust remain in the sheet.
- The inline confirmation remains actionable and disappears when host, port, username, or public key changes.
- Follow strict red-green-refactor TDD and preserve the existing setup-session guards.

---

### Task 1: Hand successful installation back to the selected-key view

**Files:**
- Modify: `RemuxApp/Sources/App/SSHPublicKeyInstallCoordinator.swift`
- Modify: `RemuxApp/Sources/App/SSHPublicKeyInstallSheet.swift`
- Modify: `RemuxApp/Sources/App/RootView.swift`
- Test: `RemuxAppTests/SSHPublicKeyInstallCoordinatorTests.swift`
- Test: `RemuxAppUITests/RemuxAppUITests.swift`

**Interfaces:**
- Produces: `SSHPublicKeyInstallSuccess` with `.alreadyInstalled` and `.installed`.
- Produces: `SSHPublicKeyInstallConfirmation.init(success:target:)` and `matches(_:)`, storing only host, port, username, and `publicKeyLine`.
- Produces: `SSHPublicKeyInstallSheet` callback `onSuccess: (SSHPublicKeyInstallSuccess) -> Void`.
- Consumes: the existing `RemuxRootModel.publicKeyInstallTarget(for:)` builder so matching uses the same trimming, port parsing, and public-key derivation as installation.

- [ ] **Step 1: Add failing confirmation behavior tests**

Add focused tests to `SSHPublicKeyInstallCoordinatorTests.swift` that construct a real `SSHPublicKeyInstallTarget`, create an `SSHPublicKeyInstallConfirmation`, and assert:

```swift
func testInstallConfirmationMatchesOnlyItsNonSecretTargetIdentity() {
    let target = makeInstallTarget(
        host: "example.test",
        port: 22,
        username: "remux",
        publicKeyLine: "ssh-ed25519 AAAA-current"
    )
    let confirmation = SSHPublicKeyInstallConfirmation(
        success: .installed,
        target: target
    )

    XCTAssertTrue(confirmation.matches(target))
    XCTAssertFalse(confirmation.matches(makeInstallTarget(host: "other.test")))
    XCTAssertFalse(confirmation.matches(makeInstallTarget(port: 2222)))
    XCTAssertFalse(confirmation.matches(makeInstallTarget(username: "other")))
    XCTAssertFalse(
        confirmation.matches(
            makeInstallTarget(publicKeyLine: "ssh-ed25519 AAAA-other")
        )
    )
}
```

Also assert that `.alreadyInstalled` presents `Already installed` and `.installed` presents `Installed on host`.

Add this test helper beside the existing coordinator test helpers:

```swift
private func makeInstallTarget(
    host: String = "example.test",
    port: Int = 22,
    username: String = "remux",
    publicKeyLine: String = "ssh-ed25519 AAAA-current"
) -> SSHPublicKeyInstallTarget {
    SSHPublicKeyInstallTarget(
        serverID: UUID(),
        host: host,
        port: port,
        username: username,
        privateKey: SSHPrivateKeyCredential(
            privateKeyPEM: "PRIVATE-KEY-NOT-RETAINED",
            passphrase: "PASSPHRASE-NOT-RETAINED"
        ),
        publicKeyLine: publicKeyLine
    )
}
```

- [ ] **Step 2: Update the two UI success tests to require dismissal and inline status**

In both existing Install on Host UI tests, replace assertions against the sheet's terminal status with assertions that:

```swift
let inlineStatus = app.staticTexts["connection.private-key.install-status"]
XCTAssertTrue(inlineStatus.waitForExistence(timeout: 5))
XCTAssertEqual(inlineStatus.label, expectedStatus)
XCTAssertFalse(app.navigationBars["Install on Host"].exists)
XCTAssertFalse(app.buttons["connection.private-key.install-cancel"].exists)
XCTAssertTrue(app.buttons["connection.private-key.install"].exists)
```

For one journey, edit the host after success and assert that the inline status disappears, proving the receipt is scoped to the current target.

```swift
let host = app.textFields["connection.host"]
host.tap()
host.typeText(".changed")
XCTAssertFalse(inlineStatus.exists)
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/SSHPublicKeyInstallCoordinatorTests

xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxUITests/RemuxAppUITests/testPrivateKeyAuthenticationFlowShowsActionsUntilKeySelected \
  -only-testing:RemuxUITests/RemuxAppUITests/testAlreadyInstalledPublicKeySkipsPasswordPrompt
```

Expected: the unit target fails to compile because the success and
confirmation types do not exist. The independently-run UI target fails
because the sheet remains presented and the selected-key view has no inline
status.

- [ ] **Step 4: Add the non-secret success and confirmation values**

In `SSHPublicKeyInstallCoordinator.swift`, add:

```swift
enum SSHPublicKeyInstallSuccess: Equatable {
    case alreadyInstalled
    case installed

    var message: String {
        switch self {
        case .alreadyInstalled:
            "Already installed"
        case .installed:
            "Installed on host"
        }
    }
}

struct SSHPublicKeyInstallConfirmation: Equatable {
    let success: SSHPublicKeyInstallSuccess
    private let host: String
    private let port: Int
    private let username: String
    private let publicKeyLine: String

    init(success: SSHPublicKeyInstallSuccess, target: SSHPublicKeyInstallTarget) {
        self.success = success
        host = target.host
        port = target.port
        username = target.username
        publicKeyLine = target.publicKeyLine
    }

    func matches(_ target: SSHPublicKeyInstallTarget) -> Bool {
        host == target.host
            && port == target.port
            && username == target.username
            && publicKeyLine == target.publicKeyLine
    }
}
```

Do not store `target.privateKey`.

- [ ] **Step 5: Report terminal success and dismiss the sheet**

Add `onSuccess` to `SSHPublicKeyInstallSheet`. Observe `coordinator.phase`; when it becomes `.alreadyInstalled` or `.installed`, call `onSuccess` exactly once. Hide the cancellation toolbar action for a terminal success frame:

```swift
.onChange(of: coordinator.phase) { _, phase in
    switch phase {
    case .alreadyInstalled:
        complete(.alreadyInstalled)
    case .installed:
        complete(.installed)
    default:
        break
    }
}
```

Use a local completion guard so repeated SwiftUI updates cannot invoke the callback twice. Preserve `onDisappear` cancellation cleanup.

- [ ] **Step 6: Record and render the matching confirmation**

In `ConnectionSetupView`:

- replace the boolean `canInstallPublicKey` callback with a callback that returns `SSHPublicKeyInstallTarget?`;
- add `@State private var publicKeyInstallConfirmation: SSHPublicKeyInstallConfirmation?`;
- on sheet success, rebuild the target from the current draft, record the confirmation, and set `isPublicKeyInstallPresented = false`;
- render a green checkmark and `confirmation.success.message` in the Install on Host row only when `confirmation.matches(currentTarget)`; and
- keep the Install on Host button enabled so it can rerun preflight.

At the root wiring site, provide:

```swift
publicKeyInstallTarget: { draft in
    try? model.publicKeyInstallTarget(for: draft)
}
```

The current target is computed, not retained, so its private key does not enter view state.

- [ ] **Step 7: Run focused tests and verify GREEN**

Run the two commands from Step 3.

Expected: confirmation tests pass and both UI journeys pass with the sheet dismissed, the exact inline result visible, and stale status hidden after target change.

- [ ] **Step 8: Run regression gates**

Run:

```bash
xcodegen generate
git diff --exit-code -- Remux.xcodeproj
scripts/test_install_authorized_key.sh
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
git diff --check
git status --short
```

Expected: project generation is clean, the authorized-key script passes, the full unit suite passes, and only the intended source/test/plan changes remain.

- [ ] **Step 9: Commit the implementation**

Stage only the files listed in this task after inspecting `git status`, then commit with a detailed message describing:

- automatic success dismissal;
- target-scoped inline confirmation;
- non-retention of private key and password material; and
- focused UI plus full-suite evidence.
