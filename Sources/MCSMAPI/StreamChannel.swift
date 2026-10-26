//
//  StreamChannel.swift
//  MCSMAPI
//
//  `POST /api/protected_instance/stream_channel` 的**业务视图**：把生成的响应模型
//  （带/不带 `{status,data,time}` 外壳两种形状）抹平成"连哪、用什么口令"。
//
//  为什么需要这层：面板 direct / proxy 两种 `dataPlane` 返回的 `addr` 含义不同
//  （节点地址 / 面板自身地址），但客户端接下来要做的事**完全一样** ——
//  连 `addr` + `prefix`，发 `stream/auth`。所以这里只做归一化，不做模式判断。
//

import Foundation

/// 一条控制台实时流通道。
public struct MCSMStreamChannel: Equatable, Sendable {

    /// `host[:port]` 或 `ws(s)://host[:port][/path]`（原样，未解析）。
    public let address: String
    /// 一次性口令：direct 模式由节点签发，proxy 模式是面板签发的网关令牌。
    public let password: String
    /// socket.io 的路径前缀（proxy 模式为空；direct 模式跟随节点配置）。
    public let prefix: String
    /// 面板的地址重映射（用不上就空）。
    public let remoteMappings: [MCSMRemoteMapping]

    public init(address: String, password: String, prefix: String = "", remoteMappings: [MCSMRemoteMapping] = []) {
        self.address = address
        self.password = password
        self.prefix = prefix
        self.remoteMappings = remoteMappings
    }
}

/// 面板的地址重映射：`from` 是浏览器看到的地址，`to` 是实际可连的地址。
public struct MCSMRemoteMapping: Equatable, Sendable {

    public struct Endpoint: Equatable, Sendable {
        public let address: String
        public let prefix: String

        public init(address: String, prefix: String = "") {
            self.address = address
            self.prefix = prefix
        }
    }

    public let from: Endpoint
    public let to: Endpoint

    public init(from: Endpoint, to: Endpoint) {
        self.from = from
        self.to = to
    }
}

extension MCSMStreamChannel {

    /// 从 `POST /api/protected_instance/stream_channel` 的响应里取通道。
    ///
    /// 面板 10.x 实际返回带外壳的形状；也兼容不套外壳（顶层直接有 `addr`/`password`）。
    /// `addr` 或 `password` 缺失就返回 `nil`（说明面板版本太老，调用方回退轮询）。
    public init?(_ response: Components.Schemas.StreamChannelResponse) {
        if let payload = response.data,
           let channel = Self(validating: payload.addr, password: payload.password,
                              prefix: payload.prefix ?? "",
                              remoteMappings: Self.mappings(payload.remoteMappings)) {
            self = channel
            return
        }
        guard let address = response.addr, let password = response.password,
              let channel = Self(validating: address, password: password, prefix: response.prefix ?? "",
                                 remoteMappings: Self.mappings(response.remoteMappings))
        else { return nil }
        self = channel
    }

    /// 纯文本响应体（面板有时用 `text/plain` 送同一份 JSON）也能解。
    public init?(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // 先剥外壳，再看顶层。
        let body = (object["data"] as? [String: Any]) ?? object
        guard let address = body["addr"] as? String, let password = body["password"] as? String else {
            return nil
        }
        guard let channel = Self(validating: address, password: password,
                                 prefix: body["prefix"] as? String ?? "",
                                 remoteMappings: MCSMRemoteMapping.parse(body["remoteMappings"]))
        else { return nil }
        self = channel
    }

    private init?(validating address: String, password: String, prefix: String, remoteMappings: [MCSMRemoteMapping]?) {
        guard !address.isEmpty, !password.isEmpty else { return nil }
        self.init(address: address, password: password, prefix: prefix, remoteMappings: remoteMappings ?? [])
    }

    private static func mappings(_ entries: [Components.Schemas.RemoteMappingEntry]?) -> [MCSMRemoteMapping] {
        (entries ?? []).compactMap { entry in
            guard let from = entry.from, let to = entry.to else { return nil }
            return MCSMRemoteMapping(
                from: .init(address: from.addr ?? "", prefix: from.prefix ?? ""),
                to: .init(address: to.addr ?? "", prefix: to.prefix ?? "")
            )
        }
    }
}

extension MCSMRemoteMapping {

    /// 从任意 JSON 值解析（`init?(text:)` 用；形状不对就当没有）。
    static func parse(_ value: Any?) -> [MCSMRemoteMapping] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let from = entry["from"] as? [String: Any], let to = entry["to"] as? [String: Any],
                  let fromAddr = from["addr"] as? String, let toAddr = to["addr"] as? String
            else { return nil }
            return MCSMRemoteMapping(
                from: .init(address: fromAddr, prefix: from["prefix"] as? String ?? ""),
                to: .init(address: toAddr, prefix: to["prefix"] as? String ?? "")
            )
        }
    }
}
