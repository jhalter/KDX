import AppKit
import KDXClassicUI

@main
enum KDXClientMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ClassicApplication(applicationName: "KDX Client")
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
