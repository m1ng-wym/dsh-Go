# Phase 1 Spec/测试基线（验收完成 · T22/T22b）

> 状态：**Phase 1 验收完成（2026-11-11）**。Spec 基线 T4 冻结 `spec-phase1-v1`；Wave 0–4（T1–T21）全部完成；T22 自动化门与 T22b 模拟器验收完成；T23 交付文档落盘。当前代码基线 `phase1/base=56111af8`（+T22b 未提交测试改动）。
> 验收结论：`--fast` pass=13/fail=0/skip=0；`--full` 曾 pass=21/fail=0/skip=1（iSH guest archive 显式 allow-skip）；RunnerTests 366/366；E2E 17 Pro + SE3 PASS；**无 FAIL**；27 个 L5 步骤 + 1 个 mock 受限步骤 deferred（逐项表见 acceptance-report §4 的 25 项归并）。R3 修复后的最终 `--full` 已重跑：**pass=21/fail=0/skip=1（仅 iSH guest archive，显式放行）**，详见 `acceptance-report.md` §2.1/§9。
> 依据：`docs/plans/2026-11-10-phase1-b-implementation.md` §0–§9；`research/dsh-ios-research/{01,02,03,07,10,11,12}.md`。
> 版本口径（Lead 已定）：merge 目标钉 **`aee6445`（v1.0.14）**；观察到 upstream/main=`3edc945f`（v1.0.15）仅记录，**不合并 v1.0.15**（见 §4 V），Phase 2 同步。
> 生成：spec-baseline（T4，2026-11-10）；T23 更新（2026-11-11）。

## 0. 最终验收入口

- 验收报告（环境/门禁/24 ID·69 AC/25 项/修复/deferred/证据/最终门禁回填）：`acceptance-report.md`
- Phase 2 功能线与遗留技术债：`phase2-backlog.md`
- 仓库版计划（T1–T23 勾选与事实）：`docs/plans/2026-11-10-phase1-b-implementation.md`
- 最终门禁结果：**pass=21/fail=0/skip=1（exit 0）**，日志 `reports/phase1/acceptance-run/t22b-verify-full-rerun.log`；T22b 首跑 18/3/1 已在 `acceptance-report.md` §8.4 留证

## 1. 产物清单

| # | 文件 | 性质 | 规模 | 状态 | 说明 |
|---|---|---|---|---|---|
| 1 | `design.md` | 目标/非目标/约束/ADR/风险 | 174 行 | ✅ 完成 | 展开计划 §0–§3；7 个 ADR；§3.8 Lead 决策；§4.2 实际 13 冲突表 |
| 2 | `upstream.lock` | 版本真源（YAML 子集） | 179 行 | ✅ 完成（含 `t1_result`/`observed_upstream`；4 项 TODO 在章节中） | Android/iOS SHA、T1 实际结果、工具链 pin、官方测试基线、mock 约定 |
| 3 | `capability-spec.md` | Phase 1 全部能力规格 | 471 行 | ✅ 完成 | **24 个 ID / 69 条 AC**（含跨切面 PERSIST-01），每条含用户故事/AC/错误边界/官方依据（文件:行）/iOS 实现位置/验收层级 |
| 4 | `test-plan.md` | L0–L6、TDD、mock、CI、flaky | 170 行 | ✅ 完成 | RED 证据模板、测试文件布局、命名规范、行为覆盖要求 |
| 5 | `verification-baseline.md` | 官方 CI/测试/契约门/43 项验收 + 新增项 | 155 行 | ✅ 完成（阈值 T6 冻结） | contract-gates 6 门落地；43 项映射（13 适用/30 deferred）；12 项新增验收 N-01…N-12 |
| 6 | `traceability.md` | ID↔实现↔测试↔验收 矩阵 | 113 行 | ✅ **69/69 AC DONE（0 PLANNED）** | 基线变更 B-1…B-7 + **69 个 AC 行**；含 L4 37 行、L5 19 行；规则：缺一行不得合并 |
| 7 | `acceptance-checklist.md` | 模拟器手工验收（53 个可勾选步骤：A–G 主验收 44 + 准备 6 + 收尾 3） | 92 行 | ✅ 完成 + **T22b 已逐项执行/记录 deferred** | 逐项结果见 `acceptance-report.md` §4 与 `reports/phase1/acceptance-run/acceptance-results.md` |
| 8 | `mocks.md` | mock/fixture 设计 | 140 行 | ✅ 完成（含 TODO-VERIFY） | 端口/凭据、四类场景、fake host/SSH/Remote 设计、接线与安全规则 |
| 9 | `test/fixtures/mock_model_server.mjs` | mock 模型 SSE 骨架（Node `node:http`） | 575 行 | ✅ **可运行**（自测 16/16 PASS） | `stream/thinking/tool/approval/question/error_http/error_stream/slow` 8 场景 + `/v1/responses` 形状 + `/__mock/config`；slow 默认 1000ms；`--self-test` 无需 repo/网络 |
| 10 | `scripts/verify.sh` | 验证入口（`--static/--fast/--full/--list/--dry-run/--allow-skip/--self-test`） | 308 行 | ✅ **可运行**（`--fast` 13/0/0；`--full` 21/0/1） | repo 自动定位（含 legacy 并排布局）；**所有模式 fail-on-skip**；`--self-test` 反假绿；`--dry-run` 先 guard 后打印 |
| 11 | `acceptance-report.md` | Phase 1 验收报告（中文） | 本文件（T23） | ✅ **完成** | 环境/基线、自动化门、24 ID·69 AC 覆盖、25 项验收、修复记录、deferred、证据索引、最终 `--full` 回填（21/0/1） |
| 12 | `phase2-backlog.md` | Phase 2 功能线与技术债 | 本文件（T23） | ✅ **完成** | 计划 §9 九条功能线 + 18 项 Phase 1 遗留技术债 + 里程碑建议 |

> 合计 **2,592 行 / 12 文件**（T4 冻结时；含本 README 与 `test/unit/verify_script.test.mjs`）。T23 新增 `acceptance-report.md`、`phase2-backlog.md`，当前目录 **12 份文件**（含 `README.md`、`upstream.lock`）。

## 2. 本次已执行的验证（T4 自证，非产品验收）

| # | 命令 | 结果 |
|---|---|---|
| V1 | `node test/fixtures/mock_model_server.mjs --self-test` | **16/16 PASS**（healthz/models/stream/tool/approval/error_http/error_stream/请求日志/config/slow=1000/thinking/question/slow 延迟/responses 非流式/responses 流式） |
| V2 | `bash -n scripts/verify.sh` | OK（语法） |
| V3 | `./scripts/verify.sh --list`（staging，repo 未就绪） | exit 0；打印 staging 与后续命令 |
| V4 | `./scripts/verify.sh --static`（staging） | exit 0（staging 子集：mock self-test 通过；已明确标注 partial） |
| V5 | `./scripts/verify.sh --fast`（repo 未就绪/不完整） | **exit 2**（符合预期：T1 完成前拒绝假装通过；T1 完成后需重跑） |
| V6 | 伪造 `/tmp/fake-repo`（仅 `app/pubspec.yaml`+`.github`）跑 `--list/--static --dry-run/--full --dry-run` | exit 0；命令与 SKIP 路径解析全部正确（不执行真实命令） |
| V7 | `git -C /tmp/dsh-git cat-file -e` × 5 | `aee6445`/`418868c3`/`ab2d179c`/`a9532e52`/`3a91fab` 均存在（含提交日期） |
| V8 | `app/ios/README.md` 真机验收表复算 | **43 项数据行**（45 行含表头/分隔）——采用 43，修正早期 42 口径 |
| V9 | 官方依据行核对：`README.md`、`docs/guide/zh/{01-chat,02-models,03-engine-hosts,10-settings,11-faq}.md`、`docs/architecture.md`、`docs/roadmap.md`、`docs/official-parity.md`、`docs/changelog.md` 关键行逐条打印比对 | **T4-fix 后重钉**：`03-engine-hosts`/`11-faq` 全部改为 repo HEAD 实际行号（`03:13/22-33/27-33/62-77/78-90/91-101`、`11-faq:45-52/80-88`）；`app/ios/README.md:108-156`；批量核对表见 `reports/T4-fix-report.md` §2 |
| V10 | 分支真实路径核对：`app/ios/Runner/**`、`app/lib/{runtime,remote/ssh,remote/relay,ui/{chat,shell,files,settings,onboarding,engine,engine_settings,providers,remote}}`、`packages/{dsh_client,dsh_remote}`、`runtime/ios/host/node_runner.cc`、`app/integration_test/ios_engine_check.dart` | 全部存在（用于"iOS 实现位置"列） |
| V11 | `project.pbxproj` 关键配置 | `PRODUCT_BUNDLE_IDENTIFIER=io.github.ccch1mneyyy.dshgo`（`:926`）；`IPHONEOS_DEPLOYMENT_TARGET=16.0`（Runner）/`15.0`；`TARGETED_DEVICE_FAMILY="1,2"` → 与计划 17.0/iPhone-only **不一致**（见 §4） |
| V12 | **repo 就绪复核**（2026-11-10T17:06+） | `phase1/base=ef8eba50`、merge=`52b78cd7`（parents `418868c3`+`aee6445`）、`upstream/main` ref=`aee6445`、工作树干净、app=`1.0.14+1`；fixture 测试 5/5 OK；`l10n_merge.py --check`=63 parts/6301 keys |
| V13 | **T4 移入 repo** | 8 文档 + README → `repo/docs/specs/phase1/`（9 文件）；`mock_model_server.mjs`→`repo/test/fixtures/`；`verify.sh`→`repo/scripts/`（chmod 755）；`test/unit/verify_script.test.mjs` 新增（T4-fix）；`git status` 仅新增文件 + T3 并发 pbxproj（非 T4），**无 T4 产品代码改动** |
| V14 | `cd repo && ./scripts/verify.sh --list` | **exit 0**；列出 static 7 / fast 4 / full 7 条计划命令；repo 正确识别 |
| V15 | `cd repo && PATH="$HOME/tools/flutter/bin:$PATH" ./scripts/verify.sh --static`（冻结前最终重跑，Flutter 3.47.7/Dart 3.13.5） | **exit 0；pass=7 fail=0 skip=0**。全部 PASS：flutter analyze（Lead 修复 2 个 merge 遗留错误后 No issues found）、dart analyze packages、l10n --check（63/6301）、guide sync（26 files）、plugin skill sync、mock self-test（16/16，含 slow/thinking/question/responses）、node syntax。修复明细：`phone_control_screen.dart:543` 改为 `() => _stopTask(status.task.id)`（main 把 `_stopTask` 改为带 taskId）；`companion_recall_room_test.dart` 的 `_Bridge.get` 补齐 v1.0.14 新增的 `followRedirects`/`maxResponseBytes` 参数。 |
| V16 | `cd repo && node test/fixtures/mock_model_server.mjs --self-test` | **16/16 PASS**（repo 版路径） |
| V17 | 泄漏/一致性检查 | T4-fix 后 `mock_model_server.mjs`/`scripts/verify.sh` 内 **0 处 staging 路径**；README §5 仅保留迁移历史记录；无 `PLACEHOLDER/XXX` 占位；TODO-VERIFY 计数见 `reports/T4-fix-report.md` §4；无 `<<<<<<<` 冲突标记 |
| V18 | `./scripts/verify.sh --self-test` + 反假绿实验 | **5/5 PASS**（`--list` 探测 repo、restricted PATH 下 `--static` 必失败、`--allow-skip` 才放行、`--dry-run` 先 guard 后打印、legacy 并排布局自动定位）；另 `test/unit/verify_script.test.mjs` 4/4 PASS（node --test） |

## 3. 已知缺口 / TODO-VERIFY（不编造，逐项列）

| # | 缺口 | 影响 | 解决时点/负责人 |
|---|---|---|---|
| G1 | ~~origin/main 引用漂移~~ **已记录（`upstream.lock#observed_upstream`）**：观察 `upstream/main=3edc945f`（v1.0.15，11-10 14:34 发布，delta 7 commits）；**merge 目标仍钉 aee6445**，不合并 v1.0.15；v1.0.15 同步推迟到 Phase 1 后每周 sync | 版本口径 | T1 建 repo 后仅 `git rev-parse upstream/main` 记录一次实测值，不得改合并目标 |
| G2 | 计划要求 iOS 17.0 + iPhone-only，但分支工程是 16.0(Runner)/15.0 + `"1,2"` | 编译/插件兼容；iPad 支持 | **Lead 决策**（见 §4 D2）；T3 实测后改 `project.pbxproj` |
| G3 | DSH 引擎对自定义渠道的细节：Base URL 是否带 `/v1`、模型名后缀、是否支持自定义头 | mock 场景触发方式 | T7/T11 前用真实引擎实测（`mocks.md` §7） |
| G4 | thinking 流式字段名（`reasoning_content` vs 其他）、tool_calls chunk 形状（OpenAI 标准 vs 适配层） | mock 场景 `thinking`/`tool` 的字节级正确性 | T12 前抓真实引擎请求/响应 |
| G5 | `packages/dsh_client` 远程 HTTP/WS 路径、mux 帧、token 鉴权方式 | fake DSH host 是否值得实现 | T19–T21 前读源码+真实引擎抓包；在此之前用 Dart fake transport |
| G6 | `packages/dsh_remote` 最小 carrier/transport 接口 | fake Remote transport 实现面 | T21 前 |
| G7 | 官方 Flutter 全量测试在 Phase 1 `--full` 的筛选命令（排除 goldens） | `verify.sh --full` 可用性 | T5 实测并写入脚本（当前命令标 [TODO-VERIFY]） |
| G8 | Phase 1 新增 Swift 契约测试文件/`-only-testing` 的名称（`Phase1*Tests`）与 Runner target 成员 | L3 门 | T5/T7 落地时定名并更新 `test-plan.md` §3 |
| G9 | `tooling/ios/engine-smoke` 的官方运行入口（`drive.mjs` 需 `--simulator/--smoke/--frameworks/--runtime/--work/--ws` 参数） | `verify.sh --full` 的 engine smoke 步骤 | T5 写入确切参数（当前用 `run.sh` 占位并 fallback） |
| G10 | 分支 README 的 43 项表与早期"42 项"口径 | 验收计数 | **已定口径=43**（07 复核 + 本次复算）；后续引用统一 43 |
| G11 | `app/ios/README.md` 部分内容过期（如声称 Mac XCTest 是默认路径，实际默认 CoreDevice） | 文档引用风险 | 引用时以 `research/11` §6.6 的订正表为准；Phase 1 不沿用过期表述 |
| G12 | 真实 DSH Remote 服务器/TURN、真实 sshd、真实模型账号 | L5/远程验收 | Phase 1 允许 fake；真实环境 L5 可选，结果单独记录；不得伪装 |
| G13 | iSH/guest 在 Phase 1 不构建 | `ios-guest.yml`/guest 测试禁用 | T5 删/禁触发；`verification-baseline.md` O9 |
| G14 | AGPL-3.0（仓库）+ iSH GPLv3（Phase 2 才用）合规 | 仅自用 Phase 1 可接受；对外需法务 | Phase 2/分发前评估（非 T4 阻塞） |

## 4. Lead 决策结果（2026-11-10，已定）

| # | 决策 | 已定结论 | 落地任务 | 备注 |
|---|---|---|---|---|
| D1 | HEAD fixture 修复 | **(a)** T1 修 `tooling/ios/test-guest-embedding.py`：`runtime/ios/phone` fixture 清单补 `descriptions.mjs`（与 `embed-engine.sh:75` 对齐），并加"产出含 descriptions.mjs"断言；**不采用 `ab2d179c` fallback** | T1（B-3） | 成本 <10 分钟；保留 HEAD 演进 |
| D2 | 部署目标/设备族 | **(a)** iOS 17.0 + `TARGETED_DEVICE_FAMILY=1`；T3 实测 SPM/依赖可编译性，若某插件要求更高版本则记录并只在必要时调整（**以实测为准，不猜**） | T3（B-5） | 分支当前 16.0(Runner)/15.0 + `"1,2"` |
| D3 | `app/ohos/` 处置 | **(a)** 保留但不构建；`host_core.*` 是 iOS 构建输入，**绝不删** | T1/T5（B-6） | 仅禁 `ohos-compile.yml` 触发、删 `host-core.py --hap` |
| D4 | mock 场景触发 | **默认 (b)**：mock 内置 `POST /__mock/scenario` 顺序控制；**两种方式都支持**，T12 前若 G3 验证引擎支持自定义 header/模型后缀再优先 (a) | T12（G3） | 见 `mocks.md` §2.2 |
| D5 | `--full` Flutter 范围 | **(a)** Phase 1 相关子集 + **排除 goldens**；G7/G9 的 TODO-VERIFY 由 T5 落地 | T5 | 见 `test-plan.md` §6/§9 |
| D6 | CI 建设时点 | **T5 建** `phase1-verify.yml`（T1/T2 就绪后） | T5 | — |
| D7 | mirror/fork 备份 | 按计划：**T1 已完成 GitHub fork 备份**，并将记录 refs manifest | T1 | mirror 位置以 T1 记录为准 |
| V | 版本口径（重要） | **合并目标按已批准计划钉 `aee6445`（v1.0.14）**；T1 执行时观察到 `upstream/main=3edc945f`（v1.0.15，2026-11-10T14:34 发布，delta 7 commits，主要属 Phase 2 域）；**v1.0.15 同步推迟到 Phase 1 结束后按每周 sync** | T1 / `upstream.lock#observed_upstream` | **文档不得写"已合并 3edc945f"** |

> 决策来源：Lead 2026-11-10 消息；已同步写入 `design.md`（ADR 备注 + §3.8 决策记录）与 `upstream.lock`（`observed_upstream` 段）。

## 5. 冻结与移交流程（已执行：2026-11-10；结果见 reports/T4-repo-ready.md）

> 执行记录：Lead 2026-11-10 17:06 发出 repo ready（`phase1/base=ef8eba50`，工作树干净）；T4 已按本节移入并跑 verify。**tag 与 commit 由 Lead 执行（T4 不做 git 操作）。**

### 5.1 移入命令清单（明确目标路径/chmod/目录）

```bash
# 0) 变量（按实际工作区调整）
WS="/Users/Zhuanz/Documents/Zenlix/DSH-Go-iOS"
SRC="$WS/staging/spec-phase1"
REPO="$WS/repo"

# 1) 建目录（幂等）
mkdir -p "$REPO/docs/specs/phase1" "$REPO/scripts" "$REPO/test/fixtures"

# 2) 8 份文档 → repo/docs/specs/phase1/
cp "$SRC/design.md"              "$REPO/docs/specs/phase1/design.md"
cp "$SRC/upstream.lock"          "$REPO/docs/specs/phase1/upstream.lock"
cp "$SRC/capability-spec.md"     "$REPO/docs/specs/phase1/capability-spec.md"
cp "$SRC/test-plan.md"           "$REPO/docs/specs/phase1/test-plan.md"
cp "$SRC/verification-baseline.md" "$REPO/docs/specs/phase1/verification-baseline.md"
cp "$SRC/traceability.md"        "$REPO/docs/specs/phase1/traceability.md"
cp "$SRC/acceptance-checklist.md" "$REPO/docs/specs/phase1/acceptance-checklist.md"
cp "$SRC/mocks.md"               "$REPO/docs/specs/phase1/mocks.md"

# 3) mock 骨架 → repo/test/fixtures/（保留文件名与 --self-test 能力）
cp "$SRC/test/fixtures/mock_model_server.mjs" "$REPO/test/fixtures/mock_model_server.mjs"
chmod 644 "$REPO/test/fixtures/mock_model_server.mjs"

# 4) verify.sh → repo/scripts/（需可执行）
cp "$SRC/scripts/verify.sh" "$REPO/scripts/verify.sh"
chmod +x "$REPO/scripts/verify.sh"
# 校验：bash -n "$REPO/scripts/verify.sh"

# 5) 可选：README 汇总 → repo/docs/specs/phase1/README.md（保留 staging 自证记录）
cp "$SRC/README.md" "$REPO/docs/specs/phase1/README.md"

# 6) 语法/自测（不依赖 repo 完整性）
cd "$REPO" && bash -n scripts/verify.sh
node test/fixtures/mock_model_server.mjs --self-test        # 期望 16/16 PASS

# 7) 检查未误带 staging 路径/TODO 泄漏
grep -rn "staging/spec-phase1" docs/specs/phase1 scripts test/fixtures | grep -v README.md || true
grep -rn "TODO-VERIFY" docs/specs/phase1 scripts test/fixtures | wc -l   # 基线=25（2026-11-10 T4；结构性引用 5 + 实际标注 20；见报告 §7）
```

**目录/权限要求**：`docs/specs/phase1/`（可读写，git 跟踪 .md）、`scripts/verify.sh`（+x）、`test/fixtures/mock_model_server.mjs`（644，Node 24 运行）。不需要改 `.gitignore`（新路径不在忽略列表；若 `test/` 被忽略需在 T1 确认）。

### 5.2 repo 就绪后 verify.sh 运行序列（TODO 列表，按序执行）

- [x] T4-a：`./scripts/verify.sh --list` → exit 0；static 7 / fast 4 / full 7 条命令；repo 正确识别（见 §2 V14）。
- [x] T4-b：`./scripts/verify.sh --static` → exit 0；pass=5/fail=0/skip=2（flutter/dart 缺失 → T2/T5 补齐；未放宽脚本）（见 §2 V15）。
- [x] T4-c：`--list` 与 `--static` 实际执行路径已核对（V14/V15）；`--dry-run` 机制在 staging 阶段已验证（V6）。
- [x] T4-d：`--fast` 在 T2 工具链就绪前不可执行（flutter/dart 缺失 → SKIP）；**冻结检查项以 T4-b（static）为准**，`--fast/--full` 归 T5/T6。
- [x] T4-e：输出已记录到 `DSH-Go-iOS/reports/T4-repo-ready.md`；`traceability.md` B-7 已回填 **DONE（T4）**。
- [x] T4-f：冻结前检查清单见 `reports/T4-repo-ready.md` §6（全部 PASS，无阻塞决策；tag 由 Lead 打）。
- [ ] T4-g：**待 Lead commit 后执行**：把 9 份文档头部状态行从 "repo-ready/T4-draft" 更新为 "frozen（spec-phase1-v1）"、在 `traceability.md` 记录冻结 commit，再打 tag（由 Lead 执行）。

## 6. 使用说明（给后续 Agent）

- **写测试前**：先读 `capability-spec.md` 对应 ID 的 AC 与"验收层级"，再按 `test-plan.md` §2 写 RED。
- **实现位置**：`capability-spec.md` 的"iOS 实现位置（预期）"来自分支真实结构；若需改文件，遵守计划 §6.1 写作用域（跨域找 Lead）。
- **验收**：`verification-baseline.md` 的 43 项（13 适用）+ N-01…N-12；L5 用 `acceptance-checklist.md` 勾选。
- **追溯**：每完成一个 AC 更新 `traceability.md` 行（PLANNED→RED→GREEN→ACCEPTED），**缺行不得合并**。
- **Mock**：`node test/fixtures/mock_model_server.mjs`；端口/凭据见 `mocks.md` §1（3901/`sk-mock-phase1-model`）。

## 7. 证据索引

- 计划：`DSH-Go-iOS/docs/plans/2026-11-10-phase1-b-implementation.md`（§0–§4/§7）
- 调研：`research/dsh-ios-research/{01,02,03,07,10,11,12}.md`；`research/DSH-Go-iOS-实现范围确认与复用方案.md`
- 官方基线：main `aee6445`、iOS `418868c3`、known-good `ab2d179c`（run 42546357246）
- 官方验收表：`app/ios/README.md:108-156`（43 项）；契约：`tooling/ios/phone-control/UI-CONTRACT.md`（Phase 1 仅参考）
- contract-gates：`.agents/skills/review/references/contract-gates.md` + `verification-map.md`
- CI 复用细节：`research/dsh-ios-research/12-reuse-ci-test-plan.md`
- 本目录自证记录：§2 的 V1–V11 命令均可重跑（staging 内）
