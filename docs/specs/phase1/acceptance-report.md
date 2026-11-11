# Phase 1 验收报告（acceptance-report.md）

- 版本：v1.1（2026-11-11 14:45，Asia/Shanghai；最终 `--full` 重跑已回填）
- 范围：计划 `docs/plans/2026-11-10-phase1-b-implementation.md` §0 的 Phase 1（B：基座闭环 + 远程主机）成功标准 1–5
- 分支/基线：`phase1/base`；已提交基线 **`56111af8`**（`fix(engine): stop no longer races URLSession invalidation (R3 crash)`）；工作树另含 **T22b 未提交测试改动**（`app/integration_test/phase1_test.dart`、`app/integration_test/phase1_acceptance_test.dart`，不涉及产品代码；当前 `git status`：T22b 两个测试文件 + `packages/dsh_remote/pubspec.lock`（构建生成副作用）；`app/analysis_options.yaml` 已还原）
- 判定规则：**未执行 ≠ 通过**；FAIL 不得以 DEFERRED 掩盖；deferred 必须写原因与承接阶段
- 结论：**Phase 1 自动化门与模拟器主路径通过；无 FAIL；有 27 项 L5 + 1 项 mock 受限 deferred。R3/T22b 后的最终 `--full` 已重跑：pass=21 fail=0 skip=1（唯一 skip 为 iSH guest archive，显式放行），详见 §2.1/§9。**

---

## 1. 环境与基线

| 项 | 锁定/实测值 | 证据 |
|---|---|---|
| 代码基线 | `phase1/base` = `56111af8`（T1 基线 `ef8eba50` → merge main `aee6445` = v1.0.14+1） | `git log`；`docs/specs/phase1/traceability.md` §1 |
| 上游版本 | Android main `aee6445`（v1.0.14）；观察到 `3edc945f`（v1.0.15）**未合并**，按计划 Phase 2 同步 | `upstream.lock#observed_upstream` |
| iOS 部署目标 | iOS 17.0，iPhone only（`TARGETED_DEVICE_FAMILY=1`） | T3 `93a8ba88`；`project.pbxproj` |
| Flutter / Dart | Flutter **3.47.7** / Dart **3.13.5** | `reports/env/t2-toolchain.md`；`verify.sh --fast` 日志 |
| Xcode / iOS SDK | **Xcode 26.6**，iOS SDK **26.5**（runtime 23F77） | T2/T3 报告 |
| Node / Python | Node **24.22.1**（nodejs-mobile v24.22.1-0）/ Python **3.12.16** | T2；T3 `prepare-engine` 成功 |
| 模拟器 | iPhone 17 Pro `1D9F8C91-5739-47B2-BDD0-0FC7207166F3`；iPhone SE3 `D9C6C518-0452-4AFE-9F8C-59EBE495BD47`；iOS 26.5 | `acceptance-results.md` 头部 |
| 构建 | `DSH_IOS_GUEST_BUILD=0 flutter build ios --simulator --debug`；Runner.app 474MB（T3），Engine 231MB | `reports/env/t3-build-spike.md` |
| 测试字体 | `DSH_TEST_FONT_DIR=DSH-Go-iOS/.fonts`（Noto CJK，repo 外 55MB） | T22a §3 |
| 工作区未提交 | T22b 测试文件；2 个构建生成物 | `git status`（2026-11-11 14:30） |

> 复跑命令、mock 端口与 CI 接线见 `ci.md` §7 与 `reports/CONTINUATION-NOTES.md`。

---

## 2. 自动化门结果

### 2.1 本地门（`scripts/verify.sh`）

| 门 | 命令 | 结果 | 证据 |
|---|---|---|---|
| L0 静态 | `verify.sh --static` | **exit 0 / pass=7 fail=0 skip=0** | T4-fix 后冻结结果；`verify.sh --fast` 步骤 1–7 同集 |
| 快速门 | `verify.sh --fast` | **exit 0 / pass=13 fail=0 skip=0** | `reports/T22/t22a-verify-fast-font-1215.log` |
| 全量门（T22a，R3 前） | `verify.sh --full --allow-skip="Phase 1 iSH guest deferred: check-archive needs DshGuest"` | **exit 0 / pass=21 fail=0 skip=1**（唯一 skip = iSH guest archive，显式放行） | `reports/T22/t22a-verify-full-rerun-1246.log`；T22a §6 |
| 全量门（T22b，R3 后，最终） | 同上（17 Pro/SE3 UDID 显式） | **exit 0 / pass=21 fail=0 skip=1**（唯一 skip = iSH guest archive，`--allow-skip` 显式放行；首跑 18/3/1 见 §8.4） | `reports/phase1/acceptance-run/t22b-verify-full-rerun.log`（2026-11-11 14:30–14:45）；首跑 `t22b-verify-full.log` |

`--fast` 步骤摘要：`flutter analyze`、packages `dart analyze`、l10n（63 parts/6301 keys）、guide sync（26 files）、plugin skill sync、mock self-test（16/16）、Node syntax、Phase 1 Flutter 目录 **88 passed**（`test/phase1` 24 + `test/chat/phase1` 51 + `test/engine/phase1` 5 + `test/files/phase1` 8）、`dart test packages`、`node --test test/unit`、官方 guest/native/host-core 门、verify 自测。

### 2.2 L3 Swift 契约（RunnerTests）

| 项 | 结果 | 证据 |
|---|---|---|
| RunnerTests（D6 过滤 `NativeToolsTests/testSystemTools`） | **366/366 passed，0 failed，0 skipped，TEST SUCCEEDED**（SE3，干净冷启，`-parallel-testing-enabled NO`） | `reports/T22/stop-crash-fix-report.md` §4.3；`reports/T22/stop-crash-fix/runnertests-full-pass.log` |
| 未过滤基线 | 362 passed + 1 failed（`testSystemTools` 60.4s，D6 deferred） | `reports/T22/t22a-runnertests.log` |
| 最终 `--full` 内 RunnerTests | **TEST SUCCEEDED**：日志 **365 条 passed / 0 failed**，`testSystemTools` 被最小过滤 | `t22b-verify-full-rerun.log` 内 `RunnerTests` 段 |
| 说明 | T22a 报告曾按 xcodebuild 日志计 361 条；R3 修复新增 3 条 `IOSPhoneHTTPTests` 后，专项 xcresult 为 **366/366**；最终 `--full` 日志计 365 条（日志与 xcresult 计数口径不同） | 三处口径已在 §8 记录 |

### 2.3 L4 端到端（真 App + 真引擎 + mock 模型）

| 场景 | 结果 | 证据 |
|---|---|---|
| E2E iPhone 17 Pro（canonical mock；含 B3/B4 stop→installed→start→新会话） | **PASS**：两轮流式各 **6** 个递增前缀；stop **501ms**；restart **3367ms**；回合 7.5s | `reports/phase1/acceptance-run/steps/integration_test_phase1__iPhone_17_Pro,_canonical_mock_.log`（最终 full 内） |
| E2E iPhone SE3（`--full` 内，最终） | **PASS**：6 个递增前缀；stop **741ms**；restart **2930ms** | `reports/phase1/acceptance-run/steps/integration_test_phase1__iPhone_SE3,_canonical_mock_.log` |
| E2E iPhone 17 Pro（`--full` 内，T22a） | **PASS**：6 prefixes | `reports/T22/steps-rerun/integration_test_phase1__iPhone_17_Pro,_canonical_mock_.log` |
| 验收自动化 `phase1_acceptance_test.dart`（17 Pro） | A1/A2/A3/A4/A5/B1/B3/C1/C2/C3/C6/D4/D6 共 **13 项自动 PASS**；加上 E2E 的 B4，自动 PASS 合计 **14 项**；C7 审批卡 120s 超时后按设计停止（记 deferred，不伪造） | `reports/phase1/acceptance-run/t22b-acceptance-17pro-run6.log` |
| 官方 engine smoke（真引擎+假模型，R3 后专项） | **PASS**：ready 4381ms、restart passed 1849ms、approvals 8、phoneTools 13、browserTools 11、systemTools 8 | `reports/T22/stop-crash-fix/engine-smoke.log` |
| 官方 engine smoke（最终 `--full` 内） | **PASS**：ready **2638ms**、restart **2111ms**、approvals 8、phoneTools 13、browserTools 11、systemTools 8 | `t22b-verify-full-rerun.log` 内 engine round |
| 官方 Flutter 子集（排除 goldens） | **PASS**：2272 passed / 12 skipped（live 环境开关）/ 0 failed | `reports/T22/steps-rerun/flutter_test__official_phase1-related_subset,_goldens_excluded_.log` |
| stop/reconnect 时序套件（隔离） | **PASS**：16/16 | `reports/T22/steps-rerun/flutter_test__stop_reconnect_timing_suite,_isolated_.log` |

### 2.4 CI（fork `m1ng-wym/dsh-Go`，workflow `Phase 1 verify`，Linux L0）

| 顺序 | run id | commit | 结果 |
|---|---|---|---|
| 最近 | **42966279010** | `56111af8` R3 fix | success（2m31s，2026-11-11 05:31Z） |
| 前一次 | 42963276472 | `ebeb1b9a` T22a | success（2m58s） |
| 连续绿 | 42876345278 / 42873621273 / 42808793659 / 42808250414 | T17-T18 / Wave2+4 / T6 / T4-fix | success |
| 历史红（已修） | 42807578306 / 42807010343 / 42806505794 / 42806057890 | 2026-11-10 依赖锁/自测捕获 | failure |

> 口径：CI 只承载 Linux L0/L1（`--ci`），macOS L3/L4 由本机 `--fast/--full` 承载；不能用 CI 绿替代 L4。6 次连续 success 从 2026-11-10 19:32（+08）起。

---

## 3. 覆盖汇总（24 个能力 ID / 69 条 AC）

### 3.1 traceability 现状

| 指标 | 数值 | 说明 |
|---|---|---|
| 能力 ID | **24** | A 基座 21 + B 远程 3（D1-09/D1-10/D1-11）+ 跨切面 PERSIST-01 |
| AC 行 | **69** | `traceability.md` §2 逐行；**0 行非 DONE**（无 PLANNED/RED/BLOCKED） |
| 含 L4 的 AC | **37** | 其中 29 行为“L4 自动”或“L2+L4”（不含 L5） |
| 含 L5 的 AC | **19** | 手工/真机项，按 §5 deferred |
| 纯 L1/L2 自动 | **21** | 1 行 L1 + 19 行 L2 + 1 行 L1+L2 |
| 类型 | 50 auto / 17 auto+manual / 2 manual | `traceability.md` 第 7 列 |

**判定**：traceability 层面 **69/69 DONE**，满足计划“traceability 100%”的字面要求；但“DONE”包含“L2 已过、L4/L5 由 T22/T22b 承接”的行。T22b 实际重跑的 L4 仅覆盖 A/B/C/D/E 的一部分（见 §4），其余 29 行 L4 的证据来自各任务 L4（T7/T8-T9/T19）或 T22a E2E，**未在 T22b 逐条重放**。本报告不把“traceability DONE”表述为“全部 AC 都在本轮模拟器实测”。

### 3.2 AC 层级分布（明细）

| 层级 | 行数 | 代表能力 |
|---|---|---|
| L1 / L1+L2 | 2 | D1-04-AC3（日志脱敏）、D4-03 搜索 |
| L2 及 L2+L4 | 39 | D2-01/D2-03/D2-04、D3-01…D3-19、D4-01/03/05/07、D9-01、D1-09…D1-11 |
| L3+L4 | 2 | D3-06-AC1/AC2（审批） |
| L4 / L4+L5 | 13 | D1-01、D1-02、D1-09、D1-11、PERSIST-01 |
| L5 / L2+L5 | 13 | D2-01-AC2、D3-19-AC1、D9-01、D1-10 等 |
| 合计 | **69** | — |

---

## 4. 25 项模拟器验收状态（roll-up）

> 口径：`acceptance-results.md` 实际记录 **44 个可勾选步骤：PASS 16 / DEFERRED-L5 27 / DEFERRED-MOCK 1 / FAIL 0**（PASS 含 E2 “部分”、G3 “部分”）。下表按验收主题归并为 **25 项**，不改变逐项状态。PASS 的自动覆盖来源引用 T22b §7 与日志。

| # | 验收主题 | 状态 | 自动覆盖来源 / deferred 原因 |
|---|---|---|---|
| 1 | A1 首次引导 | **PASS** | `phase1_acceptance`：uninstall 后 WelcomePage → 本机 → HomeShell；`t22b-acceptance-17pro-run6.log` |
| 2 | A2 引导不重复 | **PASS（部分）** | 同进程 App root 重建直达 HomeShell；**冷进程重启 deferred L5** |
| 3 | A3 自定义渠道 | **PASS** | `ProviderActions.save` 写真实引擎 `custom-mock-phase1`；表单 UI 由 L2 `d2_03_provider_config_test` 覆盖 |
| 4 | A4 模型切换 | **PASS** | 下一条消息使用 `mock-phase1-model:slow`（mock 日志） |
| 5 | A5 隐私开关持久化 | **PASS** | 关闭后 App root 重建仍为 false；无网络上报（L2） |
| 6 | B1 引擎安装 | **PASS** | `installedVersion == bundledVersion == ios-c3b9a2a33a34c4c111586a46`；L4 + `phase1_test` |
| 7 | B2 安装续装 | **DEFERRED-L5** | 测试进程内无法 `simctl terminate` 自身；T7 已有“解压 40% 杀进程续装 11s”的 L4 证据，但未在 T22b 重放 |
| 8 | B3 引擎启动/停止 | **PASS** | E2E stop 509ms → installed，App 未崩溃（R3 修复后） |
| 9 | B4 停止后再启动 | **PASS** | E2E restart 2675ms → running；新会话 7.5s 流式完成 |
| 10 | B5 自动启动 | **DEFERRED-L5** | 需外部杀进程/冷启动；开关本身 L2 覆盖，App root 重建仅部分证据 |
| 11 | B6 启动失败诊断 | **DEFERRED-L5** | 需在 App 容器破坏 runtime 后冷启动；手工步骤见 T22b §6 |
| 12 | B7 日志页凭据 | **DEFERRED-L5** | 日志页 UI 未在 L4 打开；脱敏逻辑 L2 已测（`redactDiagnostics`） |
| 13 | C1/C2 新对话 + 流式 | **PASS（部分）** | 发送前 `currentSessionProvider == null`；6 个递增前缀；抽屉“不新增空会话”未单独断言 |
| 14 | C3 思考折叠 | **PASS** | reasoning 存在且不混入正式回答；展开 `ThinkingPill` 可见 |
| 15 | C4/C5 插话/排队 | **DEFERRED-L5** | 本轮时间盒未实现 UI steer/queue 断言；L2 有队列与插话测试 |
| 16 | C6 停止 | **PASS** | `kept 2 chars: 慢速`；`running=false/stopping=false/error=null` |
| 17 | C7/C8 审批允许/拒绝 | **DEFERRED-L5** | 引擎默认 `danger-full-access`，写工具被自动执行，**审批卡不可达**（120s 超时）；需 `approval: ask` profile 或 L2 组件测试。L2 审批卡允许/拒绝分支已覆盖 |
| 18 | C9/C10 工具行/消息操作 | **DEFERRED-L5** | 未展开工具行/未做消息操作 UI；L2 已覆盖 |
| 19 | C11 提问卡 | **DEFERRED-MOCK** | canonical mock 的 `question` 只输出文本标记，不产生引擎级提问；需 fake host 注入 |
| 20 | D1–D4 会话抽屉/搜索/隐私页 | **PASS（部分）+ DEFERRED-L5** | 抽屉见 1 个会话、搜索页可用、隐私页类别可读（D6 PASS 页面级）；排序/未读/多关键词高亮/主机隔离 deferred |
| 21 | D5–D8 工作区/附件 | **DEFERRED-L5** | 相册/文件选择器为系统级；文件页/附件上限未手工覆盖；D4-05/D4-07 L2 已覆盖 |
| 22 | E1–E4 持久化/恢复 | **PASS（部分）+ DEFERRED-L5** | E2 停止→启动后新会话可用（部分）；真实杀进程/结果未知/草稿恢复 deferred |
| 23 | F1–F5 远程真连 | **DEFERRED-L5（live）** | 无真实 sshd/DSH Remote；fake transport 的 L2（T19–T21）已覆盖连接/会话/重连，不伪造真连 |
| 24 | G1/G2/G4 外观/语言/release | **DEFERRED-L5** | 未做深色冷启动/系统语言切换/release 构建；`verify --full` 只有 simulator debug + device unsigned |
| 25 | G3 SE3 小屏 | **PASS（部分）** | SE3 E2E 完成 boot/onboarding/流式/stop/restart；C7/D1/D5 布局未逐项目检 |

**小计核对**：按主题计 PASS 14（其中 5 项标“部分”，#20/#22 同时含 deferred 子项）、DEFERRED-L5 10、DEFERRED-MOCK 1；逐项 44 步小计仍为 16/27/1/0（主题归并只用于阅读，不改变逐项状态）。

---

## 5. 已知问题与修复记录

| # | 问题 | 影响 | 修复 / 状态 | 证据 |
|---|---|---|---|---|
| R3 | iOS 引擎 stop 时 `IOSPhoneBridge.retire()` 的 `session.invalidateAndCancel()` 与 500ms `poll()` 的 `post()` 竞态，触发 `NSURLSession` ObjC 异常 → SIGABRT | App 内 stop 崩溃；T22a E2E 曾移除 stop | **已修复并提交 `56111af8`**：新增 `@MainActor IOSPhoneHTTP`，读 session + 建 task 在同步 body 内完成；3 条 `IOSPhoneHTTPTests`；RunnerTests 366/366；crash 目录前后均 2 个无新增；E2E stop/restart 已加回（T22b） | `reports/T22/stop-crash-fix-report.md`；`t22b-e2e-17pro-run4.log` |
| — | 最后一个草稿附件清空后空目录不删除 | 工作区残留空目录 | **已修复 `34f2a6f8`** + 新测试 | T17-T18 报告 |
| — | SSH 非法私钥 PEM 正文泄漏到错误详情 | 凭据泄漏风险 | **已修复 `3ba1ccd9`**：`_safeKeyFailure` 脱敏 + 测试 | T20-T21 报告 |
| — | 流中断 <32ms 被 32ms flush 覆盖，`streaming` 未清 | 状态假 streaming | **已修复 `fee98b1b`**：`_settleStreamsAfterLoss` + `_watchEnded` 守卫 + 2 条回归 | T12 报告 |
| — | 新增 container listener 导致 `Ref after disposed` 回归 | 主机切换崩溃 | **已修复 `c7c05ecd`**：`ref.mounted` 守卫 + 弱断言加固 | T19 报告 |
| — | `dsh_client` heartbeat 探针在 teardown 后仍 in-flight（flake） | 测试偶发失败 | **已修复 `00feb7d9`**：teardown 前 drain | git show |
| — | `dsh_remote` 大 mutation / transfer watchdog 超时（flake） | 测试偶发失败 | **已修复 `4cb2dbb1`**：放宽 watchdog 与 timeout | git show |
| — | `analysis_options.yaml` 被 `pub get/build` 自动追加 exclude；`dsh_remote/pubspec.lock` 漂移 | 工作树变脏 | 已多次 `git checkout` 还原；**不是源改动，交付时不得提交** | T22a §2/R9 |
| — | 官方 `test-guest-embedding.py` 在 `DSH_IOS_GUEST_BUILD=0` 下 4 个用例失败 | T22b 首跑 `--full` 3 失败之一 | **环境变量泄漏**：官方 fixture 不能被 guest-skip env 影响；最终重跑去掉该 env 后 `Ran 5 tests` PASS | `t22b-verify-full.log` 行 1555-1607 |
| — | T22b 首跑 E2E 两机型 `new conversation ... timed out after 90s` / `session creation superseded` | T22b 首跑 18/3/1 的另外 2 个失败 | 判为并行/时序 flake（T22a 同用例 PASS）；重跑验证中 | `steps/integration_test_phase1__iPhone_*.log`；T22b §5 |

> 安全项：三条凭据泄漏/脱敏修复（`3ba1ccd9`、`00feb7d9` 同类、`D1-04` 日志脱敏）均保留 RED 证据；未发现新的明文密钥入库。

---

## 6. Deferred 清单（Phase 1 不计入通过率）

| 类别 | 具体项 | 原因 | 承接 |
|---|---|---|---|
| 真机 / L5 | 冷进程重启（B2/B5/B6/B7/E1/E3/E4）、审批卡（C7/C8）、插话/排队（C4/C5）、工具行/消息操作（C9/C10）、相册/文件附件（D5–D8）、深色/语言/release（G1/G2/G4）、SE3 细项 | 测试进程无法自我 terminate；权限/系统 UI 需手工；无真机 | Phase 2 真机矩阵；`acceptance-checklist.md` |
| iSH guest / archive | iSH 完整 Linux、`check-archive.sh` 形状检查 | Phase 1 不构建 iSH；`DshGuest*` 不存在 | Phase 2；`--allow-skip` 显式记录 |
| 真实 SSH / DSH Remote | 真实 sshd、真实 Relay/TURN 服务器、断线重连 live | 无真实 host/账号；fake transport 已覆盖协议 | Phase 2 |
| golden 基线 | 27 个 golden-bearing 文件（13 named + 14 mixed） | macOS 与 Linux 字体/渲染不一致，T22a 72 个像素失败 | 由 Linux CI/上游承载；Phase 2 重建 iOS 基线 |
| D6 系统工具 | `NativeToolsTests.testSystemTools`（提醒事项/通讯录/定位） | 依赖系统权限，D6 deferred | Phase 2 真机 |
| T6 未测 | mock 首 token、20 次连续启动（仅 10 次）、T6 时 SE3、真机性能/内存 | App 内无可编程发 prompt 入口；时间盒 | Phase 2 性能专项 |
| 上游同步 | v1.0.15（`3edc945f`） | 按计划锁定 v1.0.14 | Phase 2 每周 sync |
| 功能延后 | 手机操控、APNs/Live Activity、后台常驻、伙伴/桌宠、插件市场、终端/网页/导出、媒体保存、iPad、自动化任务 | 计划 §0/§9 明确不做 | `phase2-backlog.md` |

---

## 7. 证据索引

| 类别 | 路径 |
|---|---|
| 验收逐项/日志 | `reports/phase1/acceptance-run/acceptance-results.md`、`t22b-acceptance-17pro-run6.log`、`t22b-e2e-17pro-run4.log`、`t22b-verify-full*.log` |
| T22a 门禁 | `reports/T22/T22a-report.md`、`t22a-verify-fast-font-1215.log`、`t22a-verify-full-rerun-1246.log`、`reports/T22/steps-rerun/` |
| R3 修复 | `reports/T22/stop-crash-fix-report.md`、`reports/T22/stop-crash-fix/runnertests-full-pass.log`、`unit-IOSPhoneHTTPTests-SE3-pass.log`、`engine-smoke.log` |
| T22b | `reports/T22/T22b-report.md` §7 |
| 任务证据 | `reports/wave1/*.md`、`reports/wave2/*.md`；T1–T6 报告与 `reports/env/t3-build-spike.md` |
| 规格/追溯 | `docs/specs/phase1/{capability-spec,traceability,verification-baseline,acceptance-checklist,ci,test-plan,mocks,design}.md` |
| CI | GitHub Actions `m1ng-wym/dsh-Go` → `Phase 1 verify`：[42975387409](https://github.com/m1ng-wym/dsh-Go/actions/runs/42975387409)（c3070795 最终 success）；R3 修复 run 42966279010 亦 success |
| 演示录屏 | `reports/phase1/demo-6min.mp4`（5m15s / 47.5MB，H.264；素材 `reports/phase1/raw/`、说明 `reports/phase1/demo-6min.md`） |
| 计划 | `docs/plans/2026-11-10-phase1-b-implementation.md` |

---

## 8. 文档一致性 / TODO-VERIFY

1. **RunnerTests 计数**：T22a 报告写“361 条日志 passed”，R3 报告写“366/366（xcresult）”。本报告采用后者（新增 3 条 `IOSPhoneHTTPTests` + 既有用例），并要求以 `runnertests-full-pass.log` 为准；T22a 的 361 是当时日志计数，不矛盾但口径不同。
2. **T22b 状态数字**：`T22b-report.md` 首段写“PASS 16 / DEFERRED-L5 27 / DEFERRED-MOCK 1”；`acceptance-results.md` 逐项一致。另有口头“19 项 L5”的说法，**与文件不符**，以 27 为准。
3. **C7/C8**：不是产品缺陷，而是引擎 profile 默认 `danger-full-access` 导致审批卡不可达；`acceptance-results.md` §3 已给证据。Phase 2 需 `approval: ask` 测试 profile。
4. **T22b `--full` 首跑红 → 最终绿**：首跑 `t22b-verify-full.log` 为 **pass=18 fail=3 skip=1**（guest-embedding fixture 2 失败 + 2 errors，原因是 `DSH_IOS_GUEST_BUILD=0` 泄漏；E2E 17 Pro/SE3 各 1 次时序 flake）。修正后最终 `t22b-verify-full-rerun.log` = **pass=21 fail=0 skip=1**，E2E 两机型均 PASS，guest fixture `Ran 5 tests` 通过。首跑红保留，不冒充最终结果。
5. **环境变量**：`DSH_IOS_GUEST_BUILD=0` 只用于 App 构建/E2E，不应传给官方 guest-embedding fixture；T22b 首跑已踩坑，复跑脚本需隔离。
6. **工作树/提交**：本报告与 `phase2-backlog.md`、`docs/plans/**`、T22b 测试改动已由 Lead 提交为 `c3070795`（并 push；CI 全绿）；演示录屏是 workspace 交付物（`reports/phase1/demo-6min.mp4`），不进 repo。

---

## 9. 最终全量门回填（FINAL-RERUN，已完成）

> 最终 `verify.sh --full`（R3 `56111af8` + T22b 未提交测试改动）于 **2026-11-11 14:30 启动，14:45 结束**。以下为实际值（不再有 `FINAL-RERUN-PENDING`）。

| 字段 | 值 |
|---|---|
| `FINAL_RERUN_EXIT` | **0**（verify.sh 结尾逻辑：fail=0、pass=21、skip 已显式放行） |
| `FINAL_RERUN_SUMMARY` | **pass=21 fail=0 skip=1** |
| `FINAL_RERUN_SKIP` | 仅 `archive shape check (deferred: iSH guest)`；`--allow-skip="Phase 1 iSH guest deferred: check-archive needs DshGuest"` 显式放行 |
| `FINAL_RERUN_LOG` | `reports/phase1/acceptance-run/t22b-verify-full-rerun.log`（归档到 `reports/T22/final/`） |
| `FINAL_RERUN_E2E_17PRO` | **PASS**：stop 501ms / restart 3367ms / 两回合各 6 前缀 |
| `FINAL_RERUN_E2E_SE3` | **PASS**：stop 741ms / restart 2930ms / 6 前缀 |
| `FINAL_RERUN_GUEST_FIXTURE` | **PASS**：`Ran 5 tests`（首跑 4 失败消失） |
| `FINAL_RERUN_RUNNERTESTS` | **TEST SUCCEEDED**：日志 365 passed / 0 failed；R3 专项 xcresult 366/366 |
| `FINAL_RERUN_ENGINE_SMOKE` | **PASS**：ready 2638ms / restart 2111ms / approvals 8 |
| `FINAL_RERUN_CI_RUN` | **success**：`Phase 1 verify` run [42975387409](https://github.com/m1ng-wym/dsh-Go/actions/runs/42975387409)（commit `c3070795`，2m58s 全绿） |
| `FINAL_RERUN_DATE` | 2026-11-11（Asia/Shanghai） |

**判定**：除 iSH guest archive 外无 skip、无 FAIL，Phase 1 自动化门按计划 §7.1 视为**通过**。遗留的“L4 未逐条重放”仍是 §3.1 所述证据边界，不因本轮门禁全绿而消失。
