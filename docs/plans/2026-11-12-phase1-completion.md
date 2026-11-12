# Phase 1 达标补齐与收口实施计划（T24–T41，已批准）

> 批准时间：2026-11-12；批准形式：用户确认计划后退出计划模式并开始执行。
> 上下文：`docs/plans/2026-11-10-phase1-b-implementation.md` T1–T23 已完成，但 2026-11-11 的复盘确认 DoD 3 未真正达成、DoD 2/4 仍有大量 deferred/skip/证据缺口。本文件是**本轮唯一执行依据**，不新增 Phase 2 功能。
> 代码基线：`phase1/base` = `e029e5f3`；本计划在 `phase1/completion` 上执行，最终合并回 `phase1/base` 并 tag `phase1-v1.1`。

## 0. 现状判定

| 原 DoD | 现状 | 判定 |
|---|---|---|
| 1 仓库可重复构建 + CI 绿 | prepare-engine/模拟器构建/安装通过；`phase1-verify` 绿 | 基本达成；`iOS compile` manual-only 且近期被取消，需补一次真实结果 |
| 2 每条能力 spec + RED→GREEN + 模拟器验收 + traceability | 69 AC DONE；44 步中 16 PASS / 27 DEFERRED-L5 / 1 DEFERRED-MOCK；29 条 L4 未重放 | 未完全达成 |
| 3 真实引擎 + 工具/审批 + 杀 App 不丢 + 工作区可见 + SSH/Remote 切换对话 | 全部 L4 用 mock；C7/C8 不可达；杀进程只是 App root 重建；工作区/SSH/Remote 仅 L2 fake；E2E 规避“重启后新建会话” | **未达成（本轮核心）** |
| 4 verify.sh 全绿；每任务 verifier PASS；无跳过/无假绿 | `--full` 需 `--allow-skip`（iSH）；goldens 排除；RunnerTests 过滤；12 个 live 用例 skip | 未达成 |
| 5 acceptance-report 三表 | 有报告，但主体是 deferred/mock | 内容需重发 |

## 1. 未达标点（G-01–G-21）

| # | 缺口 | 补齐动作 | 闭环验收 |
|---|---|---|---|
| G-01 | 真实模型从未进入验收 | 接 opencode-go `deepseek-v4.1-flash`（`https://opencode.ai/inference/go/v1`，真实 key 只经 broker） | 真实 SSE/工具/多轮/思考日志 |
| G-02 | 审批 C7/C8 不可达 | 干净安装确认默认 `workspace-write+ask`；真实模型显式请求沙箱升级 | 允许→恰好一次；拒绝→零副作用 |
| G-03 | 杀 App 未做进程级 | 两阶段冷启动 + XCUITest terminate/launch | 会话/消息/草稿/文件/自动启动 |
| G-04 | 工作区未上真引擎 | 真实模型写文件→文件页刷新/预览 | 真引擎工作区 L4 |
| G-05 | 真实 SSH 未验 | 临时非特权 sshd（127.0.0.1:22422，独立 key，不改 `~/.ssh`）+ 真实 `dsh web` | live_ssh 7 用例 + App L4 |
| G-06 | 真实 DSH Remote 未验 | 自托管上游 `apps/server` + Host 插件（隔离 DSH_HOME） | 真实登录/连接/会话/对话/重连 |
| G-07 | C4/C5/C9/C10/C11 未验 | 真实模型驱动 5 项 | 逐项 L4 PASS |
| G-08 | 附件/系统选择器未验 | `simctl addmedia` + XCUITest Photos/Files | 真实选择→发送→恢复 |
| G-09 | B2/B5/B6/B7 未验 | 安装中 terminate→续装；冷启动自动启动；破坏 runtime；日志页 | 4 项进程级证据 |
| G-10 | 抽屉/搜索/主机隔离仅部分 | 三主机真实数据 | 多主机 L4 |
| G-11 | 深色/语言/release/SE3 未验 | simctl appearance、系统语言、release 模拟器构建、SE3 | 4 项证据 |
| G-12 | 会话创建 superseded 缺陷 | 创建被连接代际淘汰时等待就绪并重试一次，保留草稿 | 单测 RED→GREEN；E2E 恢复真实断言 |
| G-13 | 渠道保存半成品 | 创建失败补偿删除；更新失败回滚 | 故障注入测试 |
| G-14 | 模型被删发送不回退 | 重读目录→回退上一可用模型→保留草稿 | 单测 + L4 |
| G-15 | `--full` 仍 allow-skip | guest archive 改 opt-in `--guest` | `--full` skip=0 |
| G-16 | golden/RunnerTests/live skip | macOS 基线 + 平台 comparator；补权限或范围化；live 真跑 | skip 审计为 0 |
| G-17 | 29 条 L4 未重放 | AC×证据矩阵逐条重放 | 70 AC 逐条证据 |
| G-18 | T6 指标缺口 | 真实 TTFT、20 次启动、SE3、内存 | 指标报告 |
| G-19 | CI 未覆盖 L1/L2；iOS compile 未绿 | Linux 加 phase1 Flutter 测试 + drift；触发 iOS compile | CI 绿 |
| G-20 | 录屏不满足真实要求 | 真实模型/工作区/SSH/Remote 重录，实时节奏、章节、字幕 | 新视频 + QA + SHA |
| G-21 | 验收/追溯未重发 | acceptance-report v2 三表 + traceability 重填 | 文档交付 |

Phase 1 外（按原决策继续 deferred）：真机签名/安装、APNs、iSH 完整 Linux、后台常驻、手机操控、iPad、v1.0.15 同步、相机/媒体保存。

## 2. 成功标准

1. 真实引擎 + 真实模型完成工具调用与审批；杀 App 重开会话/草稿/工作区不丢；SSH 与 DSH Remote 真实连接并对话；三主机切换隔离。
2. 44 个验收步骤全部执行（PASS 或 Phase 1 外）；70 条 AC 每条有实际证据；37 条 L4 全部重放。
3. `--static/--fast/--full/--real/--remote` 全绿；`--full` skip=0；每任务独立 verifier + 最终 tag verifier PASS；无“只测 mock”的验收结论。
4. acceptance-report v2 三表 + traceability 70/70 + tag `phase1-v1.1` + fork push。
5. 真实模型演示录屏（短/中任务、真实工作区、审批、SSH、DSH Remote），无 mock、无慢放、无随意拼接。

## 3. 基础设施

- **真实模型**：opencode-go `deepseek-v4.1-flash`；推理请求需 `x-opencode-session` 头（已实测）。凭据只从 `~/.dsh/.credentials.yaml` 运行时读取，经 `test/fixtures/credential_broker.mjs` 一次性投递；不落仓、不进日志/截图；真实调用串行，预算约 100 次，重试 ≤2。
- **真实 SSH**：临时非特权 sshd（Port 22422、`UsePAM no`、`StrictModes no`、独立 AuthorizedKeysFile）；临时 host/client key；远端 `env HOME=<tmp> DSH_HOME=<tmp>/.dsh dsh web`。已验证 `SSH_OK`。不改 `~/.ssh`。
- **真实 DSH Remote**：克隆 `ds-harness-remote` pinned commit，构建自托管 Server（loopback、密码账号），隔离 `DSH_HOME` 安装 Host 插件并启动 `dsh web`；App 用自托管登录。失败时用 npm 0.5.23 + 仓库 e2e 补丁，但不得用 fake 冒充。
- **模拟器**：17 Pro `1D9F8C91-5739-47B2-BDD0-0FC7207166F3`、SE3 `D9C6C518-0452-4AFE-9F8C-59EBE495BD47`；关闭多余 booted；`/tmp/dsh-phase1-sim.lock` 串行化模拟器任务；服务与端口登记 `reports/phase1-completion/env.json`。

## 4. 任务分解（T24–T41）

### W0 基线与基础设施（串行）

- **T24 Spec v1.1**：capability-spec 增 D2-03-AC4（请求头：校验/保存/发送/不回显日志）；test-plan 增 L4-Real/L4-Process 与真实层规则；verification-baseline 增“默认 full 无 skip”门；acceptance-checklist 改为本轮执行口径；mocks 明确 mock 仅 L1/L2；traceability 增 AC4 行（70）；新增本计划与 `completion-matrix.md`；tag `spec-phase1-v1.1`。
- **T25 基础设施**：`scripts/e2e/{lib,real_provider,ssh_host,remote_stack,sim_lock}.sh`、`test/fixtures/credential_broker.mjs`、`app/integration_test/support/{e2e_env,real_provider}.dart`；harness 自测（缺 key FAIL、token 校验、不泄漏 secret、服务可重复启停）；先跑通真实模型 smoke 与真实 SSH smoke。

### W1 对话/引擎（chat 工作树）

- **T26 会话创建 superseded 修复**：RED `d3_01_session_after_restart_test.dart`；`_ensureSession` 在连接代际变化时等待就绪并重试一次；恢复 `phase1_test.dart` B4 段真实断言；变异回退必须红。
- **T27 审批 C7/C8**：先断言干净安装默认 `workspace-write+ask`（若红则清除持久化 full-access 来源）；L4-Real `phase1_real_approval_test.dart`：真实模型请求沙箱升级→允许一次/拒绝→文件系统副作用断言。
- **T30 进程级持久化**：两阶段 `phase1_cold_start_test.dart --dart-define=E2E_PHASE=seed|verify`；会话/消息/草稿/附件/工作区；引擎自动启动；unknown-result 与 crash 恢复。
- **T32 C4/C5/C9/C10/C11**：真实模型插话/排队/撤回/停止/工具行/失败态/消息复制/引用/重答/分叉/提问卡；逐项断言 + 截图。

### W2 配置渠道（providers 工作树）

- **T28 请求头 D2-03-AC4**：`packages/dsh_client` 的 `updateProvider(headers:)`；`ProviderDraft.headers` + save；表单高级区增删行与校验；header 值不进日志；真实 L4 用 opencode-go 直连完成一轮真实对话。
- **T29 事务与回退**：创建失败补偿删除、更新失败回滚；发送时 UNKNOWN_MODEL→重读目录→回退上一可用模型→保留草稿；故障注入测试。

### W3 工作区/附件（files 工作树）

- **T31**：真实模型工作区任务→文件页刷新/文本/图片/PDF 预览；会话隔离；Photos/Files 选择器（XCUITest）；9 个上限、200MB 拒绝、草稿附件冷启动恢复；修任何暴露缺陷。

### W4 远程（remote 工作树）

- **T33**：临时 sshd + 真实 `dsh web` 的 App L4（连接步骤/会话/真实模型对话/工作区/断线重连/失败回退）；自托管 Server + Host 的真实 DSH Remote L4（登录/主机列表/指纹/连接/会话/对话/重连）；三主机隔离；启用 `live_ssh_test.dart` 与 `workspace_live_test.dart`，消灭 12 skip。

### W5 UI 进程级（ui 工作树）

- **T34**：`Phase1UITests` 独立 UI test bundle（XCUIApplication(bundleIdentifier:)，复用空 TEST_TARGET_NAME 模式）；补关键控件 Semantics identifier；用例：冷启动、安装续装、自动启动、失败诊断、日志页、Photos、深色、英文、SE3。Flutter 语义不稳定时回退集成测试 + 宿主 simctl 编排。

### W6 门禁/CI（infra 工作树）

- **T35**：`verify.sh` 增 `--real/--remote/--guest`；默认 `--full` 无 skip 且不需要 allow-skip；golden 平台 comparator + macOS 基线并真跑；RunnerTests 无静默过滤（必要时先补权限，范围化须 verifier 批准）；20 次冷启动、真实 TTFT、SE3、RSS 指标；自测覆盖新模式。
- **T36**：CI 加 Linux phase1 Flutter 测试（CJK 字体）与 `git diff --exit-code` drift；skip 审计 `reports/phase1-completion/skip-audit.md`；手动触发 iOS compile 并修绿或记录基础设施阻塞。

### W7 验收/复核/交付

- **T37**：AC×证据矩阵填实（70 AC / 44 步 / 17 Pro + SE3 / 日志与截图 / fail=0 / unexecuted=0 / mock-only=0）。
- **T38**：每任务 fresh-worktree 独立 verifier（跑测试、读 spec、变异回退抽查、检查断言未放宽）；最终 tag verifier 只读复核。
- **T39**：acceptance-report v2（通过/未通过/deferred 三表）、traceability 70/70、checklist、backlog、README、plan 勾选；合并回 `phase1/base`；tag `phase1-v1.1`；push fork。
- **T40**：真实模型演示录屏：正常 App（XCUITest 驱动）× `simctl io recordVideo`；真实短/中任务、真实工作区、审批允许/拒绝、插话/排队/停止、提问卡、杀 App 重启、真实 SSH、真实 DSH Remote、三主机切换；章节卡 + ASS 中文字幕；1080×1920 30fps CFR H.264；不慢放、不随意拼接；freeze/fps/黑帧 QA；SHA + 说明。
- **T41**：最终门禁（static/fast/full/real/remote + RunnerTests + matrix）全绿；CI 绿；最终总结。

## 5. 编排

- Lead：`phase1/completion`；独占 docs/specs、l10n、pubspec、合并与最终门禁。
- worktree：chat（T26/T27/T30/T32）、providers（T28/T29）、files（T31）、remote（T33）、ui（T34）、infra（T25/T35/T36）。
- 每任务 fresh-context subagent，brief 含 spec 行号、文件白名单、RED 要求、命令、报告路径、禁止 secret；写入白名单互斥；跨域由 Lead 转发。
- 合并顺序：infra → providers → chat → files → remote → ui → gates/docs；每次合并跑 `--fast`；模拟器任务全局串行。
- verifier 每任务新 worktree；报告 `reports/verifiers/**`；最终 tag verifier 独立。

## 6. 风险与回退

- opencode-go 形状不兼容 → 已实测工具/思考/多轮可用；App 侧失败则回退本地 header 注入代理（真实模型，仅注入 header）；两者都失败则停止并报告，不降级 mock。
- 引擎丢弃 profile headers → 回退代理，保留 headers UI。
- sshd 被策略阻断 → 已实测可用；换机失败回退 asyncssh 并披露。
- 自托管 Relay 构建失败 → 仓库 pinned e2e 流程；回退 0.5.23；仍失败则阻塞并如实报告。
- XCUITest 不稳定 → 回退集成测试 + 宿主编排；系统选择器用坐标脚本；保留真实画面。
- golden 生成失败 → 仅 26 个范围内文件，平台 comparator；范围化须 verifier 批准，不静默排除。
- 真实模型限流 → 串行、预算、重试 ≤2，不弱化断言。
- 并行冲突 → worktree + 白名单 + 全局锁 + Lead 合并窗口。

## 7. 执行顺序

M0（T24/T25）→ M1（T26–T29）→ M2（T30–T33）→ M3（T34–T36）→ M4（T37–T39）→ M5（T40–T41）。

## 6. 执行状态（2026-11-13，滚动更新）

| 任务 | 状态 | 证据 |
|---|---|---|
| T24 Spec v1.1 | DONE | `docs/specs/phase1/*`；spec checker OK |
| T25 基础设施 | DONE | `reports/phase1-completion/T25/`（broker/sshd/lock 自测） |
| T26 会话 superseded | DONE | `T26`；L4 on 17 Pro |
| T27 审批 C7/C8 + 默认权限 | DONE | `T27/green/run-green.log` + `run-green.env.json`；pet 修复 |
| T28 请求头 D2-03-AC4 | DONE | `T28` |
| T29 事务/回退 | DONE | `T29` |
| T30 进程级持久化 | DONE | `T30/run-strong-final.log` 5/5 PASS 591s + mid-turn crash |
| T31 工作区/文件页 | DONE | `T31/green/workspace_real.log` |
| T32 对话控制 C4/C5/C6/C9–C11 | **OPEN（FAIL）** | 多轮到达 steer/queue/stop/tool/copy/quote/question，最终断言未绿；源码未提交 |
| T33a 真实 DSH Remote | DONE | `T33b-relay/green/02-flutter-test.log` |
| T33b 真实 SSH | DONE | `T33b-ssh/green/flutter-test.log`；真实 sshd |
| T34a Phase1UITests target | DONE | `T34a` 2/2 PASS |
| T34b 进程级 UI 流程 | **OPEN（FAIL）** | 仅 T34a 骨架；B6/B7/D6/D8/G1/G2 未产出可复现 PASS |
| T35a goldens/RunnerTests/T6 | DONE | `T35a/report.md`；27 golden、367/367 |
| T35b verify.sh 新模式 | DONE | `T35b`；`--self-test` 17/17 |
| T36 CI/skip audit | DONE（Linux 流程文件） | `T36`；CI 尚未在远端跑绿 |
| T37 matrix/traceability | DONE | `T37`；70 AC / 44 步 |
| T38 独立 verifier | DONE（发现 1 个门禁缺陷并修复） | `reports/phase1-completion/T38/report.md` |
| T39 acceptance/tag | PARTIAL | `acceptance-report.md` v2；因 T32/T34b 未闭合不 tag |
| T40 演示录屏 | DONE | `reports/phase1-completion/video/out/demo-phase1-v1.1.mp4` |
| T41 最终门禁 | PARTIAL | `--static` 7/0/0、`--fast` 13/0/0、`--full` 进行中；`--real` 缺 T32 wrapper fail-closed |
