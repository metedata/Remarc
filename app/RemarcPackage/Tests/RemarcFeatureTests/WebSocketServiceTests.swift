import Foundation
import Testing
@testable import RemarcFeature

@MainActor
@Suite("WebSocketService multi-client", .serialized)
struct WebSocketServiceTests {
    private final class TestWebSocketClient {
        private let session: URLSession
        let task: URLSessionWebSocketTask

        init(port: UInt16) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 2

            session = URLSession(configuration: configuration)

            let url = URL(string: "ws://127.0.0.1:\(port)")!
            task = session.webSocketTask(with: url)
            task.resume()
        }

        func cancel() {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        deinit {
            cancel()
        }
    }

    /// Wait until `condition` returns true, polling every 50ms, up to `timeout`.
    private func waitFor(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let start = ContinuousClock().now
        while !condition() {
            if ContinuousClock().now - start > timeout { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Start the singleton server on an OS-assigned port, return the bound port.
    private func startOnEphemeralPort() async -> UInt16 {
        let service = WebSocketService.shared
        service.stop()
        service.start(port: 0)
        await waitFor { service.boundPort != nil }
        return service.boundPort ?? 0
    }

    private func makeClient(port: UInt16) -> TestWebSocketClient {
        TestWebSocketClient(port: port)
    }

    private func sendNoOpMessage(_ client: TestWebSocketClient) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.task.send(.string(#"{"type":"tabActivity","data":{}}"#)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    @Test("two simultaneous clients both stay connected")
    func twoClientsCoexist() async throws {
        let port = await startOnEphemeralPort()
        #expect(port != 0)

        let clientA = makeClient(port: port)
        let clientB = makeClient(port: port)
        defer {
            clientA.cancel()
            clientB.cancel()
            WebSocketService.shared.stop()
        }

        // Server reports a client connected once any TCP+WS handshake completes.
        await waitFor { WebSocketService.shared.isClientConnected }
        #expect(WebSocketService.shared.isClientConnected)

        // Send a no-op application message from each client and confirm sends complete
        // without error. The server ignores tabActivity, but a completed send proves
        // the connection is still open.
        try await sendNoOpMessage(clientA)
        try await sendNoOpMessage(clientB)
    }

    @Test("disconnecting one client leaves others connected")
    func oneClientDisconnectKeepsOthers() async throws {
        let port = await startOnEphemeralPort()
        #expect(port != 0)

        let clientA = makeClient(port: port)
        let clientB = makeClient(port: port)
        defer {
            clientA.cancel()
            clientB.cancel()
            WebSocketService.shared.stop()
        }

        await waitFor { WebSocketService.shared.isClientConnected }

        // Make both handshakes observable before testing single-client teardown.
        try await sendNoOpMessage(clientA)
        try await sendNoOpMessage(clientB)

        clientA.cancel()

        // Give the server time to process the disconnect.
        try? await Task.sleep(for: .milliseconds(300))

        // Server should still report connected because clientB is alive.
        #expect(WebSocketService.shared.isClientConnected)

        // clientB should still be able to write after clientA disconnects.
        try await sendNoOpMessage(clientB)
    }
}
