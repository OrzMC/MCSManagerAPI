# MCSManagerAPI

[MCSManager](https://github.com/MCSManager/MCSManager) 面板 HTTP API 的 Swift 客户端，
用 [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator) 从
`Sources/MCSMAPI/openapi.yml` 生成。

> 这是 OrzMC 的 P2-7（多供应商远程托管）依赖项：app 侧通过 `MCSMAPI` 读 MCSManager 面板的
> 实例与状态，再由 `Sources/OrzMCRemoteHosting` 的抽象层统一成「供应商无关」的实例/动作。

## 用法

```swift
import MCSMAPI

// 面板地址 + 「用户信息 → API Key」里生成的 key
let client = MCSMClient.make(serverURL: URL(string: "https://panel.example.com")!, apiKey: key)

// 1. 节点列表（管理员）
let daemons = try await client.getDaemons()
// 2. 某个节点上的实例（含 status / config）
let page = try await client.getInstances(query: .init(daemonId: daemon.uuid, page: 1, page_size: 50))
// 3. 单个实例详情（含 processInfo / config.docker.memory）
let detail = try await client.getInstance(query: .init(uuid: instanceUUID, daemonId: daemon.uuid))
```

`MCSMClient.make` 会注入 `X-Request-API-Key`（以及官方要求的
`X-Requested-With: XMLHttpRequest` / `Accept: application/json`），并去掉面板地址的尾部斜杠。

⚠️ **面板必须打开 API Key 功能**（设置里的 `enableApiKey`）。关闭时带 key 的请求一律 403
（`API Key功能已关闭`），这不是权限不足。

### 实例状态码

`InstanceDetail.status` 是面板自己的状态码：

| 值 | 含义 |
|---|---|
| `-1` | busy（正在处理上一条指令） |
| `0` | stopped |
| `1` | stopping |
| `2` | starting |
| `3` | running |

归一化到 OrzMC 的 `RemoteServerState` 由调用方做（见 `Sources/OrzMCRemoteHosting` 的
`RemoteHostingProvider`）。

## openapi.yml 的来源

官方**没有**提供机器可读的 OpenAPI/Swagger 文件，只有 markdown apidoc
（[`MCSManager/Documentation`](https://github.com/MCSManager/Documentation) → `apis/api_instance.md`、
`apis/api_daemon.md`）。所以 `openapi.yml` 是**按官方 apidoc 手写的最小子集**：

| 项 | 值 |
|---|---|
| 依据的文档 | `MCSManager/Documentation` @ `287c3936` |
| 面板实现参考（鉴权判定） | `MCSManager/MCSManager` @ `ad4f903a`（`panel/src/app/middleware/permission.ts`） |

口径：

- **只覆盖已接入的端点**：节点列表、实例列表（含状态）、实例详情。加端点时必须同步 spec + README。
- **保守 `required`**：只有我们真的依赖的字段才必填，其余可选 —— 面板版本之间字段会增删，
  Swift 解码会忽略未知字段，所以"多给的字段"不会炸，"少给的字段"也不会炸。
- **列表项不含 `processInfo` / `space`**：这是官方文档写明的行为，`InstanceDetail` 里二者都是可选，
  详情端点才有值。

官方文档改了怎么办：跑

```bash
./scripts/check-apidoc-drift.sh
```

它会拉官方 markdown，逐个检查 spec 里声明的路径还在不在（CI 里也有一个**不阻塞**的 job 跑它）。

## 测试

```bash
swift test
```

- `ClientRequestTests`：用假 transport 断言拼出来的路径/查询参数/鉴权头（零网络）；
- `SpecDecodingTests`：拿**官方文档里的示例 JSON** 解码，验证手写 spec 与文档形状一致；
- `APIKeyMiddlewareTests`：中间件注入的头。

## License

MIT
