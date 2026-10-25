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
            // 控制台端点回的是纯文本，其它端点回 JSON。
            if operationID == "getOutputLog" {
                return (makeTextResponse(), makeTextBody("[12:00:00] [Server thread/INFO]: Done"))
            }
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

    /// 三个生命周期动作都打到 `/api/protected_instance/<动作>`，并且**同时带 daemonId 与 uuid**
    /// （面板中间件按这两个参数判断"这台实例是不是你的"，少一个就 403）。
    @Test
    func lifecycleActionsCarryDaemonAndInstance() async throws {
        for (action, path) in [
            ("openInstance", "/api/protected_instance/open"),
            ("stopInstance", "/api/protected_instance/stop"),
            ("restartInstance", "/api/protected_instance/restart"),
        ] {
            let capture = RequestCapture()
            let client = makeClient(capture: capture)
            switch action {
            case "openInstance":
                _ = try await client.openInstance(query: .init(daemonId: "d1", uuid: "i1"))
            case "stopInstance":
                _ = try await client.stopInstance(query: .init(daemonId: "d1", uuid: "i1"))
            default:
                _ = try await client.restartInstance(query: .init(daemonId: "d1", uuid: "i1"))
            }

            let request = try #require(await capture.request)
            let requestPath = try #require(request.path)
            #expect(requestPath.hasPrefix(path + "?"), "实际路径：\(requestPath)")
            let query = queryItems(of: request)
            #expect(query.first(where: { $0.name == "daemonId" })?.value == "d1")
            #expect(query.first(where: { $0.name == "uuid" })?.value == "i1")
        }
    }

    /// 控制台命令走**查询参数**（面板的 validator 就这么写的），命令里的空格/斜杠要编码好。
    @Test
    func commandSendsPercentEncodedQuery() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        _ = try await client.sendCommand(
            query: .init(daemonId: "d1", uuid: "i1", command: "/say hi & bye")
        )

        let request = try #require(await capture.request)
        let path = try #require(request.path)
        #expect(path.hasPrefix("/api/protected_instance/command?"))
        let query = queryItems(of: request)
        // 解码后的值应该和原命令一模一样（编码由客户端负责）。
        #expect(query.first(where: { $0.name == "command" })?.value == "/say hi & bye")
        // 编码后的形式里不能有裸空格（否则面板会当成参数结束）。
        #expect(!path.contains("/say hi"))
    }

    /// 控制台输出是 `text/plain` 的**原样文本**，不是 JSON 包一层。
    @Test
    func outputLogReturnsPlainText() async throws {
        let capture = RequestCapture()
        let client = makeClient(capture: capture)

        let output = try await client.getOutputLog(
            query: .init(daemonId: "d1", uuid: "i1", size: "16kb")
        )
        let text = try output.ok.body.plainText

        #expect(try await String(collecting: text, upTo: 4096).contains("Done"))
        let request = try #require(await capture.request)
        let query = queryItems(of: request)
        #expect(query.first(where: { $0.name == "size" })?.value == "16kb")
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

    /// 面板的错误响应是 **`Content-Type: text/plain` + JSON 文本**（协议中间件没改 Content-Type）。
    /// spec 里两种类型都声明了，客户端不能因此丢掉文案。
    @Test
    func forbiddenTextPlainBodyIsAvailable() async throws {
        let transport = MockTransport { _, _, _, _ in
            var response = HTTPResponse(status: .forbidden)
            response.headerFields[.contentType] = "text/plain; charset=utf-8"
            let body = #"{"status":403,"data":"密钥不正确","time":1}"#
            return (response, HTTPBody(Data(body.utf8)))
        }
        let client = MCSMClient.make(
            serverURL: URL(string: "https://panel.example.com")!,
            apiKey: "dummy",
            transport: transport
        )

        let output = try await client.getCurrentUser(query: .init(advanced: true))
        guard case .forbidden(let response) = output else {
            Issue.record("应该是 403：\(output)")
            return
        }
        guard case .plainText(let body) = response.body else {
            Issue.record("text/plain 应该映射成 .plainText：\(response.body)")
            return
        }
        let data = try await Data(collecting: body, upTo: 4096)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("密钥不正确"))
    }

    /// 用户常把面板地址粘成带尾斜杠，生成的路径本身以 `/api` 开头，不能拼出 `//api`。
    @Test
    func trailingSlashIsNormalized() {
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com/")!).absoluteString == "https://panel.example.com")
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com/sub/")!).absoluteString == "https://panel.example.com/sub")
        #expect(MCSMClient.normalized(URL(string: "https://panel.example.com")!).absoluteString == "https://panel.example.com")
    }
}
