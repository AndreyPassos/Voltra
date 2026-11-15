import XCTest
@testable import Voltra
final class ApplicationIdentityTests: XCTestCase {
    func testNestedHelperResolvesContainingApp() {
        let url = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app")
        XCTAssertEqual(ApplicationIdentity.outermostAppURL(url)?.path, "/Applications/Browser.app")
    }
    func testNonApplicationPathDoesNotInventBundle() {
        XCTAssertNil(ApplicationIdentity.outermostAppURL(URL(fileURLWithPath: "/usr/bin/afplay")))
    }
    func testExecutableInHelperResolvesOuterBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Browser.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "example.browser", "CFBundleName": "Browser"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("Frameworks/Helper.app/Contents/MacOS/Helper")
        let identity = ApplicationIdentity.resolveExecutable(executable)
        XCTAssertEqual(identity?.id, "example.browser")
        XCTAssertEqual(identity?.name, "Browser")
        XCTAssertEqual(identity?.bundleURL.path, app.path)
    }
}
