import AppKit
import SwiftUI
import XCTest
@testable import Voltra

final class CompactViewTests: XCTestCase {
    func testActiveApplicationsReserveVisibleSpaceInMenu() {
        _ = NSApplication.shared
        let suite = "VoltraCompactLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences()
        control.automatic = false
        control.save(to: defaults)
        let audio = AudioService(defaults: defaults, startTimer: false)
        audio.activeApps = []
        let empty = NSHostingView(rootView: CompactView().environmentObject(audio).frame(width: 340))
        let emptyHeight = empty.fittingSize.height
        let app = ActiveApp(id: "com.example.audio", name: "Example", processes: [])
        audio.activeApps = [app]
        audio.controlledApps = [app.id]
        let active = NSHostingView(rootView: CompactView().environmentObject(audio).frame(width: 340))
        XCTAssertGreaterThanOrEqual(active.fittingSize.height - emptyHeight, 150,
                                    "The menu needs space for the app row and its controls")
    }
    func testManyApplicationsCanScrollWithinBoundedMenu() throws {
        _ = NSApplication.shared
        let suite = "VoltraCompactScroll-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let audio = AudioService(defaults: defaults, startTimer: false)
        audio.activeApps = (0..<12).map { ActiveApp(id: "com.example.\($0)", name: "Application \($0)", processes: []) }
        audio.controlledApps = Set(audio.activeApps.map(\.id))
        let view = NSHostingView(rootView: CompactView().environmentObject(audio).frame(width: 340))
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height,
                             "All application controls must be reachable by scrolling")
        let end = document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "The list must scroll to the end")
    }
}
