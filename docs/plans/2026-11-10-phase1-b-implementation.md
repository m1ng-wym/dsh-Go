# DSH Go iOS · Phase 1（B：基座闭环 + 远程主机）实施计划（已批准）

> 批准时间：2026-11-10；批准形式：用户确认计划内容并落盘。
> 仓库版落盘：2026-11-11（T23）；内容 = 工作区计划 + T22/T23 事实更新。**本文件是 Phase 1 的唯一执行依据**；变更需 Lead 更新并记录原因。
> 执行进度（2026-11-11 14:45）：**Wave 0–4 全部完成（T1–T21）**；**T22 自动化门与验收自动化完成**（`--fast` 13/0/0；`--full` 曾 pass=21/0/1；E2E 17 Pro + SE3 PASS；RunnerTests 366/366）；**T22b 验收自动化 14 项 PASS（13 项 acceptance 测试 + E2E 的 B4），C7/C8 因 full-access profile 不可达 deferred，27 项 L5**；**T23 交付文档完成，最终 `--full` 重跑 pass=21/0/1（仅 iSH guest skip）；6 分钟演示录屏已产出（`reports/phase1/demo-6min.mp4`，5m15s）**。证据在 `DSH-Go-iOS/reports/`，汇总见 `docs/specs/phase1/acceptance-report.md`。
> 仓库：`DSH-Go-iOS/repo`，分支 `phase1/base`，基线 `56111af8`（+T22b 未提交测试改动）。
> 工作区：`/Users/Zhuanz/Documents/Zenlix/DSH-Go-iOS`；研究底稿在 `DSH-Go-iOS/research/`（可行性报告、能力清单 94 条、分支对齐与复用分析、CI/测试复用方案）。

## 0. 目标、已定决策与成功标准

**最终目标**：在 iOS 上尽可能全量对齐 DSH Go 安卓发行版（v1.0.14）核心能力。**本计划只覆盖 Phase 1**：把「本机引擎 + 对话闭环 + 工作区」基座跑通，并加远程主机（SSH / DSH Remote）能力；后续阶段在同一基座上增量。

**已确认的决策**：
- 发布形态：不上架 App Store，侧载/自用；**仅自己使用**，不设对外分发/合同/客户约束。
- 设备：**先 iPhone only**；当前**无真机、无付费 Apple 账号、不产生费用**，Phase 1 全部在 **iOS 模拟器**开发与验收；真机项进 deferred 清单，不阻塞。
- iOS 最低部署版本：**17.0**（覆盖约 95%，兼容 Xcode 26.6/27；iOS 26 专属能力用 `#available` 条件启用）。
- 技术路线：**Fork 官方 `feat/ios-foundation` 为基座 → merge main → 修冲突/门禁 → 在缺口上开发**；不重写已有能力。
- 开发方法：**Spec/测试基线先于产品代码**；严格 TDD（Red → Green → Refactor）；独立 verifier 复核，禁止"为过测试而写测试"。

**Phase 1 成功标准（Definition of Done）**：
1. 仓库可重复构建：`prepare-engine` + 模拟器 Debug 构建 + 安装到 iPhone 17 Pro 模拟器成功；已知 CI 门禁恢复绿。
2. B 范围内每条能力都有：spec（含 Given/When/Then 与边界）、先失败后通过的自动化测试、模拟器验收记录、traceability 行。
3. 真实引擎（非 mock）在模拟器中跑通一轮带工具调用与审批的对话；杀 App 重开会话不丢；工作区文件可见；SSH/DSH Remote 主机可切换并对话。
4. `scripts/verify.sh` 全绿；独立 verifier 对每个任务 PASS；无跳过/无"只测 mock"的假绿。
5. 输出 `docs/specs/phase1/acceptance-report.md`（通过/未通过/deferred 三张表）。

**Phase 1 明确不做**：手机操控/不打扰模式、iSH 完整 Linux、APNs/Live Activity、后台常驻、伙伴小屋/桌宠、插件市场/原生插件 UI、终端/网页版、图片视频保存相册、自动化任务、应用内更新、真机签名与安装。

---

## 1. 基线锁定（版本矩阵）

| 层 | 锁定值 | 说明 |
|---|---|---|
| Android 能力基线 | DSH Go **v1.0.14**，main `aee6445`（2026-11-10） | 94 条能力清单来源；`repo/docs/specs/phase1/upstream.lock` 记录 SHA |
| iOS 代码基线 | `feat/ios-foundation` head `418868c3`（2026-11-09）；已知全绿提交 `ab2d179c` 作 fallback | fork 后先修 fixture；若 HEAD 构建失败则回退 `ab2d179c` 再 cherry-pick 后续 |
| 部署目标 | **iOS 17.0**，iPhone only（`TARGETED_DEVICE_FAMILY=1`） | 模拟器 runtime 用 **iOS 26.5** |
| Xcode / macOS | **Xcode 26.6**（SDK iOS 26.5），macOS 26.5.2（现状） | 不升级 macOS；将来需 iOS 27 模拟器再升 macOS 26.6 + Xcode 27（免费） |
| Flutter / Dart | **Flutter 3.47.7**（SHA256 `dd9da574c3168460550117eb0e8dd0313ae934fabf64a82a6d557fff5fd1422e`），Dart 3.13 | 与官方 CI 完全一致 |
| Node（引擎构建/运行） | **Node 24.22.1**（nodejs-mobile `v24.22.1-0`，SHA256 `3fa1b8fb…b45326e`） | 官方分支 pin；本机需精确版本 |
| Python | **3.11+**（建议 3.12） | `prepare-engine.sh` 要求；本机 3.10 需另装 |
| iSH / Rust | **Phase 1 不启用**（Phase 2 再按官方 pin `c5c264d…`） | 不下载、不构建，节省时间 |
| 模拟器 | iPhone 17 Pro（iOS 26.5）+ iPhone SE (3rd)（小屏回归） | 无真机签名，不需要 Apple 账号 |

---

## 2. Phase 1 范围（B = A + 远程）

### 2.1 能力 ID 清单（来自 94 条清单）

**A 部分（基座闭环）**：
- 引擎：`D1-01` 运行环境安装、`D1-02` 启停/重启/自动启动、`D1-04` 引擎日志与启动失败诊断。
- 配置：`D2-01` 首次引导、`D2-03` API Key/自定义渠道、`D2-04` 模型切换与思考深度。
- 对话：`D3-01` 新对话、`D3-02` 流式/思考、`D3-03` 插话、`D3-04` 排队/立即发送、`D3-05` 停止、`D3-06` 审批卡、`D3-07` 提问卡/计划待审、`D3-08` 工具行、`D3-19` 消息操作。
- 会话/工作区：`D4-01` 会话抽屉、`D4-03` 会话搜索、`D4-05` 工作区文件浏览/预览、`D4-07` 附件（相册/文件；模拟器无相机，拍照入口禁用）。
- 安全/持久化：`D9-01` 隐私告知与匿名统计开关；会话持久化、引擎重启恢复、崩溃后恢复（归入 D1-02/D3 的验收）。

**B 部分（远程主机）**：
- `D1-09` 主机切换（本机/SSH/DSH Remote）、`D1-10` SSH 远程主机（起远端 dsh web、隧道、断线重连）、`D1-11` DSH Remote 基础连接（Relay/LAN 连接 + 会话列表 + 对话；**Remote 终端/传文件延后**）。

### 2.2 用户体验（Phase 1 演示脚本，约 6 分钟）

1. 冷启动 → 首次引导（本机/远程）→ 选择「本机」→ 安装运行环境（进度、失败可诊断）→ 启动引擎。
2. 填 API Key / 自定义渠道 → 选模型与思考档。
3. 发一条触发工具的任务（如"在工作区写 hello.md 并列出文件"）→ 流式输出、工具行、审批（允许/拒绝）→ 文件出现在工作区并可预览。
4. 插话一条、停止一次生成、发一张图/文件作为附件。
5. 杀 App 重开 → 会话、消息、工作区仍在；引擎重启成功。
6. 切换到 SSH 主机（本机跑 DSH 或 mock host）→ 看到远端会话 → 发消息/审批；断网重连。
7. 切换到 DSH Remote 主机（若服务器可用；否则 mock/占位并明确标注）。

### 2.3 非目标（Phase 1 不写）

D5 手机操控全部；D7 桌宠/伙伴/Live2D；D8 插件市场/插件 UI；D4-09 终端、D4-10 网页版、D4-11 导出；D6 通知/分享/系统集成；D3-09~18 高级 Agent 能力；D9-03~07 更新/诊断包；媒体保存相册；相机/扫码；一切依赖真机或付费账号的能力。

---

## 3. 仓库、分支与复用策略

### 3.1 仓库与分支（工作区适配版）

1. 在 `DSH-Go-iOS/repo` 建仓：
   - `git clone https://github.com/ccch1mneyyy/dsh-Go repo`
   - `cd repo && git remote rename origin upstream`
   - `git fetch upstream feat/ios-foundation:refs/remotes/upstream/feat/ios-foundation`
   - 从 `upstream/feat/ios-foundation` 建 `phase1/base`；另建 `phase1/integration`（Lead 专用合并分支）。
2. **立即 mirror 备份**（防上游删分支）：`git clone --mirror upstream ../backup/dsh-go-upstream.git` 或本地 bundle。
3. 保留 `upstream` 远程；后续每周/每官方 release `git merge upstream/main`，台账记录冲突。

### 3.2 merge main 与冲突处理（已实测：13 个冲突文件）

`git merge upstream/main` 冲突文件与处理：
- l10n 6 个：`app/lib/l10n/app_{en,zh}.arb`、`app/lib/l10n/gen/app_localizations*.dart`、`app/lib/l10n/parts/phone_{en,zh}.arb` → 手工合并 arb 输入，**不手改 gen**，跑 `python3 app/tool/l10n_merge.py` 重新生成。
- 手机相关 4 个：`app/lib/state/phone_turn_end.dart`、`app/lib/ui/chat/chat_screen.dart`、`app/lib/ui/phone/dnd_mode_page.dart`、`app/lib/ui/phone/phone_control_screen.dart` → 保留 main 的 1.0.14 逻辑 + 分支的 iOS 能力门禁（`runtime_capabilities`/`android_features`）；iOS 上隐藏 Android-only 入口。
- `runtime/patches/pins.json` → 补丁 pin 取并集并按 main 版本校正。
- `app/.gitignore` → 并集。
- 合并后 `app/pubspec.yaml` 版本对齐 **1.0.14+1**（记录在 upstream.lock）。

### 3.3 修复 HEAD 门禁（一行级）

`tooling/ios/test-guest-embedding.py` 的 fixture 补上 `runtime/ios/phone/descriptions.mjs`（与 `tooling/ios/embed-engine.sh:75` 同步）；修复后跑 `xcodebuild`/`python3 tooling/ios/test-guest-embedding.py` 验证 `iOS compile` 检查步通过。若时间紧，先钉 `ab2d179c` 作为 base，再 cherry-pick 后续修复。

### 3.4 保留/裁剪

- **必须保留**：`runtime/ohos/**`（iOS 引擎基础层）、`app/ios/**`、`runtime/ios/**`、`tooling/ios/**`、iOS 专属 Dart、共享 Dart 的 iOS 门禁。
- **保留但不构建**：`app/ohos/**`、`tooling/ohos/**`、`ohos-compile.yml`（Phase 1 删除该 workflow 触发即可）。
- **不修改**：`app/android/**`（除共享 Dart 外），保持与上游可合并。

### 3.5 复用清单（不重复造轮子）

| 复用对象 | 用法 |
|---|---|
| 引擎宿主（NodeMobile/addon framework/prepare-engine） | 直接继承，不重写 |
| iOS 24 通道 + 共享 Dart 能力门禁 | 直接继承；Phase 1 只补缺口通道（engine/files/media/diagnostics/links/notify 中所需项） |
| 官方 iOS CI（compile/engine/ui-tour） | 复制到本仓库，改触发分支、删 OHOS、保留 engine smoke（假模型） |
| 官方 Swift 契约测试 / engine-smoke / check-archive | 直接移植并接线 |
| 官方 Flutter 测试（选中子集） | 复用；goldens 暂不跑 macOS（Linux 字体差异），后续重建 iOS 基线 |
| contract-gates 6 门 / 43 项验收表 / UI-CONTRACT / guest 契约 | 采纳为验收基线；guest/手机部分标 deferred |
| 官方 mock 模型 / fake host 思路 | 在 `test/fixtures/` 实现，不依赖真实模型/服务器 |

---

## 4. 开发前 Spec 与测试基线（必须先于任何产品代码完成并冻结）

### 4.1 产物（提交到仓库，打 tag `spec-phase1-v1`）

| 文件 | 内容 |
|---|---|
| `repo/docs/specs/phase1/design.md` | 目标/非目标/约束/架构决策/风险（本计划 §0–§3 的展开） |
| `repo/docs/specs/phase1/upstream.lock` | Android `aee6445`、iOS `418868c3`、工具版本、测试基线 SHA |
| `repo/docs/specs/phase1/capability-spec.md` | 每个 Phase 1 ID：用户故事、行为（Given/When/Then）、错误/边界、依赖、官方依据（README/docs 文件:行）、iOS 实现位置、验收级别 |
| `repo/docs/specs/phase1/test-plan.md` | 测试层级、TDD 规则、mock/fixture、测试数据、CI 门、flaky 策略、覆盖率目标（行为覆盖而非行数） |
| `repo/docs/specs/phase1/verification-baseline.md` | 复用的官方 CI/测试/43 项验收；新增验收项；模拟器 vs 真机清单；阈值（T6 实测后冻结） |
| `repo/docs/specs/phase1/traceability.md` | 能力 ID ↔ spec 章节 ↔ 实现文件 ↔ 测试用例 ↔ 验收记录（逐行更新，缺一不得合并） |
| `repo/docs/specs/phase1/acceptance-checklist.md` | 模拟器手工验收 ~25 项 + deferred 真机项 |
| `repo/docs/specs/phase1/mocks.md` | mock 模型 SSE、fake DSH host、fake SSH transport、测试凭据/端口约定 |

### 4.2 测试层级与"可失败"要求

| 层 | 范围 | 命令 |
|---|---|---|
| L0 静态 | `flutter analyze`、`dart analyze`、Swift typecheck、无警告 | `scripts/verify.sh --static` |
| L1 单元 | Dart 纯逻辑、Node 运行时/桥接 | `flutter test test/unit`、`node --test` |
| L2 Widget | Flutter 页面/状态/通道 fake | `flutter test test/widget` |
| L3 契约 | Swift 通道协议、JSON/状态机、错误码（RunnerTests） | `xcodebuild test -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| L4 集成（模拟器） | 真实 Node 引擎 + mock 模型 + fake host；install/start/chat/approval/file/persist/remote | `flutter test integration_test/phase1_test.dart -d <sim>` |
| L5 手工 | 冷启动/引导/失败恢复/SSH 真连（本机 DSH） | `acceptance-checklist.md` |
| L6 Device-deferred | 相机/APNs/后台/性能/触控/真机签名 | 记录，不进 Phase 1 门 |

**TDD 硬规则**（每个任务必须遵守）：
1. 从 spec 的 AC 写**一个**失败测试（测试名含 ID，如 `D3-06_deny_approval_blocks_tool`）。
2. 运行并**记录失败输出**到任务记录；失败原因必须是"功能不存在"，不是语法/环境错误。
3. 写最小实现使该测试通过；禁止提前实现未测行为。
4. 跑目标测试 + 项目全套测试（`scripts/verify.sh --fast`），全绿才继续。
5. 重构后重跑；提交信息含 spec ID。
6. 独立 verifier 在**新 worktree/新 checkout** 上：跑测试、检查测试是否真的覆盖 spec、做"回退实现看测试是否失败"的抽查；PASS 才允许 Lead 合并。
7. 禁止：先写产品代码再补测试、只断言 mock 调用、跳过测试、测试内写生产逻辑、为过测试改断言。

### 4.3 测试基线与官方复用（先冻结再开发）

- **官方复用**：`ios-compile`（compile+engine 两 job，保留假模型真回合）、`engine-smoke`、Swift 契约套件、`check-archive`、contract-gates 6 门、43 项验收表（筛出 Phase 1 适用项）。
- **本阶段新增**：mock 模型 SSE（流式/工具调用/审批/错误）、fake SSH/Remote transport、真实引擎模拟器 E2E、持久化/杀进程恢复、iPhone-only 布局回归、远程断线重连。
- **不追求行覆盖率数字**：验收按 spec AC 与行为覆盖；每个 AC 至少一个自动化测试或被明确标为 manual/deferred。
- **阈值在 T6 基线测量后冻结**（示例，最终以实测为准）：冷启动可交互 < 3s（模拟器）、引擎启动 < 10s、停止 < 5s、mock 首 token < 2s、连续 20 次启动无崩溃、无未捕获通道异常。
- **冻结机制**：`spec-phase1-v1` tag；任何变更走 traceability + Lead 批准，避免开发中偷偷改标准。

---

## 5. 任务分解（TDD；每个任务先测试后实现）

> 执行模板（所有任务）：读 spec → 写失败测试 → 运行记录 RED → 最小实现 → 目标+全量 GREEN → 重构 → verifier 复核 → Lead 合并。下面只列每个任务的专属内容。

### Wave 0：基座工程（Lead + 全组，1–2 周）

- [x] **T1 仓库与基线**（DONE 2026-11-10 17:05）：`phase1/base` = `ef8eba50`（`chore: phase1 baseline (v1.0.14+1)`）；从 `418868c3` 建，merge `aee6445`（v1.0.14）为 `52b78cd7`，13 冲突解决；修 `test-guest-embedding.py` fixture（补 `descriptions.mjs` + 断言）。
  - 验证：`git status` 干净；fixture 5/5 OK；`l10n_merge.py --check` 63 parts/6301 keys；HEAD 树 6911 unique blob 0 missing；`git log --graph` 含两端历史。证据：`reports/tasks/T1-baseline.md`。
  - 偏差（已记录）：网络无法 `git clone`（RPC/TLS 断），改用 GitHub tree API + raw CDN 并行下载（逐文件 blob SHA 校验）+ hash-object 注入；本地 mirror 改为 GitHub fork `m1ng-wym/dsh-Go`（236 branches）+ refs 清单。
  - 版本口径：上游 main 已到 `3edc945f`（v1.0.15，11-10 14:34 发布），按计划锁定仍 merge `aee6445`；v1.0.15 推迟到 Phase 1 后每周 sync（见 `upstream.lock#observed_upstream`）。
- [x] **T2 本机工具链**（DONE 2026-11-10 17:22）：Flutter 3.47.7（SHA 校验 ✓，镜像 storage.flutter-io.cn）、Node 24.22.1（官方 SHASUMS ✓，npmmirror）、Python 3.12.16、iOS 26.5 Simulator (23F77) 安装完成；iPhone 17 Pro UDID `1D9F8C91-5739-47B2-BDD0-0FC7207166F3`、iPhone SE3 UDID `D9C6C518-0452-4AFE-9F8C-59EBE495BD47`（boot/bootstatus 141s/screenshot/shutdown 均通过）。
  - 验证：全部版本与计划 §1 一致；证据：`reports/env/t2-toolchain.md`。
  - 勘误：`xcodebuild -downloadPlatform iOS -buildVersion 26.5` 在本机不可用，实际用 `xcodebuild -downloadPlatform iOS`（自动解析为 23F77）；下载被中止后断点续传成功。
- [x] **T3 构建/安装 spike**（DONE 2026-11-10 18:05）：prepare-engine **成功**（runtimeVersion ohos-fc91d79f8f373b90f9def070，payload 173,947,425 B/15,715 files，archive 52,906,160 B，roundtrip=true，56s）；pbxproj 已改 17.0×9 + family "1"×9；Engine 231MB 就绪。
  - Lead 决策 D8：`tooling/ios/embed-engine.sh` 增加 `DSH_IOS_GUEST_BUILD=0` 跳过分支（默认仍构建，官方 fixture 5/5 保持通过）；Phase 1 本地构建设 `DSH_IOS_GUEST_BUILD=0`。
  - Lead 决策 D9：official `build.sh` 第一步 phone-self-runner 需 Rust 1.99.1（Phase 2 XCTest/CoreDevice 路线），Phase 1 T3 用等价 `cd app && flutter build ios --simulator --debug`（带引擎）；official build.sh 对比留 T5/Phase 2。
  - 环境偏差：SPM 首次解析需 flutter_webrtc binaryTarget `WebRTC.xcframework.zip`（686,209,480 B），GitHub 直连慢；用 8 路 range 并行下载 + SHA 校验 + SwiftPM artifacts 缓存种子化。
  - **结果**：prepare-engine 成功（56s，payload 173,947,425B/15,715 files，runtime.zip 52,906,160B）；`flutter build ios --simulator --debug`（DSH_IOS_GUEST_BUILD=0）→ `Xcode build done 220.7s`，Runner.app 474MB（NodeMobile/DshNodeHost/DshFlock/DshRequireBuiltin/WebRTC，无 guest），Info.plist 1.0.14 / MinimumOSVersion 17.0；simctl install 17s + launch 1s，进程存活无崩溃，首屏截图 `reports/env/logs/t3-launch-screenshot.png`。代码提交 `93a8ba88`（pbxproj 17.0/iPhone + guest gate）。deferred：official build.sh 的 phone-self-runner（Rust）步骤留 T5/Phase 2。
- [x] **T4 Spec/测试基线**（DONE 2026-11-10 17:50）：12 文件 / 2592 行提交 `8b70170f`，tag **`spec-phase1-v1`**（已 push fork）。含独立 reviewer 复审（1 P0 + 5 P1）+ T4-fix 全部修复（9 处行号重钉、verify.sh fail-on-skip + --self-test 5/5、mock slow 1000ms + 16/16 自测、traceability D9-01、D3-07 L4 方案）。冻结前 `verify.sh --static` = **exit 0 / pass=7 fail=0 skip=0**（Lead 修 2 个 merge 遗留 analyze 错误后），`flutter analyze` No issues。证据：`reports/T4-repo-ready.md`、`reports/T4-fix-report.md`。：按 §4 写齐 8 份文档 + `test/fixtures/mock_model_server.mjs` + `scripts/verify.sh` 骨架；打 `spec-phase1-v1` tag；完成后**才开始 Wave 1**。
  - 验证：每条 Phase 1 ID 在 capability-spec 与 traceability 均有行；`scripts/verify.sh --static` 可跑。
- [x] **T5 CI 接线**（DONE 2026-11-10 18:50，commit `4bbf0241`）：4 个 workflow 触发改 `phase1/**`、`if:false` 禁用 iSH/guest/phone（DEFERRED）、新增 Linux `phase1-verify.yml`、`verify.sh --ci/--full` 接线（fail-on-skip + --self-test）、engine-smoke wrapper；`--static` 7/0/0；engine smoke PASS（ready 3788ms/restart/approvals 8）；sim build 224s、device unsigned 144s。已知红：本机 macOS 下 `packages/dsh_remote` 2 timeout（T6 排查）、golden 像素（字体环境）。：复制 `ios-compile`/`ios-guest`（Phase 1 可禁用 guest job）/`ui-tour` 到 `.github/workflows/`；改触发分支为 `phase1/**`；删 `ohos-compile` 触发；本地用脚本模拟 compile+engine 门。
  - 验证：`xcodebuild build --sdk iphonesimulator` 与 `--sdk iphoneos CODE_SIGNING_ALLOWED=NO` 均成功；engine smoke 通过。
- [x] **T6 基线测量**（DONE 2026-11-10 19:35，commit `7c01d963`）：iPhone 17 Pro 模拟器（iOS 26.5，debug，真实 Node 引擎）实测并冻结阈值。冷启动 simctl launch→首屏 2402/2384/2380/2414/2339ms（中位 2384、最大 2414），全新安装首启 2856ms；引擎全新安装 9286/9999/9296ms（d1-01 probe 11s、23 进度事件），幂等安装 2223/2099/2117ms；start 3110/3066/3069ms（probe 10× 3062–3073）、stop 523/519/521ms、restart 2923/2990/2966ms；连续启动 10/10 到 running、0 崩溃、0 未捕获异常；RSS 冷启后 850MB、空闲 5min 993MB。冻结阈值：冷启<3.5s、全新安装<30s、幂等安装<5s、start<8s、stop<3s、restart<8s、0 未捕获异常、RSS 993MB(+10%)。未测（如实记录）：mock 首 token（App 内无可编程发 prompt 入口）、20 次连续启动（10 次时间盒）、SE3、真机。证据：`reports/T6-baseline-metrics.md`、`reports/t6/`、`verification-baseline.md` §6。

### Wave 1：引擎与配置（Agent: ios-branch）

- [x] **T7 D1-01 引擎安装**（DONE 2026-11-10 19:10，commit `da599599`，merge `70d24ee3`）：`RuntimeInstallFailure`+统一 `_install()`+失败原因展示+已就绪幂等；5/5 TDD（RED→GREEN）、`test/engine` 67/67；L4 真引擎模拟器 14/14 checks PASS（安装 14s、23 进度事件、引擎 running 4712ms；解压 40% 杀进程→journal→重启续装 11s）。独立 verifier：可合并（建议后续补 RED 提交树复现、L2 进度断言、AC3 损坏包/磁盘满、AC2 直接续装证据）。证据：`reports/wave1/T7-engine-install.md`。
- [x] **T8 D1-02 启停/重启/自动启动**（DONE 2026-11-11 02:07，`afd50db5`，merge `0eb9ffa6`）：真实 RED（双击把 2 次 start/stop 都转发 native）→ 最小修复 in-flight 合并；9 条新测试（d1_02 6/d1_04 3）、test/engine 76/76；L4 真引擎 16/16（start 3210ms/stop 420ms/restart 2969ms/同 pid/失败码可读）。独立 verifier 通过，弱断言（UI idle/remote-only 冷启动/2000 环形上限）留 T22。
- [x] **T9 D1-04 日志/启动失败诊断**（DONE 2026-11-11 02:07，同 T8 提交）：真实 RED（日志保留 token=/sk-/Bearer/API_KEY 明文）→ `redactDiagnostics`；snapshot/seq/去重/复制/脱敏测试 + L4 证据；verifier 通过（2000 上限未真验→T22）。
- [x] **T10 D2-01 首次引导 + D9-01 隐私告知**（DONE 2026-11-11 02:12，`3541ccac`，merge `da2a35ff`）：24 条 L2（app/test/phase1）；唯一真实 RED（首次启动隐私“说明入口”缺失）→ `usage_notice_row.dart` 标题可点开 PrivacyPage；D9-01-AC2 断言关后零请求/iOS 无上报通道；L4/L5（权限弹窗/FAQ）defer T22；verifier 通过。
- [x] **T11 D2-03/D2-04 API Key/渠道/模型切换**（DONE 2026-11-11 02:12，同 T10 提交）：渠道增改校验（Base URL/Key 错误不落半成品）、Keychain 前缀/无明文、模型与 thinking 切换持久化+下一条生效；596/596 非 golden 旧测通过；L4 mock 3901 请求 model 断言 defer T22；verifier 通过（profile-first 例外等 follow-up 已记录）。

### Wave 2：对话闭环（Agent: main-arch）

- [x] **T12 D3-01/D3-02 新对话+流式/思考**（DONE 2026-11-10 19:30，`a82c3116`+`fee98b1b`，merge `c47c4529`）：真实 RED（流中断后仍 streaming=true）→最小实现；独立 verifier 发现 AC3 竞态（<32ms 断流被 32ms flush 覆盖）→ 修复 `_settleStreamsAfterLoss`+`_watchEnded` 守卫并加 2 条回归测试，复核 PASS；`test/chat/phase1` 13/13、相关旧子集 113/113。未做：L4（T22 接线）、D3-01 为 characterization、竞态后 resync 恢复回归。证据：`reports/wave1/T12-chat-stream.md`。
- [x] **T13 D3-03/04/05 插话/排队/停止**（DONE 2026-11-11 02:18，`0ecc0dbb`，merge `5a30af26`）：33 条新测试（phase1 目录 46/46）；真实 RED 2 处（D3-05 停止超时静默收键→报错保持 running；D3-07 计划待审无标题→复用 statePlanPending）；变异 M1/M2 均被捕获；相关旧子集 286 pass（2 条 quote golden 环境红）；L4 引擎侧断言 defer T22。
- [x] **T14 D3-06/07 审批/提问**（DONE 2026-11-11 02:18，同 T13 提交）：允许一次/本对话都允许（重启恢复逐次询问）/拒绝只发一次决策/拒绝后工具不执行；提问卡提交幂等、计划待审回答/要求修改各一次；工具真实副作用与文件系统断言 defer L4/T22。
- [x] **T15 D3-08/D3-19 工具行/消息操作**（DONE 2026-11-11 02:18，同 T13 提交）：工具行摘要/展开、回合折叠已完成摘要、失败工具行错误态；复制/分叉/重答（仅最后一条、新对话重发）/引用；verifier 记录弱断言（返回原对话未点、分享仅入口）→T22。

### Wave 3：会话/工作区/附件（Agent: ios-constraints）

- [x] **T16 D4-01/D4-03 会话抽屉/搜索**（DONE 2026-11-10 18:56，commit `e32bde48`，merge `bd65232b`）：新增 12 条 widget 测试（+500 行，无产品代码改动，现有实现已满足 AC）；`test/sessions` 12/12；独立 verifier：测试有效（变异 M1–M4 均使其失败）、CONCERN（部分断言容忍重复/跨日分组未验、报告数字已修正）。证据：`reports/wave1/T16-sessions.md`。
- [x] **T17 D4-05/D4-07 工作区/附件**（DONE 2026-11-11 02:40，`8c20c19b`+`34f2a6f8`，merge `799ce827`）：18 条新 L2（files/chat/engine phase1 共 31/31）；D4-07-AC3 真实 RED（杀 App 后附件静默丢失）→ `draft_store.dart` 附件字节持久化恢复；verifier 发现并修复真实清理缺陷（最后一个附件清空后目录不删）`34f2a6f8`+新测试；文件预览/刷新/隔离/错误态齐全；L4/L5（真引擎/PDFKit/相册）defer T22。
- [x] **T18 PERSIST-01 持久化与崩溃恢复**（DONE 2026-11-11 02:40，同 T17 提交）：relaunch 会话恢复+引擎自动启动、stop→start 保留会话草稿附件、unknown-result 确认前零重执行、exit70 崩溃可恢复；进程级真引擎 L4 留 T22（报告已 DEFER）。

### Wave 4：远程主机（Agent: ios-projects）

- [x] **T19 D1-09 主机切换**（DONE 2026-11-10 19:03，`a5ae8f59`+`c7c05ecd`，merge `27200f98`）：9 条 TDD（真实 RED：活动 SSH 主机不在保存列表时未回落本机）→最小修复；独立 verifier 首轮 FAIL（新增 container listener 导致 `Ref after disposed` 回归）→ 修复 `ref.mounted` 守卫+加固弱断言，复核 PASS，目标 9/9、回归测试 14/14。AC1 会话列表内容 deferred 到 L4 fake host。证据：`reports/wave1/T19-hosts.md`。
- [x] **T20 D1-10 SSH 远程主机**（DONE 2026-11-11 02:14，`3ba1ccd9`，merge `4883e519`）：fake SSH transport 13 条（d1_10 8/d1_11 5）；真实 RED（非法私钥 PEM 正文泄漏到错误详情）→ `_safeKeyFailure` 脱敏；重启/断线/隧道/失败不残留均有断言；真实 sshd L5 deferred；verifier 通过。
- [x] **T21 D1-11 DSH Remote 基础**（DONE 2026-11-11 02:14，同 T20 提交）：fake relay+Noise 连接、会话列表、对话/审批、重连去重、不可达 retry、终端/传文件入口隐藏（Phase 2 标注）；真实服务器 L5 deferred；verifier 通过。

### Wave 5：收口（Lead + verifier）

- [x] **T22 全量验证**（DONE 2026-11-11；证据 `reports/T22/` + `reports/phase1/acceptance-run/`）：`scripts/verify.sh --fast` = **pass=13 fail=0 skip=0**；`--full` = **pass=21 fail=0 skip=1**（唯一 skip 为 iSH guest archive，`--allow-skip` 显式放行；commit `ebeb1b9a`）；E2E **iPhone 17 Pro + SE3 均 PASS**（6 个递增流式前缀）；RunnerTests **366/366 passed（D6 `testSystemTools` 过滤）**；engine smoke PASS。R3 引擎 stop 崩溃修复 `56111af8`，T22b 已把 stop/restart 加回 E2E（stop 509ms / restart 2675ms）。
  - 最终结果：R3 + T22b 未提交测试改动后的 `--full` 2026-11-11 14:30–14:45 重跑 = **pass=21 fail=0 skip=1**（仅 iSH guest archive，`--allow-skip` 放行）；E2E 17 Pro（stop 501ms/restart 3367ms）与 SE3（stop 741ms/restart 2930ms）均 PASS；guest fixture 5/5。T22b 首跑 18/3/1 已留证，未冒充最终绿。
- [x] **T23 交付文档**（DONE 2026-11-11 14:35）：`docs/specs/phase1/acceptance-report.md`（环境/门禁/24 ID·69 AC/25 项验收/修复/deferred/证据/待回填字段）、`docs/specs/phase1/phase2-backlog.md`（§9 + 18 项技术债）、本计划仓库版、`docs/specs/phase1/README.md` 状态更新。**6 分钟演示录屏已产出**：`reports/phase1/demo-6min.mp4`（5m15s / 47.5MB；三段真实模拟器录制：17 Pro E2E、17 Pro acceptance、SE3 E2E，ffmpeg 拼接+标题卡；说明 `reports/phase1/demo-6min.md`）。

---

## 6. Agent Teams 编排与写入权限

### 6.1 角色与写作用域（复用现有 8 名 teammate，不新建超出上限）

| 角色 | 成员 | 写作用域（独占） | 职责 |
|---|---|---|---|
| Lead | 我 | `app/lib/app.dart`、`main.dart`、`l10n/**`、`pubspec.yaml`、`docs/specs/**`（与 test-infra 共管）、合并 `phase1/integration` | 合并/冲突/门禁/最终验收 |
| Engine | `ios-branch` | `app/ios/Runner/Engine*`、`Guest*`、`runtime/ios/host/**`、`tooling/ios/**`、`app/lib/runtime/**`、`app/lib/state/runtime_capabilities_state.dart` | T7–T11 |
| Chat | `main-arch` | `app/lib/state/chat_state.dart`、`app/lib/ui/chat/**`、`app/test/chat/**` | T12–T15 |
| Sessions/Files | `ios-constraints` | `app/lib/state/sessions_state.dart`、`workspaces_state.dart`、`attachments.dart`、`app/lib/ui/sessions/**`、`app/lib/ui/files/**`、`app/lib/media/**` | T16–T18 |
| Remote | `ios-projects` | `app/lib/remote/**`、`packages/dsh_remote/**`、`app/lib/ui/remote/**`、`app/lib/state/hosts_state.dart` | T19–T21 |
| Test infra | `spec-baseline` | `test/**`、`integration_test/**`、`test/fixtures/**`、`scripts/verify.sh`、`.github/workflows/**`、`docs/specs/phase1/test-*` | T4–T6、测试工具/CI |
| Verifier | `gh-forensics` | 只读 + `reports/verify/**` | 独立复核每个任务/最终分支 |

**跨域规则**：一个共享文件同一时间只能有一个 owner；跨域改动由 Lead 转交；每任务独立 worktree（`/tmp/dsh-phase1/<task>`），完成后 Lead 合并到 `phase1/integration`；禁止在共享工作树并行编辑。`app/android/**` 不改。

### 6.2 执行节奏

1. **Wave 0 串行**（T1→T6），因为基座/门禁/测试基线未定前不并行写功能。
2. Wave 1–4 **按域并行**：每个 agent 在自己的 worktree 从 `phase1/integration` 拉分支，TDD 完成后发 verifier。
3. Verifier 在**新 worktree** 复核：跑测试、检查 RED 证据、回退实现抽查、审 spec 对齐；PASS 后 Lead 合并，更新 traceability。
4. 每日 Lead 集成窗口：合并、跑 `scripts/verify.sh`、处理冲突；共享文件冲突只由 Lead 解。
5. 每个 Wave 结束做一次**整体回归 + 独立 review**（verifier 或另一个未参与该域的 agent）。

---

## 7. 验证与验收（Phase 1 门）

### 7.1 自动化门（必须全绿）

- `scripts/verify.sh`：`flutter analyze`；`flutter test`（unit/widget，排除暂不适用的 goldens）；`dart test`（packages）；Node tests；`xcodebuild build --sdk iphonesimulator`；`xcodebuild build --sdk iphoneos CODE_SIGNING_ALLOWED=NO`（设备编译不安装）；RunnerTests（模拟器）；`integration_test/phase1_test.dart`（iPhone 17 Pro + SE3）；official engine smoke（mock 模型）。
- **无跳过**：任何 skip 必须在 `acceptance-report.md` 标注原因（device-deferred 或上游已知），否则视为失败。

### 7.2 模拟器手工验收（~25 项，节选）

冷启动/引导/引擎安装/引擎启停/引擎失败诊断/API Key/模型切换/新对话/流式/思考折叠/插话/排队/停止/审批允许/审批拒绝/提问卡/工具行/会话抽屉/会话搜索/工作区预览/附件相册/附件文件/杀进程恢复/引擎重启恢复/SSH 连接/断线重连/主机切换/隐私开关。

### 7.3 Deferred（真机/付费/外部依赖，Phase 1 不计入）

相机/拍照、扫码、真实 APNs、后台挂起/长任务、性能/内存/jetsam、触感/传感器、CoreDevice/DDI 手机操控、真机签名安装、App Store/TestFlight、iSH guest 真机、iPad。

### 7.4 交付物

- 可运行模拟器 App（Debug + Release-no-codesign 构建脚本）
- `repo/docs/specs/phase1/*` 全部文档 + `spec-phase1-v1` tag
- `scripts/verify.sh` + CI workflows
- 6 分钟演示录屏 + `acceptance-report.md`
- 本计划的仓库版（`repo/docs/plans/2026-11-10-phase1-b-implementation.md`，含任务勾选）

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| merge main 冲突/回归 | 基座不稳 | 已实测 13 文件冲突；l10n 用生成器；冲突只由 Lead 处理；T1 后先跑官方 CI 门 |
| HEAD fixture 红 | CI 假失败 | 一行修复；fallback `ab2d179c` |
| prepare-engine 下载/编译失败 | 无法跑引擎 | 按官方 pin/SHA 校验；网络重试；保留 CI artifact 备选；T3 首日验证 |
| Python 3.10 不满足 | 构建失败 | brew/pyenv 安装 3.12，脚本内用绝对路径 |
| 模拟器与真机差异 | 假绿 | 明确 deferred 清单；关键协议做 contract test；Phase 2 真机矩阵补 |
| 共享 Dart 并行冲突 | 返工 | 单 owner + worktree + Lead 合并窗口 |
| 远程测试无 host | T19–T21 不可测 | mock SSH/Remote transport + 本机 DSH/sshd 可选；无 host 时标 manual-deferred |
| 测试为过而过 | 质量假象 | 独立 verifier + RED 证据 + 回退抽查 + traceability |
| Flutter/macOS 工具链差异 | 构建不一致 | 完全按官方 pin；CI 用 macos-26 镜像 |

---

## 9. Phase 2 边界（本计划不做，仅记录）

手机操控（CoreDevice/XCTest，侧载）、iSH 完整 Linux、通知/APNs/Live Activity、后台常驻、伙伴小屋/桌宠、插件生态、终端/网页版、媒体保存、自动化任务、iPad 适配、真机矩阵与性能专项、上游同步机制常态化。

---

## 10. 环境准备命令（执行阶段用）

```bash
# 模拟器 runtime（Xcode 26.6）
xcodebuild -downloadPlatform iOS -buildVersion 26.5
xcrun simctl list runtimes
xcrun simctl create "iPhone 17 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro <runtime-id>
xcrun simctl create "iPhone SE3" com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation <runtime-id>

# Flutter 3.47.7（SHA 校验）
curl -fL -o /tmp/flutter.zip https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_arm64_3.47.7-stable.zip
echo "dd9da574c3168460550117eb0e8dd0313ae934fabf64a82a6d557fff5fd1422e  /tmp/flutter.zip" | shasum -a 256 -c -
unzip -q /tmp/flutter.zip -d ~/tools && export PATH="$HOME/tools/flutter/bin:$PATH"

# Node 24.22.1（nvm/fnm 或官方 pkg）
nvm install 24.22.1 && nvm use 24.22.1
# Python 3.12
brew install python@3.12

# 构建与安装
cd ~/Documents/Zenlix/DSH-Go-iOS/repo
tooling/ios/prepare-engine.sh
tooling/ios/build.sh --simulator --debug
xcrun simctl boot "iPhone 17 Pro"
xcrun simctl install booted app/build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted <bundle-id>
```

---

## 11. 计划批准后的第一步

从 **T1–T6（基座 + spec/测试基线冻结）** 开始，不写任何 Phase 1 产品功能代码；完成并给用户看 `spec-phase1-v1` 文档与基线测量结果后，再按 Wave 1–4 并行推进。
