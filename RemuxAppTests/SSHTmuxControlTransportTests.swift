@preconcurrency import Citadel
import NIO
@preconcurrency import NIOSSH
import XCTest
@testable import Remux

final class SSHTmuxControlTransportTests: XCTestCase {
    func testPasswordResolvedAuthFingerprintChangesWithSecret() {
        let first = ResolvedSSHAuth.password(
            username: "deploy",
            password: "first",
            identityID: UUID(),
            displayLabel: "deploy"
        )
        let second = ResolvedSSHAuth.password(
            username: "deploy",
            password: "second",
            identityID: UUID(),
            displayLabel: "deploy"
        )

        XCTAssertNotEqual(first.authFingerprint, second.authFingerprint)
    }

    func testPasswordResolvedAuthFingerprintDoesNotExposeSecret() {
        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "super-secret",
            identityID: UUID(),
            displayLabel: "deploy"
        )

        XCTAssertFalse(auth.authFingerprint.contains("super-secret"))
        XCTAssertTrue(auth.authFingerprint.hasPrefix("password:"))
    }

    func testPasswordResolvedAuthCarriesUsernameAndDisplayLabel() {
        let identityID = UUID()

        let auth = ResolvedSSHAuth.password(
            username: "deploy",
            password: "secret",
            identityID: identityID,
            displayLabel: "Work password"
        )

        XCTAssertEqual(auth.identityID, identityID)
        XCTAssertEqual(auth.username, "deploy")
        XCTAssertEqual(auth.displayLabel, "Work password")
        XCTAssertEqual(auth.credential, .password("secret"))
    }

    func testConfigurationStoresOptionalTraceFlowID() {
        let server = SavedServer(displayName: "Trace Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let defaultConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            sessionName: "base"
        )
        XCTAssertNil(defaultConfiguration.traceFlowID)
        XCTAssertEqual(defaultConfiguration.controlNoResponseTimeout, .seconds(15))

        let tracedConfiguration = SSHTmuxControlConfiguration(
            host: server.host,
            authenticationMethod: {
                .passwordBased(username: server.username, password: "pw")
            },
            hostKeyValidator: trustedHostStore.validator(for: server),
            connectTimeout: .seconds(10),
            controlNoResponseTimeout: .seconds(12),
            sessionName: "base",
            traceFlowID: "session.open.test"
        )
        XCTAssertEqual(tracedConfiguration.traceFlowID, "session.open.test")
        XCTAssertEqual(tracedConfiguration.connectTimeout, .seconds(10))
        XCTAssertEqual(tracedConfiguration.controlNoResponseTimeout, .seconds(12))
    }

    func testSSHRootServiceKeyIsServerAndCredentialScoped() {
        let server = SavedServer(
            displayName: "Build Host",
            host: "server.example.com",
            username: "tester"
        )
        let base = SavedWorkspace(serverID: server.id, sessionName: "base")
        let logs = SavedWorkspace(serverID: server.id, sessionName: "logs")

        let baseTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            sshAuth: makePasswordAuth(server: server, password: "test-password")
        )
        let logsTarget = TmuxConnectionTarget(
            server: server,
            workspace: logs,
            sshAuth: makePasswordAuth(server: server, password: "test-password")
        )
        let changedPasswordTarget = TmuxConnectionTarget(
            server: server,
            workspace: base,
            sshAuth: makePasswordAuth(server: server, password: "other-test-password")
        )
        let changedSavedUserPreservedAuthTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester",
                identityID: server.identityID
            ),
            workspace: base,
            sshAuth: baseTarget.sshAuth
        )
        let changedAuthUserTarget = TmuxConnectionTarget(
            server: SavedServer(
                id: server.id,
                displayName: server.displayName,
                host: server.host,
                username: "other-tester",
                identityID: server.identityID
            ),
            workspace: base,
            sshAuth: makePasswordAuth(
                server: server,
                username: "other-tester",
                password: "test-password"
            )
        )

        XCTAssertEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: logsTarget)
        )
        XCTAssertNotEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedPasswordTarget)
        )
        XCTAssertEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedSavedUserPreservedAuthTarget)
        )
        XCTAssertNotEqual(
            RemuxSSHRootKey(target: baseTarget),
            RemuxSSHRootKey(target: changedAuthUserTarget)
        )
    }

    func testSSHRootServiceReusableReleaseKeepsRootIdleReusable() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceInvalidatedReleaseRemovesRoot() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testSSHRootServiceLeaseCancelsIdleCloseAndIncrementsActiveCount() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 0,
            idleCloseScheduled: true
        )
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceSecondReservationSharesRoot() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)

        // SSH multiplexes session channels over one authenticated
        // connection: concurrent opens to the same server share the
        // root (and its in-flight authentication) instead of paying
        // a full TCP + auth handshake each.
        let first = await pool.reserveEntryForTesting(for: key)
        let second = await pool.reserveEntryForTesting(for: key)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.reservationCount, 2)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceCapacityBoundsSharedRoot() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        _ = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: RemuxSSHRootService.maxConcurrentLeases - 1
        )

        // One slot left: a reservation takes it, the next must fall
        // back to a dedicated connection (nil = pool refuses).
        let last = await pool.reserveEntryForTesting(for: key)
        XCTAssertNotNil(last)
        let overflow = await pool.reserveEntryForTesting(for: key)
        XCTAssertNil(overflow)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceClaimRequiresMatchingReservation() async throws {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        do {
            try await pool.leaseEntryForTesting(
                for: key,
                generation: generation,
                reservationID: UUID()
            )
            XCTFail("expected stale reservation to fail")
        } catch let error as SSHTmuxControlTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 1)
        XCTAssertEqual(entry?.activeLeaseCount, 0)

        try await pool.leaseEntryForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceReleasedReservationReturnsRootToIdle() async throws {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(for: key)
        let reservedID = await pool.reserveEntryForTesting(for: key)
        let reservationID = try XCTUnwrap(reservedID)

        await pool.releaseReservationForTesting(
            for: key,
            generation: generation,
            reservationID: reservationID
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.reservationCount, 0)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceReusableReleasesMultipleLeasesIndependently() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        var entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)

        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )

        entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.activeLeaseCount, 0)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceInvalidationRetiresSharedRootUntilLastLease() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 2
        )

        // One session invalidates: the root leaves the pool (no new
        // leases) but must NOT close under the sibling still using it.
        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .invalidated
        )

        var snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
        XCTAssertEqual(snapshot.retiredCount, 1)

        // The sibling's release drains the retired root.
        await pool.releaseEntryForTesting(
            for: key,
            generation: generation,
            disposition: .reusable
        )
        snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.retiredCount, 0)
    }

    func testSSHRootServiceCloseIdleConnectionsPreservesActiveEntries() async {
        let pool = RemuxSSHRootService()
        let serverID = UUID()
        let idleKey = makeSSHRootKey(
            serverID: serverID,
            host: "idle.example.com"
        )
        let reservedKey = makeSSHRootKey(
            serverID: serverID,
            host: "reserved.example.com"
        )
        let activeKey = makeSSHRootKey(
            serverID: serverID,
            host: "active.example.com"
        )
        let otherServerKey = makeSSHRootKey(
            serverID: UUID(),
            host: "other.example.com"
        )
        await pool.insertEntryForTesting(for: idleKey, activeLeaseCount: 0)
        await pool.insertEntryForTesting(
            for: reservedKey,
            activeLeaseCount: 0,
            reservationID: UUID()
        )
        await pool.insertEntryForTesting(for: activeKey, activeLeaseCount: 1)
        await pool.insertEntryForTesting(for: otherServerKey, activeLeaseCount: 0)

        await pool.closeIdleConnections(forServerID: serverID)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: idleKey))
        XCTAssertNotNil(snapshot.entry(for: reservedKey))
        XCTAssertNotNil(snapshot.entry(for: activeKey))
        XCTAssertNotNil(snapshot.entry(for: otherServerKey))
        XCTAssertEqual(snapshot.entryCount, 3)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceCloseAllConnectionsEvictsAllEntries() async {
        let pool = RemuxSSHRootService()
        await pool.insertEntryForTesting(
            for: makeSSHRootKey(host: "first.example.com")
        )
        await pool.insertEntryForTesting(
            for: makeSSHRootKey(host: "second.example.com")
        )

        await pool.closeAllConnections()

        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
    }

    func testSSHRootServiceAuthenticationFailureRemovesEntry() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            idleCloseScheduled: true
        )

        await pool.markAuthenticationFailedForTesting(for: key, generation: generation)

        let snapshot = await pool.snapshot()
        XCTAssertNil(snapshot.entry(for: key))
    }

    func testSSHRootServiceAuthenticationSuccessMarksReadyAndSchedulesIdleClose() async {
        let pool = RemuxSSHRootService(idleTimeout: .seconds(60))
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.isIdleCloseScheduled, true)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceAuthenticationSuccessKeepsReservedEntryOpen() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let reservationID = UUID()
        let generation = await pool.insertEntryForTesting(
            for: key,
            readiness: .connecting,
            activeLeaseCount: 0,
            reservationID: reservationID
        )

        await pool.markAuthenticationSucceededForTesting(for: key, generation: generation)

        _ = reservationID
        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.readiness, .ready)
        XCTAssertEqual(entry?.reservationCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testSSHRootServiceGenerationMismatchDoesNotMutateCurrentEntry() async {
        let pool = RemuxSSHRootService()
        let key = makeSSHRootKey()
        let generation = await pool.insertEntryForTesting(
            for: key,
            activeLeaseCount: 1,
            idleCloseScheduled: false
        )

        await pool.releaseEntryForTesting(
            for: key,
            generation: UUID(),
            disposition: .invalidated
        )

        let entry = await pool.snapshot().entry(for: key)
        XCTAssertEqual(entry?.generation, generation)
        XCTAssertEqual(entry?.activeLeaseCount, 1)
        XCTAssertEqual(entry?.isIdleCloseScheduled, false)
        await pool.closeAllConnections()
    }

    func testInboundStreamYieldsBytesInCallOrder() async throws {
        let stream = SSHTmuxControlInboundStream()
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        let third = Data("third".utf8)

        stream.yield(first)
        stream.yield(second)
        stream.yield(third)
        stream.finish(nil)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let receivedFirst = try await iterator.next()
        let receivedSecond = try await iterator.next()
        let receivedThird = try await iterator.next()
        let end = try await iterator.next()

        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)
        XCTAssertEqual(receivedThird, third)
        XCTAssertNil(end)
    }

    func testInboundStreamIgnoresYieldsAfterFinish() async throws {
        let stream = SSHTmuxControlInboundStream()

        stream.finish(nil)
        stream.yield(Data("late".utf8))

        var iterator = stream.receivedBytes.makeAsyncIterator()
        let end = try await iterator.next()

        XCTAssertNil(end)
    }

    func testInboundStreamFinishesWithFirstError() async {
        enum Failure: Error, Equatable {
            case first
            case second
        }

        let stream = SSHTmuxControlInboundStream()

        stream.finish(Failure.first)
        stream.finish(Failure.second)

        var iterator = stream.receivedBytes.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("expected first finish error")
        } catch let error as Failure {
            XCTAssertEqual(error, .first)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testResizeStateBeginsApplyingOnlyWhenViewportChanges() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)

        XCTAssertNil(state.beginApplyingIfNeeded())

        state.markApplied(initial)
        XCTAssertNil(state.beginApplyingIfNeeded())

        state.request(.init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700))
        XCTAssertEqual(
            state.beginApplyingIfNeeded(),
            .init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        )
        XCTAssertTrue(state.isApplying)
        XCTAssertNil(state.beginApplyingIfNeeded())
    }

    func testResizeStateCoalescesToLatestViewportAfterApply() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)
        state.markApplied(initial)

        let first = TmuxControlViewport(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        let second = TmuxControlViewport(columns: 100, rows: 32, pixelWidth: 1000, pixelHeight: 720)
        state.request(first)

        XCTAssertEqual(state.beginApplyingIfNeeded(), first)

        state.request(second)
        XCTAssertEqual(state.completeApplied(first), second)
        XCTAssertTrue(state.isApplying)
        XCTAssertNil(state.completeApplied(second))
        XCTAssertFalse(state.isApplying)
    }

    func testResizeStateResetsApplyingFlagOnFailure() {
        let initial = TmuxControlViewport(columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600)
        var state = TmuxViewportResizeState(initialViewport: initial)
        state.markApplied(initial)
        state.request(.init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700))

        XCTAssertNotNil(state.beginApplyingIfNeeded())
        XCTAssertTrue(state.isApplying)

        state.failApplying()

        XCTAssertFalse(state.isApplying)
        XCTAssertEqual(
            state.beginApplyingIfNeeded(),
            .init(columns: 90, rows: 30, pixelWidth: 900, pixelHeight: 700)
        )
    }

    func testChannelRequestReplyTrackerMatchesFailuresToOldestPendingReply() {
        var tracker = SSHTmuxControlChannelRequestReplyTracker()

        tracker.expectReply(for: .pseudoTerminal)
        tracker.expectReply(for: .exec)

        XCTAssertEqual(tracker.pendingCount, 2)
        XCTAssertEqual(tracker.acknowledgeSuccess(), .pseudoTerminal)
        XCTAssertEqual(tracker.acknowledgeFailure(), .exec)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testChannelRequestReplyTrackerReportsUnknownFailureWithoutPendingReply() {
        var tracker = SSHTmuxControlChannelRequestReplyTracker()

        XCTAssertEqual(tracker.acknowledgeFailure(), .unknown)
        XCTAssertEqual(tracker.pendingCount, 0)
    }

    func testChannelRequestFailureDescriptionNamesRejectedRequest() {
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.pseudoTerminal)),
            "SSH pseudo-terminal request failed"
        )
    }

    func testChannelDataRouterForwardsOnlyStdoutAsControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let first = Data("%begin 1 0\\n".utf8)
        let second = Data("%end 1 0\\n".utf8)

        XCTAssertEqual(
            router.route(type: .channel, data: first),
            .stdout(reportFirstOutput: true)
        )
        XCTAssertEqual(
            router.route(type: .channel, data: second),
            .stdout(reportFirstOutput: false)
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, first.count + second.count)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
    }

    func testChannelDataRouterCapturesStderrWithoutControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let stderr = Data("tmux: no server running\\n".utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, stderr.count)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, 0)
        XCTAssertTrue(diagnostics?.stderrPreview?.contains("tmux: no server running") == true)
    }

    func testChannelDataRouterCapturesUnknownExtendedDataWithoutControlOutput() {
        var router = SSHTmuxControlChannelDataRouter()
        let extended = Data("extended diagnostic\\n".utf8)

        XCTAssertEqual(
            router.route(type: SSHChannelData.DataType(extended: 2), data: extended),
            .extendedData(typeDescription: "SSHChannelData(extended: 2)")
        )

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stdoutByteCount, 0)
        XCTAssertEqual(diagnostics?.stderrByteCount, 0)
        XCTAssertEqual(diagnostics?.extendedDataByteCount, extended.count)
        XCTAssertTrue(diagnostics?.extendedDataPreview?.contains("extended diagnostic") == true)
    }

    func testStartupDiagnosticsBoundsStderrPreview() {
        var router = SSHTmuxControlChannelDataRouter()
        let stderr = Data(String(repeating: "x", count: 500).utf8)

        XCTAssertEqual(router.route(type: .stdErr, data: stderr), .stderr)

        let diagnostics = router.diagnostics
        XCTAssertEqual(diagnostics?.stderrByteCount, 500)
        XCTAssertLessThanOrEqual(diagnostics?.stderrPreview?.count ?? 0, 260)
    }

    func testTransportFailureDescriptionIncludesBoundedDiagnosticsWhenPresent() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )

        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.remoteExit(1)),
            "remoteExit(1)"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stderr_preview=\"tmux failed\"")
        )
        XCTAssertEqual(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec)),
            "SSH exec request failed"
        )
        XCTAssertTrue(
            String(describing: SSHTmuxControlTransportError.channelRequestFailed(.exec, diagnostics: diagnostics))
                .contains("stderr_bytes=18")
        )
        XCTAssertFalse(
            String(describing: SSHTmuxControlTransportError.remoteExit(1, diagnostics: diagnostics))
                .contains("stdout_preview")
        )
    }

    func testChannelCompletionReportsRemoteExitWithDiagnosticsOnClose() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 12,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        var completionState = SSHTmuxControlChannelCompletionState()

        completionState.recordExitStatus(1)

        let completion = completionState.finish(nil, diagnostics: diagnostics)
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport remote exit failure")
            return
        }

        XCTAssertEqual(
            String(describing: error),
            "remoteExit(1) stdout_bytes=12 stderr_bytes=18 extended_bytes=0 stderr_preview=\"tmux failed\""
        )
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testChannelCompletionKeepsRequestRejectionAsImmediateFailure() {
        let diagnostics = SSHTmuxStartupDiagnostics(
            stdoutByteCount: 0,
            stderrByteCount: 18,
            extendedDataByteCount: 0,
            stderrPreview: "tmux failed",
            extendedDataPreview: nil
        )
        var completionState = SSHTmuxControlChannelCompletionState()
        let requestFailure = SSHTmuxControlTransportError.channelRequestFailed(
            .exec,
            diagnostics: diagnostics
        )

        let completion = completionState.finish(requestFailure, diagnostics: diagnostics)
        guard case .failure(let error as SSHTmuxControlTransportError) = completion else {
            XCTFail("expected transport request failure")
            return
        }

        XCTAssertEqual(error, requestFailure)
        XCTAssertNil(completionState.finish(nil, diagnostics: diagnostics))
    }

    func testFirstOutputGateKeepsEarlyFailure() throws {
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let gate = SSHTmuxControlFirstOutputGate(promise: promise)
        let failure = SSHTmuxControlTransportError.remoteExit(1)

        gate.fail(failure)
        gate.succeed()

        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertEqual(error as? SSHTmuxControlTransportError, failure)
        }
    }

    func testFirstOutputGateIgnoresFinishAfterFirstOutput() throws {
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        let gate = SSHTmuxControlFirstOutputGate(promise: promise)

        gate.succeed()
        gate.fail(SSHTmuxControlTransportError.remoteExit(1))

        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testControlSessionCommandAttachesOrCreatesNamedSession() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "tmux",
            sessionName: "base",
            initialViewport: TmuxControlViewport(
                columns: 45,
                rows: 37,
                pixelWidth: 1_190,
                pixelHeight: 2_162
            )
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec 'tmux' -C new-session -A -s 'base' -x 45 -y 37"
        )
    }

    func testControlSessionCommandShellEscapesValues() {
        let command = SSHTmuxControlCommandBuilder.attachOrCreateControlSessionCommand(
            tmuxExecutable: "/opt/homebrew/bin/tmux",
            sessionName: "owner's base",
            initialViewport: TmuxControlViewport(
                columns: 120,
                rows: 40,
                pixelWidth: 0,
                pixelHeight: 0
            )
        )

        XCTAssertEqual(
            command,
            "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin TERM=xterm-256color; exec '/opt/homebrew/bin/tmux' -C new-session -A -s 'owner'\"'\"'s base' -x 120 -y 40"
        )
    }

    func testSendAfterCloseFailsInsteadOfQueueingBytes() async {
        let server = SavedServer(displayName: "Closed Host", host: "example.com", username: "tester")
        let trustedHostStore = TrustedHostStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let transport = SSHTmuxControlTransport(
            configuration: SSHTmuxControlConfiguration(
                host: server.host,
                authenticationMethod: {
                    .passwordBased(username: server.username, password: "pw")
                },
                hostKeyValidator: trustedHostStore.validator(for: server),
                sessionName: "base"
            )
        )

        await transport.close(disposition: .reusable)

        do {
            try await transport.send(Data("send-keys -t %1 a\n".utf8))
            XCTFail("expected closed transport failure")
        } catch let error as SSHTmuxControlTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeSSHRootKey(
        serverID: SavedServer.ID = UUID(),
        host: String = "server.example.com",
        port: Int = 22,
        username: String = "tester",
        password: String = "pw"
    ) -> RemuxSSHRootKey {
        let server = SavedServer(
            id: serverID,
            displayName: host,
            host: host,
            port: port,
            username: username
        )
        let workspace = SavedWorkspace(serverID: server.id, sessionName: "base")
        return RemuxSSHRootKey(
            target: TmuxConnectionTarget(
                server: server,
                workspace: workspace,
                sshAuth: makePasswordAuth(
                    server: server,
                    username: username,
                    password: password
                )
            )
        )
    }

    private func makePasswordAuth(
        server: SavedServer,
        username: String? = nil,
        password: String
    ) -> ResolvedSSHAuth {
        .password(
            username: username ?? server.username,
            password: password,
            identityID: server.identityID,
            displayLabel: server.displayName
        )
    }
}
