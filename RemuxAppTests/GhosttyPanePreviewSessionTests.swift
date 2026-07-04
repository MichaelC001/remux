import Foundation
import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyPanePreviewSessionTests: XCTestCase {
    func testWindowGridPreviewSizingUsesWindowTileBudget() {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5051)!
        var capturedOptions: ghostty_surface_preview_image_options_s?

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, options, _, _ in
                capturedOptions = options
                return .started(request)
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

        XCTAssertEqual(capturedOptions?.max_width_px, 477)
        XCTAssertEqual(capturedOptions?.max_height_px, 360)
        session.cancelAll()
    }

    func testTransientUnavailableSurfaceRetriesPreviewStart() async {
        let paneID = UUID()
        let fakeRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5151)!
        var startedPaneIDs: [UUID] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, _, _ in
                startedPaneIDs.append(requestedPaneID)
                guard startedPaneIDs.count > 1 else {
                    return .surfaceUnavailable
                }
                return .started(fakeRequest)
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

    func testAcceptedAsyncTransientFailureRetriesPreviewStart() async {
        let paneID = UUID()
        let firstRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5251)!
        let secondRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5252)!
        var startedPaneIDs: [UUID] = []
        var callbacks: [CapturedPreviewCallback] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { requestedPaneID, _, userdata, callback in
                startedPaneIDs.append(requestedPaneID)
                callbacks.append(.init(userdata: userdata, callback: callback))
                return .started(startedPaneIDs.count == 1 ? firstRequest : secondRequest)
            },
            cancel: { _ in },
            release: { releasedRequests.append($0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(1),
            previewRequestClient: client
        )

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
        XCTAssertEqual(releasedRequests, [firstRequest])
        if case .pending? = session.imagesByPaneID[paneID] {
            session.cancelAll()
        } else {
            XCTFail("expected retried preview to be pending")
        }
        XCTAssertEqual(releasedRequests, [firstRequest, secondRequest])
    }

    func testAcceptedRequestReleasesWhenSessionDisappearsBeforeCallback() async {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5253)!
        var callbacks: [CapturedPreviewCallback] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback in
                callbacks.append(.init(userdata: userdata, callback: callback))
                return .started(request)
            },
            cancel: { _ in },
            release: { releasedRequests.append($0) }
        )

        var session: GhosttyPanePreviewSession? = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )
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
            releasedRequests == [request]
        }
        XCTAssertTrue(didRelease)
    }

    func testOkCompletionWithoutPixelsRecordsRenderFailed() async {
        let paneID = UUID()
        let request: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5254)!
        var callbacks: [CapturedPreviewCallback] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback in
                callbacks.append(.init(userdata: userdata, callback: callback))
                return .started(request)
            },
            cancel: { _ in },
            release: { releasedRequests.append($0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            retryDelay: .milliseconds(500),
            previewRequestClient: client
        )

        callbacks[0].callback(
            callbacks[0].userdata,
            GHOSTTY_SURFACE_PREVIEW_STATUS_OK,
            ghostty_surface_preview_image_s()
        )

        let didRelease = await waitUntil {
            releasedRequests == [request]
        }
        XCTAssertTrue(didRelease)
        assertFailed(
            session.imagesByPaneID[paneID],
            status: GHOSTTY_SURFACE_PREVIEW_STATUS_RENDER_FAILED
        )
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
        var canceledRequests: [ghostty_surface_preview_request_t] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { paneID, _, _, _ in
                startedPaneIDs.append(paneID)
                switch paneID {
                case retainedPaneID:
                    return .started(retainedRequest)
                case removedPaneID:
                    return .started(removedRequest)
                case addedPaneID:
                    return .started(addedRequest)
                default:
                    XCTFail("unexpected pane request \(paneID)")
                    return .rejected
                }
            },
            cancel: { canceledRequests.append($0) },
            release: { releasedRequests.append($0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [retainedPaneID, removedPaneID],
            scale: 1,
            previewRequestClient: client
        )

        session.reconcile(leafIDs: [retainedPaneID, addedPaneID])

        XCTAssertEqual(startedPaneIDs, [retainedPaneID, removedPaneID, addedPaneID])
        XCTAssertNil(session.imagesByPaneID[removedPaneID])
        XCTAssertEqual(canceledRequests, [removedRequest])
        XCTAssertEqual(releasedRequests, [removedRequest])
        XCTAssertPending(session.imagesByPaneID[retainedPaneID])
        XCTAssertPending(session.imagesByPaneID[addedPaneID])

        session.cancelAll()
        XCTAssertEqual(canceledRequests.count, 3)
        XCTAssertTrue(canceledRequests.contains(retainedRequest))
        XCTAssertTrue(canceledRequests.contains(removedRequest))
        XCTAssertTrue(canceledRequests.contains(addedRequest))
        XCTAssertEqual(releasedRequests.count, 3)
        XCTAssertTrue(releasedRequests.contains(retainedRequest))
        XCTAssertTrue(releasedRequests.contains(removedRequest))
        XCTAssertTrue(releasedRequests.contains(addedRequest))
    }

    func testCanceledRequestCallbackDoesNotCompleteNewRequestForSamePane() async {
        let paneID = UUID()
        let firstRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5155)!
        let secondRequest: ghostty_surface_preview_request_t = OpaquePointer(bitPattern: 0x5156)!
        var callbacks: [CapturedPreviewCallback] = []
        var canceledRequests: [ghostty_surface_preview_request_t] = []
        var releasedRequests: [ghostty_surface_preview_request_t] = []
        var startCount = 0

        let client = GhosttyPanePreviewSession.PreviewRequestClient(
            start: { _, _, userdata, callback in
                startCount += 1
                callbacks.append(.init(userdata: userdata, callback: callback))
                return .started(startCount == 1 ? firstRequest : secondRequest)
            },
            cancel: { canceledRequests.append($0) },
            release: { releasedRequests.append($0) }
        )

        let session = GhosttyPanePreviewSession(
            leafIDs: [paneID],
            scale: 1,
            previewRequestClient: client
        )

        session.reconcile(leafIDs: [])
        session.reconcile(leafIDs: [paneID])

        XCTAssertEqual(canceledRequests, [firstRequest])
        XCTAssertEqual(releasedRequests, [firstRequest])
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
        XCTAssertEqual(releasedRequests, [firstRequest])

        session.cancelAll()
        XCTAssertEqual(canceledRequests, [firstRequest, secondRequest])
        XCTAssertEqual(releasedRequests, [firstRequest, secondRequest])
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
}

private struct CapturedPreviewCallback {
    let userdata: UnsafeMutableRawPointer?
    let callback: ghostty_surface_preview_image_callback_f
}
