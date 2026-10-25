//
//  APIKeyMiddleware.swift
//  MCSMAPI
//
//  MCSManager 面板的鉴权头。官方 apidoc 里两种写法都支持：
//    - 查询参数 `?apikey=<key>`
//    - 请求头 `X-Request-API-Key: <key>`
//
//  这里用**请求头**：不落 URL（不进访问日志 / 不被分享链接带走），也不会和面板的
//  其它 query 参数打架。面板侧判定见 `panel/src/app/middleware/permission.ts`
//  （`x-request-api-key` 优先于 `?apikey=`）。
//
//  另外两个头官方文档要求随请求发送（`X-Requested-With: XMLHttpRequest`、
//  `Content-Type: application/json`）；带 API Key 时面板其实不看 `X-Requested-With`，
//  但按文档发出去可以兼容把 token 校验放在前面的部署/反代。
//

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// 给每个请求加上 MCSManager 的 API Key（以及官方要求的两个固定头）。
public struct APIKeyMiddleware {

    /// 面板「用户信息 → API Key」里生成的 key。与账号密码同等权限，**不要**写进日志/截图。
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

extension APIKeyMiddleware: ClientMiddleware {

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let name = HTTPField.Name("X-Request-API-Key") {
            request.headerFields[name] = apiKey
        }
        if let name = HTTPField.Name("X-Requested-With") {
            request.headerFields[name] = "XMLHttpRequest"
        }
        if request.headerFields[.accept] == nil {
            request.headerFields[.accept] = "application/json"
        }
        if request.headerFields[.contentType] == nil {
            request.headerFields[.contentType] = "application/json; charset=utf-8"
        }
        return try await next(request, body, baseURL)
    }
}
