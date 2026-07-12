import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyPanePreviewSessionTests: XCTestCase {
    func testRequestLeaseDefersReleaseUntilHandleInstall() {
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5010)!
        let recorder = PreviewRequestActionRecorder()
        let lease = makeLease(recorder: recorder)

        lease.release()
        XCTAssertTrue(recorder.events.isEmpty)

        lease.install(request)
        lease.release()

        XCTAssertEqual(recorder.actions, [.release])
        XCTAssertEqual(recorder.handles, [UInt(bitPattern: request)])
    }

    func testRequestLeaseDefersCancelThenReleaseUntilHandleInstall() {
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5011)!
        let recorder = PreviewRequestActionRecorder()
        let lease = makeLease(recorder: recorder)

        lease.cancelAndRelease()
        XCTAssertTrue(recorder.events.isEmpty)

        lease.install(request)
        lease.cancelAndRelease()
        lease.release()

        XCTAssertEqual(recorder.actions, [.cancel, .release])
        XCTAssertEqual(
            recorder.handles,
            [UInt(bitPattern: request), UInt(bitPattern: request)]
        )
    }

    func testRequestLeaseConcurrentInstallCancelAndReleaseNeverDuplicatesActions() {
        for index in 1 ... 200 {
            let rawHandle = UInt(0x6000 + index)
            let recorder = PreviewRequestActionRecorder()
            let lease = makeLease(recorder: recorder)

            DispatchQueue.concurrentPerform(iterations: 3) { operation in
                switch operation {
                case 0:
                    lease.install(OpaquePointer(bitPattern: rawHandle)!)
                case 1:
                    lease.cancelAndRelease()
                default:
                    lease.release()
                }
            }

            XCTAssertEqual(recorder.actions.filter { $0 == .release }.count, 1)
            XCTAssertLessThanOrEqual(recorder.actions.filter { $0 == .cancel }.count, 1)
            XCTAssertTrue(recorder.handles.allSatisfy { $0 == rawHandle })
            if recorder.actions.contains(.cancel) {
                XCTAssertEqual(recorder.actions, [.cancel, .release])
            }
        }
    }

    func testRejectedStartPerformsNoHandleAction() {
        let paneID = UUID()
        let recorder = PreviewRequestActionRecorder()
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, _, _, completion in completion(.rejected) },
            cancel: { recorder.record(.cancel, request: $0) },
            release: { recorder.record(.release, request: $0) }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()

        XCTAssertTrue(recorder.events.isEmpty)
        assertFailed(
            session.imagesByPaneID[paneID],
            status: GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED
        )
    }

    func testNativeCallbackReleasesBeforeMainActorDeliveryOnCallbackThread() async throws {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5012)!
        let recorder = PreviewRequestActionRecorder()
        var capturedCallback: CapturedPreviewCallback?
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                capturedCallback = .init(userdata: userdata, callback: callback)
                completion(.started(request))
            },
            cancel: { recorder.record(.cancel, request: $0) },
            release: { recorder.record(.release, request: $0) }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .seconds(10),
            previewRequestClient: client
        )

        session.startRefreshing()
        let callback = try XCTUnwrap(capturedCallback)
        let callbackReturned = DispatchSemaphore(value: 0)
        let callbackThread = Thread {
            recorder.record(.callback, request: request)
            callback.callback(
                callback.userdata,
                GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED,
                ghostty_surface_preview_image_s()
            )
            recorder.record(.callbackReturned, request: request)
            callbackReturned.signal()
        }
        callbackThread.qualityOfService = .userInteractive
        callbackThread.start()

        XCTAssertEqual(callbackReturned.wait(timeout: .now() + 1), .success)
        let events = recorder.events
        XCTAssertEqual(events.map(\.action), [.callback, .release, .callbackReturned])
        let callbackEvent = try XCTUnwrap(events.first)
        let releaseEvent = try XCTUnwrap(events.dropFirst().first)
        XCTAssertEqual(callbackEvent.threadID, releaseEvent.threadID)
        XCTAssertPending(session.imagesByPaneID[paneID])

        let didDeliver = await waitUntil {
            if case .failed? = session.imagesByPaneID[paneID] { return true }
            return false
        }
        XCTAssertTrue(didDeliver)
        session.cancelAll()
    }

    func testCachedPreviewIsReadyWithoutStartingRequest() throws {
        let paneID = UUID()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cachedImage = try XCTUnwrap(context.makeImage())
        var startCount = 0
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, _, _, completion in
                startCount += 1
                completion(.rejected)
            },
            cancel: { _ in },
            release: { _ in },
            cachedPreview: { requestedPaneID in
                requestedPaneID == paneID
                    ? .init(image: cachedImage, source: .remotePaneGeometry)
                    : nil
            }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()
        XCTAssertEqual(startCount, 0)
        guard case .ready(let result)? = session.imagesByPaneID[paneID] else {
            return XCTFail("expected cached preview to be ready")
        }
        XCTAssertTrue(result.image === cachedImage)
        XCTAssertEqual(result.source, .remotePaneGeometry)
    }

    func testUncachedPreviewDoesNotStartUntilRefreshBegins() {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5050)!
        var startCount = 0
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, _, _, completion in
                startCount += 1
                completion(.started(request))
            },
            cancel: { _ in },
            release: { _ in }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(session.imagesByPaneID[paneID])

        session.startRefreshing()

        XCTAssertEqual(startCount, 1)
        XCTAssertPending(session.imagesByPaneID[paneID])
        session.cancelAll()
    }

    func testMixedCachedAndUncachedPanesOnlyRequestColdPreviewAfterRefreshBegins() throws {
        let cachedPaneID = UUID()
        let uncachedPaneID = UUID()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cachedImage = try XCTUnwrap(context.makeImage())
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5053)!
        var startedPaneIDs: [UUID] = []
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { paneID, _, _, _, completion in
                startedPaneIDs.append(paneID)
                completion(.started(request))
            },
            cancel: { _ in },
            release: { _ in },
            cachedPreview: { paneID in
                paneID == cachedPaneID
                    ? .init(image: cachedImage, source: .remotePaneGeometry)
                    : nil
            }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [cachedPaneID, uncachedPaneID],
            scale: 1,
            previewRequestClient: client
        )

        XCTAssertTrue(startedPaneIDs.isEmpty)
        guard case .ready(let result)? = session.imagesByPaneID[cachedPaneID] else {
            return XCTFail("expected cached pane to be ready during construction")
        }
        XCTAssertTrue(result.image === cachedImage)
        XCTAssertNil(session.imagesByPaneID[uncachedPaneID])

        session.startRefreshing()

        XCTAssertEqual(startedPaneIDs, [uncachedPaneID])
        XCTAssertPending(session.imagesByPaneID[uncachedPaneID])
        session.cancelAll()
    }

    func testCancelBeforeRefreshPreventsRequestStart() {
        let paneID = UUID()
        var startCount = 0
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, _, _, completion in
                startCount += 1
                completion(.rejected)
            },
            cancel: { _ in },
            release: { _ in }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.cancelAll()
        session.startRefreshing()

        XCTAssertEqual(startCount, 0)
        XCTAssertNil(session.imagesByPaneID[paneID])
    }

    func testCachedActivePreviewStaysVisibleWhenRefreshFails() async throws {
        let paneID = UUID()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cachedImage = try XCTUnwrap(context.makeImage())
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5052)!
        var callbacks: [CapturedPreviewCallback] = []
        var startCompletions: [GhosttyPanePreviewSession.PreviewRequestClient.StartCompletion] = []
        let requestActions = PreviewRequestActionRecorder()
        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                callbacks.append(.init(userdata: userdata, callback: callback))
                startCompletions.append(completion)
            },
            cancel: { _ in },
            release: { requestActions.record(.release, request: $0) },
            cachedPreview: { requestedPaneID in
                requestedPaneID == paneID
                    ? .init(image: cachedImage, source: .remotePaneGeometry)
                    : nil
            },
            shouldRefreshCachedImage: { $0 == paneID }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()

        guard case .ready(let refreshingImage)? = session.imagesByPaneID[paneID] else {
            return XCTFail("expected cached image to remain visible during refresh")
        }
        XCTAssertTrue(refreshingImage.image === cachedImage)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(startCompletions.count, 1)

        startCompletions[0](.started(request))

        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED,
            ghostty_surface_preview_image_s()
        )

        let didRelease = await waitUntil {
            requestActions.handles(for: .release) == [UInt(bitPattern: request)]
        }
        XCTAssertTrue(didRelease)
        guard case .ready(let finalImage)? = session.imagesByPaneID[paneID] else {
            return XCTFail("expected failed refresh to preserve cached image")
        }
        XCTAssertTrue(finalImage.image === cachedImage)
    }

    func testWindowGridPreviewSizingUsesWindowTileBudget() {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5051)!
        var capturedOptions: ghostty_surface_preview_image_options_s?

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, options, _, _, completion in
                capturedOptions = options
                completion(.started(request))
            },
            cancel: { _ in },
            release: { _ in }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 3,
            previewSizing: .windowGrid(availableWidth: 361),
            previewRequestClient: client
        )

        session.startRefreshing()
        XCTAssertEqual(capturedOptions?.max_width_px, 477)
        XCTAssertEqual(capturedOptions?.max_height_px, 360)
        session.cancelAll()
    }

    func testTransientUnavailableSurfaceRetriesPreviewStart() async {
        let paneID = UUID()
        let fakeRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5151)!
        var startedPaneIDs: [UUID] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, _, _, completion in
                startedPaneIDs.append(requestedPaneID)
                guard startedPaneIDs.count > 1 else {
                    completion(.surfaceUnavailable)
                    return
                }
                completion(.started(fakeRequest))
            },
            cancel: { _ in },
            release: { _ in }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

        session.startRefreshing()
        XCTAssertEqual(startedPaneIDs, [paneID])
        assertFailed(
            session.imagesByPaneID[paneID],
            status: GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED
        )

        let didRetry = await waitUntil {
            startedPaneIDs.count == 2
        }

        XCTAssertTrue(didRetry)
        XCTAssertEqual(startedPaneIDs, [paneID, paneID])
        if case .pending? = session.imagesByPaneID[paneID] {
            session.cancelAll()
        } else {
            XCTFail("expected retried preview to be pending")
        }
    }

    func testNonTransientStartFailureDoesNotRetry() async {
        let paneID = UUID()
        var startedPaneIDs: [UUID] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, _, _, completion in
                startedPaneIDs.append(requestedPaneID)
                completion(.failed(GHOSTTY_SURFACE_PREVIEW_STATUS_INVALID_OPTIONS))
            },
            cancel: { _ in },
            release: { _ in }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

        session.startRefreshing()
        assertFailed(
            session.imagesByPaneID[paneID],
            status: GHOSTTY_SURFACE_PREVIEW_STATUS_INVALID_OPTIONS
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(startedPaneIDs, [paneID])
    }

    func testAcceptedAsyncTransientFailureRetriesPreviewStart() async {
        let paneID = UUID()
        let firstRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5251)!
        let secondRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5252)!
        var startedPaneIDs: [UUID] = []
        var callbacks: [CapturedPreviewCallback] = []
        let requestActions = PreviewRequestActionRecorder()

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, userdata, callback, completion in
                startedPaneIDs.append(requestedPaneID)
                callbacks.append(.init(userdata: userdata, callback: callback))
                completion(.started(startedPaneIDs.count == 1 ? firstRequest : secondRequest))
            },
            cancel: { _ in },
            release: { requestActions.record(.release, request: $0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

        session.startRefreshing()
        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_SURFACE_CLOSED,
            ghostty_surface_preview_image_s()
        )

        let didRetry = await waitUntil {
            startedPaneIDs.count == 2
        }

        XCTAssertTrue(didRetry)
        XCTAssertEqual(startedPaneIDs, [paneID, paneID])
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: firstRequest)]
        )
        if case .pending? = session.imagesByPaneID[paneID] {
            session.cancelAll()
        } else {
            XCTFail("expected retried preview to be pending")
        }
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: firstRequest), UInt(bitPattern: secondRequest)]
        )
    }

    func testEachPaneKeepsItsOwnSixRetryBudget() async {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        var attemptsByPaneID: [UUID: Int] = [:]

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { paneID, _, _, _, completion in
                attemptsByPaneID[paneID, default: 0] += 1
                completion(.surfaceUnavailable)
            },
            cancel: { _ in },
            release: { _ in }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [firstPaneID, secondPaneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

        session.startRefreshing()

        let exhaustedBothBudgets = await waitUntil {
            attemptsByPaneID[firstPaneID] == 7 &&
                attemptsByPaneID[secondPaneID] == 7
        }
        XCTAssertTrue(exhaustedBothBudgets)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(attemptsByPaneID[firstPaneID], 7)
        XCTAssertEqual(attemptsByPaneID[secondPaneID], 7)
    }

    func testCancellationBeforeDeferredAcceptanceCancelsAndReleasesAcceptedHandleOnce() async {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5255)!
        var capturedCallback: CapturedPreviewCallback?
        var startCompletion: GhosttyPanePreviewSession.PreviewRequestClient.StartCompletion?
        let requestActions = PreviewRequestActionRecorder()

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                capturedCallback = .init(userdata: userdata, callback: callback)
                startCompletion = completion
            },
            cancel: { requestActions.record(.cancel, request: $0) },
            release: { requestActions.record(.release, request: $0) }
        )
        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()
        XCTAssertPending(session.imagesByPaneID[paneID])
        session.cancelAll()
        XCTAssertTrue(requestActions.events.isEmpty)

        startCompletion?(.started(request))
        XCTAssertEqual(requestActions.actions, [.cancel, .release])
        XCTAssertEqual(
            requestActions.handles,
            [UInt(bitPattern: request), UInt(bitPattern: request)]
        )

        capturedCallback?.callback(
            capturedCallback?.userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_CANCELLED,
            ghostty_surface_preview_image_s()
        )
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(requestActions.actions, [.cancel, .release])
    }

    func testAcceptedRequestReleasesWhenSessionDisappearsBeforeCallback() async {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5253)!
        var callbacks: [CapturedPreviewCallback] = []
        let requestActions = PreviewRequestActionRecorder()

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                callbacks.append(.init(userdata: userdata, callback: callback))
                completion(.started(request))
            },
            cancel: { _ in },
            release: { requestActions.record(.release, request: $0) }
        )

        var session: GhosttyPanePreviewSession? = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )
        session?.startRefreshing()
        weak var weakSession = session
        XCTAssertNotNil(weakSession)

        session = nil
        XCTAssertNil(weakSession)

        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_CANCELLED,
            ghostty_surface_preview_image_s()
        )

        let didRelease = await waitUntil {
            requestActions.handles(for: .release) == [UInt(bitPattern: request)]
        }
        XCTAssertTrue(didRelease)
    }

    func testOkCompletionWithoutPixelsRecordsRenderFailed() async {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5254)!
        var callbacks: [CapturedPreviewCallback] = []
        let requestActions = PreviewRequestActionRecorder()

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                callbacks.append(.init(userdata: userdata, callback: callback))
                completion(.started(request))
            },
            cancel: { _ in },
            release: { requestActions.record(.release, request: $0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(500),
            previewRequestClient: client
        )

        session.startRefreshing()
        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_OK,
            ghostty_surface_preview_image_s()
        )

        let didRelease = await waitUntil {
            requestActions.handles(for: .release) == [UInt(bitPattern: request)]
        }
        XCTAssertTrue(didRelease)
        let didDeliverFailure = await waitUntil {
            if case .failed(GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED)? =
                session.imagesByPaneID[paneID] {
                return true
            }
            return false
        }
        XCTAssertTrue(didDeliverFailure)
        session.cancelAll()
    }

    func testReconcileCancelsRemovedPaneStartsAddedPaneAndKeepsRetainedPanePending() {
        let retainedPaneID = UUID()
        let removedPaneID = UUID()
        let addedPaneID = UUID()
        let retainedRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5152)!
        let removedRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5153)!
        let addedRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5154)!
        var startedPaneIDs: [UUID] = []
        let requestActions = PreviewRequestActionRecorder()

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { paneID, _, _, _, completion in
                startedPaneIDs.append(paneID)
                switch paneID {
                case retainedPaneID:
                    completion(.started(retainedRequest))
                case removedPaneID:
                    completion(.started(removedRequest))
                case addedPaneID:
                    completion(.started(addedRequest))
                default:
                    XCTFail("unexpected pane request \(paneID)")
                    completion(.rejected)
                }
            },
            cancel: { requestActions.record(.cancel, request: $0) },
            release: { requestActions.record(.release, request: $0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [retainedPaneID, removedPaneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()
        session.reconcile(leafIDs: [retainedPaneID, addedPaneID])

        XCTAssertEqual(startedPaneIDs, [retainedPaneID, removedPaneID, addedPaneID])
        XCTAssertNil(session.imagesByPaneID[removedPaneID])
        XCTAssertEqual(
            requestActions.handles(for: .cancel),
            [UInt(bitPattern: removedRequest)]
        )
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: removedRequest)]
        )
        XCTAssertPending(session.imagesByPaneID[retainedPaneID])
        XCTAssertPending(session.imagesByPaneID[addedPaneID])

        session.cancelAll()
        let expectedHandles = Set([
            UInt(bitPattern: retainedRequest),
            UInt(bitPattern: removedRequest),
            UInt(bitPattern: addedRequest),
        ])
        XCTAssertEqual(Set(requestActions.handles(for: .cancel)), expectedHandles)
        XCTAssertEqual(Set(requestActions.handles(for: .release)), expectedHandles)
    }

    func testCanceledRequestCallbackDoesNotCompleteNewRequestForSamePane() async {
        let paneID = UUID()
        let firstRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5155)!
        let secondRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5156)!
        var callbacks: [CapturedPreviewCallback] = []
        let requestActions = PreviewRequestActionRecorder()
        var startCount = 0

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback, completion in
                startCount += 1
                callbacks.append(.init(userdata: userdata, callback: callback))
                completion(.started(startCount == 1 ? firstRequest : secondRequest))
            },
            cancel: { requestActions.record(.cancel, request: $0) },
            release: { requestActions.record(.release, request: $0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.startRefreshing()
        session.reconcile(leafIDs: [])
        session.reconcile(leafIDs: [paneID])

        XCTAssertEqual(
            requestActions.handles(for: .cancel),
            [UInt(bitPattern: firstRequest)]
        )
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: firstRequest)]
        )
        XCTAssertPending(session.imagesByPaneID[paneID])

        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_CANCELLED,
            ghostty_surface_preview_image_s()
        )

        let didStayPending = await waitUntil {
            if case .pending? = session.imagesByPaneID[paneID] {
                return true
            }
            return false
        }
        XCTAssertTrue(didStayPending)
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: firstRequest)]
        )

        session.cancelAll()
        XCTAssertEqual(
            requestActions.handles(for: .cancel),
            [UInt(bitPattern: firstRequest), UInt(bitPattern: secondRequest)]
        )
        XCTAssertEqual(
            requestActions.handles(for: .release),
            [UInt(bitPattern: firstRequest), UInt(bitPattern: secondRequest)]
        )
    }

    private func assertFailed(
        _ state: GhosttyPanePreviewSession.PreviewState?,
        status expectedStatus: ghostty_surface_preview_status_e,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let actualStatus)? = state else {
            XCTFail("expected failed preview state", file: file, line: line)
            return
        }
        XCTAssertEqual(actualStatus, expectedStatus, file: file, line: line)
    }

    private func XCTAssertPending(
        _ state: GhosttyPanePreviewSession.PreviewState?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .pending? = state else {
            XCTFail("expected pending preview state", file: file, line: line)
            return
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeLease(
        recorder: PreviewRequestActionRecorder
    ) -> GhosttyPreviewRequestLease {
        GhosttyPreviewRequestLease(
            cancel: { recorder.record(.cancel, request: $0) },
            release: { recorder.record(.release, request: $0) }
        )
    }
}

private struct CapturedPreviewCallback: @unchecked Sendable {
    let userdata: UnsafeMutableRawPointer?
    let callback: ghostty_surface_preview_image_callback_f
}

private final class PreviewRequestActionRecorder: @unchecked Sendable {
    enum Action: Equatable {
        case callback
        case cancel
        case release
        case callbackReturned
    }

    struct Event: Equatable {
        let action: Action
        let handle: UInt
        let threadID: UInt64
    }

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    var actions: [Action] {
        events.map(\.action)
    }

    var handles: [UInt] {
        events.map(\.handle)
    }

    func handles(for action: Action) -> [UInt] {
        events.compactMap { event in
            event.action == action ? event.handle : nil
        }
    }

    func record(_ action: Action, request: ghostty_surface_preview_request_t) {
        let event = Event(
            action: action,
            handle: UInt(bitPattern: request),
            threadID: UInt64(pthread_mach_thread_np(pthread_self()))
        )
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
