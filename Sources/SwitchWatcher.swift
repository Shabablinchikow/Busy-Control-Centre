import Foundation

/// Where the bar's physical switch is, straight from the device.
///
/// Priority cannot answer this. The Apps and Settings screens are scenes of the
/// bar's own busy app, which sits at PASSTHROUGH the whole time the switch is
/// anywhere but a running session — so a draw is accepted at Apps exactly as it
/// is at Off, and a widget happily paints over the bar's own menu.
///
/// The device does publish the switch, though: `/api/status/ws` streams protobuf
/// `BSB_State.State` messages, and a flick of the switch arrives as
/// `StateUpdate.input.switch_event.position`. That is what this watches.
enum SwitchPosition: Int {
    case busy = 0, custom = 1, off = 2, apps = 3, settings = 4

    /// Anything but Off means the bar is showing a screen of its own.
    var isOff: Bool { self == .off }

    var name: String {
        switch self {
        case .busy: return "Busy"
        case .custom: return "Custom"
        case .off: return "Off"
        case .apps: return "Apps"
        case .settings: return "Settings"
        }
    }
}

/// Reads just enough protobuf to dig one field out of a message. The schema is
/// public (busy-app/busybar-protobuf) and the path never changes, so a full
/// decoder would be a dependency bought for four field numbers.
enum Proto {
    /// Wire-format fields as (number, payload) pairs; only the two types that
    /// appear on this path are kept — varints and length-delimited messages.
    static func fields(_ data: Data) -> [(number: Int, varint: UInt64, bytes: Data)] {
        var out: [(Int, UInt64, Data)] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let (key, next) = varint(data, i) else { return out }
            i = next
            let number = Int(key >> 3), wire = key & 0x7
            switch wire {
            case 0:
                guard let (value, after) = varint(data, i) else { return out }
                out.append((number, value, Data()))
                i = after
            case 2:
                guard let (len, after) = varint(data, i),
                      after + Int(len) <= data.endIndex else { return out }
                out.append((number, 0, data[after..<(after + Int(len))]))
                i = after + Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return out
            }
        }
        return out
    }

    static func varint(_ data: Data, _ start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0, shift: UInt64 = 0, i = start
        while i < data.endIndex {
            let byte = data[i]
            value |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// The switch position carried by a `BSB_State.State` message, if it carries
    /// one: State.updates(2) → StateUpdate.input(11) → InputEvent.switch_event(2)
    /// → SwitchEvent.position(1).
    static func switchPosition(in state: Data) -> SwitchPosition? {
        for update in fields(state) where update.number == 2 {
            for input in fields(update.bytes) where input.number == 11 {
                for event in fields(input.bytes) where event.number == 2 {
                    for position in fields(event.bytes) where position.number == 1 {
                        return SwitchPosition(rawValue: Int(position.varint))
                    }
                }
            }
        }
        return nil
    }
}

/// Keeps a WebSocket to the bar open and reports every flick of the switch.
///
/// Reconnects for as long as it runs; the bar drops the connection on its own
/// schedule and a widget that stopped pausing because a socket died would be
/// worse than one that never paused at all.
@MainActor
final class SwitchWatcher {
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    /// Its own session: the shared one is pinned to a single connection per host
    /// for the draw traffic, and a socket parked on it would block every draw.
    private static let session = URLSession(configuration: .ephemeral)

    func start(host: String, token: String?) {
        stop()
        task = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                let ok = await self?.connect(host: host, token: token) ?? false
                if Task.isCancelled { return }
                backoff = ok ? 1 : min(30, backoff * 2)
                _ = await barSleep(backoff)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// One connection's lifetime. Returns true if it ever became usable, which is
    /// all the backoff needs to know.
    private func connect(host: String, token: String?) async -> Bool {
        guard let url = URL(string: "ws://\(host)/api/status/ws") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-API-Token") }
        let socket = Self.session.webSocketTask(with: req)
        self.socket = socket
        socket.resume()

        // Streaming is opt-in; without this the bar sends nothing.
        do {
            try await socket.send(.string(#"{"enable": true}"#))
        } catch {
            socket.cancel(with: .abnormalClosure, reason: nil)
            return false
        }

        BarState.shared.noteReconnected()

        var alive = false
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                alive = true
                guard case .data(let payload) = message else { continue }
                if let position = Proto.switchPosition(in: payload) {
                    barLog.info("switch -> \(position.name, privacy: .public)")
                    BarState.shared.note(switch: position)
                }
            } catch {
                break
            }
        }
        socket.cancel(with: .goingAway, reason: nil)
        return alive
    }
}
