import Foundation
import Network
import StorageCore

/// Serves Storage Spaces over HTTP (Network.framework): bytes in, the API, bytes out. One request per
/// connection. Taken from Peter (and Tool Mac Tool Run before him).
final class APIServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    /// On the main thread.
    var onState: ((State) -> Void)?

    private let api: StorageAPI
    private let queue = DispatchQueue(label: "StorageSpaces.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(api: StorageAPI) {
        self.api = api
    }

    /// Listens on 127.0.0.1 (or every interface, with `network`) at `port`.
    func start(port: Int, network: Bool) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            report(.failed("\(port) isn't a port"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if !network {
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        }
        let listener: NWListener
        do {
            listener = network ? try NWListener(using: params, on: nwPort) : try NWListener(using: params)
        } catch {
            report(.failed("Couldn't listen on port \(port): \(error.localizedDescription)"))
            return
        }
        report(.starting)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.report(.running(port: port))
            case .failed(let error):
                let inUse = "\(error)".contains("48") || "\(error)".lowercased().contains("in use")
                self.report(.failed(inUse ? "Port \(port) is in use by another app (is Storage Spaces open twice?)" : "Stopped: \(error.localizedDescription)"))
                listener.cancel()
                self.listener = nil
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        guard let listener else {
            report(.stopped)          // after a failure: the panel stops showing it
            return
        }
        self.listener = nil
        listener.cancel()
        queue.async {
            for c in self.connections.values { c.close() }
            self.connections = [:]
        }
        report(.stopped)
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { self.onState?(state) }
    }

    /// On the server's queue.
    private func accept(_ nw: NWConnection) {
        let c = Connection(nw, api: api, queue: queue)
        let key = ObjectIdentifier(c)
        connections[key] = c
        c.onClose = { [weak self] in self?.queue.async { self?.connections[key] = nil } }
        c.start()
    }
}

/// One client: reads its request, answers it, closes. A client that hangs up while it waits
/// (for a change, on /api/changes) has its request's work cancelled.
private final class Connection: ResponseWriter, @unchecked Sendable {
    private let nw: NWConnection
    private let api: StorageAPI
    private let queue: DispatchQueue
    private var parser = HTTPParser()
    private var work: Task<Void, Never>?
    private var closed = false
    var onClose: (() -> Void)?

    init(_ nw: NWConnection, api: StorageAPI, queue: DispatchQueue) {
        self.nw = nw
        self.api = api
        self.queue = queue
        parser.fromLoopback = Self.isLoopback(nw.endpoint)
        parser.peer = Self.address(nw.endpoint)
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    static func address(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return a.asIPv4.map { "\($0)" } ?? "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                do {
                    switch try self.parser.feed(data) {
                    case .more(let sendContinue):
                        if sendContinue { self.nw.send(content: HTTPResponse.continueLine, completion: .idempotent) }
                    case .done(let request):
                        self.answer(request)
                        self.watchForHangUp()
                        return
                    }
                } catch let e as HTTPError {
                    self.finish(JSON.response(["error": e.message, "code": e.code], status: e.status))
                    return
                } catch {
                    self.finish(JSON.response(["error": error.localizedDescription, "code": "bad_request"], status: 400))
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    /// Once the request is in: the client closing its side means it has gone.
    private func watchForHangUp() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            guard let self, !self.closed else { return }
            if isComplete || error != nil {
                self.close()
            } else {
                self.watchForHangUp()
            }
        }
    }

    private func answer(_ request: HTTPRequest) {
        work = Task { [weak self] in
            guard let self else { return }
            let response = await self.api.route(request)
            await self.send(response, head: request.method != "HEAD")
        }
    }

    private func send(_ response: HTTPResponse, head includeBody: Bool) async {
        switch response.body {
        case .data(let data):
            var out = response.head()
            if includeBody { out.append(data) }
            await sendLast(out)
        case .stream(let make):
            do {
                try await write(response.head(), framed: false)
                try await make(self)
                await sendLast(HTTPResponse.lastChunk)
            } catch {
                close()          // the client went, or making it failed part way: nothing more to say
            }
        }
    }

    /// ResponseWriter: one chunk of a streamed body.
    func write(_ data: Data) async throws {
        try await write(data, framed: true)
    }

    private func write(_ data: Data, framed: Bool) async throws {
        guard !data.isEmpty else { return }
        if closed { throw WriterGone() }
        let bytes = framed ? HTTPResponse.chunk(data) : data
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            nw.send(content: bytes, completion: .contentProcessed { error in
                if error != nil { done.resume(throwing: WriterGone()) } else { done.resume() }
            })
        }
    }

    private func sendLast(_ data: Data) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            nw.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                done.resume()
            })
        }
        close()
    }

    private func finish(_ response: HTTPResponse) {
        Task { await send(response, head: true) }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            work?.cancel()
            nw.cancel()
            onClose?()
        }
    }
}
