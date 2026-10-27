//
//  StreamEndpointTests.swift
//  MCSMStreamTests
//
//  地址解析：规则来自面板前端 `parseForwardAddress`（见 StreamEndpoint.swift 的注释）。
//

import Foundation
import Testing

@testable import MCSMAPI
@testable import MCSMStream

@Suite("通道地址解析")
struct StreamEndpointTests {

    private func url(_ address: String, prefix: String = "", panel: String = "https://mcs.example.com") -> String? {
        MCSMStreamEndpoint.resolve(
            address: address,
            prefix: prefix,
            panelURL: URL(string: panel)!
        )?.absoluteString
    }

    @Test("proxy 模式：面板地址 + 空前缀 + https → wss")
    func proxyMode() {
        #expect(url("mcs.example.com") == "wss://mcs.example.com/socket.io/?EIO=4&transport=websocket")
    }

    @Test("direct 模式：节点给了端口")
    func directWithPort() {
        #expect(
            url("10.0.0.5:24444") == "wss://10.0.0.5:24444/socket.io/?EIO=4&transport=websocket"
        )
    }

    @Test("回环地址换成本面板的主机名（保留端口）")
    func loopbackBecomesPanelHost() {
        #expect(
            url("127.0.0.1:24444") == "wss://mcs.example.com:24444/socket.io/?EIO=4&transport=websocket"
        )
        #expect(
            url("localhost:24444") == "wss://mcs.example.com:24444/socket.io/?EIO=4&transport=websocket"
        )
        #expect(
            url("127.0.0.1") == "wss://mcs.example.com/socket.io/?EIO=4&transport=websocket"
        )
    }

    @Test("节点配了路径前缀（两侧斜杠都容忍）")
    func prefixPath() {
        #expect(
            url("10.0.0.5:24444", prefix: "/daemon/")
                == "wss://10.0.0.5:24444/daemon/socket.io/?EIO=4&transport=websocket"
        )
        #expect(
            url("10.0.0.5:24444", prefix: "daemon")
                == "wss://10.0.0.5:24444/daemon/socket.io/?EIO=4&transport=websocket"
        )
    }

    @Test("地址自带协议时以它为准")
    func explicitScheme() {
        #expect(
            url("ws://10.0.0.5:24444") == "ws://10.0.0.5:24444/socket.io/?EIO=4&transport=websocket"
        )
        #expect(
            url("http://10.0.0.5:24444") == "ws://10.0.0.5:24444/socket.io/?EIO=4&transport=websocket"
        )
        #expect(
            url("https://10.0.0.5:24444") == "wss://10.0.0.5:24444/socket.io/?EIO=4&transport=websocket"
        )
    }

    @Test("面板走 http 时用 ws")
    func insecurePanel() {
        #expect(
            url("mcs.example.com:81", panel: "http://mcs.example.com:81")
                == "ws://mcs.example.com:81/socket.io/?EIO=4&transport=websocket"
        )
    }

    @Test("空地址 / 空主机 → 解析失败")
    func invalidAddress() {
        #expect(url("") == nil)
        #expect(url("   ") == nil)
        #expect(MCSMStreamEndpoint.resolve(address: "", prefix: "", panelURL: URL(string: "https://x")!) == nil)
    }

    @Test("通道模型：带外壳与裸形状都能解")
    func channelFromResponse() throws {
        let payload = Components.Schemas.StreamChannelPayload(addr: "127.0.0.1:24444", password: "p1")
        let wrapped = Components.Schemas.StreamChannelResponse(status: 200, data: payload)
        let channel = try #require(MCSMStreamChannel(wrapped))
        #expect(channel.address == "127.0.0.1:24444")
        #expect(channel.password == "p1")
        #expect(channel.prefix == "")

        let bare = Components.Schemas.StreamChannelResponse(status: nil, addr: "a.example.com", password: "p2", prefix: "/node")
        #expect(MCSMStreamChannel(bare)?.prefix == "/node")

        let empty = Components.Schemas.StreamChannelResponse(status: 200)
        #expect(MCSMStreamChannel(empty) == nil)
    }

    @Test("通道模型：从 text/plain 的 JSON 文本也能解")
    func channelFromText() throws {
        let text = """
        {"status":200,"data":{"addr":"127.0.0.1:24444","password":"tok","prefix":"","remoteMappings":[]},"time":1}
        """
        let channel = try #require(MCSMStreamChannel(text: text))
        #expect(channel.address == "127.0.0.1:24444")
        #expect(channel.password == "tok")
        #expect(channel.remoteMappings.isEmpty)

        #expect(MCSMStreamChannel(text: "{\"status\":500,\"data\":\"节点未连接\"}") == nil)
        #expect(MCSMStreamChannel(text: "not json") == nil)
    }

    @Test("端点的 URL 与口令打包")
    func endpoint() throws {
        let channel = MCSMStreamChannel(address: "mcs.example.com", password: "tok")
        let endpoint = try MCSMStreamEndpoint(channel: channel, panelURL: URL(string: "https://mcs.example.com")!)
        #expect(endpoint.password == "tok")
        #expect(endpoint.url.scheme == "wss")
        #expect(endpoint.url.path == "/socket.io")
    }
}
