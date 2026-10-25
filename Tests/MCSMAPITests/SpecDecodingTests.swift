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
}
