import Network
import Foundation

/// There is no requestAuthorization-style API for Local Network access (TN3179);
/// the sanctioned trigger is advertising a Bonjour service and browsing for it,
/// which forces the system to raise the permission dialog on first use.
enum LocalNetworkPermission {
    private static var browser: NWBrowser?
    private static var listener: NWListener?

    static func trigger() {
        let type = "_busybar._tcp"  // must be listed in NSBonjourServices
        if let l = try? NWListener(using: .tcp) {
            l.service = NWListener.Service(name: "BusyBar", type: type)
            l.stateUpdateHandler = { _ in }
            l.newConnectionHandler = { $0.cancel() }
            l.start(queue: .main)
            listener = l
        }
        let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        b.stateUpdateHandler = { _ in }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            browser?.cancel(); listener?.cancel()
            browser = nil; listener = nil
        }
    }
}
