//
//  FakeSocketIOServer.swift
//  MCSMStreamTests
//
//  一个**真的 WebSocket 服务端**（Network.framework 的 `NWProtocolWebSocket`），只实现面板终端
//  用得到的那几帧。这样 `MCSMStreamClient` 是被端到端跑过的：握手 → `stream/auth` → 输出 →
//  心跳 → 断开，而不是只测"帧字符串拼得对不对"。
//
//  为什么不用 JS 的 socket.io 起假服务：`swift test` 要在 CI 上跑，不能假设有 node/npm。
//

import Foundation
import Network
import os

@testable import MCSMStream

/// 假面板节点的行为：收到 `stream/auth` 后怎么答、答完发什么。
struct FakeSocketIOScript {
    /// 期望的口令；`nil` = 无论收到什么都答 `true`。
    var expectedPassword: String? = "tok"
    /// 鉴权通过后依次推送的 `instance/stdout` 文本。
    var stdoutAfterAuth: [String] = []
    /// 鉴权通过后是否推一条 `instance/stopped`（模拟实例退出）。
    var stopAfterAuth = false
    /// 握手后立刻发一个 Engine.IO ping（验证客户端会回 pong）。
    var pingAfterOpen = false
}

final class FakeSocketIOServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-socketio")
    private let script: FakeSocketIOScript

    /// 服务端收到的客户端帧（测试断言用）。
    private let lock = NSLock()
    private var receivedFrames: [String] = []
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0

    init(script: FakeSocketIOScript) throws {
        self.script = script
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let assigned = listener.port else {
            listener.cancel()
            throw NSError(domain: "FakeSocketIOServer", code: 1)
        }
        port = assigned.rawValue
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    /// 客户端发过来的帧（去掉时间顺序问题的快照）。
    var frames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return receivedFrames
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        // Engine.IO：连上先由服务端发 open 包。
        send(#"0{"sid":"fake","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#, on: connection)
        if script.pingAfterOpen {
            send("2", on: connection)
        }
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                self.handle(text, on: connection)
            }
            _ = context
            self.receiveLoop(on: connection)
        }
    }

    private func handle(_ text: String, on connection: NWConnection) {
        lock.lock(); receivedFrames.append(text); lock.unlock()
        switch SocketIOFrame.decode(text) {
        case .connected:
            send(#"40{"sid":"fake-ns"}"#, on: connection)
        case .pong:
            break
        case let .event(name, _):
            switch name {
            case "stream/auth":
                let authData = SocketIOFrame.decode(text).value(forKey: "data") as? [String: Any]
                let password = authData?["password"] as? String
                let ok = script.expectedPassword == nil || password == script.expectedPassword
                send(SocketIOFrame.event("stream/auth", data: ok), on: connection)
                guard ok else { return }
                for text in script.stdoutAfterAuth {
                    let payload: [String: Any] = ["data": ["instanceUuid": "inst-1", "text": text]]
                    send(SocketIOFrame.event("instance/stdout", data: payload["data"]), on: connection)
                }
                if script.stopAfterAuth {
                    send(SocketIOFrame.event("instance/stopped", data: ["instanceUuid": "inst-1"]), on: connection)
                }
            case "stream/detail":
                send(SocketIOFrame.event("stream/detail", data: ["status": 3]), on: connection)
            default:
                break
            }
        default:
            break
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}
