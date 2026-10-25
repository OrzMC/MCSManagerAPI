import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import MCSMAPI

@Suite(Tag.List.tags(.unit, .http, .middleware))
final class APIKeyMiddlewareTests {

    @Test
    func addsAPIKeyAndDocumentedHeaders() async throws {
        let middleware = APIKeyMiddleware(apiKey: "abcd1234")
        let request = HTTPRequest(method: .get, scheme: "https", authority: "panel.example.com", path: "/api/instance")
        let capture = RequestCapture()

        _ = try await middleware.intercept(
            request,
            body: nil,
            baseURL: URL(string: "https://panel.example.com")!,
            operationID: "test"
        ) { req, _, _ in
            await capture.record(req, baseURL: URL(string: "https://panel.example.com")!, operationID: "test")
            return (HTTPResponse(status: .ok), nil)
        }

        let sent = await capture.request
        #expect(sent?.headerFields[HTTPField.Name("X-Request-API-Key")!] == "abcd1234")
        #expect(sent?.headerFields[HTTPField.Name("X-Requested-With")!] == "XMLHttpRequest")
        #expect(sent?.headerFields[.accept] == "application/json")
    }
}
