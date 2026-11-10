# Phase 1 验证与验收基线（verification-baseline.md）

> 状态：T4-draft（staging）。阈值在 **T6 基线测量后冻结**（本文件先给占位与测量方法）。
> 依据：计划 §4.3、§7；`research/dsh-ios-research/12-reuse-ci-test-plan.md`（官方复用方案）；`research/dsh-ios-research/07-verification.md`（43 项口径复核）；`.agents/skills/review/references/contract-gates.md`；`app/ios/README.md`（分支真实结构）。
> 使用：T22 全量验证按本文件执行；未覆盖项必须进 `acceptance-report.md` 的 deferred 表并说明原因。

## 1. 复用的官方 CI / 测试资产（Phase 1 适用子集）

| # | 官方资产 | Phase 1 用在哪 | 是否改动 | 依据 |
|---|---|---|---|---|
| O1 | `ios-compile.yml` 的 `compile` job：`build.sh --simulator --debug` + `build.sh --release --no-codesign` | 每次 Phase 1 PR / 集成窗（L0 构建门） | 改触发分支为 `phase1/**`；删 `host-core.py --hap`（OHOS 对照）；保留其余 | `12-reuse-ci-test-plan.md` §2.2/§2.7 |
| O2 | `ios-compile.yml` 的 `engine` job：`engine-smoke/drive.mjs`（**真引擎+假模型**：五工具、Worker、git、rg、2MiB、取消、停止、持久会话、重启） | T22 与每个 Wave 结束的 L4；**Phase 1 核心回归** | 不修改；mock 模型场景可用官方假模型或 `test/fixtures/mock_model_server.mjs` | `ios-compile.yml` engine job；`tooling/ios/engine-smoke/drive.mjs` |
| O3 | engine job 的 `app-check.mjs --mode engine/launch`（真 App 内安装/启动/停止/重启/重置/30s 存活/白屏检测） | T22 L4 | 不修改 | 同上 |
| O4 | `fd-drive.mjs`（停止不误关他人 fd）、`heap-drive.mjs`（堆上限退出码 70 恢复）、`image-drive.mjs`（ImageIO） | T22 L4（引擎稳定性） | 不修改；`image` 的 48MP 大图项转 deferred | 同上；`app/ios/README.md:91-94` |
| O5 | `RunnerTests` 的 14 个 Swift contract suite（App 内系统工具/Swift 契约） | T22 L3；作为**上游基线**（防止 merge 回归） | 不改官方文件；Phase 1 新增 `Phase1*Tests.swift` 独立文件 | `12-reuse-ci-test-plan.md` §3.1 T1 |
| O6 | `check-archive.sh`（unsigned Archive 形状检查） | T22 构建门 | 不改 | `ios-compile.yml` engine job |
| O7 | `ios-ui-tour.yml`（9 站截图/录屏，**无断言**） | 仅作可视证据（T22 附件） | 改触发；可作为 Phase 1 UI 变更留痕 | `12-reuse-ci-test-plan.md` §2.4 |
| O8 | `ci.yml` 的 `flutter`/`dart`/`runtime`/`checks` job | `--fast`：dart packages + Node 单测子集；`--full`：相关 Flutter 子集（排除 goldens，见 §5 TODO） | 保留；不改上游 job | 官方 `ci.yml`；`12-reuse-ci-test-plan.md` §3.3 |
| O9 | `tooling/ios/guest-tests/**`、`ios-guest.yml`（iSH guest） | **Phase 1 禁用**（不构建 iSH）；仅保留为 Phase 2 资产 | 禁用触发 | 计划 §1/§3.4；design ADR-2 |
| O10 | `dev-run.sh`、官方开发脚本 | 不用于 Phase 1 门（真机脚本） | — | `CONTRIBUTING.md` 真机调界面 |

**官方测试基线锚点**：`ab2d179c`（run [42546357246](https://github.com/ccch1mneyyy/dsh-Go/actions/runs/42546357246) 三 job 全绿）；HEAD `418868c3` 的 compile job 红于 fixture 漂移。
**T1 实测基线（2026-11-10，T4 复核）**：仓库 `DSH-Go-iOS/repo` 的 `phase1/base=ef8eba50`（merge `52b78cd7`，merged main `aee6445`；`upstream/main` ref 实测 `aee6445`），工作树干净，app `1.0.14+1`；fixture 测试 5/5 OK；l10n `--check` 63 parts/6301 keys OK；上游线上 v1.0.15=`3edc945f` 未拉入（按计划推迟）。

## 2. contract-gates 6 门在 Phase 1 的落地

| 门 | 官方要求 | Phase 1 执行方式 | 检查点 |
|---|---|---|---|
| 门 1 桥接 HTTP 契约 | `/dsh-go/v1/*` 路由/方法/鉴权/状态码/错误码形状；单端改须同步另一端+版本迁移 | **Phase 1 不改 bridge**；若必须改（如引擎桥适配 iOS），必须：更新 `packages/dsh_client` 调用方 + 契约测试（L3）+ 错误码稳定 | verifier 检查 diff 是否触碰 `runtime/bridge/**`；触碰则要求两端测试 |
| 门 2 客户端公开 API | `packages/dsh_client` 公共导出签名/语义兼容；新增能力有测试；不得绕过 carrier 开新 HTTP 客户端 | 远程/对话改动若动 `dsh_client`：`dart analyze + dart test` 全绿 + 新增 API 有测试 | `scripts/verify.sh --fast` 的 dart 段 |
| 门 3 能力状态三态 | unknown/supported/unsupported 不得压成 bool；UI 文案穷尽；仅主机明确回答才显示不支持 | Phase 1 涉及主机能力（SSH/Remote/本机）与模型能力（看图/思考）必须三态；`hosts_state`/`engine_capabilities` 改动必须测 unknown | 代码审查 + L2 测试（`D1-09`/`D2-04` 相关） |
| 门 4 runtime 补丁与 pins | 补丁与 `pins.json` 同步；引擎版本变化后补丁仍可应用；node 测试覆盖 | merge main 后 `runtime/patches/pins.json` 取并集；重跑 `runtime/tests` 子集 + `prepare-engine.sh`；记录 runtimeVersion | T1/T3 验证：`python3 -I runtime/lib/rtbuild.py …` + `node --test runtime/tests/*.test.mjs`（子集） |
| 门 5 l10n 与文档同步 | ARB 中英同步、`l10n_merge.py --check`；`docs/guide` 与内置技能同步 `guide_sync.py --check` | 每次改文案/引导/设置：两个 `--check` 必须过 | `scripts/verify.sh --static` |
| 门 6 插件 SDK 消费面 | `sdk/plugin-kit` 公开 API/skill 生成物同步；跳过≠通过 | Phase 1 不改插件 SDK；若 merge main 带来变化，跑 `sdk/plugin-kit npm test` + `sync-skill.mjs --check` | `--full` 可选项 |
| 门禁自修改 | 实现与保护 gate 同改须列旧 gate 结果/新 gate 扩大集合/独立 oracle | Phase 1 若改 `verify.sh`/CI 门：PR 必须附"旧门对坏实现的结果 + 新门覆盖集合"证明 | verifier 专项检查 |

## 3. 官方 43 项真机验收表 → Phase 1 适用性映射

> 口径：`app/ios/README.md`「## 真机验收」共 **43 项数据行**（07 复核：43 项、零通过记录）。「适用」= 模拟器可在 Phase 1 验；「部分」= 主路径可验、部分子项 deferred；「Deferred」= Phase 1 不做/需真机/付费/外部依赖。

| # | 验收项 | Phase 1 判定 | 对应能力/说明 |
|---|---|---|---|
| 1 | 首次引导 | **适用（L5）** | D2-01；权限弹窗人工确认 |
| 2 | 远程连接 | **部分（L4 fake + L5 真 sshd 可选）** | D1-09/10/11；真实服务器 deferred |
| 3 | 系统识别 | Deferred | 语音 D6/Phase 2 |
| 4 | 语音被打断 | Deferred | 同上 |
| 5 | 通知 | Deferred | D6/APNs Phase 2 |
| 6 | 通知被拒 | Deferred | 同上 |
| 7 | 快捷操作 | Deferred | D6 |
| 8 | 冷启动快捷操作 | Deferred | D6 |
| 9 | 分享文字和链接 | Deferred | D6 |
| 10 | 分享照片 | Deferred | D6/D4-07 只做附件选择 |
| 11 | 分享过多 | Deferred | D6 |
| 12 | 唤起失败 | Deferred | D6 |
| 13 | 分享时被杀 | Deferred | D6 |
| 14 | 重装 | Deferred（真机安装） | 无签名/安装通道；Phase 1 仅模拟器重装 App 可测 ✅ 部分 |
| 15 | `.dshgo` | Deferred | D6 |
| 16 | 链接 | Deferred | D6 |
| 17 | 文件（打开/保存/PDF 预览） | **部分（适用）** | D4-05 预览；"保存到文件 App" Phase 2 |
| 18 | 相册（保存图片） | Deferred | D4-08/Phase 2 |
| 19 | WebView | Deferred | D4-10/Phase 2 |
| 20 | 本机引擎安装 | **适用（L4）** | D1-01；`app-check.mjs` |
| 21 | 本机引擎一轮 | **适用（L4）** | D1-02/D3-02/D3-06；`drive.mjs`（假模型） |
| 22 | 本机引擎重启 | **适用（L4）** | D1-02 |
| 23 | 本机引擎切后台 | Deferred（后台/长任务） | L6；仅记录不阻塞 |
| 24 | 结果未知 | **适用（L2+L5）** | PERSIST-01 |
| 25 | 本机产出 | **部分（L4）** | 产出列表/预览可验；分享/保存 Downloads deferred |
| 26 | 本机图片 | **部分（L4）** | 小图/透明 PNG 可验；48MP 内存 deferred（L6） |
| 27 | 重置和卸载 | **部分（L4）** | 重置可验（`app-check`）；卸载后空间回收 deferred |
| 28 | 只连远程不加载引擎 | **适用（L5）** | 内存对比手工（阈值 T6） |
| 29 | 后台继续（iOS 26） | Deferred | L6 |
| 30 | Siri | Deferred | D6 |
| 31 | 内置浏览器 | Deferred | Phase 2 |
| 32 | 浏览器和 App 分开 | Deferred | Phase 2 |
| 33 | 提醒事项 | Deferred | D6 系统工具 |
| 34 | 改过的提醒 | Deferred | D6 |
| 35 | 联系人 | Deferred | D6 |
| 36 | 选图片和识别 | Deferred | D6/Vision |
| 37 | 位置 | Deferred | D6 |
| 38 | 控制其他 App | Deferred | D5 手机操控（Phase 2 侧载） |
| 39 | 换主题的网页小窗 | Deferred | D7/Phase 2 |
| 40 | 深色模式（启动不闪白） | **适用（部分 L5）** | 纯 Flutter/启动屏；iPhone 模拟器可验 |
| 41 | 中文（权限说明/快捷操作跟随） | **适用（L2/L5）** | l10n 测试 + 手工切语言 |
| 42 | 图标 | Deferred | D7 |
| 43 | 换图标 | Deferred | D7 |

**统计**：适用/部分 **13 项**（1,2,17,20,21,22,24,25,26,27,28,40,41）；Deferred **30 项**（含真机/付费/Phase 2 能力）。

## 4. Phase 1 新增验收项（官方资产不覆盖）

| # | 新增项 | 验收方式 | 通过标准（建议） | 层级 |
|---|---|---|---|---|
| N-01 | **mock 模型 SSE 四场景** | `node --test test/unit/mock_model_server.test.mjs`（mock 自测）+ 引擎 L4 消费 | stream/tool/approval/error 各场景可复现；场景由 `x-mock-scenario` 头选择；请求日志可断言 | L1 |
| N-02 | **真实引擎一轮（工具+审批+文件）** | `integration_test/phase1_test.dart` + engine-smoke | 真引擎（非 mock 引擎）+ mock 模型完成：写文件→审批允许→文件出现在工作区；第二轮拒绝→无文件 | L4 |
| N-03 | **拒绝审批后工具不执行（安全负例）** | 同上，`D3-06_deny_approval_blocks_tool` | 断言文件系统无副作用 + 引擎未收到 tool/execute | L4 |
| N-04 | **杀 App 重开会话仍在** | 集成测试 `persist_01` + L5 | 会话/消息完整；引擎自动重启；工作区文件仍在 | L4+L5 |
| N-05 | **引擎重启后会话可继续** | 集成测试 | 停止→启动→原会话可继续，消息不丢不重 | L4 |
| N-06 | **结果未知不重复执行** | 集成/单测（unknown_results 状态机）+ L5 | 横幅提示；确认前拒绝；确认后继续；工具不重跑 | L2+L5 |
| N-07 | **iPhone-only 布局回归** | iPhone 17 Pro + iPhone SE3 两个模拟器跑 phase1_test | 无 overflow/不可点；关键页（对话/抽屉/设置/文件）在 SE3 小屏可用 | L4 |
| N-08 | **远程 fake host/SSH 连接与断线重连** | fake DSH host + fake SSH transport（L4）；本地 sshd（L5 可选） | 连接成功/失败/重连状态正确；不串主机数据；无重复消息 | L4+L5 |
| N-09 | **主机切换数据隔离** | 集成测试 | 切到另一主机后会话列表只含该主机；切回原主机数据仍在 | L4 |
| N-10 | **无 skip / 无假绿审计** | verifier 手工 + `verify.sh --full` fail-on-skip | `--full` 无 skip（除非 `--allow-skip` 且报告注明）；回退实现抽查失败 | L0/L5 |
| N-11 | **性能阈值**（T6 冻结） | 见 §6 | 见 §6 占位 | L5 |
| N-12 | **隐私开关与日志脱敏** | L2 + L5 | 统计开关关闭后无网络发送；日志/诊断不含完整 API Key | L2+L5 |

## 5. 模拟器 vs 真机 deferred 清单（Phase 1）

| Deferred 项 | 原因 | 记录位置 |
|---|---|---|
| 相机/拍照/扫码 | 模拟器无相机；D6 Phase 2 | acceptance-report deferred 表 |
| APNs / 锁屏通知 / 后台提醒 | 需付费账号+服务端；D6 | 同上 |
| 后台挂起/长任务/BGContinuedProcessingTask | 真机行为；L6 | 同上 |
| 性能/内存/jetsam（真机） | 无真机；阈值用模拟器基线 | 同上 |
| 触感/传感器 | 模拟器不可用 | 同上 |
| CoreDevice/DDI 手机操控 | 侧载+私有 API；D5 Phase 2 | 同上 |
| 真机签名安装/TestFlight/App Store | 无付费账号；侧载自用 | 同上 |
| iSH guest 真机 | Phase 1 不构建 iSH | 同上 |
| iPad/横屏适配 | Phase 1 iPhone only | 同上 |
| 真实 DSH Remote 服务器 / 真实 TURN | 依赖外部账号/网络 | 同上 |
| 48MP 大图/视频保存相册 | 内存/媒体 Phase 2 | 同上 |

> **TODO（T5）**：官方 Flutter 全量测试（936 文件）在 Phase 1 `--full` 的执行范围需确认——建议只跑与 Phase 1 模块相关的官方测试子集（chat/session/files/engine/remote），**排除 goldens**（Linux 字体基线不可在 macOS 跑；具体排除命令在 T5 由实测确定并写入 `verify.sh`）。

## 6. 阈值占位（T6 实测后冻结，示例值以计划 §4.3 为准）

| 指标 | 测量方法 | 占位阈值（待 T6） | 冻结后写处 |
|---|---|---|---|
| 冷启动可交互（模拟器） | 录屏/埋点：launch→首屏可点 | < 3 s | 本表 + acceptance-report |
| 引擎启动（install→ready） | `app-check`/驱动计时 | < 10 s（首次安装除外） | 同上 |
| 引擎停止 | stop→状态 final | < 5 s | 同上 |
| mock 首 token | 发送→首个 delta | < 2 s | 同上 |
| 连续启动次数 | 20 次 start/stop 循环 | 20 次无崩溃 | 同上 |
| 未捕获通道异常 | app-check/日志扫描 | 0 | 同上 |
| 内存（仅连远程不加载引擎） | 模拟器 instrumentation/Xcode | 基线值 ±10%（T6 记录） | 同上 |
| 模拟器机型 | iPhone 17 Pro + iPhone SE3 | 两档均过 L4 | 同上 |

## 7. 验收记录格式

每次 L4/L5 验收记录（供 `acceptance-report.md` 汇总）：

```yaml
id: D3-06-AC2            # 能力 AC
test: D3-06_deny_approval_blocks_tool
level: L4
command: "cd app && flutter test integration_test/phase1_test.dart -d <UDID> --plain-name D3-06"
build_sha: "<git rev-parse HEAD>"
simulator: "iPhone 17 Pro (iOS 26.5)"
result: PASS|FAIL|DEFERRED
evidence: "reports/phase1/<date>/<id>.log"   # 原始输出，不许摘要代替
notes: ""
```

- **PASS 条件**：测试真实执行、未 skip、断言覆盖 AC；L5 必须附截图/日志 + 人工结论。
- **FAIL 处理**：修复后重跑并保留失败记录；不得只保留通过记录。
- **DEFERRED**：必须引用本文件 §5 原因；否则视为未覆盖。
