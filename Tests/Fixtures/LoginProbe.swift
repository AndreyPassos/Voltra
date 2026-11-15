import Foundation
import ServiceManagement

if CommandLine.arguments.contains("--cleanup") {
    do { try SMAppService.mainApp.unregister(); print("cleanup-ok") }
    catch { print("cleanup-not-needed-or-error: \(error.localizedDescription)") }
    exit(0)
}
do {
    try SMAppService.mainApp.register()
    let status = SMAppService.mainApp.status
    print("registered-status=\(status.rawValue)")
    try SMAppService.mainApp.unregister()
    print("unregistered-status=\(SMAppService.mainApp.status.rawValue)")
} catch {
    print("registration-test-error: \(error.localizedDescription)")
    try? SMAppService.mainApp.unregister()
    exit(1)
}
