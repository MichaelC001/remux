import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyTerminalPresentationProjectorTests: XCTestCase {
    func testSelectionSheetPresentationChangeCancelsAndResetsWhenDismissingPresentedSheet() {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: .windows,
            nextKind: nil
        )

        XCTAssertTrue(change.shouldCancelCurrentPreviewSession)
        XCTAssertTrue(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationChangeResetsAbsentDismissalWithoutCancellation() {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: nil,
            nextKind: nil
        )

        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertTrue(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationChangeDoesNotCancelOrResetWhenPresenting() {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: nil,
            nextKind: .panes
        )

        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertFalse(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationChangePreservesPresentedReplacementBehavior() {
        let change = GhosttySelectionSheetPresentationChange(
            currentKind: .windows,
            nextKind: .panes
        )

        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertFalse(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationStatePreservesCapturedHeightWhenPresenting() {
        var state = GhosttySelectionSheetPresentationState()
        state.captureBottomReplacementHeight(128)

        let change = state.apply(nextKind: .windows)

        XCTAssertEqual(state.presentedKind, .windows)
        XCTAssertEqual(state.bottomReplacementHeight, 128)
        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertFalse(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationStateDismissalResetsHeightAndRequestsCancellation() {
        var state = GhosttySelectionSheetPresentationState()
        state.captureBottomReplacementHeight(96)
        _ = state.apply(nextKind: .windows)

        let change = state.apply(nextKind: nil)

        XCTAssertNil(state.presentedKind)
        XCTAssertEqual(state.bottomReplacementHeight, 0)
        XCTAssertTrue(change.shouldCancelCurrentPreviewSession)
        XCTAssertTrue(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationStatePreservesHeightWhenReplacingPresentedSheet() {
        var state = GhosttySelectionSheetPresentationState()
        state.captureBottomReplacementHeight(72)
        _ = state.apply(nextKind: .windows)

        let change = state.apply(nextKind: .panes)

        XCTAssertEqual(state.presentedKind, .panes)
        XCTAssertEqual(state.bottomReplacementHeight, 72)
        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertFalse(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationStatePreservesHeightWhenReplacingSameKind() {
        var state = GhosttySelectionSheetPresentationState()
        state.captureBottomReplacementHeight(64)
        _ = state.apply(nextKind: .panes)

        let change = state.apply(nextKind: .panes)

        XCTAssertEqual(state.presentedKind, .panes)
        XCTAssertEqual(state.bottomReplacementHeight, 64)
        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertFalse(change.shouldResetBottomReplacementHeight)
    }

    func testSelectionSheetPresentationStateAbsentDismissalResetsHeightWithoutCancellation() {
        var state = GhosttySelectionSheetPresentationState()
        state.captureBottomReplacementHeight(44)

        let change = state.apply(nextKind: nil)

        XCTAssertNil(state.presentedKind)
        XCTAssertEqual(state.bottomReplacementHeight, 0)
        XCTAssertFalse(change.shouldCancelCurrentPreviewSession)
        XCTAssertTrue(change.shouldResetBottomReplacementHeight)
    }

    func testReadinessProjectionReportsRuntimeStateSemantics() {
        let reason = TerminalDisconnectReason(
            kind: .transportIO,
            message: "tmux transport ended: closed"
        )
        let cases: [(TerminalReadinessSnapshot, TerminalRuntimeState)] = [
            (
                Self.readinessSnapshot(phase: .idle, focused: false),
                .connecting
            ),
            (
                Self.readinessSnapshot(phase: .starting, focused: true),
                .connecting
            ),
            (
                Self.readinessSnapshot(phase: .running, focused: false),
                .connecting
            ),
            (
                Self.readinessSnapshot(
                    phase: .running,
                    transportWritable: false,
                    topLevelCount: 0,
                    focused: true
                ),
                .connected
            ),
            (
                Self.readinessSnapshot(phase: .failed(message: "fallback", reason: reason), focused: false),
                .disconnected(reason)
            ),
            (
                Self.readinessSnapshot(phase: .failed(message: "runtime failed", reason: nil), focused: true),
                .disconnected(
                    TerminalDisconnectReason(
                        kind: .unknown,
                        message: "runtime failed"
                    )
                )
            ),
        ]

        for (readiness, expectedState) in cases {
            XCTAssertEqual(TerminalReadinessProjector.runtimeState(readiness), expectedState)
        }
    }

    func testReadinessProjectionSeparatesInteractionAndTransportInputGates() {
        XCTAssertFalse(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .idle, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isInputAvailable(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isTransportAvailableForInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.canSubmitInput(
                Self.readinessSnapshot(phase: .running, transportWritable: true, focused: true)
            )
        )
    }

    func testScalarCanSubmitInputProjectionMatchesSnapshotProjection() {
        let cases: [TerminalReadinessSnapshot] = [
            Self.readinessSnapshot(phase: .idle, transportWritable: true, focused: true),
            Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true),
            Self.readinessSnapshot(phase: .running, transportWritable: false, focused: true),
            Self.readinessSnapshot(phase: .running, transportWritable: true, focused: false),
            Self.readinessSnapshot(phase: .running, transportWritable: true, focused: true),
        ]

        for snapshot in cases {
            XCTAssertEqual(
                TerminalReadinessProjector.canSubmitInput(
                    phase: snapshot.phase,
                    transportWritable: snapshot.transportWritable,
                    hasFocusedSurface: snapshot.hasFocusedSurface
                ),
                TerminalReadinessProjector.canSubmitInput(snapshot)
            )
        }
    }

    func testUITestInputReadyUsesSubmitInputContractNotStatusReady() {
        let statusReadyWithoutFocusedSurface = Self.readinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            focused: false
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isTerminalStatusReady(
                statusReadyWithoutFocusedSurface,
                commandFailureMessage: nil
            )
        )
        XCTAssertFalse(TerminalReadinessProjector.uiTestInputReady(statusReadyWithoutFocusedSurface))

        let notTransportWritable = Self.readinessSnapshot(
            phase: .running,
            transportWritable: false,
            topLevelCount: 1,
            focused: true
        )
        XCTAssertFalse(TerminalReadinessProjector.uiTestInputReady(notTransportWritable))

        let inputReady = Self.readinessSnapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 1,
            focused: true
        )
        XCTAssertTrue(TerminalReadinessProjector.uiTestInputReady(inputReady))

        XCTAssertFalse(
            TerminalReadinessProjector.uiTestInputReady(
                Self.readinessSnapshot(phase: .starting, transportWritable: true, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.uiTestInputReady(
                Self.readinessSnapshot(
                    phase: .failed(message: "failed", reason: nil),
                    transportWritable: true,
                    focused: true
                )
            )
        )
        XCTAssertEqual(
            TerminalReadinessProjector.uiTestInputReady(inputReady),
            TerminalReadinessProjector.canSubmitInput(inputReady)
        )
    }

    func testReadinessProjectionPreservesStatusAndTraceConditions() {
        XCTAssertTrue(
            TerminalReadinessProjector.isWaitingForPanes(
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isWaitingForPanes(
                phase: .running,
                topLevelCount: 0
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isWaitingForPanes(
                Self.readinessSnapshot(phase: .starting, topLevelCount: 0, focused: false)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isWaitingForPanes(
                phase: .failed(message: "runtime failed", reason: nil),
                topLevelCount: 0
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: nil
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: true),
                commandFailureMessage: "tmux command failed"
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.isTerminalStatusReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false),
                commandFailureMessage: nil
            )
        )

        XCTAssertFalse(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .starting, topLevelCount: 1, focused: true)
            )
        )
        XCTAssertFalse(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: true)
            )
        )
        XCTAssertTrue(
            TerminalReadinessProjector.shouldTraceTerminalReady(
                Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false)
            )
        )
    }

    func testStatusOverlayProjectionPreservesStatePrecedence() {
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .idle, topLevelCount: 0, focused: false),
                commandFailureMessage: "ignored",
                debugStatus: "idle debug",
                registryDebugSummary: "idle registry"
            ),
            .starting
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .starting, topLevelCount: 0, focused: false),
                commandFailureMessage: nil,
                debugStatus: "starting debug",
                registryDebugSummary: "starting registry"
            ),
            .starting
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(
                    phase: .failed(message: "transport lost", reason: nil),
                    topLevelCount: 1,
                    focused: true
                ),
                commandFailureMessage: "ignored",
                debugStatus: "failed debug",
                registryDebugSummary: "failed registry"
            ),
            .failed(message: "transport lost", reason: nil)
        )
    }

    func testStatusOverlayProjectionPreservesHostKeyChallengeReason() {
        let challenge = SSHHostKeyTrustChallenge(
            kind: .changed,
            serverID: UUID(uuidString: "7b882734-5e15-48dd-a48c-40ff7b8906db")!,
            host: "macbook.local",
            trustedKeyType: "ssh-ed25519",
            trustedOpenSSHPublicKey: "ssh-ed25519 trusted",
            receivedKeyType: "ssh-ed25519",
            receivedOpenSSHPublicKey: "ssh-ed25519 received"
        )
        let reason = TerminalDisconnectReason(
            kind: .hostKey,
            message: "Host key changed",
            hostKeyChallenge: challenge
        )

        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(
                    phase: .failed(message: "Host key changed", reason: reason),
                    topLevelCount: 1,
                    focused: true
                ),
                commandFailureMessage: nil,
                debugStatus: "failed debug",
                registryDebugSummary: "failed registry"
            ),
            .failed(message: "Host key changed", reason: reason)
        )
    }

    func testStatusOverlayProjectionPreservesRunningPrecedence() {
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: "No space for another pane.",
                debugStatus: "running debug",
                registryDebugSummary: "running registry"
            ),
            .commandFailure("No space for another pane.")
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 0, focused: false),
                commandFailureMessage: nil,
                debugStatus: "transport started",
                registryDebugSummary: "top=0"
            ),
            .waitingForPanes(
                debugStatus: "transport started",
                registryDebugSummary: "top=0"
            )
        )
        XCTAssertEqual(
            GhosttyTerminalPresentationProjector.terminalStatusOverlayProjection(
                readiness: Self.readinessSnapshot(phase: .running, topLevelCount: 1, focused: false),
                commandFailureMessage: nil,
                debugStatus: "transport started",
                registryDebugSummary: "top=1"
            ),
            .ready
        )
    }

    func testTerminalReadyTraceFieldsPreserveExistingKeysAndAddRawReadinessFacts() throws {
        let workspaceID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let selectedLeafID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let snapshot = TerminalReadinessProjector.snapshot(
            phase: .running,
            transportWritable: true,
            topLevelCount: 2,
            selectedActiveLeafID: selectedLeafID
        )

        XCTAssertEqual(
            TerminalReadinessProjector.terminalReadyTraceFields(
                snapshot,
                managedSurfaceCount: 3,
                workspaceID: workspaceID
            ),
            [
                "topLevels": "2",
                "managedSurfaces": "3",
                "workspaceID": workspaceID.uuidString,
                "phase": "running",
                "transportWritable": "true",
                "selectedActiveLeafID": "AAAAAAAA",
            ]
        )
    }


    private static func managedSurface(
        handle: ghostty_surface_t = UnsafeMutableRawPointer(bitPattern: 0x1)!
    ) -> GhosttyManagedSurface {
        GhosttyManagedSurface(
            id: UUID(),
            view: GhosttyKitSurfaceView(frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            controlSurface: GhosttyKitControlSurface(
                surface: handle,
                ownership: .borrowed
            )
        )
    }

    private static func readinessSnapshot(
        phase: GhosttyTerminalRuntimePhase,
        transportWritable: Bool = false,
        topLevelCount: Int = 1,
        focused: Bool
    ) -> TerminalReadinessSnapshot {
        TerminalReadinessProjector.snapshot(
            phase: phase,
            transportWritable: transportWritable,
            topLevelCount: topLevelCount,
            selectedActiveLeafID: focused ? UUID() : nil
        )
    }
}
