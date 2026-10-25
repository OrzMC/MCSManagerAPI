//
//  MCSMClient.swift
//  MCSMAPI
//
//  构造客户端的便捷入口：把"面板地址 + API Key"变成可以直接用的 `Client`。
//

import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public enum MCSMClient {

    /// 默认请求超时（秒）。
    ///
    /// 面板挂在 Cloudflare Tunnel 后面时，首次请求偶尔要十几秒才出结果（实测 17s）；
    /// 而 `URLSession` 默认 60 秒 —— 卡住时用户会长时间停在「加载中…」，看不出是失败还是在等。
    /// 20 秒足够覆盖慢启动，又能在"面板挂了"时较快给出结论。
    public static let defaultTimeout: TimeInterval = 20

    /// 构造一个指向自己面板的客户端。
    ///
    /// - Parameters:
    ///   - serverURL: 面板根地址，例如 `https://panel.example.com`。尾部斜杠会被去掉
    ///     （生成的请求路径本身以 `/api/...` 开头）。
    ///   - apiKey: 面板里生成的 API Key。**同时需要在面板设置里打开 API Key 功能**，
    ///     否则面板会返回 403（`enableApiKey` 关闭时所有 key 请求都被拒）。
    ///   - transport: 默认走 `URLSession`；单测可以塞假的以实现"零网络"。
    public static func make(
        serverURL: URL,
        apiKey: String,
        timeout: TimeInterval = defaultTimeout,
        transport: (any ClientTransport)? = nil
    ) -> Client {
        Client(
            serverURL: normalized(serverURL),
            transport: transport ?? URLSessionTransport(configuration: .init(session: makeSession(timeout: timeout))),
            middlewares: [APIKeyMiddleware(apiKey: apiKey)]
        )
    }

    /// 只建一条"短超时"的会话：不要在全局 `URLSession.shared` 上改配置。
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        // 面板连不上时宁可快速失败，也不要等到网络恢复（列表会一直转圈）。
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// 去掉尾部斜杠；顺带把不带 scheme 的输入补成 `https://`（用户常只填域名）。
    static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? url
    }
}
