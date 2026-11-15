import AppKit
import Foundation
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let sound = NSSound(contentsOfFile: CommandLine.arguments[1], byReference: true)!
sound.loops = true
sound.play()
application.run()
