import Foundation
import Network
import PixelMenuBarCore

/// Loopback-only HTTP listener for `POST /api/hooks/claude`, the same endpoint the
/// pixel-agents hook script posts to. Parsing and auth live in PixelMenuBarCore.
final class HookServer {
    private let handler: HookRequestHandler
    private let queue = DispatchQueue(label: "pixel-menubar.hook-server")
    private var listener: NWListener?
    /// Called on the main queue.
    private let onHook: (NormalizedHook) -> Void

    /// Connections that have not sent a full request after this long are dropped.
    private static let connectionTimeout: TimeInterval = 5

    init(token: String, onHook: @escaping (NormalizedHook) -> Void) {
        handler = HookRequestHandler(token: token)
        self.onHook = onHook
    }

    /// Starts listening on an OS-assigned loopback port; `ready` gets the port.
    func start(ready: @escaping (Result<Int, Error>) -> Void) {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params)
            self.listener = listener

            var reported = false
            listener.stateUpdateHandler = { state in
                guard !reported else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        reported = true
                        ready(.success(Int(port)))
                    }
                case let .failed(error):
                    reported = true
                    ready(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        } catch {
            ready(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch HTTPRequestParser.parse(buffer) {
            case let .request(request):
                let response = self.handler.handle(request)
                self.respond(response.status, on: connection, timeout: timeout)
                if let hook = response.hook {
                    DispatchQueue.main.async { self.onHook(hook) }
                }
            case let .reject(status):
                self.respond(status, on: connection, timeout: timeout)
            case .needMore:
                if error != nil || isComplete {
                    timeout.cancel()
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer, timeout: timeout)
                }
            }
        }
    }

    private func respond(_ status: Int, on connection: NWConnection, timeout: DispatchWorkItem) {
        timeout.cancel()
        let head = "\(httpStatusLine(status))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address): return address.isLoopback
        case let .ipv6(address): return address.isLoopback
        default: return false
        }
    }
}
