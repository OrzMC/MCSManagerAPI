//
//  MCSMStreamClientTests.swift
//  MCSMStreamTests
//
//  端到端：真 WebSocket（本地假面板）↔ `MCSMStreamClient`。
//

import Foundation
import MCSMAPI
import Testing

@testable import MCSMStream

@Suite("实时流客户端（本地假面板）", .serialized)
struct MCSMStreamClientTests {

    private func endpoint(_ port: UInt16, password: String = "tok") -> MCSMStreamEndpoint {
        let channel = MCSMStreamChannel(address: "127.0.0.1:\(port)", password: password)
        // 回环地址会被换成本面板主机名，这里让面板就是 127.0.0.1，正好保持直连。
        return MCSMStreamEndpoint(
            url: MCSMStreamEndpoint.resolve(
                address: channel.address,
                prefix: "",
                panelURL: URL(string: "http://127.0.0.1")!
            )!,
            password: channel.password
        )
    }

    /// 收事件直到满足条件或超时；返回期间收到的所有事件。
    private func collect(
        _ stream: AsyncStream<MCSMStreamClient.Event>,
        until condition: @escaping (MCSMStreamClient.Event) -> Bool,
        timeout: Duration = .seconds(8)
    ) async -> [MCSMStreamClient.Event] {
        await withTaskGroup(of: [MCSMStreamClient.Event]?.self) { group in
            group.addTask {
                var events: [MCSMStreamClient.Event] = []
                for await event in stream {
                    events.append(event)
                    if condition(event) { return events }
                }
                return events
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    @Test("鉴权通过后能收到实时输出")
    func receivesOutput() async throws {
        let server = try FakeSocketIOServer(script: .init(
            expectedPassword: "tok",
            stdoutAfterAuth: ["[12:00:00] Done (1.2s)!\r\n", "[12:00:01] [Server thread/INFO]: 世界已保存\r\n"]
        ))
        defer { server.stop() }

        let client = MCSMStreamClient(configuration: .init(maxAttempts: 1)) {
            self.endpoint(server.port)
        }
        let events = await collect(await client.events()) { event in
            if case .output = event { return true }
            return false
        }
        await client.close()

        #expect(events.contains(.ready))
        #expect(events.contains(.output("[12:00:00] Done (1.2s)!\r\n")))
        // 服务端确实收到了 `stream/auth` 与 `stream/detail`
        let frames = server.frames
        #expect(frames.contains { $0.hasPrefix("42[\"stream/auth\"") })
        #expect(frames.contains { $0.hasPrefix("42[\"stream/detail\"") })
    }

    @Test("口令被拒：重试用尽后落到 .fallback（调用方回退轮询）")
    func rejectsWrongPassword() async throws {
        let server = try FakeSocketIOServer(script: .init(expectedPassword: "right"))
        defer { server.stop() }

        let client = MCSMStreamClient(configuration: .init(maxAttempts: 2, backoff: .milliseconds(50))) {
            self.endpoint(server.port, password: "wrong")
        }
        let events = await collect(await client.events()) { event in
            if case .fallback = event { return true }
            return false
        }
        await client.close()

        #expect(events.contains { if case .fallback = $0 { return true } else { return false } })
        #expect(!events.contains(.ready))
        #expect(!events.contains { if case .connecting(attempt: 1) = $0 { return true } else { return false } } == false)
    }

    @Test("服务端 ping 要回 pong（否则面板 25 秒后踢连接）")
    func repliesToPing() async throws {
        let server = try FakeSocketIOServer(script: .init(stdoutAfterAuth: ["hello"], pingAfterOpen: true))
        defer { server.stop() }

        let client = MCSMStreamClient(configuration: .init(maxAttempts: 1)) {
            self.endpoint(server.port)
        }
        _ = await collect(await client.events()) { event in event == .ready }
        // 给 pong 一点时间回到服务端
        try await Task.sleep(for: .milliseconds(300))
        await client.close()
        #expect(server.frames.contains("3"))
    }

    @Test("实例退出事件透传为 .lifecycle")
    func forwardsLifecycle() async throws {
        let server = try FakeSocketIOServer(script: .init(stdoutAfterAuth: ["bye"], stopAfterAuth: true))
        defer { server.stop() }

        let client = MCSMStreamClient(configuration: .init(maxAttempts: 1)) {
            self.endpoint(server.port)
        }
        let events = await collect(await client.events()) { $0 == .lifecycle("stopped") }
        await client.close()
        #expect(events.contains(.lifecycle("stopped")))
    }

    @Test("连不上时重试用尽 → .fallback，不崩不卡")
    func serverUnreachable() async throws {
        // 拿一个刚被释放的端口，连上去必然失败。
        let port = try await {
            let server = try FakeSocketIOServer(script: .init())
            let value = server.port
            server.stop()
            return value
        }()

        let client = MCSMStreamClient(configuration: .init(maxAttempts: 2, backoff: .milliseconds(50))) {
            self.endpoint(port)
        }
        let events = await collect(await client.events(), until: { event in
            if case .fallback = event { return true }
            return false
        }, timeout: .seconds(20))
        await client.close()
        #expect(events.contains { if case .fallback = $0 { return true } else { return false } })
    }
}
