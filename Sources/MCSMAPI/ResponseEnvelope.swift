//
//  ResponseEnvelope.swift
//  MCSMAPI
//
//  面板的**统一响应外壳**：`{status, data, time}`（协议中间件 `protocol.ts` 对**所有** `/api/*`
//  响应做 `JSON.stringify({status, data, time})`，包括纯文本接口 —— 所以 `outputlog` 的
//  `text/plain` 体里装的也是这个 JSON）。
//

import Foundation

/// 面板响应外壳。
public struct MCSMResponseEnvelope: Equatable, Sendable {

    public let status: Int?
    public let data: String?
    public let time: Int?

    public init(status: Int?, data: String?, time: Int? = nil) {
        self.status = status
        self.data = data
        self.time = time
    }
}

extension MCSMResponseEnvelope {

    /// 解析 `{"status":200,"data":"…","time":…}`；不是这个形状时返回 `nil`。
    public init?(text: String) {
        guard let encoded = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return nil }
        status = object["status"] as? Int
        data = object["data"] as? String
        time = object["time"] as? Int
    }

    /// 从**纯文本接口**（`outputlog`）的原始响应里取出真正的文本。
    ///
    /// - 有外壳就取 `data`（这是面板 10.x 的实际行为）；
    /// - 没有外壳（老版本 / 将来改了协议）就把原文原样返回 —— 两种都工作，不用猜版本。
    public static func unwrapText(_ raw: String) -> String {
        guard let envelope = MCSMResponseEnvelope(text: raw) else { return raw }
        return envelope.data ?? ""
    }

    /// 同 `unwrapText(_:)`，但外壳里 `status` 不是 2xx 时抛错（面板偶尔这么报"节点未连接"）。
    public static func checkedText(_ raw: String) throws -> String {
        guard let envelope = MCSMResponseEnvelope(text: raw) else { return raw }
        if let status = envelope.status, !(200..<300).contains(status) {
            throw MCSMResponseError(status: status, message: envelope.data)
        }
        return envelope.data ?? ""
    }
}

/// 外壳里带出来的错误（纯文本接口用）。
public struct MCSMResponseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: Int
    public let message: String?

    public init(status: Int, message: String?) {
        self.status = status
        self.message = message
    }

    public var description: String {
        "MCSMResponseError(status: \(status), message: \(message ?? "nil"))"
    }
}
