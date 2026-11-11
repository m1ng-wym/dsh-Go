# Phase 1 测试计划（test-plan.md）

> 状态：**v1.1**（2026-11-12，Phase 1 收口）。v1 冻结 69 AC；v1.1 新增 D2-03-AC4 与 L4-Real/冷启动/UI 进程级三层证据要求。
> 依据：计划 §4.2（测试层级与"可失败"要求）、§7.1（自动化门）；`capability-spec.md`（**70** 个 AC）；`verification-baseline.md`（验收门）；`mocks.md`（mock 设计）；`docs/plans/2026-11-12-phase1-completion.md`（收口计划）。
> 原则：**行为覆盖优先于行覆盖率**；每个 AC 至少一个自动化测试或被明确标 `manual`/`deferred`；禁止"只断言 mock 调用"的测试。

## 1. 测试层级（L0–L6）

| 层 | 范围 | 运行位置 | 命令（repo 就绪后） | 必达 |
|---|---|---|---|---|
| **L0 静态** | `flutter analyze`、`dart analyze`（packages）、Swift typecheck、l10n/guide 生成物一致性、Node 语法/静态检查 | 本机/CI ubuntu | `scripts/verify.sh --static` | 所有任务 |
| **L1 单元** | Dart 纯逻辑（状态机/解析/脱敏/队列）、Node 运行时/桥接、Swift 纯函数 | 本机/CI | `flutter test test/unit`；`dart test`（packages）；`node --test test/unit/**/*.test.mjs`；Swift 纯逻辑在 RunnerTests | 所有逻辑改动 |
| **L2 Widget** | Flutter 页面/状态/通道 fake（approval card、queue、drawer、search、files、model sheet…） | 本机/CI ubuntu（flutter test 无需模拟器） | `flutter test test/widget` | 所有 UI AC |
| **L3 契约** | Swift 通道协议/JSON/错误码（RunnerTests）；Dart↔bridge 契约；审批/问题事件形状 | macOS 模拟器 | `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`（只跑 Phase 1 相关 suite） | 通道/协议改动 |
| **L4 集成（模拟器）** | **真 Node 引擎 + 确定性 mock 模型**；只用于 L1/L2 边界与确定性时序（流中断、超时、错误态） | macOS 模拟器 | `flutter test integration_test/phase1_test.dart -d <sim>`；辅助 `tooling/ios/engine-smoke/*`（官方资产） | 每个 Wave 结束 |
| **L4-Real（模拟器，DoD 3 法定层）** | **真 App + 真引擎 + 真实 opencode-go 模型**；工具调用/审批/工作区/持久化；真实 SSH；真实自托管 DSH Remote | macOS 模拟器 | `scripts/verify.sh --real`；`scripts/verify.sh --remote`；`app/integration_test/phase1_real_*` | Phase 1 v1.1 验收 |
| **L4-Process（模拟器，进程级）** | `simctl terminate`/XCUITest `terminate()+launch()`；冷启动、安装续装、自动启动、失败诊断、杀进程持久化、系统选择器 | macOS 模拟器 | `Phase1UITests` + 宿主脚本 | Phase 1 v1.1 验收 |
| **L5 手工** | 仅系统不可自动化项（权限弹窗等）；**不再接受**“真实模型/真实 sshd/真实 Remote 属 L5”的口径 | 模拟器 | `acceptance-checklist.md` 44 项逐项证据（PASS/Phase 1 外） | Phase 1 v1.1 |
| **L6 Device-deferred** | 相机/APNs/后台/性能/触控/真机签名/CoreDevice/DDI | 真机 | 记录，不进 Phase 1 门 | T23 交付报告 |

**层级选择规则**：AC 已标注层级（`capability-spec.md` 每条）；实现测试不得低于该层级。纯 UI 行为默认 L2；涉及引擎/持久化/远程必须有 L4；安全相关负例（拒绝、不重复执行、脱敏）必须有独立断言。

### 1.1 真实层与进程层的硬规则（v1.1 收口）

1. **真实模型**：L4-Real 使用 opencode-go `deepseek-v4.1-flash`（`baseURL=https://opencode.ai/inference/go/v1`，需 `x-opencode-session` 头），凭据只从运行时 credential broker 取，不落仓、不进日志、不进截图；缺 key / 网络不可达一律 FAIL，不 skip。
2. **真实 SSH**：使用临时非特权 sshd（`127.0.0.1:22422`，临时 host/client key、独立 `AuthorizedKeysFile`），不改 `~/.ssh`；远端 `dsh web` 使用临时 `DSH_HOME`。fake SSH 只保留给 L2 负例。
3. **真实 DSH Remote**：自托管上游 `apps/server` + `ds-harness-remote` Host 插件（隔离 `DSH_HOME`，loopback）；fake relay 只保留给 L2 负例。
4. **进程级**：凡“杀 App 重开/安装续装/冷启动自动启动/失败诊断”必须有 `simctl terminate` 或 XCUITest `terminate()+launch()` 的证据；进程内 `runApp` 重建不算。
5. **禁止假绿**：默认 `--full` 的 skip 必须为 0；`--real`/`--remote` 缺前置条件即 FAIL；任何 `skip:`/`-skip-testing`/文件排除必须写入 `reports/phase1-completion/skip-audit.md` 并由 verifier 复核。
6. **预算**：真实模型调用串行、总预算约 100 次；网络失败最多重试 2 次，重试不得放宽容差或改写断言。

## 2. TDD 硬规则与 RED 证据

每个任务（T7–T21）必须按以下顺序，违反任一项 verifier 直接 FAIL：

1. **写一个失败测试**：测试名含能力 ID（`D3-06_deny_approval_blocks_tool`）；一个测试只验证一个 AC。
2. **运行并记录 RED**：
   - 命令 + 完整失败输出 + 退出码写入任务记录（`reports/T<id>-red.md` 或任务 PR 描述）。
   - 失败原因必须是**"功能不存在/行为不符"**；语法错误、环境错误、测试自身错误不算 RED，修好再跑。
   - 失败输出需能让人看出期望行为（断言信息含 AC 编号）。
3. **最小实现**：只写让该测试通过的最少代码；禁止提前实现未测行为。
4. **GREEN**：目标测试通过 + `scripts/verify.sh --fast` 全绿（含 L0/L1/L2 + 相关 L3/L4）。
5. **重构后重跑**；提交信息含 spec ID。
6. **独立 verifier**：在新 worktree/新 checkout 复核——跑测试、检查测试确实覆盖 spec、**回退实现抽查**（`git stash`/反向 patch 后测试必须失败）、检查无 skip、检查 traceability 已更新。PASS 才允许 Lead 合并。
7. **禁止**：先写产品代码再补测试；只断言 mock 调用；测试里写生产逻辑；为过测试改断言/断言实现内部细节；跳过测试；用 `--update-goldens` 掩盖回归。

### RED 记录模板

```markdown
## T<id> RED 证据
- AC：D3-06-AC2
- 测试：`app/test/phase1/d3_06_approval_test.dart` :: `D3-06_deny_approval_blocks_tool`
- 命令：`cd repo/app && flutter test test/phase1/d3_06_approval_test.dart`
- 退出码：1
- 失败原因（摘要）：点击"拒绝"后 mock 引擎仍收到 tool/execute，文件被创建 → 断言失败（期望拒绝后无执行）
- 失败输出：<贴关键 20 行>
- 环境：Flutter 3.47.7 / iPhone 17 Pro (iOS 26.5) / commit <sha>
```

## 3. 测试文件布局与命名

> **注意**：T1 合并后的仓库里 `app/test/` 已存在大量官方测试；Phase 1 **新增**测试放独立目录，避免与上游冲突，便于上游同步。

```
repo/
  app/test/phase1/                      # Flutter 单元/Widget（新增）
    d1_01_engine_install_test.dart
    d1_02_engine_lifecycle_test.dart
    d1_04_engine_diagnostics_test.dart
    d1_09_host_switch_test.dart
    d1_10_ssh_host_test.dart
    d1_11_dsh_remote_test.dart
    d2_01_onboarding_test.dart
    d2_03_provider_config_test.dart
    d2_04_model_switch_test.dart
    d3_01_new_chat_test.dart
    d3_02_stream_test.dart
    d3_03_steer_test.dart
    d3_04_queue_test.dart
    d3_05_stop_test.dart
    d3_06_approval_test.dart
    d3_07_question_plan_test.dart
    d3_08_tool_row_test.dart
    d3_19_message_actions_test.dart
    d4_01_sessions_drawer_test.dart
    d4_03_session_search_test.dart
    d4_05_workspace_files_test.dart
    d4_07_attachments_test.dart
    d9_01_privacy_test.dart
    persist_01_recovery_test.dart
    support/                            # 测试夹具：FakeDshClient、FakeHost、SseServer harness
  app/integration_test/phase1_test.dart  # L4：真引擎 + mock 模型（确定性边界）
  app/integration_test/phase1_real_*.dart # L4-Real：真引擎 + 真实 opencode-go / 真实 SSH / DSH Remote
  app/ios/PhoneRunner/Phase1UITests.swift # L4-Process：冷启动/续装/系统选择器（独立 UI test bundle）
  app/ios/RunnerTests/Phase1*Tests.swift # L3：仅新增 Swift 契约测试（新增文件，不改官方文件）
  test/fixtures/                        # 仓库根（新增，跨语言 fixture）
    mock_model_server.mjs               # Node SSE mock（本次交付骨架）
    fake_dsh_host/                      # fake host 脚本/说明（Phase 1 按需实现）
    fixtures/                           # 固定测试数据（会话样本、图片、PDF）
  test/unit/                            # Node 单元测试（新增）
  test/contract/                        # 可选：JSON schema/事件形状（新增）
  scripts/verify.sh                     # 本次交付骨架
```

**命名规范**：
- 测试函数：`<ID>_<behavior>`（如 `D3-06_deny_approval_blocks_tool`）；同一测试文件内可加 `_2`。
- 测试文件：`<id 小写>_<topic>_test.dart` / `.mjs`。
- L5 步骤：`AC-<n>` 对应 `acceptance-checklist.md` 的条目。

## 4. Mock / Fixture 设计（细节见 `mocks.md`）

| Mock | 用途 | 端口/凭据 | 覆盖场景 |
|---|---|---|---|
| **mock 模型服务**（`test/fixtures/mock_model_server.mjs`，Node `node:http`） | 替代真实模型 API，给真引擎喂确定性响应 | `127.0.0.1:3901`；`sk-mock-phase1-model` | ①流式文本 ②工具调用 ③审批前工具调用（触发审批卡）④错误（HTTP/SSE） |
| **fake DSH host** | 远程主机（D1-09/10/11）的假 host：会话列表/发送/流式/审批事件 | `127.0.0.1:3902`；`mock-host-token-phase1` | 连接/会话列表/一轮流式/审批/断线 |
| **fake SSH transport** | 远程 SSH 的传输层 fake（Dart 接口 mock） | 进程内 | 连接/Tofu 指纹/隧道/重连/认证失败 |
| **fake DSH Remote transport** | Relay 传输 fake（Dart 接口 mock） | 进程内 | 连接/会话/重连/不支持能力 |
| 官方 engine-smoke（复用） | 真引擎/工具/审批/guest/图片/fd/heap 的官方夹具 | 见官方 `tooling/ios/engine-smoke/` | 见 `verification-baseline.md` §3 |

**测试隔离规则**：
- 每个测试用独立临时目录（`Directory.systemTemp.createTemp` / `mkdtemp`），结束清理；不得写用户目录。
- mock 服务每个测试文件启动一个实例（随机端口可用 `MOCK_MODEL_PORT=0` 由 harness 读取实际端口；默认固定 3901 便于手工调试）。
- 测试不得依赖真实网络、真实 API Key、真实 DSH 服务器；唯一例外是 L5 手工步骤（显式标注）。
- 时间：优先注入 `Clock`/`fake_async`；禁止 `sleep` > 100ms 的等待（用事件/轮询上限）。

## 5. 测试数据

| 数据 | 位置 | 说明 |
|---|---|---|
| mock SSE 场景脚本 | `test/fixtures/scenarios.json`（Phase 1 新增） | `{name, chunks[], toolCall?, error?}`；mock 服务按 `x-mock-scenario` 头选择 |
| 会话/消息样本 | `test/fixtures/fixtures/session_*.json` | 与 `packages/dsh_client` 模型对齐；用于 L1/L2 |
| 图片附件 | `test/fixtures/fixtures/img_1x1.png`、`img_8x8.png` | 小体积、可提交；不要用官方 `app/test/fixtures`（避免冲突/体积） |
| 文本/PDF 工作区样本 | `test/fixtures/fixtures/workspace/`（`hello.md`、`note.txt`、`one_page.pdf`） | L4 工作区预览用 |
| SSH 指纹/主机样本 | `test/fixtures/fixtures/ssh/` | 仅测试用生成密钥，不得复用真实密钥 |
| 结果未知场景 | `test/fixtures/scenarios.json#unknown_inflight` | 工具执行中杀进程/断连，验证不重复执行 |

> 所有 fixture 必须无隐私数据、无真实凭据、体积 < 1 MB（PDF/PNG 例外但 < 5 MB）。禁止把真实设备日志/配对记录/截图放进 fixture。

## 6. CI 门

### 6.1 本地 `scripts/verify.sh`（唯一入口）

| 档 | 内容 | 用时目标 |
|---|---|---|
| `--static` | L0：`flutter analyze`、`dart analyze`（packages）、`node --check`/`node --test test/unit`（语法/纯单测）、l10n/guide `--check`、Swift `swiftc -typecheck`（无 Xcode 时的可用子集） | < 3 min |
| `--fast` | `--static` + L1/L2（`flutter test test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1` + packages `dart test` + Node 单测） | < 10 min |
| `--full` | `--fast` + L3（RunnerTests；仅排除 D6 deferred 的 `NativeToolsTests/testSystemTools`）+ L4（`integration_test/phase1_test.dart` 在 iPhone 17 Pro 与 SE3，经 `app/integration_test/run_phase1_e2e.sh` 启动 canonical mock 模型 127.0.0.1:3901）+ 官方 engine smoke（mock 模型）+ `xcodebuild build`（模拟器/设备 unsigned）；Archive 形状检查依赖 iSH guest（Phase 1 deferred），verify 输出 SKIP 并需 `--allow-skip` 记录 | < 45–60 min |

- `--full` **默认 fail-on-skip**：任何 skip 需 `--allow-skip=<reason>` 显式放行并写进报告（计划 §7.1）。
- `--list` 列出将执行的步骤（供 verifier/Lead 核对）；`--dry-run` 只打印命令。
- **测试目录口径（T22a）**：本分支的 L1/L2 用例落在能力子目录（`test/phase1`、`test/chat/phase1`、`test/engine/phase1`、`test/files/phase1`），没有独立的 `test/unit`/`test/widget`；`--fast` 已按真实目录接线，`--full` 另跑官方相关大子集（排除 goldens）。
- **模拟器解析（T22a）**：`--full` 把设备名解析为 UDID（同名设备存在时不歧义），可用 `DSH_SIM_17PRO`/`DSH_SIM_SE3` 覆盖；设置 `VERIFY_STEP_LOG_DIR=<dir>` 可把每步输出保存为日志。
- **L4 前置（T22a）**：wrapper 在 127.0.0.1:3901 启动 `test/fixtures/mock_model_server.mjs`，用 `simctl uninstall` 保证首次启动路径，并设置 `DSH_IOS_GUEST_BUILD=0`（Phase 1 不构建 iSH；与构建门一致）。
- CI：`.github/workflows/phase1-verify.yml`（T5 新增）在 `phase1/**` PR 上跑 `--fast`；`phase1/integration` 上跑 `--full`（macOS 仅 L3/L4 需要）。

### 6.2 GitHub Actions（继承官方 + Phase 1 增量）

| workflow | 触发 | 内容 | 来源 |
|---|---|---|---|
| `phase1-verify.yml`（新） | `pull_request` → `phase1/**` / push `phase1/integration` | `scripts/verify.sh --static/--fast`（ubuntu）+ `--full`（macos-26，nightly/集成窗） | T5 |
| `ios-compile.yml`（适配） | push `phase1/**` | 官方 compile + engine（假模型）两 job，去 OHOS | 官方复用（T5） |
| `ios-ui-tour.yml`（适配） | push `phase1/**`，路径命中 UI | 9 站截图，仅作可视证据 | 官方复用 |
| `ci.yml`（保留） | PR→main / push main（上游同步用） | 官方全量 Flutter/Dart/runtime 测试 | 官方 |

> `ios-guest.yml` Phase 1 **禁用**（不构建 iSH）；`ohos-compile.yml` 删除触发。

## 7. Flaky 策略

1. **禁止用重试掩盖失败**：`flutter test`/`dart test` 不开 `--retry` 作为通过手段；CI 不设自动重跑。
2. **隔离**：每个 L4 测试用新模拟器安装/新临时数据目录；引擎测试前后 stop；mock 服务实例随测试文件生命周期。
3. **确定性**：mock 响应固定；动画/时间用 fake clock；等待使用条件轮询（上限 30s）+ 明确失败信息。
4. **已知 flaky**：若确认为上游/环境问题，登记 `reports/flaky.md`（现象、频率、根因、临时规避、移除条件），并标 `DEFERRED-ENV`；不得静默 skip。
5. **性能/超时**：L4 单测超时上限 180s；`--full` 用 `--concurrency=1` 跑引擎测试（模拟器共享）。

## 8. 行为覆盖率要求

- **每个 AC 必须有测试或明确 manual/deferred**（traceability 行不得空）：Phase 1 合并前 PLANNED/RED = 0。
- **安全负例必测**：D3-06-AC2（拒绝后不执行）、D3-05-AC3/PERSIST-01-AC3（结果未知不重复执行）、D1-04-AC3（凭据脱敏）、D4-05-AC2（错误路径）。
- **必修路径 L4 覆盖**：D1-01/02、D3-02/05/06、D4-05、PERSIST-01、D1-09/10（fake）至少各 1 条 L4。
- **不追求**行覆盖率数字；但要求 L1/L2 不出现"只断言 widget 存在"的空测试（verifier 抽查）。
- 覆盖度报告：T22 生成 `acceptance-report.md` 的"通过/未通过/deferred"三表 + traceability 汇总（自动脚本统计 GREEN/DEFERRED 数量）。

## 9. 与官方测试的关系

- **复用而非重写**：官方 `app/test/**`（936 文件）、`app/ios/RunnerTests`（15 文件 8,251 行）、`tooling/ios/engine-smoke`、`runtime/tests` 按 `verification-baseline.md` 接入 `--full`；Phase 1 新增测试只覆盖**缺口与验收 AC**，不重复官方已有覆盖。
- **goldens**：Phase 1 **不在 macOS 上跑官方 goldens**（Linux 字体基线，macOS 会大面积误报；见 `12-reuse-ci-test-plan.md` §3.3）。若 UI 有 iOS 专属改动，用 `ios-ui-tour` 截图 + L5 目检，不新建 golden 基线。
