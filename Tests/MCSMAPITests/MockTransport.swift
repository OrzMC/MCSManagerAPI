import Foundation
import HTTPTypes
import OpenAPIRuntime

/// 记录"客户端真正发出去的请求"，并回一份固定响应。
struct MockTransport: ClientTransport {
    let handler: @Sendable (HTTPRequest, HTTPBody?, URL, String) async throws -> (HTTPResponse, HTTPBody?)

    init(
        handler: @escaping @Sendable (HTTPRequest, HTTPBody?, URL, String) async throws -> (
            HTTPResponse, HTTPBody?
        )
    ) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws
        -> (HTTPResponse, HTTPBody?)
    {
        try await handler(request, body, baseURL, operationID)
    }
}

actor RequestCapture {
    private(set) var request: HTTPRequest?
    private(set) var baseURL: URL?
    private(set) var operationID: String?

    func record(_ request: HTTPRequest, baseURL: URL, operationID: String) {
        self.request = request
        self.baseURL = baseURL
        self.operationID = operationID
    }
}

func makeJSONBody(_ object: Any) throws -> HTTPBody {
    HTTPBody(try JSONSerialization.data(withJSONObject: object))
}

func makeJSONResponse(status: HTTPResponse.Status = .ok) -> HTTPResponse {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "application/json; charset=utf-8"
    return response
}

func makeTextResponse(status: HTTPResponse.Status = .ok) -> HTTPResponse {
    var response = HTTPResponse(status: status)
    response.headerFields[.contentType] = "text/plain; charset=utf-8"
    return response
}

func makeTextBody(_ text: String) -> HTTPBody {
    HTTPBody(text)
}
