//
//  SocketIOFrame.swift
//  MCSMStream
//
//  Engine.IO v4 + Socket.IO v5 的**最小帧编解码**（只覆盖面板终端用到的那几种）。
//
//  线上就是一条条 WebSocket 文本帧，首字符是 Engine.IO 包类型：
//
//  | 前缀 | 含义 | 方向 |
//  |---|---|---|
//  | `0`  | open（带 `{sid, pingInterval, pingTimeout}`） | 服务端 → 客户端 |
//  | `1`  | close | 双向 |
//  | `2`  | ping | 服务端 → 客户端（v4 由服务端发，客户端回 `3`） |
//  | `3`  | pong | 客户端 → 服务端 |
//  | `40` | socket.io connect（默认命名空间） | 双向 |
//  | `41` | disconnect | 双向 |
//  | `42` | event，后面是 `["事件名", 参数…]` | 双向 |
//  | `44` | connect_error | 服务端 → 客户端 |
//
//  面板终端用到的业务事件（参数统一是 `{ "data": … }` 外壳）：
//
//  - 客户端发：`stream/auth {data:{password}}`、`stream/detail {}`、`stream/input {data:{command}}`；
//  - 服务端发：`stream/auth {data:true|false}`、`instance/stdout {data:{instanceUuid,text}}`、
//    `stream/detail {data:{…}}`、`instance/stopped` / `instance/opened` / `instance/failure`。
//
//  实现取舍：事件参数**保留原始 JSON 文本**（`dataJSON`）而不是 `[String: Any]` ——
//  `Any` 既不是 `Equatable` 也不是 `Sendable`，存进枚举会让整个类型没法比较/跨并发域传递；
//  需要取值时用下面几个便利属性按需解析（一次解析，成本可忽略）。
//

import Foundation

/// 一条解析后的 Engine.IO / Socket.IO 帧。
public enum SocketIOFrame: Equatable, Sendable {

    /// `0`：握手成功，带服务端的 `sid` 等参数（原文 JSON，本包不解析）。
    case open(String)
    /// `1`：服务端要求关闭。
    case close
    /// `2`：服务端 ping（必须回 `3`）。
    case ping
    /// `3`：服务端回了我们的 pong（本项目不发 ping，保留解析以便诊断）。
    case pong
    /// `40`：socket.io 命名空间已连接。
    case connected
    /// `41`：socket.io 断开。
    case disconnected
    /// `42`：业务事件（`name` + 原始 JSON 参数）。
    case event(name: String, dataJSON: String)
    /// `44`：连接被拒绝（如鉴权失败）。
    case connectError(String)
    /// 其它（二进制帧、未知包）—— 记录但不处理，别让一条怪帧把连接搞挂。
    case unknown(String)

    /// 解析一条**文本**帧。
    public static func decode(_ text: String) -> SocketIOFrame {
        guard let first = text.first else { return .unknown(text) }
        switch first {
        case "0":
            return .open(String(text.dropFirst()))
        case "1":
            return .close
        case "2":
            return .ping
        case "3":
            return .pong
        case "4":
            // `40` / `41` / `42` / `44`
            let rest = text.dropFirst()
            guard let kind = rest.first else { return .unknown(text) }
            switch kind {
            case "0":
                return .connected
            case "1":
                return .disconnected
            case "2":
                return Self.decodeEvent(String(rest.dropFirst()))
            case "4":
                return .connectError(String(rest.dropFirst()))
            default:
                return .unknown(text)
            }
        default:
            return .unknown(text)
        }
    }

    /// `42["stream/auth",{"data":true}]` → `.event(name:dataJSON:)`
    static func decodeEvent(_ json: String) -> SocketIOFrame {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let name = array.first as? String
        else { return .unknown(json) }
        guard array.count > 1 else { return .event(name: name, dataJSON: "null") }
        // 规范化成排序键的紧凑 JSON：同样的参数总是得到同样的字符串（可断言、可比较）。
        let dataJSON: String
        if let encoded = try? JSONSerialization.data(
            withJSONObject: array[1], options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        ), let text = String(data: encoded, encoding: .utf8) {
            dataJSON = text
        } else {
            dataJSON = "null"
        }
        return .event(name: name, dataJSON: dataJSON)
    }

    // MARK: - 编码

    /// 建立默认命名空间连接（握手收到 `0` 之后发）。
    public static let connectPacket = "40"
    /// 回 ping。
    public static let pongPacket = "3"
    /// 主动断开 socket.io 命名空间。
    public static let disconnectPacket = "41"

    /// 发一个业务事件：`42["name",{"data":…}]`。
    public static func event(_ name: String, data: Any?) -> String {
        let payload: [String: Any] = ["data": data ?? NSNull()]
        // `.withoutEscapingSlashes`：`stream/auth` 里的 `/` 不必转义成 `\/`，
        // 面板/节点两种都认，但不转义时可读性好得多（日志、测试断言都直接看）。
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: [name, payload],
            options: [.withoutEscapingSlashes]
        ), let json = String(data: encoded, encoding: .utf8)
        else { return "42[\"\(name)\",{}]" }
        return "42" + json
    }
}

// MARK: - 事件参数取值

extension SocketIOFrame {

    /// `stream/auth` 的 `data == true`？不是这个事件时 `nil`。
    public var authAccepted: Bool? {
        guard case let .event(name, dataJSON) = self, name == "stream/auth" else { return nil }
        return Self.boolValue(forKey: "data", in: dataJSON)
    }

    /// `instance/stdout` 的文本（不是该事件 / 没有文本时 `nil`）。
    public var stdoutText: String? {
        guard case let .event(name, dataJSON) = self, name == "instance/stdout" else { return nil }
        guard let data = Self.object(forKey: "data", in: dataJSON) else { return nil }
        return data["text"] as? String
    }

    /// 实例生命周期事件 → `opened` / `stopped` / `failure`。
    public var instanceLifecycle: String? {
        guard case let .event(name, _) = self else { return nil }
        switch name {
        case "instance/opened": return "opened"
        case "instance/stopped": return "stopped"
        case "instance/failure": return "failure"
        default: return nil
        }
    }

    /// 事件参数里的某个键（`{"data": …}` 的外壳由调用方自己指定键名）。
    public func value(forKey key: String) -> Any? {
        guard case let .event(_, dataJSON) = self else { return nil }
        return Self.object(forKey: key, in: dataJSON)
    }

    private static func object(in json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func object(forKey key: String, in json: String) -> [String: Any]? {
        object(in: json)?[key] as? [String: Any]
    }

    private static func boolValue(forKey key: String, in json: String) -> Bool? {
        guard let root = object(in: json) else { return nil }
        return root[key] as? Bool
    }
}
