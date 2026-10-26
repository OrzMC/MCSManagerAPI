//
//  StreamEndpoint.swift
//  MCSMStream
//
//  把面板给的通道信息（`addr` + `prefix`）解析成一条可以直连的 socket.io WebSocket URL。
//
//  规则照抄面板前端 `frontend/src/tools/protocol.ts` 的 `parseForwardAddress`，
//  只保留我们用得到的部分：
//
//  - `addr` 带 `ws://` / `wss://` / `http://` / `https://` 时按它定协议，否则跟随面板自己的协议；
//  - `127.0.0.1` / `localhost` 开头的地址换成本面板的主机名（节点与面板常同机部署，
//    面板返回的就是节点视角的 `127.0.0.1:24444`，从客户端当然连不上）；
//  - socket.io 的路径是 `prefix + "/socket.io"`（`prefix` 只在节点配置了路径前缀时才非空，
//    面板 proxy 模式下为空）。
//

import Foundation
import MCSMAPI

public struct MCSMStreamEndpoint: Equatable, Sendable {

    /// 已经拼好的 WebSocket URL（含 `?EIO=4&transport=websocket`）。
    public let url: URL
    /// 一次性口令（`stream/auth` 要发的内容）。
    public let password: String

    public init(url: URL, password: String) {
        self.url = url
        self.password = password
    }
}

extension MCSMStreamEndpoint {

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        /// `addr` 里没有主机名，或拼出来的 URL 不合法。
        case invalidAddress(String)

        public var description: String {
            switch self {
            case let .invalidAddress(raw):
                return "面板返回的地址无法解析：\(raw)"
            }
        }
    }

    /// 由通道 + 面板地址算出连接目标。
    ///
    /// - Parameters:
    ///   - channel: 面板 `stream_channel` 的返回。
    ///   - panelURL: 用户在 app 里填的面板地址（用来决定 `ws`/`wss` 和回环地址的替换）。
    public init(channel: MCSMStreamChannel, panelURL: URL) throws {
        let resolved = Self.resolve(address: channel.address, prefix: channel.prefix, panelURL: panelURL)
        guard let resolved else { throw Error.invalidAddress(channel.address) }
        url = resolved
        password = channel.password
    }

    /// 解析核心（纯函数，单测直接打这里）。
    static func resolve(address rawAddress: String, prefix rawPrefix: String, panelURL: URL) -> URL? {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }

        // 1. 协议：显式写了就用写的，否则跟随面板（https → wss）。
        let lower = address.lowercased()
        var scheme = panelURL.scheme?.lowercased() == "http" ? "ws" : "wss"
        for (candidate, websocket) in [
            ("wss://", "wss"), ("ws://", "ws"), ("https://", "wss"), ("http://", "ws")
        ] where lower.hasPrefix(candidate) {
            scheme = websocket
            address = String(address.dropFirst(candidate.count))
            break
        }

        // 2. 拆 host / port / path（IPv6 这里不管：面板地址不会是 `[::1]`）。
        var path = ""
        if let slash = address.firstIndex(of: "/") {
            path = String(address[slash...])
            address = String(address[..<slash])
        }
        var host = address
        var port: String?
        if let colon = address.lastIndex(of: ":"), address[address.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(address[..<colon])
            port = String(address[address.index(after: colon)...])
        }

        // 3. 回环地址换成面板主机名（保留端口与路径）。
        let hostLower = host.lowercased()
        if hostLower == "localhost" || hostLower == "127.0.0.1" || hostLower.hasPrefix("127.0.0.") {
            guard let panelHost = panelURL.host, !panelHost.isEmpty else { return nil }
            host = panelHost
        }
        guard !host.isEmpty else { return nil }

        // 4. 拼 socket.io 路径：`prefix + "/socket.io"`。
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var socketPath = prefix.isEmpty ? "/socket.io" : "/\(prefix)/socket.io"
        if socketPath.hasSuffix("/") { socketPath.removeLast() }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = socketPath
        if let port, let value = Int(port) { components.port = value }
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        // `path` 只在使用 `prefix` 为空且地址自带路径时才有意义（面板不会这么给），忽略。
        _ = path
        return components.url
    }
}
