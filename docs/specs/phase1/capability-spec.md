# Phase 1 能力规格（capability-spec.md）

> 状态：**v1.1**（2026-11-12，Phase 1 收口；新增 D2-03-AC4，其余 AC 不变）。历史冻结：`spec-phase1-v1`（T4，69 AC）；本轮 `spec-phase1-v1.1`（70 AC）。
> 范围：Phase 1 全部能力 ID（计划 §2.1）—— D1-01/02/04、D2-01/03/04、D3-01..08、D3-19、D4-01/03/05/07、D9-01、D1-09/10/11，另加跨切面 **PERSIST-01**（会话持久化/引擎重启/崩溃恢复，计划 §2.1 末条）。
> v1.1 说明：Phase 1 收口发现真实网关（opencode-go 等）要求自定义请求头才能推理；这是 B 范围内“自定义渠道”能力的边界缺口，故新增 **D2-03-AC4**。其余缺口（真实模型、审批可达、进程级杀 App、真实 SSH/Remote、L4 重放等）是**既有 AC 的证据补齐**，不新增/不降低标准。
> 规范：每条 ≥2 条 Given/When/Then 验收标准，编号 `<ID>-AC<n>`；每条 AC 必须可自动化（L0–L4）或明确 `manual`/`deferred`（L5/L6）。
> 证据：`官方依据` 只引用**已核验的文件:行**（main `aee6445` 快照 + `git show` 抽查；行号以本次核对为准）。iOS 实现位置来自分支 `418868c3` 的真实目录结构。
> 关联：`upstream.lock`（版本）、`test-plan.md`（层级/命名）、`traceability.md`（逐行状态，共 **70** 个 AC 行）、`verification-baseline.md`（验收门）。

## 0. 汇总

| 分组 | 能力 ID | 条数 | ≥2 AC | 自动化层级（最低必达） |
|---|---|---|---|---|
| D1 引擎 | D1-01, D1-02, D1-04 | 3 | 3 | L2 状态机 + L4 集成 |
| D2 配置 | D2-01, D2-03, D2-04 | 3 | 3 | L2 widget + L4 |
| D3 对话 | D3-01…D3-08, D3-19 | 9 | 9 | L1/L2 + L4（D3-02/06） |
| D4 会话/工作区/附件 | D4-01, D4-03, D4-05, D4-07 | 4 | 4 | L2 + L4 |
| D9 安全 | D9-01 | 1 | 1 | L2 + L5 |
| D1 远程 | D1-09, D1-10, D1-11 | 3 | 3 | L1/L2 + L4（fake transport）+ L5（真实 host） |
| 跨切面 | PERSIST-01 | 1 | 1 | L4 + L5 |
| **合计** | | **24** | **24** | AC 合计 **70** 条（69 + v1.1 的 D2-03-AC4；与 traceability 行数一致） |

**验收层级定义**（见 `test-plan.md` §1）：L0 静态 / L1 单元 / L2 Widget / L3 契约 / L4 集成（模拟器，真引擎 + **真实或确定性模型**）/ L5 模拟器手工 / L6 真机 deferred。收口轮新增 L4-Real（真实模型/真实 SSH/真实 DSH Remote）作为 L4 的子层；DoD 3 的证据必须来自 L4-Real，mock 只能用于 L1/L2 边界。

**测试命名规范**：`<ID>_<snake_case_behavior>`，例：`D3-06_deny_approval_blocks_tool`；同 ID 多测试加后缀 `_2` 或语义后缀（`_timeout`）。测试文件位置见 `test-plan.md` §3。

---

## D1 引擎与运行环境

### D1-01 · 本机运行环境安装（P0）

- **用户故事**：作为首次使用的用户，我想在 App 内一次装好 Node/DSH 运行环境（离线可用），这样不用电脑也能跑本机引擎。
- **依赖**：无（T3 构建 spike 之后）；后续 D1-02/D2 全部依赖本项。
- **AC**
  - **D1-01-AC1** — Given 全新安装且从未安装运行环境，When 在「设置 › 本机引擎」点安装，Then 进度事件依次出现（安装中→已安装），`getStatus().phase` 走 `notInstalled → installing → installed`，结束后可启动引擎。`自动化 L4`
  - **D1-01-AC2** — Given 安装进行到一半，When 杀掉 App 再打开并再次点安装，Then 安装从断点继续并在有限时间内完成，不重复解压/不崩溃，最终 `installed`。`自动化 L4 + 手工 L5`
  - **D1-01-AC3** — Given 安装包损坏或磁盘不足，When 安装失败，Then 页面显示失败原因与重试入口（不静默、不白屏），App 不崩溃，`failureLog`/诊断可读。`自动化 L2 + 手工 L5`
- **错误/边界**：重复点安装（进行中）不得并发解压；空间不足/校验失败给出稳定错误码；安装成功后重复安装应幂等（版本一致立即完成）。
- **官方依据**：
  - `README.md:176` —「**本机运行**：在 App 内安装 Ubuntu、Node.js 与 DSH 运行环境，无需 Root 或另装 Termux。」
  - `docs/guide/zh/03-engine-hosts.md:22-33` —「## 本机引擎 / 启动、停止、重启…启动失败时显示失败原因和修复按钮…日志」。
  - `docs/architecture.md:12` — 本地运行时「Ubuntu 24.04 base + Node + @deepseek-ai/dsh，经 proot 运行」；`:82-89` 持久化系统与更新约定（首次安装/重置才激活 rootfs、失败不破坏性兜底）。
  - iOS 侧契约：`app/ios/README.md:89-90`（同进程 NodeMobile 首次解压约 160MB；引擎第一次启动才加载）。
- **iOS 实现位置（预期）**：`app/ios/Runner/EngineChannel.swift:660`（`case "install"`）+ `EngineRuntime.swift`；`app/lib/runtime/runtime_bridge.dart`、`app/lib/runtime/runtime_state.dart`；`app/lib/ui/engine/engine_screen.dart`、`engine_status.dart`。
- **测试名示例**：`D1-01_install_progress_to_installed`、`D1-01_install_resumes_after_terminate`。
- **验收层级**：AC1 L4、AC2 L4+L5、AC3 L2+L5。
- **Phase 1 风险**：iOS 无 PRoot；安装形态是"引擎包解压 + NodeMobile framework"，不是 Ubuntu rootfs（见 design ADR-3）。

### D1-02 · 引擎启动/停止/重启/自动启动（P0）

- **用户故事**：作为本机用户，我想随时启停引擎、停止前有确认、停止后在原地能再启动，这样对话可被中断且不用重开 App。
- **依赖**：D1-01。
- **AC**
  - **D1-02-AC1** — Given 已安装，When 点启动，Then 状态进入 `starting → running`，可用 `getStatus().baseUrl` 直连；再点停止，状态 `stopping → installed/stopped`，且正在生成的一轮被中断（客户端收到终止，UI 回 idle）。`自动化 L2 + L4`
  - **D1-02-AC2** — Given 引擎已停止，When 再点启动（同一 App 进程内），Then 引擎成功重启、新对话可用，**不需要重开 App**（分支特性：`runtime/ios/host/node_runner.cc`）。`自动化 L4 + 手工 L5`
  - **D1-02-AC3** — Given 已安装本机环境且默认「打开 App 时自动启动」开启，When 冷启动 App，Then 自动触发启动；When 用户关闭该开关再冷启动，Then 不自动启动（只连远程场景不加载引擎）。`自动化 L4`
  - **D1-02-AC4** — Given 引擎运行中，When 重复点启动/停止（快速双击），Then 状态机幂等、无并发启动、无崩溃、最终状态与最后一次操作一致。`自动化 L2`
- **错误/边界**：启动失败显示原因 + 修复入口（重试/安全模式/日志）；启动中停止要正确取消；引擎异常退出后状态为 error 且可重启（本 Phase 不做自动恢复策略之外的新机制）。
- **官方依据**：
  - `docs/guide/zh/03-engine-hosts.md:27-33` —「**启动**、**停止**、**重启**：停止前会确认；停止和重启都会中断进行中的对话」「启动失败时…修复按钮」「**打开 App 时自动启动**：默认开启」「**日志**」「**后台运行**、**诊断**」。
  - `docs/architecture.md:91-95` — 本地连接：原生层起 `dsh web --host 127.0.0.1 --port 3080 --no-open`，从 stdout 解析 token。
  - iOS 分支：`app/ios/README.md:90` —「停止后能原地再启动，不用重开应用（`runtime/ios/host/node_runner.cc`）」；`runtime/ios/host/node_runner.cc:232-265`（强制 `--jitless`、`--max-old-space-size=256`、`ERR_IOS_HOST_ALREADY_STARTED`、`ERR_IOS_HOST_ARGV`）。
- **iOS 实现位置（预期）**：`app/ios/Runner/EngineChannel.swift:665/670/679`（start/stop/reopenApp）、`EngineRuntime.swift`；`app/lib/runtime/runtime_state.dart`、`app/lib/state/engine_control.dart`；`app/lib/ui/engine/engine_screen.dart`。
- **测试名示例**：`D1-02_start_stop_roundtrip`、`D1-02_restart_after_stop_without_relaunch`、`D1-02_double_start_is_idempotent`。
- **验收层级**：L2（状态机）+ L4（真引擎）+ L5。
- **TODO-VERIFY**：`EngineRuntime.swift` 中 start/stop 的具体行号与错误码集合（本次只核验文件存在与 `EngineChannel` case 行号）；T7 实现时补。

### D1-04 · 引擎日志与启动失败诊断（P0/P1 边界：Phase 1 必做诊断入口）

- **用户故事**：作为排障中的用户，我想看到引擎实时日志和启动失败原因，这样不连电脑也能定位问题。
- **依赖**：D1-02。
- **AC**
  - **D1-04-AC1** — Given 引擎运行或失败，When 打开日志页，Then 显示最近 N 行（默认 300、最多 2000），每条含 `seq/stream/line`，`seq` 单调；App 先订阅事件再取快照，只接 `seq > throughSeq` 的批次，无重复/漏行。`自动化 L1/L2 + L4`
  - **D1-04-AC2** — Given 启动失败，When 查看失败页，Then 显示这次失败原因（优先本次而非旧错误）、可一键复制诊断、可进入日志页；失败页在引擎不可用时仍可打开。`自动化 L2 + 手工 L5`
  - **D1-04-AC3** — Given 日志中含 API Key/Token，When 展示/复制，Then 敏感串按既有脱敏规则打码（不出现完整凭据）。`自动化 L1`
- **错误/边界**：日志环形缓冲有上限；快照与事件不重叠；引擎崩溃后仍可读取 last failure。
- **官方依据**：
  - `docs/architecture.md:52-53` — `getLogs`、`getLogSnapshot`（默认 300/最多 2000，返回 `{entries, throughSeq}`）；`:69` EventChannel `dsh/runtime/events`（`logs` 批次约 100ms，`seq` 进程内递增、重启不归零）。
  - `docs/guide/zh/11-faq.md:45-52` —「## 引擎反复启动失败 … 安全模式 … 诊断页会显示…」。
  - `docs/roadmap.md:15` — 稳定性：「崩溃分类 + 插件搞崩时自动进安全模式重启、上次正常配置恢复、诊断信息一键复制、诊断包导出」。
- **iOS 实现位置（预期）**：`app/ios/Runner/EngineChannel.swift:681/683/690`（getLogs/getLogSnapshot/failureLog）、`app/ios/Runner/DiagnosticsChannel.swift`；`app/lib/runtime/runtime_state.dart`；`app/lib/ui/engine/log_view.dart`、`engine_status.dart`；`app/lib/diagnostics/`。
- **测试名示例**：`D1-04_log_snapshot_does_not_overlap_events`、`D1-04_start_failure_shows_reason`、`D1-04_logs_mask_credentials`。
- **验收层级**：L1/L2 + L4 + L5。

---

## D2 配置

### D2-01 · 首次引导（本机/远程 + 最小权限）（P0）

- **用户故事**：作为新用户，我第一次打开就知道选「本机」还是「远程」，并且只被请求必要权限。
- **依赖**：无（可与 D1-01 并行）。
- **AC**
  - **D2-01-AC1** — Given 首次启动，When 进入引导，Then 出现「本机 / 远程主机」二选一；选本机进入安装/启动路径，选远程进入添加 SSH/Remote 主机路径；中途可返回重选。`自动化 L2`
  - **D2-01-AC2** — Given 首次启动（iOS 模拟器），When 走完引导，Then 只出现 Phase 1 必需的权限请求（如通知仅在使用时/网络），不请求 Android 专属权限（存储/电池优化/无障碍）；完成后进入主界面且不再重复引导。`自动化 L5（权限弹窗无法自动点，人工确认）`
  - **D2-01-AC3** — Given 已完成引导，When 从设置重新进入引导，Then 可修改运行位置/主机选择且不破坏已有数据。`自动化 L2`
- **错误/边界**：引导中跳过安装（远程用户）不阻塞；App 重启后引导状态持久化；未装引擎时本机入口给出"先安装"提示。
- **官方依据**：
  - `README.md:187-193`（Android 安装要求/仅远程可不装本机环境）；`:193`「仅连接远程主机时，不必在手机上安装本机运行环境。」
  - `docs/guide/zh/03-engine-hosts.md:13` —「## 本机还是远程」。
  - `docs/roadmap.md:12` — P0「DeepSeek 账号登录…引导页改为『账号登录（推荐）/ 我有 API Key』」（引导形态依据）。
- **iOS 实现位置（预期）**：`app/lib/ui/onboarding/`（分支真实 12 文件：`onboarding_flow.dart`、`connect_page.dart`、`runtime_choice.dart`、`local_install.dart`、`setup_progress.dart`、`welcome_page.dart`、`api_key_page.dart`、`access_step.dart`、`runtime_setup_page.dart`、`onboarding_scaffold.dart`、`appearance_step.dart`、`usage_notice_row.dart`）。
- **测试名示例**：`D2-01_onboarding_choice_local_vs_remote`、`D2-01_onboarding_not_repeated_after_complete`。
- **验收层级**：L2 + L5。

### D2-03 · API Key 与自定义渠道（P0）

- **用户故事**：作为用户，我能添加 OpenAI/Anthropic/Responses 兼容渠道并保存 Key，这样可用任意兼容服务。
- **依赖**：D3-01（有对话入口即可验证）。
- **AC**
  - **D2-03-AC1** — Given 设置 › 模型 › 添加渠道，When 选择兼容协议、填 Base URL 与 API Key、获取/手动添加模型并保存，Then 保存成功、新模型出现在「选择模型」，且 Key 只写入 Keychain（不出现在日志/诊断/UI 明文之外）。`自动化 L2 + L4（mock 模型）`
  - **D2-03-AC2** — Given Base URL 非法 / Key 错误 / 获取模型失败，When 保存或测试，Then 显示可读错误且不崩溃、不保存半成品配置。`自动化 L2`
  - **D2-03-AC3** — Given 修改已有渠道的 Base URL/Key，When 保存，Then 只有该渠道变化，其他渠道与模型选择不受影响。`自动化 L2`
  - **D2-03-AC4** — Given 某兼容网关要求额外的请求头才能推理（如 opencode-go 的 `x-opencode-session`），When 在添加/编辑渠道的高级区增删请求头并保存，Then 头名必须为合法 HTTP token、值不得含 CR/LF，重复名（大小写不敏感）被拒绝；保存后 headers 进入该渠道 profile 并随推理请求发送，编辑时回显且不清空未知字段；header 值不进入日志/诊断/错误详情。`自动化 L2 + L4（真实网关）`
- **错误/边界**：Key 为空/格式错误的提示；跨站点复用 Key 需确认（官方行为，Phase 1 可只做提示不强制）；订阅渠道只读（Phase 1 不做订阅登录）；请求头只能放在高级区，不能被普通“获取模型”流程静默丢弃；删除全部请求头等价于不发送自定义头。
- **官方依据**：
  - `docs/guide/zh/02-models.md:29-48` —「## 渠道页」「官方/订阅/自定义」三组、「## 添加自定义渠道」步骤（兼容协议 OpenAI/Anthropic/Responses、Base URL、API Key、获取模型、手动添加、保存）。
  - `docs/official-parity.md:77` —「模型服务商与密钥 … 自定义渠道；订阅建的渠道只读」。
- **iOS 实现位置（预期）**：`app/lib/ui/providers/provider_form_page.dart`、`app/lib/ui/engine_settings/`；`app/lib/secrets/secure_storage.dart`（Keychain：`IOSOptions(accessibility: unlocked_this_device)`）；引擎设置 API：`packages/dsh_client/lib/src/engine_settings_api.dart`（分支路径）。
- **测试名示例**：`D2-03_add_custom_provider_saves_key_to_keychain`、`D2-03_invalid_base_url_shows_error`、`D2-03_provider_headers_roundtrip_and_validate`。
- **验收层级**：L2 + L4；AC4 为 L2 + L4-Real（opencode-go `deepseek-v4.1-flash` 直连）。

### D2-04 · 模型切换与思考深度（P0）

- **用户故事**：作为用户，我在对话里随时切模型和思考档位，马上生效。
- **依赖**：D2-03、D3-01。
- **AC**
  - **D2-04-AC1** — Given 已有可用模型，When 点聊天顶栏模型胶囊并选择另一个模型，Then 选择持久化、下一条消息使用新模型（可用 mock 模型服务日志断言请求 model 字段）。`自动化 L2 + L4`
  - **D2-04-AC2** — Given 所选模型支持思考档位，When 打开选择，Then 显示「不思考」与模型声明的档位；选择后本轮/下轮请求携带对应 reasoning 配置；模型不支持时不显示该选项。`自动化 L2 + L4`
  - **D2-04-AC3** — Given 切换失败（模型不可用/渠道被删），When 发送，Then 提示错误、回退到上一个可用模型且不丢失输入。`自动化 L2`
- **错误/边界**：生成中切换模型只影响下一轮（当前轮不换）；无模型时给出去配置入口。
- **官方依据**：
  - `docs/guide/zh/01-chat.md:16` —「## 选择模型」；`docs/guide/zh/02-models.md:58-68`（模型设置：上下文/最大输出/输入类型/思考档位）。
  - `docs/official-parity.md:22` —「`/模型`：模型与推理等级 … 聊天顶栏模型胶囊」。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/model_sheet.dart`、`chat_header.dart`；`app/lib/state/chat_state.dart`；`packages/dsh_client/lib/src/session_api.dart`（模型目录）。
- **测试名示例**：`D2-04_switch_model_applies_to_next_turn`、`D2-04_thinking_levels_hidden_when_unsupported`。
- **验收层级**：L2 + L4。

---

## D3 对话与 Agent 交互

### D3-01 · 新对话与首条消息建会话（P0）

- **用户故事**：作为用户，打开就是可用输入框；发出首条才建会话，不留空会话。
- **依赖**：D2-04。
- **AC**
  - **D3-01-AC1** — Given 在主界面，When 点击新对话，Then 显示输入框与空状态，**不创建**会话；When 输入并发送首条消息，Then 才创建会话并开始流式，会话出现在抽屉列表。`自动化 L2 + L4`
  - **D3-01-AC2** — Given 无可用主机/未安装引擎，When 进入新对话，Then 输入框可用但发送给出明确错误/引导（不崩溃）。`自动化 L2`
- **错误/边界**：空输入不可发送；发送失败保留输入内容；新建会话的默认工作区/模型/权限按上次选择（D2 交互）。
- **官方依据**：
  - `docs/guide/zh/01-chat.md:5-15` —「## 开始新对话」「## 选择模型」。
  - `docs/official-parity.md:15` —「对话视图…聊天页」。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/empty_state.dart`、`composer.dart`、`chat_screen.dart`；`app/lib/state/chat_state.dart`；`app/lib/state/sessions_state.dart`。
- **测试名示例**：`D3-01_first_message_creates_session`、`D3-01_empty_session_not_created_on_open`。
- **验收层级**：L2 + L4。

### D3-02 · 流式回复与思考过程（P0）

- **用户故事**：作为用户，回复逐字出现，思考可展开/收起且收起时显示首行预览。
- **依赖**：D3-01。
- **AC**
  - **D3-02-AC1** — Given mock 模型按 SSE 分片返回 ≥2 个内容块，When 发送消息，Then 输入框上方的回答逐块追加（可在两帧之间观察到中间态），最终完整落库并在重开后仍完整。`自动化 L2 + L4`
  - **D3-02-AC2** — Given 回复包含 thinking 内容，When 流式结束后，Then 思考块可展开/收起；收起时显示首行预览；思考内容不混入正式回答。`自动化 L2`
  - **D3-02-AC3** — Given 流式中途连接断开/mock 返回错误，When 错误发生，Then 当前消息进入错误态（可重试），不无限转圈、不丢已生成内容。`自动化 L2 + L4`
- **错误/边界**：分片乱序/重复（按 mux 事件 seq 去重）；空回复；超长回复截断提示（Phase 1 不优化）。
- **官方依据**：
  - `docs/official-parity.md:15`、`:35` — 对话视图/思考胶囊；`:32-35`（思考与工具卡）。
  - `docs/guide/zh/01-chat.md:5-15`（开始新对话/流式）。
  - 客户端流式：`packages/dsh_client/lib/src/mux.dart`（事件流）；`session_api.dart`（prompt/session）。
- **iOS 实现位置（预期）**：`app/lib/state/chat_state.dart`；`app/lib/ui/chat/chat_rows.dart`、`chat_list.dart`、`turn_summary.dart`；`packages/dsh_client/lib/src/mux.dart`。
- **测试名示例**：`D3-02_stream_appends_chunks_incrementally`、`D3-02_stream_error_shows_retry_state`。
- **验收层级**：L2 + L4。

### D3-03 · 插话（steer）（P0）

- **用户故事**：生成中插一条，AI 下一步看到，不打断当前轮。
- **依赖**：D3-02。
- **AC**
  - **D3-03-AC1** — Given 一轮正在生成，When 直接发送一条消息（默认插话），Then 消息显示在对话底部、不打断生成，且 AI 的下一步（mock 下一请求的 messages 中）包含这条内容。`自动化 L2 + L4`
  - **D3-03-AC2** — Given 插话发送失败（连接断开），When 失败，Then 消息回到输入框/草稿并提示，不丢失。`自动化 L2`
- **错误/边界**：插话仅在生成中可用；生成结束后自动转为普通发送；多设备插话只要服务端事件有就显示（Phase 1 可选）。
- **官方依据**：
  - `README.md:81` —「插话、打断，过程自动收好」；`docs/roadmap.md:27` —「默认插话（DSH `steer`，AI 下一步就看到，不打断）」。
  - `docs/official-parity.md:16` —「输入框、排队发送、插话」；`docs/guide/zh/01-chat.md:52-57` — 插话/中断并发送/排队。
- **iOS 实现位置（预期）**：`app/lib/state/chat_state.dart`、`composer.dart`；`packages/dsh_client/lib/src/session_api.dart`（steer）。
- **测试名示例**：`D3-03_steer_does_not_abort_turn`、`D3-03_steer_failure_restores_draft`。
- **验收层级**：L2 + L4。

### D3-04 · 排队发送/立即发送（P0）

- **用户故事**：消息可先排队，随时改成立即插话/撤回，撤回后回到输入框。
- **依赖**：D3-02。
- **AC**
  - **D3-04-AC1** — Given 一轮生成中，When 长按发送键选「排队」，Then 消息进入底部排队区；当前轮结束后自动发送并开始下一轮。`自动化 L2 + L4`
  - **D3-04-AC2** — Given 排队中有消息，When 点「立即发送」/「改为插话」/「撤回」，Then 分别立即发送/转为插话/回到输入框；三种操作后状态一致、无重复发送。`自动化 L2`
- **错误/边界**：撤回后输入内容可编辑再发；同一轮多条排队按顺序；生成中禁止空消息入队。
- **官方依据**：
  - `docs/roadmap.md:27` —「长按发送可选『停下来先处理这条』或『排队』；排队中的消息可改为插话或撤回（撤回后回到输入框）」。
  - `docs/guide/zh/01-chat.md:52-63` —「长按发送键可以选发送方式」「插话和排队的消息显示在对话底部，可以立即发送/改为插话/撤回」。
  - `docs/official-parity.md:16`。
- **iOS 实现位置（预期）**：`app/lib/state/chat_state.dart`（queue 状态）、`composer.dart`（长按菜单/排队区 UI）。
- **测试名示例**：`D3-04_queued_message_sends_after_turn`、`D3-04_withdraw_returns_text_to_composer`。
- **验收层级**：L2 + L4。

### D3-05 · 停止生成（P0）

- **用户故事**：一键停下本轮，停后连接不受损，可继续下一轮。
- **依赖**：D3-02。
- **AC**
  - **D3-05-AC1** — Given 正在生成，When 点停止（发送键变停止键），Then 本轮结束、UI 回 idle、已生成内容保留，随后可立即发下一条。`自动化 L2 + L4`
  - **D3-05-AC2** — Given 停止时存在排队消息，When 停止完成，Then 排队消息开始下一轮（与官方行为一致）。`自动化 L2 + L4`
  - **D3-05-AC3** — Given 停止请求超时/连接已断，When 无法确认停止，Then 显示"结果未知/连接异常"，不假装已停止、不重复执行工具。`自动化 L2`
- **错误/边界**：连续点停止幂等；停止后恢复流不串到下一条消息。
- **官方依据**：
  - `docs/guide/zh/01-chat.md:52-63` —「输入框为空时，生成中的发送键变为停止键，点按停止当前这一轮。停止后，排队的消息会接着开始下一轮」。
  - `docs/roadmap.md:31` — 停止/出错轮不折叠。
  - iOS 分支：`app/ios/README.md:134`（一轮真引擎含取消/停止，CI engine job 实证）。
- **iOS 实现位置（预期）**：`app/lib/state/chat_state.dart`；`composer.dart`；`packages/dsh_client/lib/src/session_api.dart`（cancel/stop）。
- **测试名示例**：`D3-05_stop_ends_turn_and_keeps_partial`、`D3-05_stop_then_queue_starts_next`。
- **验收层级**：L2 + L4。

### D3-06 · 审批卡（允许一次/总是/拒绝）（P0）

- **用户故事**：工具执行前在对话里批准/拒绝，理由可见；拒绝后不执行。
- **依赖**：D3-08（工具行展示）。
- **AC**
  - **D3-06-AC1** — Given 工具需要审批（如 bash 写文件），When 弹出审批卡，Then 卡片显示命令/文件/原因；点「允许本次」后工具执行一次、工具行出现结果。`自动化 L3 + L4`
  - **D3-06-AC2** — Given 审批卡出现，When 点「拒绝」，Then 工具**不执行**（文件系统无副作用/无可执行结果），对话继续且工具行显示拒绝；审批决定事件只发一次。`自动化 L3 + L4`（测试名 `D3-06_deny_approval_blocks_tool`）
  - **D3-06-AC3** — Given 点「本对话都允许」，When 后续普通工具需要审批，Then 自动放行并显示「自动允许中」横幅；When App 重启，Then 恢复逐次询问。`自动化 L2 + L4`
- **错误/边界**：审批超时；审批期间取消本轮；并发多个审批卡排队；拒绝后模型收到拒绝并继续；「总是允许」不覆盖敏感/危险操作（Phase 1 以引擎侧策略为准）。
- **官方依据**：
  - `docs/official-parity.md:28` —「权限审批卡 | ui-approval · 接管输入框 | ☑️ | 聊天里的审批卡」。
  - `docs/guide/zh/01-chat.md:64-79` —「## 回答提问、处理授权 … 授权卡：看清命令、文件和原因，再选允许本次或拒绝」「本对话都允许…输入框上方会出现自动允许中…App 重启后恢复逐次询问」。
  - 客户端事件：`packages/dsh_client/lib/src/models.dart:1406/1416/1424`（`approval/asked`、`approval/decided`、`approval/policy` case）；应答方法 `packages/dsh_client/lib/src/session_api.dart:674-682`。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/chat_rows.dart`（审批卡）、`app/lib/state/chat_state.dart`（approval 状态机）；`packages/dsh_client/lib/src/session_api.dart`。
- **测试名示例**：`D3-06_allow_once_executes_tool_once`、`D3-06_deny_approval_blocks_tool`、`D3-06_auto_allow_resets_after_restart`。
- **验收层级**：L3（JS/Dart 契约）+ L2 + L4。

### D3-07 · 提问卡与计划待审（P0）

- **用户故事**：模型提问、计划待审在对话里回答/要求修改后再执行。
- **依赖**：D3-06。
- **AC**
  - **D3-07-AC1** — Given 模型发起提问，When 弹出提问卡，Then 显示选项；选择并提交后卡片变已答、结果回传，对话继续；只有一个提问时可从输入框直接回答。`自动化 L2`（L4 见下方"L4 交付方案"）
  - **D3-07-AC2** — Given 计划待审卡，When 点「同意执行」/「要求修改」，Then 分别继续执行/回到修改流程；卡片状态与事件一致（不重复提交）。`自动化 L2`（L4 见下方"L4 交付方案"）
  - **L4 交付方案（T12/T19 落地）**：mock 模型无法直接产出引擎级提问事件（`user-questions/request` 由 `ask_user_question` 工具/引擎 waterfall 触发，见 `models.dart:970/1118-1129`）。L4 采用 **fake DSH host 注入**：fake host 在会话 `$events` 上按需发出 `user-questions/request` waterfall（含 1–3 个问题、选项、超时/拒绝 code），App 走真实 widget 事件链→提交 answer→断言 `session_api.dart:682` 的 answer 到达 fake host；fake host 契约写入 `mocks.md` §3.4。在此之前 D3-07 的 `L4` 标记为 **deferred（T12/T19）**，不阻塞冻结。
- **错误/边界**：多个提问串行；提交失败保留卡片可重试；「其他回答」自定义文本非空。
- **官方依据**：
  - `docs/official-parity.md:29` —「提问卡、计划待审（同意执行 / 要求修改）」。
  - `docs/guide/zh/01-chat.md:64-79` —「提问卡：选一个答案，或点其他回答自己写…」。
  - 客户端事件：`packages/dsh_client/lib/src/models.dart:970/1118-1129`（`user-questions/request` waterfall，`ask_user_question` 工具触发）与 `packages/dsh_client/lib/src/session_api.dart:682-706`（answer/reject/attachWait 方法）。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/chat_rows.dart`；`app/lib/state/chat_state.dart`。
- **测试名示例**：`D3-07_question_answer_submits_once`、`D3-07_plan_review_requires_choice`。
- **验收层级**：L2 + L4。

### D3-08 · 工具行（分组摘要/展开参数结果）（P0）

- **用户故事**：工具调用折叠成一行摘要，点开看参数与结果。
- **依赖**：D3-02。
- **AC**
  - **D3-08-AC1** — Given 模型发起工具调用，When 流式中工具开始/结束，Then 先出现"调用中"行，完成后显示动词+首个字符串参数的摘要；点开显示参数与结果（结果过长可截断）。`自动化 L2`
  - **D3-08-AC2** — Given 同一轮多次工具调用，When 一轮结束，Then 工具行按顺序展示；正常结束的轮可折叠成「已完成 · N 次工具调用」，回答留在外面（D3 验收覆盖回合折叠）。`自动化 L2`
  - **D3-08-AC3** — Given 工具失败，When 结果返回，Then 工具行显示错误态（与成功区分、可展开看错误）。`自动化 L2`
- **错误/边界**：参数是非 JSON/空；工具名未知（通用行）；结果含图片（Phase 1 仅文本，图片附件 deferred）。
- **官方依据**：
  - `docs/official-parity.md:32` —「工具卡片、工作流运行节点、Cordis 卡片 … 聊天里的工具行」；`:15` 过程折叠。
  - `docs/roadmap.md:23` —「工具行分组摘要 + 回合改动卡（点开看 diff）」。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/tool_view.dart`、`chat_rows.dart`、`turn_summary.dart`；`packages/dsh_client/lib/src/session_api.dart`（tool-call 事件）。
- **测试名示例**：`D3-08_tool_row_summary_and_expand`、`D3-08_failed_tool_row_shows_error`。
- **验收层级**：L2。

### D3-19 · 消息操作（复制/分叉/重新回答/引用）（P0）

- **用户故事**：长按消息可复制、从这里分叉、重新回答、引用追问。
- **依赖**：D3-01。
- **AC**
  - **D3-19-AC1** — Given 一条 AI 回答，When 点操作行/长按菜单，Then 复制可用（剪贴板内容正确）、分享入口存在、从这里分叉进入新会话且原对话不变。`自动化 L2 + 手工 L5`
  - **D3-19-AC2** — Given 最后一条 AI 回答，When 点「重新回答」，Then 在新对话中重发（原对话不变），提示条可「返回原对话」；生成中/有排队/带附件时该操作不可用。`自动化 L2 + L4`
  - **D3-19-AC3** — Given 选中文字，When 点「引用」，Then 输入框上方出现引用块，发送后引用随消息发出。`自动化 L2`
- **错误/边界**：复制无内容失败提示；分叉失败保留原会话；非最后一条回答无「重新回答」。
- **官方依据**：
  - `docs/official-parity.md:31`（从某条消息分叉）、`:117-118`（重新回答/引用追问）。
  - `docs/guide/zh/01-chat.md:80-90` —「回答下方的操作行可以直接复制、分享、分叉和重新回答。长按 AI 的回答打开菜单…」「重新回答只对整段对话的最后一条回答可用…」。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/chat_rows.dart`、`secret_mask.dart`；`app/lib/state/chat_state.dart`；`packages/dsh_client/lib/src/session_api.dart`（`session/fork`）。
- **测试名示例**：`D3-19_regenerate_only_on_last_answer`、`D3-19_quote_block_attached_to_message`。
- **验收层级**：L2 + L4 + L5。

---

## D4 会话 / 工作区 / 文件 / 附件

### D4-01 · 会话抽屉（列表/未读/待确认/筛选）（P0）

- **用户故事**：左滑抽屉看全部会话，未读、待审批、待回答有标记并可筛选。
- **依赖**：D3-01。
- **AC**
  - **D4-01-AC1** — Given 有多个会话，When 打开抽屉，Then 按最近活动排序；未读/待确认/待回答有标记；点击切换会话，消息区正确切换。`自动化 L2 + L4`
  - **D4-01-AC2** — Given 抽屉筛选器，When 选「未读/待确认」，Then 只显示匹配会话；无匹配显示空状态；切回「全部」恢复。`自动化 L2`
  - **D4-01-AC3** — Given 切换主机，When 抽屉刷新，Then 只显示当前主机会话（不混主机）；主机断开时显示连接状态。`自动化 L2 + L4`
- **错误/边界**：会话加载失败可重试；新会话插入位置；会话删除/归档（Phase 1 只读主路径，归档操作可选）。
- **官方依据**：
  - `docs/guide/zh/01-chat.md:91-101` —「## 整理对话列表」。
  - `docs/roadmap.md:61` — 抽屉整理（筛选：全部/运行中/待确认/未读；待确认与未读标记）。
  - `docs/official-parity.md:54-57`（会话重命名/归档、待处理交互标记、未读完成提醒）。
- **iOS 实现位置（预期）**：`app/lib/ui/shell/sessions_drawer.dart`、`home_shell.dart`、`session_search_page.dart`；`app/lib/state/sessions_state.dart`。
- **测试名示例**：`D4-01_drawer_filters_unread`、`D4-01_sessions_follow_current_host`。
- **验收层级**：L2 + L4。

### D4-03 · 会话搜索（P0）

- **用户故事**：抽屉顶部即时搜标题/内容，多关键词高亮。
- **依赖**：D4-01。
- **AC**
  - **D4-03-AC1** — Given 多个会话，When 在抽屉搜索框输入关键词，Then 标题即时匹配、多关键词按 AND 匹配、命中高亮；清空恢复列表。`自动化 L2`
  - **D4-03-AC2** — Given 引擎内容索引可用（本机引擎），When 搜索正文词，Then 返回内容命中（中文分词限制按官方说明）；When 切换到远程/未索引主机，Then 只搜标题并给出说明。`自动化 L4（本机引擎）+ 手工 L5`
- **错误/边界**：空关键词不搜；超长输入；无结果空状态；搜索中切主机取消。
- **官方依据**：
  - `docs/roadmap.md:35` —「会话搜索：抽屉顶部，标题即时匹配，多关键词、高亮；本机引擎开了内容索引（中文只能搜到被标点隔开的词）」。
  - `docs/official-parity.md:55` —「会话搜索 | ui-sidebar · 搜索」。
- **iOS 实现位置（预期）**：`app/lib/ui/shell/session_search_page.dart`、`sessions_drawer.dart`；`app/lib/state/sessions_state.dart`；`packages/dsh_client/lib/src/session_api.dart`（搜索）。
- **测试名示例**：`D4-03_search_multi_keyword_and_highlight`、`D4-03_search_without_index_title_only`。
- **验收层级**：L1/L2 + L4。

### D4-05 · 工作区文件浏览与预览（P0）

- **用户故事**：浏览/搜索工作区，文本、图片、PDF 直接预览。
- **依赖**：D1-02（本机）或 D1-10/11（远程）。
- **AC**
  - **D4-05-AC1** — Given 工作区有文件，When 打开文件页，Then 列出目录/文件（图标区分类型）；点文本打开文本预览、点图片显示图片、点 PDF 显示 PDF 预览（iOS 用分支 PDFKit 路径）。`自动化 L4（本机引擎）+ 手工 L5`
  - **D4-05-AC2** — Given 文件不存在/无权限/二进制不支持，When 打开，Then 显示明确错误或"不支持预览"提示，不崩溃、不白屏。`自动化 L2`
  - **D4-05-AC3** — Given 本轮 Agent 改了文件，When 回到文件页，Then 能看到变更（刷新后可读新内容）；文件列表按工作区隔离。`自动化 L4`
- **错误/边界**：大文件截断预览；工作区切换清空列表；路径遍历安全（引擎侧）；Phase 1 预览格式以官方为限（Office 转 PDF 由 Host 决定，可标 deferred）。
- **官方依据**：
  - `docs/official-parity.md:48` —「工作区文件树与文档预览 … 文本 / 图片 / PDF / 表格预览，Office 由主机转 PDF 预览」。
  - `docs/roadmap.md:49` —「工作区文件与文档预览：浏览、搜索、文本 / 图片 / PDF / 表格预览」。
- **iOS 实现位置（预期）**：`app/lib/ui/files/files_page.dart`、`workspace_browser.dart`、`file_glyph.dart`、`table_view.dart`；`app/ios/Runner/NativeFilesChannel.swift`；`packages/dsh_client/lib/src/files_api.dart`/`workspace_api.dart`。
- **测试名示例**：`D4-05_workspace_lists_and_previews_text`、`D4-05_preview_missing_file_shows_error`。
- **验收层级**：L2 + L4 + L5。

### D4-07 · 附件上传（相册/文件 + 待发送条）（P0）

- **用户故事**：发图片/文件，输入框上方有待发送条，消息里显示缩略图/文件卡。
- **依赖**：D3-01。
- **AC**
  - **D4-07-AC1** — Given 输入框，When 从相册选择 1–2 张图片（模拟器相册）或从文件选择器选一个文件，Then 待发送条显示附件（可移除）、发送后消息带缩略图/文件卡。`自动化 L2 + L5（模拟器选择器人工）`
  - **D4-07-AC2** — Given 一次选超过 9 个附件或单文件超限（200MB 官方上限），When 添加，Then 拒绝并提示（不静默截断）。`自动化 L2`
  - **D4-07-AC3** — Given 未发送即杀 App，When 重开，Then 待发送附件与草稿恢复（与 PERSIST-01 联动）或明确清空提示（二选一，按实现选定并测试）。`自动化 L4 + 手工 L5`
- **错误/边界**：模拟器无相机 → 拍照入口禁用/隐藏（Phase 1 明确）；附件上传失败保留待发送条；同消息文本+附件组合。
- **官方依据**：
  - `docs/guide/zh/01-chat.md:20-31` —「## 图片、文件与语音：点输入框旁的加号，选相册、拍照或文件。每条消息最多 9 个附件」。
  - `docs/roadmap.md:26` —「附件：相册 / 拍照 / 文件；输入框上方待发送条；消息里显示缩略图与文件卡…」。
  - `docs/official-parity.md:23` —「/文件：添加附件」。
- **iOS 实现位置（预期）**：`app/lib/ui/chat/media/`（分支真实：`gallery.dart`、`media_card.dart`、`media_viewer.dart`、`media_grid.dart`、`generate_*.dart` 等）、`app/lib/media/`（`media_card.dart`…）；`app/lib/state/attachments.dart`、`draft_store.dart`；`app/ios/Runner/NativeMediaChannel.swift`、`NativeFilesChannel.swift`。
- **测试名示例**：`D4-07_attachment_tray_shows_selected_photos`、`D4-07_reject_more_than_nine_attachments`、`D4-07_draft_attachments_survive_relaunch`。
- **验收层级**：L2 + L5（选择器）+ L4（草稿恢复）。

---

## D9 安全 / 隐私

### D9-01 · 隐私告知与匿名统计开关（P0）

- **用户故事**：明确告知采什么、发给谁；匿名统计可一键关（默认开）。
- **依赖**：无。
- **AC**
  - **D9-01-AC1** — Given 首次启动，When 走欢迎页/引导，Then 显示匿名统计开关（默认开）与说明入口；设置 › 隐私与分享可再次查看/关闭。`自动化 L2 + 手工 L5`
  - **D9-01-AC2** — Given 关闭统计，When 关闭后触发上报路径，Then 不发送统计（iOS 分支 `UsageChannel.swift` 明确"nothing is sent from iOS"；以网络层断言/日志为证）；开关状态持久化且重开保持。`自动化 L2 + L5`
  - **D9-01-AC3** — Given 打开隐私页，When 阅读，Then 列出本机采集/不外发的数据类别（不含 API Key/对话/文件），与官方 FAQ 描述一致。`手工 L5`
- **错误/边界**：iOS 无 Android 匿名统计上报路径 → Phase 1 以"仅告知+本地开关"实现并在验收报告注明差异（不得声称已上报/已关闭上报）。
- **官方依据**：
  - `README.md:197-201` —「## 数据与权限 …『发送匿名使用统计』默认开启，可在首次引导或『设置 → 隐私与分享』关闭」。
  - `docs/guide/zh/11-faq.md:80-88` —「## App 会发送哪些数据」详细清单与关闭后果。
  - `docs/guide/zh/10-settings.md:69` —「## 权限」（设置入口）。
  - iOS 分支差异：`app/ios/Runner/UsageChannel.swift:1-12`（注释：统计在 iOS 端丢弃，nothing is sent from iOS）。
- **iOS 实现位置（预期）**：`app/lib/ui/settings/privacy_page.dart`；`app/ios/Runner/UsageChannel.swift`；`app/lib/state/`（开关持久化）。
- **测试名示例**：`D9-01_no_usage_network_call_when_off`、`D9-01_privacy_page_lists_data_classes`。
- **验收层级**：L2 + L5。

---

## D1 远程主机

### D1-09 · 主机切换（本机/SSH/DSH Remote）（P0）

- **用户故事**：一个抽屉在手机本机、电脑 SSH、DSH Remote 三类主机间切换，对话跟随主机。
- **依赖**：D1-02、D1-10、D1-11。
- **AC**
  - **D1-09-AC1** — Given 至少两个主机（本机 + 一个远程），When 在抽屉底部打开切换主机并选择另一台，Then 连接成功、会话列表切换为该主机的会话、当前主机名与连接状态可见。`自动化 L2 + L4（fake host）`
  - **D1-09-AC2** — Given 上次使用远程主机，When 冷启动，Then 自动连回上次主机（可在远程页关闭该行为）；已保存主机不受影响。`自动化 L2`
  - **D1-09-AC3** — Given 切换到一个不可达主机，When 连接失败，Then 显示错误与重试/管理入口，仍可切回上一个可用主机；不同主机的会话/工作区数据不串。`自动化 L2 + L4`
- **错误/边界**：切换时进行中的一轮要显式处理（停止或提示，Phase 1 采用"停止并提示"）；主机删除时当前主机回落到本机。
- **官方依据**：
  - `README.md:177` —「**远程连接**：通过 SSH 或 DSH Remote 使用电脑、服务器上的 DSH。」
  - `docs/guide/zh/03-engine-hosts.md:62-77` —「## 切换主机 … 选择本机或一台远程主机 … 打开 App 时会连回上次使用的主机 … 想每次先用本机，在远程主机页关闭连接上次使用的主机」。
  - `docs/roadmap.md:145` —「两者都接到同一个 `HostConnection`，抽屉里加"主机切换"（本机 / 电脑 / 服务器）」。
- **iOS 实现位置（预期）**：`app/lib/ui/remote/host_switcher.dart`、`host_status.dart`、`remote_screen.dart`；`app/lib/state/hosts_state.dart`；`app/lib/state/connection_state.dart`。
- **测试名示例**：`D1-09_switch_host_updates_sessions`、`D1-09_unreachable_host_keeps_previous`。
- **验收层级**：L2 + L4。

### D1-10 · SSH 远程主机（P0）

- **用户故事**：填主机/端口/密钥即可用电脑上的 DSH；自动起远端 dsh web、隧道与断线重连。
- **依赖**：D1-09。
- **AC**
  - **D1-10-AC1** — Given 远程主机开启 SSH 且装有 DSH，When 在「添加 SSH 主机」填主机/用户名/端口/密码或私钥并「测试连接」，Then 首次弹指纹信任（TOFU，与主机一致才允许），成功后保存主机。`自动化 L2（表单/状态）+ 手工 L5（真实 sshd）`
  - **D1-10-AC2** — Given 已保存 SSH 主机，When 连接，Then 自动在远端启动 `dsh web`（或使用配置的启动命令）、建立本地端口转发，会话列表加载、发消息流式返回；断开后自动重连。`自动化 L4（fake transport/本地 sshd 可选）+ 手工 L5`
  - **D1-10-AC3** — Given 认证失败/指纹不匹配/远端起不来，When 连接，Then 显示具体错误（不显示密码/私钥明文），不建立隧道、不写入半成品主机。`自动化 L2 + 手工 L5`
- **错误/边界**：私钥口令；nvm 安装的 DSH 需完整路径（启动命令可配）；删除主机只删本地设置与密钥，不影响远端；iOS 本地网络权限（真机 deferred）。
- **官方依据**：
  - `docs/guide/zh/03-engine-hosts.md:78-90` —「## 添加 SSH 主机 … 填主机/用户名/端口 … 密码或私钥 … 启动命令默认 `dsh web` … 测试连接 … 首次连接会弹『信任这台主机？』… 保存」。
  - `docs/roadmap.md:142` —「B. SSH 远程（自带，dartssh2 端口转发 + 现有客户端）」；`:145` B 已完成（主机指纹 TOFU、自动启动远端 dsh web、隧道、断线重连、私钥粘贴/导入）。
- **iOS 实现位置（预期）**：`app/lib/remote/ssh/ssh_transport.dart`、`local_forward.dart`、`remote_shell.dart`、`ssh_host_config.dart`、`ssh_link.dart`、`remote_bootstrap.dart`；`app/lib/ui/remote/ssh_host_form.dart`、`link_progress.dart`；`app/lib/remote/secret_store.dart`。
- **测试名示例**：`D1-10_add_ssh_host_requires_fingerprint_trust`、`D1-10_ssh_connect_and_stream_message`、`D1-10_ssh_auth_failure_shows_error`。
- **验收层级**：L2 + L4（fake）+ L5（真实 host）。
- **TODO-VERIFY**：远端 `dsh web` 启动/隧道复用的具体 Dart 入口签名（T20 补）；iOS `NSLocalNetworkUsageDescription` 是否已在分支 Info.plist 声明。

### D1-11 · DSH Remote 基础连接（P0）

- **用户故事**：扫码/账号连电脑，Noise 端到端加密；续线后会话列表+对话可用。
- **依赖**：D1-09。
- **AC**
  - **D1-11-AC1** — Given 已登录 Remote 账号/有主机，When 选择一台在线主机并信任指纹，Then 建立 Relay（或 LAN/P2P 若可用）连接，会话列表加载，可发消息/审批。`自动化 L4（fake transport）+ 手工 L5（真实服务器，若可用）`
  - **D1-11-AC2** — Given 连接中断，When 网络恢复，Then 自动重试并恢复会话（不产生重复消息）；无法连接时显示错误与重试入口。`自动化 L4`
  - **D1-11-AC3** — Given Phase 1 范围，When 打开 Remote 终端/传文件入口，Then 入口隐藏或标注 Phase 2（不出现"已实现"假象）。`自动化 L2`
- **错误/边界**：上游服务器未开放时入口按官方说明"入口不出现/提示服务端未支持"；WebRTC 直连失败自动回落 Relay；不做终端/传文件（Phase 2）。
- **官方依据**：
  - `docs/guide/zh/03-engine-hosts.md:91-101` —「## DSH Remote … 无需配置网络，连接端到端加密 … 首次连接核对身份指纹 … 连接默认自动尝试局域网/P2P、TURN，最后回落 Relay」。
  - `docs/roadmap.md:137-149`（P2 远程方案 A/B 状态与验证边界）；`docs/changelog.md:19`（1.0.14 远端终端/传文件为新增，Phase 1 延后）。
- **iOS 实现位置（预期）**：`packages/dsh_remote/lib/dsh_remote.dart`、`src/state.dart`；`app/lib/remote/relay/relay_backend.dart`、`dsh_remote_backend.dart`、`webrtc_peer.dart`、`network_route.dart`；`app/lib/ui/remote/relay_login_sheet.dart`、`relay_credit.dart`。
- **测试名示例**：`D1-11_remote_connect_lists_sessions`、`D1-11_remote_reconnect_no_duplicate`、`D1-11_terminal_entry_hidden_phase1`。
- **验收层级**：L2 + L4（fake）+ L5（真实服务器可选）。
- **TODO-VERIFY**：真实 `dsh.r2049.cn` 服务器可用性（研究 11 标注未验证线上账号登录）；WebRTC transport 依赖 `flutter_webrtc` iOS 构建（Phase 1 若 Relay 可用则 WebRTC 可标 deferred）。

---

## 跨切面

### PERSIST-01 · 会话持久化 / 引擎重启恢复 / 崩溃恢复（Phase 1 验收门）

- **用户故事**：作为用户，杀掉 App 或引擎崩溃后重开，会话、消息、工作区与草稿都还在；结果未知的调用不会被重复执行。
- **依赖**：D1-02、D3、D4。
- **AC**
  - **PERSIST-01-AC1** — Given 完成至少一轮对话（含工具调用），When 杀掉 App 再打开，Then 会话列表包含该会话、消息完整、可继续对话；本机引擎自动重启成功。`自动化 L4 + 手工 L5`
  - **PERSIST-01-AC2** — Given 引擎停止/重启（不杀 App），When 重启完成，Then 原会话可继续、工作区文件仍可见；未发送草稿/附件按 D4-07 约定恢复。`自动化 L4`
  - **PERSIST-01-AC3** — Given 工具执行到一半杀掉 App，When 重开该会话，Then 横幅提示"有调用没等到结果"；确认前工具被拒绝；确认后对话可继续，该调用不会重跑。`自动化 L2（unknown_results 状态机）+ 手工 L5`
  - **PERSIST-01-AC4** — Given 引擎崩溃（模拟退出码 70 或异常退出），When 崩溃后，Then App 存活、状态为可重启，重启后不重复执行已完成的工具调用。`自动化 L4`
- **错误/边界**：本机 vs 远程主机分别验证；不会把"进程内状态还在"当成持久化通过；不重复执行工具是安全断言（必须有明确负例测试）。
- **官方依据**：
  - `docs/architecture.md:82-89` — 持久化系统与引擎更新（首次安装/重置、事务、失败不破坏性兜底）。
  - `docs/roadmap.md:15-16` — 稳定性/安全模式（崩溃分类、上次正常配置恢复、安全模式）。
  - iOS 分支验收项：`app/ios/README.md:136-137` —「本机引擎切后台…接着跑或明确报结果未知，不重复执行工具」「结果未知…确认之前工具被拒绝；确认后对话能继续，那个调用不会重跑」。
  - 实现：`app/lib/state/unknown_results.dart:15-60`（iOS/OHOS durable：`durableCallsHostProvider`、`abandonUnknownResults`、`acknowledgeLifecycleUnknown`）。
- **iOS 实现位置（预期）**：`app/lib/state/unknown_results.dart`、`draft_store.dart`、`runtime_state.dart`；`app/ios/Runner/EngineRuntime.swift`（退出/重启路径）；`app/lib/state/chat_state.dart`（恢复横幅）。
- **测试名示例**：`PERSIST-01_relaunch_keeps_conversation`、`PERSIST-01_unknown_result_blocks_reexecution`、`PERSIST-01_engine_crash_recoverable`。
- **验收层级**：L4 + L5。

---

## 附：AC 层级统计与 deferred 标注

| 层级 | AC 数（粗略） | 说明 |
|---|---|---|
| L0 静态 | 0（作为门，不是 AC） | 由 `scripts/verify.sh --static` 保证 |
| L1 单元 | ~9 | chat 状态/搜索/日志脱敏/远程 transport |
| L2 Widget/状态机 | ~38 | 绝大多数 UI 行为 |
| L3 契约 | ~4 | 审批事件、通道协议 |
| L4 集成（模拟器真引擎+mock） | ~30 | 引擎/对话/工作区/持久化/远程 fake |
| L5 手工（模拟器） | ~12 | 引导权限、选择器、真实 sshd、隐私页 |
| L6 deferred（真机/付费/外部） | — | 相机/APNs/后台/真机手机操控/真实 TURN/DDI 等，见 `verification-baseline.md` |

> 标注规则：同一 AC 可跨层（如 D1-01-AC2 = L4+L5），统计按"最低必达"计。所有 AC 在 `traceability.md` 有行，未自动化者必须有 L5 步骤或 deferred 标记，否则视为未覆盖。
