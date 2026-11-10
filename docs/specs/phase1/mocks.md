# Phase 1 Mock / Fixture 设计（mocks.md）

> 状态：T4-draft（staging）。骨架实现：`test/fixtures/mock_model_server.mjs`（本次交付）；fake host/transport 为设计（实现分别在 T12/T19–T21 落地）。
> 原则：**不依赖真实模型/真实服务器/真实 API Key**；mock 必须确定性、可记录、可断言，不能"只回 200"。
> 与官方一致：官方 CI 也是"真引擎 + 假模型/合成模型 + 生产审批链"（`tooling/ios/engine-smoke/drive.mjs`、`guest-drive.mjs`），Phase 1 沿用该范式。

## 1. 端口与凭据约定（全 Phase 1 统一）

| 服务 | 地址 | 凭据 | 说明 |
|---|---|---|---|
| mock 模型服务 | `http://127.0.0.1:3901` | API Key：`sk-mock-phase1-model`（任意非空也可，mock 不校验但记录） | 给 DSH 引擎当 OpenAI 兼容渠道；**不要**用 3080（本机引擎端口）或真实服务端口 |
| fake DSH host | `http://127.0.0.1:3902` | token：`mock-host-token-phase1`（Authorization/`?token=` 两种都接受，模拟真实握手） | 远程主机（D1-09/10/11）的假 host |
| fake web / 页面（可选） | `http://127.0.0.1:3903` | — | 后续网页版/WebView 用例预留 |
| fake SSH server（可选） | `127.0.0.1:3904` | 测试用临时密钥（**不得**用真实 key） | 仅在需要真实 TCP SSH 子集时启用；优先用 fake SSH transport |
| 本机引擎（真） | `http://127.0.0.1:3080` | 由引擎 stdout token 换取 cookie | 官方既有约定（`docs/architecture.md:91-95`）；mock 不得占用此端口 |
| DSH Remote 真实服务器 | 不固定 | 测试账号 | Phase 1 默认不需要；L5 可选 |

**规则**：
1. mock 端口固定（便于手工调试）；测试 harness 可用 `--port 0` 取随机端口，并从服务启动日志读取实际端口。
2. 凭据必须明显是假的（含 `mock`/`phase1` 字样），禁止任何真实 Key。
3. 所有 mock 只监听 `127.0.0.1`，不得监听 `0.0.0.0`（CI/本机安全）。
4. 测试结束必须关闭 mock 服务；端口占用时报错并提示 `lsof -i :3901`，不得静默换端口导致断言错位。

## 2. mock 模型服务（`test/fixtures/mock_model_server.mjs`）

### 2.1 接口

| 方法/路径 | 用途 | 响应 |
|---|---|---|
| `GET /healthz` | 存活探测 | `200 {"ok":true,"scenarios":[...]}` |
| `GET /v1/models` | 模型列表（供"获取模型"流程） | `200 {"object":"list","data":[{"id":"mock-phase1-model"},…]}` |
| `POST /v1/chat/completions` | OpenAI 兼容 chat（DSH 引擎主要路径） | `stream:true` → SSE；否则 JSON（便于负例） |
| `POST /v1/responses` | Responses 协议最小实现（若引擎/渠道选该协议；**TODO-VERIFY** DSH 0.2.2 是否使用） | 同 SSE 风格，字段按 OpenAI Responses 最小集 |
| `POST /__mock/reset` | 清空请求日志（测试隔离） | `200` |
| `GET /__mock/log` | 返回本次进程请求日志（JSON 数组） | `200` |

**流式格式（SSE）**：`Content-Type: text/event-stream`，每块 `data: {json}\n\n`，最后 `data: [DONE]\n\n`。OpenAI chat chunk 形状：
`{"id":"chatcmpl-mock-1","object":"chat.completion.chunk","created":<ts>,"model":"mock-phase1-model","choices":[{"index":0,"delta":{"content":"…"},"finish_reason":null}]}`
工具调用 chunk：`delta.tool_calls=[{"index":0,"id":"call_mock_1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hi\"}"}}]`，随后 `finish_reason:"tool_calls"`。

### 2.2 场景（四类要求 + 辅助）

| 场景名 | 触发方式 | 行为 | 用于 |
|---|---|---|---|
| `stream`（默认） | 无头/`x-mock-scenario: stream` | 分 4–6 块输出文本（≥2 块间有延迟，可观察中间态） | D3-02 流式 |
| `thinking` | `x-mock-scenario: thinking` | 先输出 `delta.reasoning_content`（或 engine 约定的 thinking 字段，**TODO-VERIFY 字段名**）再输出正文 | D3-02 思考折叠 |
| `tool` | `x-mock-scenario: tool` | 输出一次 `tool_calls`（`bash` 或 `write`，参数读场景配置） | D3-08 工具行 |
| `approval` | `x-mock-scenario: approval` | 输出需要审批的工具调用（写工作区文件 `mock-hello.md`）；**审批由真引擎/真 App 弹出**，mock 只负责发起 | D3-06 审批允许/拒绝 |
| `question` | `x-mock-scenario: question` | mock 只在正文输出 `[mock-question]` 标记（**不能**产生引擎级提问）；D3-07 的 L4 用 fake host 注入 `user-questions/request`（§3.4），mock 文本仅用于 L1/L2 | D3-07（L2；L4=fake host） |
| `error_http` | `x-mock-scenario: error_http` | `HTTP 429/500` + OpenAI error JSON | D3-02 错误态 |
| `error_stream` | `x-mock-scenario: error_stream` | 已发送 1 块后发送 `data: {"error":{...}}` 并结束 | D3-02 中途错误 |
| `slow` | `x-mock-scenario: slow` | 每块间隔**默认 1000ms**（`SLOW_DELAY_MS`，可用 `x-mock-delay-ms`/`mock_delay_ms` 覆盖；`GET /__mock/config` 可查），用于停止/插话/排队测试 | D3-03/04/05 |

**`/v1/responses` 形状**：与 chat 共用同一场景控制面（scenario 头/后缀/body/`POST /__mock/scenario`）；非流式返回 Responses 最小对象（`object:"response"` + `output[]`，工具调用为 `function_call` item），流式发送 Responses 事件（`response.created` / `response.output_text.delta` / `response.output_item.added` / `response.completed`；错误沿用 `error` 事件）。DSH 引擎是否实际走 Responses 协议仍待 G3 验证（若走 chat，则本形状不参与）。

**场景选择优先级**：请求头 `x-mock-scenario` > 模型名后缀（`mock-phase1-model:approval`）> 请求体 `mock_scenario` 字段 > 默认 `stream`。DSH 引擎配置渠道时无法加自定义头时才用模型名后缀（需引擎允许特殊模型名，**TODO-VERIFY**；否则通过"同一 mock 端口按请求顺序切场景"的测试专用控制接口：`POST /__mock/scenario` 设置下一场景）。

> **Lead 决策（2026-11-10，D4）**：**两种触发方式都支持**；**默认 (b)** —— 测试用 mock 内置 `POST /__mock/scenario` 顺序控制（确定性最好，已实现）。T12 前若 G3 验证 DSH 引擎支持自定义请求头或模型名后缀，则优先改用 (a)（header/后缀）并在测试 support 中切换；在此之前测试代码统一通过 `MockModel.arm(scenario)`（内部调 `/__mock/scenario`）设置场景，不依赖引擎行为。

### 2.3 请求日志与断言

- 每次请求追加一行 JSONL（默认 stdout；`MOCK_MODEL_LOG=<path>` 时写文件）：
  `{"ts":…,"scenario":"approval","model":"mock-phase1-model","stream":true,"messages":N,"tools":N,"last_user":"…（截断 200）","response":"tool_call:bash","status":200}`
- 测试断言示例：`D2-04_switch_model_applies_to_next_turn` 断言日志最后一条 `model == "mock-phase1-model"`；`D3-03_steer_does_not_abort_turn` 断言下一请求 `messages` 含插话文本。
- **禁止**在日志中写入真实 Key/对话敏感内容（测试数据为合成）。

### 2.4 运行

```bash
node test/fixtures/mock_model_server.mjs --port 3901            # 启动（默认 3901）
node test/fixtures/mock_model_server.mjs --self-test            # 自测 16 项（无需 repo/网络），CI L0/L1 用
MOCK_MODEL_PORT=0 node test/fixtures/mock_model_server.mjs       # 随机端口（harness 读启动日志）
curl -s http://127.0.0.1:3901/healthz
```

## 3. fake DSH host（`test/fixtures/fake_dsh_host/`，Phase 1 新增）

**目的**：让 D1-09/10/11 的远程路径在**没有真实电脑/服务器**时可做 L4：连接、会话列表、发消息流式、审批事件、断线重连。

**契约（Phase 1 最小集，依据 `packages/dsh_client` 实际调用；TODO-VERIFY 精确路径/形状）**：

| 路径 | 方法 | 行为 |
|---|---|---|
| `/` | GET | 返回 200 + token 换 cookie 的极简登录页/握手（模拟 `dsh web` 的 token） |
| `/api/session/list`（名称待核） | POST | 返回固定会话列表（2 条：普通/带审批） |
| 会话事件流（WebSocket/`mux`） | — | 发送 `session/follow` 事件：assistant delta、tool-call、approval/asked |
| `/api/approval/decide`（名称待核） | POST | 记录决定；下一轮不再请求 |
| `/__mock/state` | GET | 调试：当前会话/请求计数/连接数 |
| `/__mock/stall`、`/__mock/close` | POST | 模拟断线/停摆，用于重连测试 |

**实现要求**：Node `node:http`（+ `ws` 仅在必要时；优先复用仓库已有 ws 依赖，不新增生产依赖）；只监听 127.0.0.1:3902；token 固定 `mock-host-token-phase1`；请求/事件记录 JSONL；提供 `--self-test`。

> **TODO-VERIFY（阻塞 fake host 实现，T19–T21 前解决）**：`packages/dsh_client` 的实际 HTTP/WS 路径与鉴权方式（token→cookie? header?）、`mux` 帧格式、审批/提问事件形状。核验方法：读 main 分支 `packages/dsh_client/lib/src/{rpc,mux,session_api}.dart` + 用真实本机引擎抓包对照。**在核实前，D1-09/10/11 的 L4 用 Dart 层 fake transport（第 4/5 节）而不是 HTTP fake host。**

#### 3.4 fake DSH host：`user-questions/request` 注入（D3-07 的 L4 方案）

mock 模型无法产出引擎级提问（提问由 `ask_user_question` 工具/引擎 waterfall 触发）。因此 D3-07 的 L4 由 fake DSH host 注入事件，App 端走真实事件链：

- **传输**：fake host 与 `mock_model_server.mjs` 同进程不同端口（`127.0.0.1:3902`），实现引擎最小 HTTP/SSE：`/api/*` 会话事件流（mux）、`/api/session/answer` 等；具体路由以 `packages/dsh_client/lib/src/mux.dart`/`session_api.dart` 实测为准（G5 待 T12 核对）。
- **注入时机**：测试通过 `POST /__mock/events`（fake host 控制面）指定下一条 `$events` 报文，例如：
  ```json
  {"type":"user-questions/request","eventId":"q-mock-1","agentId":"agent-mock",
   "request":{"questions":[{"id":"q1","question":"mock 提问：选一个","options":[{"label":"A"},{"label":"B"}]}]}}
  ```
  对应客户端模型 `packages/dsh_client/lib/src/models.dart:1118-1129`（`UserQuestionRequest.fromWaterfall`）；App 提交后 fake host 记录 `session_api.dart:682`（answer）调用，断言 `{id, selected}` 到达且只提交一次。
- **覆盖**：单问题/多问题串行、超时（`ASK_TIMED_OUT`）、拒绝、提交失败重试（fake host 第一次回 500）。
- **交付**：T12 把 fake host 放进 `test/fixtures/fake_dsh_host.mjs` 并在 `verify.sh --fast` 的 Dart/Flutter 测试中接线；在此之前 D3-07 L4 状态为 deferred（不阻塞 spec 冻结）。

## 4. fake SSH transport（Dart 接口 mock）

- **接口**：`app/lib/remote/ssh/ssh_transport.dart`（分支真实存在）；测试实现 `test/phase1/support/fake_ssh_transport.dart`。
- **场景**：连接成功/认证失败/主机指纹不匹配/隧道建立失败/中途断线/重连成功。
- **断言点**：`D1-10` AC1–AC3；不发起真实 TCP；私钥/口令不出现在日志。
- **L5 可选**：本机启动临时 sshd（macOS 远程登录）→ 走真实链路；结果单独记录，不替代 L4。

## 5. fake DSH Remote transport（Dart 接口 mock）

- **接口**：`packages/dsh_remote` 的 carrier/transport 抽象（分支 `lib/src/state.dart` 等；**TODO-VERIFY** 最小接口）。
- **场景**：Relay 连接成功/失败、会话列表、一轮流式、审批、断线重连、不支持能力（终端/传文件应被隐藏）。
- **断言点**：`D1-11` AC1–AC3；`D1-09` AC1/AC3。
- 真实服务器仅 L5 可选（`docs/roadmap.md:145` 自述线上服务器未验证，不得声称真实可用）。

## 6. 与测试/CI 的接线

| 场景 | 使用方式 |
|---|---|
| L1（Node 单测） | `node --test test/unit/`（mock 服务自测：`--self-test`） |
| L2（Flutter widget） | 纯 Dart fake（`FakeDshClient`/`FakeHostState`），**不启动** Node 服务 |
| L4（集成，模拟器） | 真引擎 + mock 模型（3901）+ fake transport；启动顺序：mock 模型 → fake host/transport → App |
| L5（手工） | `node test/fixtures/mock_model_server.mjs` + App 配置自定义渠道 `http://127.0.0.1:3901/v1` |
| CI | L0/L1 跑 mock `--self-test`；L4 在 macOS runner 启动 mock 后跑 integration test；结束后 kill 服务 |

## 7. TODO-VERIFY（mock 相关未核实项，见 README 汇总）

1. DSH 引擎配置"自定义渠道"时：Base URL 是否必须带 `/v1`、模型名是否允许后缀、是否支持自定义请求头（决定场景触发方式）。
2. 流式 JSON 字段（`reasoning_content` vs `reasoning` vs engine 自定义 thinking 事件）。
3. 工具调用 chunk 的精确形状（OpenAI 标准 vs DSH 适配层）。
4. `packages/dsh_client` 的远程 HTTP/WS 路径、mux 帧、鉴权（决定 fake DSH host 是否值得实现）。
5. `packages/dsh_remote` 的最小 carrier 接口（决定 fake transport 的实现面）。
6. mock 模型是否会被引擎的"模型目录/能力探测"要求额外接口（如 `/v1/models` 之外的能力声明）。
