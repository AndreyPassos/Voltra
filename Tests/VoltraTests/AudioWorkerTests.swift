import XCTest
@testable import Voltra
final class AudioWorkerTests: XCTestCase {
    func testBlockedAudioStartupDoesNotBlockCaller() {
        let worker = AudioWorker()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "started")
        let completed = expectation(description: "completed")
        worker.run({ started.fulfill(); gate.wait(); return 7 }) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), 7)
            completed.fulfill()
            return true
        }
        wait(for: [started], timeout: 2)
        gate.signal()
        wait(for: [completed], timeout: 2)
    }
    func testBlockedStartReportsTimeoutAndStillFinishesOnce() {
        let worker = AudioWorker()
        let gate = DispatchSemaphore(value: 0)
        let timedOut = expectation(description: "timeout reported")
        let completed = expectation(description: "later completion")
        worker.run({ gate.wait(); return 9 }, timeout: 0.05, onTimeout: { timedOut.fulfill() }) { result in
            XCTAssertEqual(try? result.get(), 9)
            completed.fulfill()
            return true
        }
        wait(for: [timedOut], timeout: 1)
        gate.signal()
        wait(for: [completed], timeout: 2)
    }
    func testCompletedStartDoesNotReportTimeout() {
        let worker = AudioWorker()
        let timedOut = expectation(description: "no timeout"); timedOut.isInverted = true
        let completed = expectation(description: "completed")
        worker.run({ 1 }, timeout: 0.05, onTimeout: { timedOut.fulfill() }) { _ in completed.fulfill(); return true }
        wait(for: [completed, timedOut], timeout: 0.2)
    }
    func testDiscardedStartIsCleanedBeforeNextStart() {
        let worker = AudioWorker()
        var order: [String] = []
        let done = expectation(description: "next completed")
        worker.run({ 1 }, discard: { _ in order.append("cleanup") }) { _ in false }
        worker.run({ order.append("next"); return 2 }) { _ in done.fulfill(); return true }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(order, ["cleanup", "next"])
    }
    func testObsoleteQueuedStartIsSkippedBeforeNewStart() {
        let worker = AudioWorker()
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "first started")
        let finished = expectation(description: "latest finished")
        var obsoleteRan = false
        worker.run({ started.fulfill(); gate.wait(); return 1 }) { _ in true }
        wait(for: [started], timeout: 2)
        worker.run({ obsoleteRan = true; return 2 }, shouldStart: { false }) { _ in XCTFail("Obsolete work should not complete"); return false }
        worker.run({ 3 }) { _ in finished.fulfill(); return true }
        gate.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertFalse(obsoleteRan)
    }
    func testRecoveryClearsOnlyItsOwnStallWarning() {
        let suite = "VoltraStallWarning-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var control = AppControlPreferences(); control.automatic = false; control.save(to: defaults)
        let service = AudioService(defaults: defaults, startTimer: false)
        let first = ActiveApp(id: "first", name: "First", processes: [])
        let second = ActiveApp(id: "second", name: "Second", processes: [])
        service.reportStalledStart(first)
        XCTAssertNotNil(service.error)
        service.clearStalledWarning(for: second.id)
        XCTAssertNotNil(service.error)
        service.clearStalledWarning(for: first.id)
        XCTAssertNil(service.error)
        service.reportStalledStart(first)
        service.error = "Unrelated failure"
        service.clearStalledWarning(for: first.id)
        XCTAssertEqual(service.error, "Unrelated failure")
    }

}
