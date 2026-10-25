import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import MCSMAPI

/// 端到端（零网络）：拼出来的 URL / 查询参数 / 鉴权头是不是面板要的那一套。
@Suite(Tag.List.tags(.unit, .http, .transport))
final class ClientRequestTests {

    /// `HTTPRequest.path` 在 swift-http-types 里是**路径 + 查询串**（没有单独的 `query` 属性）。
    private func queryItems(of request: HTTPRequest) -> [URLQueryItem] {
        guard let path = request.path else { return [] }
        return URLComponents(string: path)?.queryItems ?? []
    }

    private func makeClient(
        baseURL: String = "https://panel.example.com",
        capture: RequestCapture
    ) -> Client {
        let transport = MockTransport { request, _, url, operationID in
            await capture.record(request, baseURL: url, operationID: operationID)
            // 每个端点回一份形状正确的最小响应（只为让解码通过，测试关心的是请求本身）。
            let payload: Any =
                switch operationID {
                case "getDaemons": ["status": 200, "data": []]
                case "getInstance": ["status": 200, "data": ["instanceUuid": "inst-1", "status": 3]]
                default: ["status": 200, "data": ["data": []]]
                }
            return (makeJSONResponse(), try makeJSONBody(payload))
        }
        return MCSMClient.make(
            serverURL: URL(string: baseURL)!,
            apiKey: "test-api-key",
            transport: transport
        )
    }

    @Test
    func instanceListSendsDaemonAndPaging() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        let output = try await client.getInstances(
            query: .init(daemonId: "daemon-1", page: 2, page_size: 50)
        )
        _ = try output.ok.body.json

        let request = try #require(await capture.request)
        let path = try #require(request.path)
        #expect(path.hasPrefix("/api/service/remote_service_instances?"))
        #expect(request.method == .get)
        let query = queryItems(of: request)
        #expect(query.first(where: { $0.name == "daemonId" })?.value == "daemon-1")
        #expect(query.first(where: { $0.name == "page" })?.value == "2")
        #expect(query.first(where: { $0.name == "page_size" })?.value == "50")
        // 鉴权头由 middleware 注入，应该在 transport 之前就带上了
        #expect(request.headerFields[HTTPField.Name("X-Request-API-Key")!] == "test-api-key")
        #expect(request.headerFields[HTTPField.Name("X-Requested-With")!] == "XMLHttpRequest")
    }

    @Test
    func instanceDetailSendsUUIDAndDaemon() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        _ = try await client.getInstance(query: .init(uuid: "inst-1", daemonId: "daemon-1"))

        let request = try #require(await capture.request)
        let path = try #require(request.path)
        #expect(path.hasPrefix("/api/instance?"))
        let query = queryItems(of: request)
        #expect(query.first(where: { $0.name == "uuid" })?.value == "inst-1")
        #expect(query.first(where: { $0.name == "daemonId" })?.value == "daemon-1")
    }

    /// 普通用户列实例走 `/api/auth?advanced=true`（管理员端点要 ROLE.ADMIN，普通 key 会 403）。
    @Test
    func currentUserRequestsAdvancedInstances() async throws {
        let capture = RequestCapture()
        let transport = MockTransport { request, _, url, operationID in
            await capture.record(request, baseURL: url, operationID: operationID)
            let payload: [String: Any] = ["uuid": "u1", "permission": 1, "instances": []]
            return (makeJSONResponse(), try makeJSONBody(payload))
        }
        let client = MCSMClient.make(
            serverURL: URL(string: "https://panel.example.com")!,
            apiKey: "test-api-key",
            transport: transport
        )

        let output = try await client.getCurrentUser(query: .init(advanced: true))
        let user = try output.ok.body.json
        #expect(user.uuid == "u1")
        #expect(user.permission == 1)

        let request = try #require(await capture.request)
        let path = try #require(request.path)
        #expect(path.hasPrefix("/api/auth?"))
        #expect(queryItems(of: request).first(where: { $0.name == "advanced" })?.value == "true")
    }

    @Test
    func daemonListUsesServiceRoute() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        _ = try await client.getDaemons()

        let request = try #require(await capture.request)
        #expect(request.path == "/api/service/remote_services")
        #expect(request.method == .get)
    }

    /// 默认用**短超时**的会话（面板挂掉时要尽快给结论，而不是停在「加载中…」）。
    @Test
    func defaultClientUsesShortTimeoutSession() {
        #expect(MCSMClient.defaultTimeout == 20)
        let session = MCSMClient.makeSession(timeout: 20)
        #expect(session.configuration.timeoutIntervalForRequest == 20)
        #expect(session.configuration.timeoutIntervalForResource == 60)
        #expect(session.configuration.waitsForConnectivity == false)
    }

    /// 用户常把面板地址粘成带尾斜杠，生成的路径本身以 `/api` 开头，不能拼出 `//api`。
    @Test
    func trailingSlashIsNormalized() {
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com/")!).absoluteString == "https://panel.example.com")
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com/sub/")!).absoluteString == "https://panel.example.com/sub")
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com")!).absoluteString == "https://panel.example.com")
    }
}
