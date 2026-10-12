import AppKit
import KDXClientUI

@main enum KDXServerMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ClassicServerApplication()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
