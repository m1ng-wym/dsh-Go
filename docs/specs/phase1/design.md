# Phase 1 设计说明（design.md）

> 状态：T4-draft（staging，待 freeze `spec-phase1-v1`）
> 展开依据：`DSH-Go-iOS/docs/plans/2026-11-10-phase1-b-implementation.md` §0–§3（唯一执行依据）、`research/dsh-ios-research/11-ios-branch-gap-usability.md`、`research/DSH-Go-iOS-实现范围确认与复用方案.md` §3。
> 版本真源：`upstream.lock`。能力真源：`capability-spec.md`。验收真源：`verification-baseline.md`。

## 1. 目标与非目标

### 1.1 目标（Phase 1 = B：基座闭环 + 远程主机）

1. 把 DSH Go 的核心闭环在 iOS 模拟器跑通：**本机引擎安装/启停 → 配置 API Key/模型 → 新对话/流式/插话/排队/停止/审批/提问/工具行/消息操作 → 会话抽屉/搜索 → 工作区浏览/附件 → 杀进程恢复**。
2. 加远程主机：**主机切换（本机/SSH/DSH Remote）+ SSH 远程 dsh web + DSH Remote 基础连接**（会话列表/对话/审批）。
3. 建立可复现的**工程与验证基线**：官方 CI/测试适配到本仓库；`scripts/verify.sh` 全绿；每条能力有 spec + 先失败后通过的测试 + traceability 行。
4. 产出模拟器可运行 App 与验收记录；真机项进 deferred。

### 1.2 非目标（Phase 1 明确不做）

见计划 §2.3 / §7.3：手机操控全部（D5）、iSH 完整 Linux、APNs/Live Activity、后台常驻、伙伴小屋/桌宠、插件市场/原生插件 UI、终端/网页版、媒体保存相册、自动化任务、应用内更新、真机签名安装、iPad 适配、App Store/TestFlight。

> 注意：**iSH guest 在 Phase 1 不构建、不启用**（计划 §1 工具链表：Rust/iSH 不下载不构建）。分支里 `runtime/ios/guest/**`、`tooling/ios/ish/**` 作为**将来资产保留**，但 Phase 1 测试与验收不得依赖 iSH guest 通过；guest 相关 case 在 `verification-baseline.md` 标 deferred。

## 2. 约束

| # | 约束 | 来源/证据 |
|---|---|---|
| C1 | **只做 iPhone、iOS 17.0+、模拟器验收**；无真机、无付费 Apple 账号、零费用 | 计划 §0、§1 |
| C2 | 侧载/自用，不上架；不设对外分发/合同/客户约束 | 计划 §0 |
| C3 | 技术路线：**fork `feat/ios-foundation` → merge main → 修冲突/门禁 → 缺口上开发**；不重写已有能力 | 计划 §3 |
| C4 | 必须保留 `runtime/ohos/**`（iOS 引擎基础层）、`app/ios/**`、`runtime/ios/**`、`tooling/ios/**`；`app/ohos/**` 保留但不构建；`app/android/**` 不改 | 计划 §3.4 |
| C5 | 工具链完全对齐官方 pin：Flutter 3.47.7 / Xcode 26.6 / Node 24.22.1 / Python ≥3.11 | `upstream.lock`；`tooling/ios/prepare-engine.sh:16-19,31` |
| C6 | 严格 TDD：先 RED（功能不存在导致的失败），最小实现，L0–L4 全绿；独立 verifier 复核 | 计划 §4.2 |
| C7 | 无跳过：任何 skip 必须在 `acceptance-report.md` 说明（device-deferred/上游已知） | 计划 §7.1 |

## 3. 架构决策（ADR）

### ADR-1 基座 = fork iOS 分支，而不是从 main 重建

- **决策**：以 `upstream/feat/ios-foundation@418868c3` 建 `phase1/base`，再 merge `upstream/main@aee6445`。
- **理由**：分支已有最难复刻的四块资产——iOS 引擎宿主（NodeMobile `--jitless` 同进程）、guest 沙箱（Phase 1 不启用但保留）、iOS 原生通道层、官方 CI/测试夹具（engine-smoke/假模型/check-archive）。`research/11` §7.2 列出这 5 部分价值。
- **代价/风险**：408 ahead / 350 behind、HEAD CI 红（fixture 漂移）、分支 app 版本 1.0.12+1。→ T1 修 fixture + merge main（13 冲突）+ 对齐 1.0.14+1。
- **Lead 决策（2026-11-10，D1=(a)）**：T1 **修 `tooling/ios/test-guest-embedding.py` fixture**（`runtime/ios/phone` 清单补 `descriptions.mjs`，与 `embed-engine.sh:75` 对齐），并加"产出含 descriptions.mjs"断言；**不采用 `ab2d179c` fallback**。版本口径：merge 目标钉 `aee6445`（v1.0.14），不合并 3edc945f/v1.0.15（见 `upstream.lock#observed_upstream`）。
- **T1 实际结果（2026-11-10，已复核）**：`phase1/base=ef8eba50`；merge commit=`52b78cd7`（parents `418868c3` + `aee6445`，13 冲突已解）；`repo` 的 `upstream/main` ref 实测=`aee6445`；工作树干净；app 版本 `1.0.14+1`；fixture 测试 5/5 OK；l10n `--check` 63 parts/6301 keys OK。T1 时上游线上 main=`3edc945f`（v1.0.15）**未拉进 repo**，按计划推迟。

### ADR-2 `runtime/ohos` 是 iOS 引擎基础层，不是"OHOS 专属代码"

- **决策**：保留 `runtime/ohos/**`；只禁用 OHOS 的**构建工作流/目标**（`ohos-compile.yml`、`host-core.py --hap`），不删共享源码。
- **证据**：`tooling/ios/prepare-engine.sh` 用 `runtime/ohos/package/prepare-inputs.py`、`compose-runtime.py`、`runtime/ohos/process`、`runtime/ohos/node/build-tools` 组合 iOS 运行时；`tooling/ios/embed-engine.sh:41-42` 与 `build-engine-native.sh:39-40` 直接引用 `runtime/ohos/host/publication_binding.cc`、`app/ohos/entry/src/main/cpp/host_core.{cpp,h}`。
- **后果**：删除/改名这些路径会导致 iOS 引擎无法构建；T1/T5 的裁剪只做 workflow 触发层。

### ADR-3 本机引擎：同进程 NodeMobile `--jitless`，不是 PRoot、不是独立进程

- **决策**：直接继承分支引擎宿主（`runtime/ios/host/**`、`app/ios/Runner/EngineRuntime.swift`、`EngineChannel.swift`），Phase 1 只做安装/启停/重启/日志/诊断缺口。
- **证据**：`app/ios/README.md`「本机引擎和鸿蒙共用基础层：同进程的 Node（NodeMobile 24.22.1，`--jitless`）」；`runtime/ios/host/node_runner.cc`（原地停止/再启动；堆上限退出码 70；fd 取舍）。官方架构文档 `docs/architecture.md:91-95` 的本地连接方式仍是本机 `dsh web` + token + cookie（Android 形态），iOS 使用同一 DSH 引擎协议，仅宿主实现不同。
- **后果**：Phase 1 命令执行走 just-bash/Node Worker 语义，不承诺真实 Linux（guest 契约 5 条中 2–4 条 deferred，见 `verification-baseline.md`）。
- **Lead 决策（2026-11-10，D3=(a)）**：`app/ohos/**` 保留但 Phase 1 不构建；`app/ohos/entry/src/main/cpp/host_core.{cpp,h}` 是 iOS 构建输入（`embed-engine.sh:41-42`、`build-engine-native.sh:39-40`），**绝不删除**。仅禁用/删除 `ohos-compile.yml` 触发与 `host-core.py --hap` 步骤。

### ADR-4 远程主机：共享 Dart 优先，iOS 原生仅网络权限

- **决策**：SSH 与 DSH Remote 全部走共享 Dart（`app/lib/remote/ssh/**`、`packages/dsh_remote/**`、`app/lib/remote/relay/**`）；iOS 侧最多补 Info.plist 本地网络用途说明与网络状态。
- **证据**：branch 真实目录 `app/lib/remote/ssh/{ssh_transport,local_forward,remote_shell,ssh_host_config,ssh_link,remote_bootstrap}.dart`、`app/lib/remote/relay/{relay_backend,dsh_remote_backend,webrtc_peer,network_route}.dart`、`packages/dsh_remote/lib/{dsh_remote.dart,src/state.dart}`；官方 `docs/guide/zh/03-engine-hosts.md:62/78/91`（主机切换/SSH/DSH Remote）与 `docs/roadmap.md:137-149`（Remote 方案 A/B 状态）。
- **后果**：Phase 1 的远程测试可用 fake transport/mock host，不强依赖真实服务器；真实 SSH 主机作为 L5 手工。

### ADR-5 持久化与崩溃恢复以"真实引擎 + 杀进程"为验收

- **决策**：会话/消息/工作区由 DSH 引擎侧持久化；App 侧只保留端点/凭据/草稿等；杀 App 重开 → 会话仍在、引擎可重启。
- **证据**：`docs/architecture.md:82-89`（持久化系统与引擎更新）；`docs/roadmap.md:15-16`（稳定性/安全模式）；分支 `app/lib/state/unknown_results.dart`（结果未知 durable 语义，`research/11` D3-12/§2.4）；`app/lib/state/draft_store.dart`。
- **后果**：验收必须包含"杀进程后重开"（L4 集成 + L5 手工），不能只做进程内状态断言。

### ADR-6 测试策略：mock 模型/假 host 先行，真实引擎补位

- **决策**：L1/L2 用纯 Dart/Flutter mock；L4 用**真 Node 引擎 + mock 模型 SSE + fake host/transport** 在模拟器跑；真实模型只做一次 L5 手工冒烟。
- **理由**：官方 CI 亦采用"假模型真回合"（`tooling/ios/engine-smoke/drive.mjs` 头注释：drives real tool/lifecycle rounds；`guest-drive.mjs`：synthetic model, production approval chain）。Phase 1 无真实账号/网络预算，mock 是唯一可重复路径。
- **产物**：`test/fixtures/mock_model_server.mjs`（Node `node:http`，SSE/工具调用/审批/错误四场景）、`mocks.md` 端口与凭据约定、fake DSH host / fake SSH transport 设计。
- **Lead 决策（2026-11-10，D4）**：**默认 (b)** —— mock 内置 `POST /__mock/scenario` 顺序控制；两种方式都支持（若 T12 前 G3 验证引擎支持自定义 header/模型后缀，则优先 (a)）。`mocks.md` 已写清两种方式与默认值。

### ADR-7 验收分层：模拟器必过，真机 deferred

- **决策**：L0–L4 全绿为 Phase 1 门；L5 手工仅模拟器；L6 真机/付费/外部依赖进 deferred 清单（计划 §7.3）。
- **后果**：`verification-baseline.md` 明确每项 AC 的层级与 deferred 状态；`acceptance-report.md` 三张表（通过/未通过/deferred）。

### 3.8 Lead 决策记录（2026-11-10，已定）

| # | 决策 | 已定结论 | 落地位置/任务 | 备注 |
|---|---|---|---|---|
| D1 | HEAD fixture 修复 | **(a)** 修 `test-guest-embedding.py` fixture（补 `descriptions.mjs` + 加"产出含 descriptions.mjs"断言）；**不用 ab2d179c fallback** | T1（B-3） | 与 `embed-engine.sh:75` 对齐 |
| D2 | 部署目标/设备族 | **(a)** iOS 17.0 + `TARGETED_DEVICE_FAMILY=1`；T3 实测 SPM/依赖可编译性，若插件要求更高版本则记录并只在必要时调整（以实测为准） | T3（B-5） | 分支当前 16.0/15.0 + `"1,2"` |
| D3 | `app/ohos/` 处置 | **(a)** 保留但不构建；`host_core.*` 绝不删（iOS 构建输入） | T1/T5（B-6） | 仅删 OHOS workflow 触发/`--hap` |
| D4 | mock 场景触发 | **默认 (b)** `POST /__mock/scenario`；**两种都支持**，若 G3 验证引擎支持 header/模型后缀则 T12 前优先 (a) | T12（G3） | 见 `mocks.md` §2.2 |
| D5 | `--full` Flutter 范围 | **(a)** Phase 1 相关子集 + 排除 goldens；G7/G9 TODO 由 T5 落地 | T5 | 见 `test-plan.md` §6/§9 |
| D6 | CI 建设时点 | T5 建 `phase1-verify.yml`（T1/T2 就绪后） | T5 | — |
| D7 | mirror/fork 备份 | 按计划：T1 已完成 GitHub fork 备份，并将记录 refs manifest | T1 | 位置以 T1 记录为准 |
| V | 版本口径 | **合并目标钉 `aee6445`（v1.0.14）**；T1 已合并 `aee6445`（merge `52b78cd7`，base `ef8eba50`）；观察到的上游线上 main=`3edc945f`（v1.0.15，11-10 14:34 发布）**未拉进 repo**；v1.0.15 同步推迟到 Phase 1 结束后每周 sync | T1 已完成 / `upstream.lock#t1_result` | 不得写"已合并 3edc945f" |

## 4. 组件与调用链（Phase 1 视角）

```
Flutter 共享 Dart（app/lib/ui、app/lib/state，大多平台无关）
   │  MethodChannel/EventChannel（iOS 分支 24 个 iOS 通道，Phase 1 相关：dsh/runtime(+events)、dsh/app、dsh/files、dsh/media、dsh/links、dsh/diagnostics、dsh/secrets、dsh/attachment-files）
   ▼
Swift 原生层（app/ios/Runner/）
   ├─ EngineChannel.swift / EngineRuntime.swift     本机引擎安装/启停/日志（→ runtime/ios/host/**）
   ├─ DiagnosticsChannel.swift                       日志/诊断
   ├─ NativeFilesChannel.swift / NativeMediaChannel.swift  文件与附件
   └─ 其他（Phase 1 保留但不扩展：Guest/Phone/Pet/Share/Siri…）
   ▼
NodeMobile 24.22.1 --jitless（运行时由 tooling/ios/prepare-engine.sh 组装：runtime/ohos 基础层 + runtime/ios 宿主/addon）
   ▼
DSH 引擎（@deepseek-ai/dsh 0.2.2-rc.1 pin）──本机 loopback──> App/Dart 客户端（packages/dsh_client）
   │
   └─ 远程：packages/dsh_client（HTTP/SSE/mux）+ app/lib/remote/ssh/**（dartssh2 端口转发）
            + packages/dsh_remote/**（Noise/Relay/LAN/WebRTC）+ app/lib/remote/relay/**
```

- **本地连接契约**（沿用官方）：原生层启动本机 `dsh web`，从 stdout 解析 token；Dart 用 token 换 cookie，之后 HTTP/WS 带 cookie、不带 `Origin`（`docs/architecture.md:91-95`）。
- **引擎平台通道契约**（分支实现，Phase 1 必须保持）：`dsh/runtime` 方法 `getStatus/install/start/stop/reset/reopenApp/getLogs/getLogSnapshot/clearFailure/failureLog/publishDiagnostics…` + `dsh/runtime/events`（`app/ios/Runner/EngineChannel.swift` 实际 case 列表）。
- **流式/审批协议**：`packages/dsh_client/lib/src/mux.dart` + `session_api.dart` 等；关键事件 `approval/asked|decided|policy`、`question`、`tool-call*`、`session/follow`（grep 实证，见 `capability-spec.md` 各条依据）。

### 4.2 merge main 的 13 个冲突文件（T1 实测，逐项结果）

> 来源：T1 报告 `reports/tasks/T1-baseline.md` §3（`git diff --name-only --diff-filter=U` 实测；merge `52b78cd7`，parents `418868c3` + `aee6445`）。**恰好 13 个冲突文件，无额外冲突**；`app/pubspec.yaml` **不在冲突列表**（clean merge，版本自然成为 main 的 `1.0.14+1`）。
> 处理脚本：`reports/tasks/resolve_t1_conflicts.py`（可复跑，断言每个文件预期 hunk 数 + 无残留 conflict marker；`git grep -l '^<<<<<<< '` = 空）。

| # | 文件（实际冲突） | 处理结果 |
|---|---|---|
| 1 | `app/lib/l10n/parts/phone_en.arb` | 纯增量合并：main 新增 key + 分支 5 个 iOS key（`phoneIos*`）；无同 key 冲突（脚本校验） |
| 2 | `app/lib/l10n/parts/phone_zh.arb` | 同上（中英同步） |
| 3 | `app/lib/l10n/app_en.arb` | **不手改**：由 parts 重新生成（官方工具） |
| 4 | `app/lib/l10n/app_zh.arb` | 同上 |
| 5 | `app/lib/l10n/gen/app_localizations.dart` | **不手改 gen**：`python3 app/tool/l10n_merge.py` 重新生成 |
| 6 | `app/lib/l10n/gen/app_localizations_en.dart` | 同上 |
| 7 | `app/lib/l10n/gen/app_localizations_zh.dart` | 同上；结果：`✓ 63 parts, 6301 keys` |
| 8 | `app/lib/state/phone_turn_end.dart` | 取 main 的 `if (link.onStatus(legacy))`，保留分支新增 `_nativeOwnerSessionId = status.task.ownerSessionId;`（分支 `_snapshot` 依赖） |
| 9 | `app/lib/ui/chat/chat_screen.dart` | dispose 两行并集：`_toTop?.dispose();`（分支 iOS 状态栏）+ `_dropPreparedPhoneSkill();`（main） |
| 10 | `app/lib/ui/phone/dnd_mode_page.dart` | main 的 `!_ready || _busy` 守卫 + 分支的 `Switch.adaptive`（iOS 观感） |
| 11 | `app/lib/ui/phone/phone_control_screen.dart`（2 hunk） | hunk1：main 的 `_resumeRead`/`_skillPromptsReady` 逻辑 + 分支 `phoneLinkProvider.refresh()`；hunk2：取 main 的 `PhoneSkillAutoPrompt` 包装（分支 `_buildIOS()` 早返回路径不受影响） |
| 12 | `runtime/patches/pins.json` | 并集：base 113 + main 10 + 分支 21 → **144 条**，保持排序；两侧新增 key 无重叠 |
| 13 | `app/.gitignore` | 并集：保留分支 HarmonyOS 段（`/pubspec_overrides.yaml`）+ main v1.0.14 伙伴小屋新措辞 |

**结果核对（T4 复核）**：merge `52b78cd7` 为真实两父合并；工作树干净；`upstream/main` ref=`aee6445`；`app/pubspec.yaml`=`1.0.14+1`；fixture 测试 5/5；l10n `--check` 63 parts/6301 keys。**13 冲突为文本级解决，编译级验证（flutter analyze/xcodebuild）属 T3 第一道门**（T1 报告 §6 风险 1）。

## 5. 数据与状态

| 数据 | 位置/机制 | Phase 1 AC |
|---|---|---|
| 会话/消息/工作区 | DSH 引擎侧持久化（本机引擎目录；远程主机侧） | PERSIST-01、D3-01、D4-01 |
| API Key/凭据 | iOS Keychain（`app/lib/secrets/secure_storage.dart`；`flutter_secure_storage` `unlocked_this_device`） | D2-03；D9-01（隐私告知） |
| 端点/主机列表/当前主机 | 共享 Dart（`packages/dsh_client` secret store 抽象 + `app/lib/state/hosts_state.dart`） | D1-09 |
| 草稿/待发送附件 | `app/lib/state/draft_store.dart`、`attachments.dart`；杀进程后可恢复 | D4-07、PERSIST-01 |
| 结果未知标记 | `app/lib/state/unknown_results.dart`（durable） | PERSIST-01 |
| 诊断日志 | 引擎环形缓冲 + `EngineChannel.getLogSnapshot`/`DiagnosticsChannel` | D1-04 |

## 6. 风险（Phase 1）

| 风险 | 影响 | 缓解 | 触发点 |
|---|---|---|---|
| merge main 冲突/回归（13 文件） | 基座不稳 | Lead 独占冲突解决；l10n 走生成器；T1 后先跑官方 compile/engine 门 | T1 |
| HEAD fixture 红 | CI 假失败、无法验收 | 一行修复或钉 `ab2d179c` | T1/T5 |
| prepare-engine 下载/编译失败 | 无本机引擎 → 只剩远程 | 官方 pin/SHA 校验；网络重试；CI artifact 备选；T3 首日 spike | T3 |
| 本机 Python 3.10 不足 | prepare-engine 失败 | 安装 3.12（`brew install python@3.12`），脚本内绝对路径 | T2 |
| iOS 17.0 与分支 15/16 部署目标差异 | 编译/插件兼容问题 | T3 实测；按 target 设置；记录理由 | T3 |
| 模拟器与真机差异 | 假绿 | deferred 清单 + contract test + Phase 2 真机矩阵 | 全程 |
| 远程无真实 host | D1-10/11 不可测 | mock/fake transport + 本机 sshd/DSH 可选；无 host 标 manual-deferred | T19–T21 |
| 测试为过而过 | 质量假象 | 独立 verifier + RED 证据 + 回退抽查 + traceability 100% | 每任务 |
| AGPL/GPL 合规（若对外） | 法务风险 | Phase 1 自用；对外前法务评估（iSH GPLv3 尤其） | Phase 2+ |

## 7. 与其它文档的关系

- `upstream.lock`：版本/SHA/工具链真源。
- `capability-spec.md`：每个 ID 的用户故事、AC、证据、实现位置、验收层级。
- `test-plan.md`：L0–L6、TDD 规则、mock/fixture、CI 门、flaky 策略。
- `verification-baseline.md`：复用的官方 CI/测试/contract-gates/43 项验收 + 新增项 + deferred + 阈值占位。
- `traceability.md`：ID ↔ 实现 ↔ 测试 ↔ 验收记录（逐行，缺一不得合并）。
- `acceptance-checklist.md`：模拟器手工验收步骤。
- `mocks.md` + `test/fixtures/mock_model_server.mjs` + `scripts/verify.sh`：可执行基座。
