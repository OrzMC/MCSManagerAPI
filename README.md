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

// 普通用户（permission = 1）：列自己拥有的实例（**唯一**能用的入口）
let user = try await client.getCurrentUser(query: .init(advanced: true))
let myInstances = try user.ok.body.json.instances ?? []   // 每项自带 daemonId / status / docker / info

// 管理员（permission = 10）：按节点列全部实例
let daemons = try await client.getDaemons()
let page = try await client.getInstances(query: .init(daemonId: daemon.uuid, page: 1, page_size: 50))
// 单个实例详情（含 processInfo / config.docker.memory）
let detail = try await client.getInstance(query: .init(uuid: instanceUUID, daemonId: daemon.uuid))
```

### 动作与控制台

```swift
// 生命周期动作：三个都是 GET + `daemonId` / `uuid`（uuid 是**实例 UUID**，不是昵称）
try await client.openInstance(query: .init(daemonId: daemonId, uuid: instanceUUID))
try await client.stopInstance(query: .init(daemonId: daemonId, uuid: instanceUUID))
try await client.restartInstance(query: .init(daemonId: daemonId, uuid: instanceUUID))

// 控制台命令：走**查询参数**（不是请求体），编码由客户端负责
try await client.sendCommand(
    query: .init(daemonId: daemonId, uuid: instanceUUID, command: "/say hi")
)

// 控制台输出：`text/plain` 的日志尾部。注意面板把**所有**响应的包了一层
// `{status, data, time}`（连纯文本接口也一样），所以要 unwrap 一次。
let log = try await client.getOutputLog(
    query: .init(daemonId: daemonId, uuid: instanceUUID, size: "16kb")
)
let raw = try await String(collecting: log.ok.body.plainText, upTo: 1 << 20)
let text = try MCSMResponseEnvelope.checkedText(raw)   // 或 unwrapText(raw) 不抛错
```

| 端点 | 权限 | 说明 |
|---|---|---|
| `GET /api/protected_instance/open` | 实例的主人（**普通用户也行**） | 启动。面板立即返回，状态随后变化 |
| `GET /api/protected_instance/stop` | 同上 | 停止（发送 `stop`，不强制杀进程） |
| `GET /api/protected_instance/restart` | 同上 | 重启 |
| `GET /api/protected_instance/kill` | 同上 | **强制终止**（守护进程直接杀进程，不给保存机会）。面板侧超时 30 秒 |
| `GET /api/protected_instance/command` | 同上 | 命令走查询参数；`/` 开头是 MC 命令，不带 `/` 是控制台命令 |
| `GET /api/protected_instance/outputlog` | 同上 | 返回 `text/plain` 的**日志尾部**，可能从半行开始。体里仍是 `{status,data,time}` 外壳 → 用 `MCSMResponseEnvelope` 解 |
| `POST /api/protected_instance/stream_channel` | 同上 | 控制台**实时流**的第一步：拿 `addr` + 一次性口令，然后连那台 socket.io 发 `stream/auth`。见下节 |

### 实时流（`MCSMStream`，另一个 product）

轮询 `outputlog` 的实时性差；面板支持把节点 stdout 一条条推过来（面板自己的前端就是这么做的）：

```swift
import MCSMStream

let channel = try await MCSMStreamChannel(client.getStreamChannel(query: .init(daemonId: d, uuid: u)))!
let endpoint = try MCSMStreamEndpoint(channel: channel, panelURL: panelURL)

let stream = MCSMStreamClient { endpoint }
for await event in await stream.events() {
    switch event {
    case .ready:                 break          // stream/auth 通过，可以收输出了
    case .output(let text):      buffer.append(text)
    case .fallback(let reason):  await poll()   // 实时流不可用 → 回退轮询
    case .connecting, .lifecycle: break
    }
}
```

要点（都是踩过的）：

- **一次性口令**：每次重连都要重新申请通道 → 客户端收的是 `makeEndpoint` 闭包，不是固定 URL；
- **`addr` 可能是节点视角**（`127.0.0.1:24444`，面板 `dataPlane=direct` 时就是节点的公开地址）：
  回环地址会被换成本面板的主机名；连不上（节点在 NAT 后面）就回退轮询，这是正常路径；
- **`/socket.io/` 的尾部斜杠不能少**：少了会 404 / 握手失败（实测 `-1011 Websocket handshake failure`）；
- **必须回 pong**：Engine.IO v4 由服务端 ping，不回会被 20~25 秒后踢掉；
- 事件参数形如 `{ "data": … }`，`instance/stdout` 的 `data.text` 是**原始终端文本**（带 ANSI 码、
  可能半行、可能 `\r` 覆盖）→ 交给 `ConsoleTextParser` 那一套渲染，别自己按行切。

### 响应外壳（重要）

面板的协议中间件（`protocol.ts`）对**每一个** `/api/*` 响应都做
`JSON.stringify({status, data, time})`，而且**不改 `Content-Type`**（所以 JSON 体常带着
`text/plain`，`outputlog` 的日志文本也被塞进外壳的 `data` 里）。

| 情况 | 处理 |
|---|---|
| `application/json` 接口 | 按 schema 解 `{status, data}`（本 spec 的 `DaemonListResponse` / `InstancePage` / `CurrentUserResponse` 都已声明） |
| `text/plain` 接口（`outputlog`） | 体是 JSON 文本 → `MCSMResponseEnvelope.unwrapText(_:)` / `checkedText(_:)` |
| 错误响应 | 同理：`{"status":403,"data":"密钥不正确"}`，`text/plain` |

⚠️ `/protected_instance/*` 的中间件先校验"这台实例是不是你的"（`daemonId` + `uuid` 缺一个就 403
「参数不正确或非法访问实例」），**再**看 API Key 的权限等级 —— 所以普通用户的 key 完全够用。

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

### 权限：管理员 vs 普通用户（重要）

| 账号 | 列实例的入口 | 说明 |
|---|---|---|
| 管理员（`permission = 10`） | `GET /api/service/remote_services` → `GET /api/service/remote_service_instances` | 面板所有节点的所有实例 |
| 普通用户（`permission = 1`） | `GET /api/auth?advanced=true` | **只能**列自己拥有的实例；管理员端点对普通 key 一律 403（面板文案可能误导成「密钥不正确」） |

`GET /api/auth` 的响应**没有** `{status,data,time}` 外壳，且 API Key 也能用
（面板从 key 反查用户）；`advanced=true` 时每条实例已带 `daemonId` / `status` / `docker` / `info`。

## openapi.yml 的来源

官方**没有**提供机器可读的 OpenAPI/Swagger 文件，只有 markdown apidoc
（[`MCSManager/Documentation`](https://github.com/MCSManager/Documentation) → `apis/api_instance.md`、
`apis/api_daemon.md`）。所以 `openapi.yml` 是**按官方 apidoc 手写的最小子集**：

| 项 | 值 |
|---|---|
| 依据的文档 | `MCSManager/Documentation` @ `287c3936`；`GET /api/auth` 另据面板源码 `panel/src/app/routers/general_user_router.ts` |
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

## 真实面板冒烟（可选）

`stream_channel` 的形状与 socket.io 可达性只有真面板能验证，所以有一个默认跳过的测试：

```bash
ORZMC_MCSM_LIVE_URL=https://mcs.example.com \
ORZMC_MCSM_LIVE_KEY=<API Key> \
ORZMC_MCSM_LIVE_DAEMON=<daemonId> \
ORZMC_MCSM_LIVE_INSTANCE=<instanceUuid> \
swift test --filter LiveStreamTests
```

它会：申请通道 → 连 socket.io → 期望 `stream/auth` 回 `true` → 发一条 `/list` → 期望收到实时输出。
口令与实例**不要**写进仓库。

## 测试

```bash
swift test
```

- `ClientRequestTests`：用假 transport 断言拼出来的路径/查询参数/鉴权头（零网络）；
- `SpecDecodingTests`：拿**官方文档里的示例 JSON** 解码，验证手写 spec 与文档形状一致；
- `APIKeyMiddlewareTests`：中间件注入的头。

## License

MIT
