//
//  MCSMStreamClient.swift
//  MCSMStream
//
//  面板控制台的**实时输出流**客户端（Engine.IO v4 + Socket.IO v5 的最小子集，走
//  `URLSessionWebSocketTask`，不引第三方依赖）。
//
//  为什么自己写：面板只有 JS 的 `socket.io-client`；iOS/macOS 侧没有官方 Swift 包，
//  而我们需要的只有"连上 → 发一句 stream/auth → 收 instance/stdout 文本"这么点东西。
//  协议本身十来行，自己实现比引一个没人维护的封装更可控（且能单测）。
//
//  取消/重连的语义：
//  - 口令是**一次性的**，所以每次重连都要重新申请通道 → 客户端拿的是一个 `makeEndpoint`
//    闭包，而不是一个固定 URL；
//  - 重试用指数退避，全部失败后**不报错崩溃**，而是发 `.fallback`，由调用方退回轮询
//    （面板 `dataPlane=direct` 且节点在 NAT 后面时，直连本来就不可达，这是正常情况）。
//

import Foundation
import MCSMAPI

public actor MCSMStreamClient {

    // MARK: - 对外事件

    public enum Event: Sendable, Equatable {
        /// 第 n 次尝试（1 起）：正在申请通道 / 建立连接。
        case connecting(attempt: Int)
        /// 鉴权通过，`stream/auth` 回了 `true` —— 从现在起可以收实时输出。
        case ready
        /// 一段终端输出（原样文本，可能不带换行；交给 `ConsoleTextParser` 处理）。
        case output(String)
        /// 实例生命周期：`opened` / `stopped` / `failure`。
        case lifecycle(String)
        /// 放弃实时流（附原因），调用方应回退轮询。
        case fallback(reason: String)
    }

    public struct Configuration: Sendable {
        /// 等 `stream/auth` 回来的上限；超时按本次失败处理（口令一次性，重连会重新申请）。
        public var handshakeTimeout: Duration
        /// 最多尝试几次（含首次）。
        public var maxAttempts: Int
        /// 首次退避间隔，之后每次翻倍。
        public var backoff: Duration

        public init(handshakeTimeout: Duration = .seconds(15),
                    maxAttempts: Int = 3,
                    backoff: Duration = .milliseconds(600)) {
            self.handshakeTimeout = handshakeTimeout
            self.maxAttempts = maxAttempts
            self.backoff = backoff
        }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case timeout
        case rejected
        case closed
        case badResponse(String)

        public var description: String {
            switch self {
            case .timeout: return "等待面板响应超时"
            case .rejected: return "面板拒绝了这个口令"
            case .closed: return "连接被关闭"
            case let .badResponse(text): return "面板返回了意外内容：\(text.prefix(80))"
            }
        }
    }

    // MARK: - 状态

    private let makeEndpoint: @Sendable () async throws -> MCSMStreamEndpoint
    private let session: URLSession
    private let configuration: Configuration

    private var task: URLSessionWebSocketTask?
    private var isReady = false
    private var stopped = false

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = URLSession(configuration: .ephemeral),
        makeEndpoint: @escaping @Sendable () async throws -> MCSMStreamEndpoint
    ) {
        self.configuration = configuration
        self.session = session
        self.makeEndpoint = makeEndpoint
    }

    // MARK: - 生命周期

    /// 连接并持续产出事件流。返回的流结束 = 已放弃实时流（最后一条是 `.fallback`）。
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let runner = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.run(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                runner.cancel()
                Task { await self.close() }
            }
        }
    }

    /// 主动关闭（界面退出 / 切走时调用）。
    public func close() {
        stopped = true
        if let task {
            // 先打个招呼再断，服务端能立刻回收订阅。
            task.send(.string(SocketIOFrame.disconnectPacket)) { _ in }
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
        isReady = false
    }

    /// 通过实时流发一条控制台命令（面板会当成 `instance.execPreset("command", …)`）。
    /// 没连上时抛 `Failure.closed`，调用方回退 HTTP 接口。
    public func sendCommand(_ command: String) async throws {
        guard let task, isReady else { throw Failure.closed }
        let payload = SocketIOFrame.event("stream/input", data: ["command": command])
        try await task.send(.string(payload))
    }

    // MARK: - 主循环

    private func run(_ continuation: AsyncStream<Event>.Continuation) async {
        var attempt = 0
        var delay = configuration.backoff
        var lastReason = ""
        while !stopped, attempt < maxAttemptsSafe {
            attempt += 1
            continuation.yield(.connecting(attempt: attempt))
            do {
                try await connectOnce(continuation)
                // `connectOnce` 正常返回 = 服务端主动结束（实例停了 / 面板重启），
                // 不当作失败，直接结束（界面会靠状态刷新得知）。
                return
            } catch {
                if stopped || Task.isCancelled { return }
                lastReason = (error as? CustomStringConvertible)?.description ?? "\(error)"
            }
            if attempt < maxAttemptsSafe {
                try? await Task.sleep(for: delay)
                delay = delay * 2
            }
        }
        guard !stopped else { return }
        continuation.yield(.fallback(reason: lastReason.isEmpty ? "实时流不可用" : lastReason))
    }

    private var maxAttemptsSafe: Int { max(1, configuration.maxAttempts) }

    /// 一次完整连接：申请通道 → WS 握手 → `stream/auth` → 转发输出，直到断开。
    private func connectOnce(_ continuation: AsyncStream<Event>.Continuation) async throws {
        let endpoint = try await makeEndpoint()

        let socket = session.webSocketTask(with: endpoint.url)
        task = socket
        isReady = false
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if task === socket { task = nil }
            isReady = false
        }

        var handshakeDeadline: Task<Void, Never>?

        while !stopped {
            let message = try await receive(on: socket, timeout: handshakeTimeoutIfNeeded())
            handshakeDeadline?.cancel()
            handshakeDeadline = nil

            switch message {
            case let .string(text):
                let frame = SocketIOFrame.decode(text)
                switch frame {
                case .open:
                    try await socket.send(.string(SocketIOFrame.connectPacket))
                case .connected:
                    let auth = SocketIOFrame.event("stream/auth", data: ["password": endpoint.password])
                    try await socket.send(.string(auth))
                    // 鉴权回来之前先挂个超时，避免"连上了但永远没 auth"。
                    let timeout = configuration.handshakeTimeout
                    handshakeDeadline = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard let self, await self.isNotReady else { return }
                        await self.cancelSocket(socket)
                    }
                case .ping:
                    try await socket.send(.string(SocketIOFrame.pongPacket))
                case .close, .disconnected:
                    if isReady { return }
                    throw Failure.closed
                case let .connectError(detail):
                    throw Failure.badResponse(detail)
                case let .event(name, _):
                    if case let accepted? = frame.authAccepted {
                        guard accepted else { throw Failure.rejected }
                        isReady = true
                        handshakeDeadline?.cancel()
                        handshakeDeadline = nil
                        continuation.yield(.ready)
                        // 顺便要一次实例详情（面板会把状态/配置推回来，用于顶部状态行）。
                        try await socket.send(.string(SocketIOFrame.event("stream/detail", data: [:])))
                        continue
                    }
                    if let text = frame.stdoutText {
                        continuation.yield(.output(text))
                        continue
                    }
                    if let lifecycle = frame.instanceLifecycle {
                        continuation.yield(.lifecycle(lifecycle))
                        continue
                    }
                    _ = name
                case .pong, .unknown:
                    break
                }
            case .data:
                // 面板只发文本；二进制帧直接忽略。
                break
            @unknown default:
                break
            }
        }
        handshakeDeadline?.cancel()
    }

    private var isNotReady: Bool { !isReady }

    private func cancelSocket(_ socket: URLSessionWebSocketTask) {
        socket.cancel(with: .goingAway, reason: nil)
    }

    /// 握手阶段的每次 `receive` 都带超时；连上之后无限等（服务端会自己 ping）。
    private func handshakeTimeoutIfNeeded() -> Duration? {
        isReady ? nil : configuration.handshakeTimeout
    }

    private func receive(
        on socket: URLSessionWebSocketTask,
        timeout: Duration?
    ) async throws -> URLSessionWebSocketTask.Message {
        guard let timeout else { return try await socket.receive() }
        return try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await socket.receive() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            guard let message = try await group.next() else { throw Failure.timeout }
            return message
        }
    }
}
