//
//  LiveStreamTests.swift
//  MCSMStreamTests
//
//  **真实面板**的冒烟测试：默认跳过，只在给了环境变量时跑。用来回答两个只有真机能回答的问题：
//
//  1. `stream_channel` 在这个面板版本上返回什么形状（外壳 / 裸、`direct` 还是 `proxy` 模式）；
//  2. 节点/面板的 socket.io 到底连不连得上、`stream/auth` 会不会回 `true`。
//
//  用法（口令与实例由调用方给，**不要写进仓库**）：
//
//  ```
//  ORZMC_MCSM_LIVE_URL=https://mcs.example.com \
//  ORZMC_MCSM_LIVE_KEY=<面板 API Key> \
//  ORZMC_MCSM_LIVE_DAEMON=<daemonId> \
//  ORZMC_MCSM_LIVE_INSTANCE=<instanceUuid> \
//  swift test --filter LiveStreamTests
//  ```
//
//  预期：拿得到通道 → 连上 → `.ready`（实例在跑时还能收到 `instance/stdout`）。
//

import Foundation
import MCSMAPI
import Testing

@testable import MCSMStream

private struct LiveConfiguration {
    let panelURL: URL
    let apiKey: String
    let daemonID: String
    let instanceUUID: String

    static var fromEnvironment: LiveConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["ORZMC_MCSM_LIVE_URL"].flatMap(URL.init(string:)),
              let key = env["ORZMC_MCSM_LIVE_KEY"], !key.isEmpty,
              let daemon = env["ORZMC_MCSM_LIVE_DAEMON"], !daemon.isEmpty,
              let instance = env["ORZMC_MCSM_LIVE_INSTANCE"], !instance.isEmpty
        else { return nil }
        return LiveConfiguration(panelURL: url, apiKey: key, daemonID: daemon, instanceUUID: instance)
    }
}

@Suite("真实面板冒烟（需环境变量）", .serialized)
struct LiveStreamTests {

    @Test("申请通道 → 连 socket.io → stream/auth 通过", .enabled(if: LiveConfiguration.fromEnvironment != nil))
    func liveChannelAuthenticates() async throws {
        let config = try #require(LiveConfiguration.fromEnvironment)
        let client = MCSMClient.make(serverURL: config.panelURL, apiKey: config.apiKey)

        let output = try await client.getStreamChannel(
            query: .init(daemonId: config.daemonID, uuid: config.instanceUUID)
        )
        guard case .ok(let ok) = output else {
            Issue.record("stream_channel 未返回 200：\(output)")
            return
        }
        let channel = try #require(MCSMStreamChannel(ok.body.json), "面板没给通道信息")
        print("[live] addr=\(channel.address) prefix=\(channel.prefix) mappings=\(channel.remoteMappings.count)")

        let endpoint = try MCSMStreamEndpoint(channel: channel, panelURL: config.panelURL)
        print("[live] socket.io=\(endpoint.url.absoluteString)")

        let streamClient = MCSMStreamClient(
            configuration: .init(handshakeTimeout: .seconds(20), maxAttempts: 1)
        ) {
            endpoint
        }
        var sawReady = false
        var firstOutput: String?

        // 有界等待：实时流在"实例在跑但没有新输出"时会一直安静，不能无限等事件。
        let events = await streamClient.events()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .ready:
                        sawReady = true
                        // 连上之后立刻发一条**只读**命令：既验证双向通道（`stream/input`），
                        // 也顺带制造一段输出，免得"实例安静"时测试永远等不到 stdout。
                        try? await streamClient.sendCommand("/list")
                    case let .output(text):
                        if firstOutput == nil { firstOutput = text }
                    case let .fallback(reason):
                        print("[live] fallback=\(reason)")
                        Issue.record("实时流不可用：\(reason)")
                    case .connecting, .lifecycle:
                        break
                    }
                    if sawReady && firstOutput != nil { return }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(40))
            }
            await group.next()
            group.cancelAll()
        }
        await streamClient.close()
        print("[live] ready=\(sawReady) firstOutput=\(firstOutput?.prefix(120) ?? "(空)")")
        #expect(sawReady, "stream/auth 没有通过")
        #expect(firstOutput != nil, "发了 /list 却没收到任何实时输出")
    }
}
