import AppKit
import KDXClassicUI

let application = NSApplication.shared
let delegate = ClassicApplication()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
