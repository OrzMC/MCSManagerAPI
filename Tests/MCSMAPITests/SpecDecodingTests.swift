import Foundation
import Testing

@testable import MCSMAPI

/// 用**官方 apidoc 里的示例 JSON** 解码，确保手写的 spec 与文档形状一致。
///
/// 面板不同版本会加减字段；这里同时验证"多余字段不会让解码失败"（宽容解码）。
@Suite(Tag.List.tags(.unit, .spec))
final class SpecDecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test
    func decodesDaemonList() throws {
        let response = try decode(
            Components.Schemas.DaemonListResponse.self,
            """
            {
              "status": 200,
              "data": [
                {
                  "uuid": "957c6bddf379445c82bac5edf7684bbc",
                  "ip": "s1.example.com",
                  "port": 24444,
                  "prefix": "",
                  "available": true,
                  "remarks": "CN-ZJ-DEV-01",
                  "instances": [{ "instanceUuid": "x", "status": 3 }]
                }
              ],
              "time": 1718594177859
            }
            """
        )

        #expect(response.status == 200)
        #expect(response.data.count == 1)
        #expect(response.data[0].uuid == "957c6bddf379445c82bac5edf7684bbc")
        #expect(response.data[0].available == true)
        #expect(response.data[0].remarks == "CN-ZJ-DEV-01")
    }

    @Test
    func decodesInstanceListWithStatus() throws {
        let response = try decode(
            Components.Schemas.InstanceListResponse.self,
            """
            {
              "status": 200,
              "data": {
                "page": 1,
                "pageSize": 10,
                "maxPage": 1,
                "allTags": ["tag1", "tag2"],
                "data": [
                  {
                    "instanceUuid": "50c73059001b436fa85c0d8221c157cf",
                    "started": 6,
                    "autoRestarted": 0,
                    "status": 3,
                    "config": {
                      "nickname": "Survival",
                      "type": "minecraft/java",
                      "startCommand": "java -jar server.jar",
                      "cwd": "/srv/mc",
                      "docker": { "memory": 4096, "image": "mcsm-java:17", "ports": ["25565:25565/tcp"] },
                      "pingConfig": { "ip": "127.0.0.1", "port": 25565, "type": 1 }
                    },
                    "info": { "mcPingOnline": true, "currentPlayers": 2, "maxPlayers": 20, "version": "1.21.4" }
                  }
                ]
              },
              "time": 1718594177859
            }
            """
        )

        #expect(response.data.data.count == 1)
        let instance = response.data.data[0]
        #expect(instance.instanceUuid == "50c73059001b436fa85c0d8221c157cf")
        #expect(instance.status == 3)
        #expect(instance.config?.nickname == "Survival")
        #expect(instance.config?.docker?.memory == 4096)
        #expect(instance.config?.pingConfig?.port == 25565)
        #expect(instance.info?.currentPlayers == 2)
        // 列表端点本来就不返回 processInfo
        #expect(instance.processInfo == nil)
    }

    @Test
    func decodesInstanceDetailWithProcessInfo() throws {
        let response = try decode(
            Components.Schemas.InstanceDetailResponse.self,
            """
            {
              "status": 200,
              "data": {
                "instanceUuid": "50c73059001b436fa85c0d8221c157cf",
                "status": 3,
                "space": 123456789,
                "config": { "nickname": "Survival", "enableRcon": true, "rconPort": 25575 },
                "info": { "allocatedPorts": [{ "host": "25565", "container": 25565, "protocol": "tcp" }] },
                "processInfo": {
                  "cpu": 12.5, "memory": 1073741824, "ppid": 1, "pid": 42,
                  "ctime": 1000, "elapsed": 60000, "timestamp": 1718594177859
                }
              },
              "time": 1718594177859
            }
            """
        )

        let detail = response.data
        #expect(detail.status == 3)
        #expect(detail.space == 123456789)
        #expect(detail.processInfo?.memory == 1_073_741_824)
        #expect(detail.info?.allocatedPorts?.first?._protocol == "tcp")
        #expect(detail.config?.enableRcon == true)
    }

    /// `GET /api/auth?advanced=true`：**没有** `{status,data,time}` 外壳，实例带 daemonId/status。
    @Test
    func decodesCurrentUserWithAdvancedInstances() throws {
        let user = try decode(
            Components.Schemas.CurrentUserResponse.self,
            """
            {
              "uuid": "u1",
              "userName": "joker",
              "permission": 1,
              "isInit": true,
              "open2FA": false,
              "instances": [
                {
                  "instanceUuid": "50c73059001b436fa85c0d8221c157cf",
                  "daemonId": "d1",
                  "nickname": "我的生存服",
                  "status": 3,
                  "hostIp": "10.0.0.2:24444",
                  "remarks": "CN-ZJ",
                  "processType": "general",
                  "docker": {},
                  "info": { "currentPlayers": 3, "maxPlayers": 20 }
                }
              ]
            }
            """
        )

        #expect(user.permission == 1)
        #expect(user.instances?.count == 1)
        #expect(user.instances?.first?.daemonId == "d1")
        #expect(user.instances?.first?.status == 3)
        #expect(user.instances?.first?.info?.currentPlayers == 3)
    }

    /// 同一个 `/api/auth` 在**带外壳**的版本上也要能解（实测面板 10.x 就是这种）。
    @Test
    func decodesCurrentUserInsideEnvelope() throws {
        let response = try decode(
            Components.Schemas.CurrentUserResponse.self,
            """
            {
              "status": 200,
              "time": 1718594177859,
              "data": {
                "uuid": "u1",
                "userName": "testuser",
                "loginTime": "2026-10-24 16:26:49",
                "registerTime": "2026-10-01 09:00:00",
                "permission": 1,
                "instances": [
                  { "instanceUuid": "i1", "daemonId": "d1", "nickname": "我的服", "status": 3 }
                ]
              }
            }
            """
        )

        #expect(response.status == 200)
        #expect(response.data?.permission == 1)
        #expect(response.data?.instances?.first?.instanceUuid == "i1")
    }

    /// 面板权限不足时返回 403 + 字符串 data：能解成 `ErrorResponse`，不是崩在解码上。
    @Test
    func decodesForbiddenError() throws {
        let response = try decode(
            Components.Schemas.ErrorResponse.self,
            #"{"status": 403, "data": "Forbidden", "time": 1718594177859}"#
        )
        #expect(response.status == 403)
        #expect(response.data == "Forbidden")
    }
    // MARK: - 统一响应外壳（`{status, data, time}`）

    /// 面板的协议中间件把**所有**响应都包了一层，纯文本接口（`outputlog`）也一样：
    /// `text/plain` 体里装的是 `{"status":200,"data":"<日志>","time":…}`。
    @Test
    func unwrapsPanelTextEnvelope() {
        let raw = #"{"status":200,"data":"[12:00:00] [Server thread/INFO]: Done","time":1718594177859}"#
        #expect(MCSMResponseEnvelope.unwrapText(raw) == "[12:00:00] [Server thread/INFO]: Done")
    }

    /// 没有外壳（老版本/协议改了）就原样返回，不猜版本。
    @Test
    func passesThroughPlainTextWithoutEnvelope() {
        let raw = "[12:00:00] [Server thread/INFO]: Done\n[12:00:01] [Server thread/INFO]: Bye"
        #expect(MCSMResponseEnvelope.unwrapText(raw) == raw)
    }

    /// 外壳里 status 不是 2xx → 抛错，把面板那句原因带出来。
    @Test
    func throwsWhenEnvelopeStatusIsError() {
        let raw = #"{"status":500,"data":"[Forbidden] 节点未连接","time":1}"#
        #expect(throws: MCSMResponseError.self) {
            _ = try MCSMResponseEnvelope.checkedText(raw)
        }
        do {
            _ = try MCSMResponseEnvelope.checkedText(raw)
        } catch let error as MCSMResponseError {
            #expect(error.status == 500)
            #expect(error.message == "[Forbidden] 节点未连接")
        } catch {
            Issue.record("期望 MCSMResponseError，实际 \(error)")
        }
    }
}
