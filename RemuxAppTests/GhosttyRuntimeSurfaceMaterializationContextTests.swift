import GhosttyKit
import XCTest
@testable import Remux

@MainActor
final class GhosttyRuntimeSurfaceMaterializationContextTests: XCTestCase {
    func testScrollContainerOwnsAttachedSurfaceUntilDetach() {
        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var managed: GhosttyManagedSurface? = Self.managedSurface()
        let weakManaged = WeakBox(managed)

        container.update(
            surface: managed!,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )
        managed = nil

        XCTAssertNotNil(weakManaged.value)
        container.detachCurrentSurfaceForRemoval()
        XCTAssertNil(weakManaged.value)
    }

    func testScrollContainerDetachCurrentSurfaceForRemovalClearsAttachedSurface() {
        let container = GhosttyPaneScrollContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let managed = Self.managedSurface()

        _ = container.update(
            surface: managed,
            displayScale: 2,
            submitRouteForwardedMouseScroll: nil,
            submitRouteForwardedMousePosition: nil
        )

        XCTAssertTrue(managed.view.superview != nil)
        XCTAssertNotNil(managed.onScrollStateChange)
        XCTAssertFalse(managed.view.isHidden)

        container.detachCurrentSurfaceForRemoval()
        container.detachCurrentSurfaceForRemoval()

        XCTAssertNil(managed.view.superview)
        XCTAssertNil(managed.onScrollStateChange)
        XCTAssertTrue(managed.view.isHidden)
    }

    private final class WeakBox<T: AnyObject> {
        weak var value: T?

        init(_ value: T?) {
            self.value = value
        }
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
}
