# Phase 1 CI 接线与本地门禁（ci.md）

> 状态：T5 产出（2026-11-10）。`docs/specs/phase1/**` 已于 `spec-phase1-v1` 冻结；本文件是**允许新增**的 CI 说明，`verification-baseline.md` 只追加了 §8 CI 映射（逐条列在 `reports/T5-ci.md` §7）。
> 依据：计划 §5 T5、§3.5、§7.1；`research/dsh-ios-research/12-reuse-ci-test-plan.md`；官方 `.github/workflows/{ios-compile,ios-guest,ios-ui-tour,ohos-compile,ci}.yml`；本地实测见 `reports/T5-ci.md`。

## 1. 原则

- **无密钥、无付费账号、无真机、无 App Store**：Phase 1 所有 CI job 只用 GitHub 免费额度（public repo 免费；fork `m1ng-wym/dsh-Go` 若为 public 可直接跑）。
- **不假绿**：所有门禁命令走 `scripts/verify.sh`（static/fast/ci/full 全模式 fail-on-skip；内置 `--self-test` 反假绿）。
- **不重复上游 job**：iOS 构建/引擎门继续用官方 `ios-compile.yml`（只改触发与 Phase 1 范围）；新增的 `phase1-verify.yml` 只做 Linux 可跑部分（L0 + 脚本自测）。
- **不改产品代码**：T5 只改 `.github/workflows/**`、`scripts/verify.sh`、`docs/specs/phase1/**`、`test/**`。

## 2. Workflow → 门禁映射

| Workflow | Phase 1 触发 | 关键 job / 门禁 | Phase 1 状态 | 本地等价 |
|---|---|---|---|---|
| `ios-compile.yml` | `push: phase1/**`（paths: app/packages/tooling-ios/runtime-ios/runtime-ohos/runtime-patches/workflow）+ `workflow_dispatch` | `compile` job：`build.sh --simulator --debug` + `build.sh --release --no-codesign`；`engine` job：官方 `engine-smoke/drive.mjs`（真引擎+假模型，五工具/Worker/git/rg/2MiB/取消/停止/持久会话/重启）、`app-check.mjs`、`fd/heap/image` smoke、Swift contracts、`check-archive.sh` | **必须绿**（Phase 1 发布门） | `scripts/verify.sh --full`（本机 macOS）；引擎冒烟亦可用 `bash test/fixtures/run_engine_smoke.sh` |
| `ios-compile.yml` 内 `phone-protocol` job | 同上 | 手机操控 native owner（Linux 检查） | **DEFERRED**（Phase 2 手机操控；job 已 `if: false`，文件保留） | 无 |
| `ios-compile.yml` engine job 内 iSH/guest 步骤（10 个 step） | 同上 | iSH build / guest rootfs / guest approval chain | **DEFERRED**（Phase 1 不构建 iSH；step 已 `if: false`，文件保留） | 无（`ios-guest.yml` 手动才有） |
| `ios-guest.yml` | **无自动触发**（仅 `workflow_dispatch`） | iSH + Alpine guest 全链 | **DEFERRED**（Phase 1 禁用；文件保留给 Phase 2） | 无 |
| `ohos-compile.yml` | **无自动触发**（仅 `workflow_dispatch`） | oh-flutter / HAP 编译 | **DEFERRED**（Phase 1 不构建 OHOS；`app/ohos/**` 保留为 iOS 构建输入，见 design ADR-2/D3） | 无 |
| `ios-ui-tour.yml` | `push: phase1/**`（paths: app/lib/ui/** 等）+ dispatch | 9 站截图/录屏（**无断言**，仅证据） | **可选证据**（失败不阻塞冻结；matches 官方职责） | `bash tooling/ios/ui-tour.mjs`（需手动） |
| `ci.yml` | 上游规则（`main` push / PR to main） | Android/Gradle/Flutter/dart/runtime 检查 | **不用于 Phase 1**（Android 与 Phase 1 无关；不新增触发，避免白跑） | `scripts/verify.sh --fast/--ci` 覆盖其中 Dart/Node 子集 |
| **新增** `phase1-verify.yml` | `push: phase1/**` + PR to `phase1/**` + dispatch | Job `static`：`setup-node 24.22.1` + `setup-python 3.12` + Flutter 3.47.7（pinned SHA）→ `flutter pub get --enforce-lockfile` → **`./scripts/verify.sh --static`** + `node --test test/unit/*.test.mjs` | **必须绿**（L0 快速门；Linux，无 Xcode） | `./scripts/verify.sh --static` + `node --test test/unit/*.test.mjs` |
| `pr-gate.yml` | 上游规则 | 外部 PR 自动关闭 | 不变（仓库政策） | — |

**为什么新增 `phase1-verify.yml`**：ios-compile 是 90–120 分钟 macOS 重门；Phase 1 需要一个 **Linux 上 2–3 分钟**的 L0 快速门，保证每个 `phase1/**` 提交先过 static（否则 spec/脚本/工具链小改动要等一小时才知道红）。它**不复制**任何 iOS/Xcode job（避免与 ios-compile 重复）。

## 3. 触发范围（改了什么）

| 文件 | 改动（最小 diff） | 理由 |
|---|---|---|
| `ios-compile.yml` | `branches: ['feat/ios-**','ios/**']` → `['phase1/**']`；`phone-protocol` job 加 `if: false`；engine job 的 10 个 iSH/guest/phone-runner step 加 `if: false`（各 1 行注释） | Phase 1 分支触发；手机操控/iSH 属 Phase 2（保留文件供后续启用） |
| `ios-ui-tour.yml` | `feat/ios-foundation` → `phase1/**` | Phase 1 UI 证据 |
| `ios-guest.yml` | 删除 push 触发（保留 `workflow_dispatch`）+ 标题/注释标 DEFERRED | iSH 不构建（Phase 2） |
| `ohos-compile.yml` | 删除 push 触发（保留 `workflow_dispatch`）+ 标题/注释标 DEFERRED | OHOS 不构建（D3=(a)；源码保留） |
| `ci.yml` | 未改 | 上游 Android 流程与 Phase 1 无关，不改行为 |
| `phase1-verify.yml` | **新增**（static job） | Linux L0 快速门（见 §2） |

> **行尾保持**：`ios-compile.yml` 原始为 CRLF。修改后已恢复 CRLF（`\r\n` 计数 = 行数），`git diff --stat` 与 `git diff -w --stat` 一致（无空白重排）；其余 3 个 workflow 原本 LF，保持 LF。

## 4. 本地等价命令（实测，macOS 26.5.2 / Xcode 26.6 / Flutter 3.47.7 / Node 24.22.1 / Python 3.12）

| 门禁 | 命令 | 2026-11-10 实测 |
|---|---|---|
| L0 static | `PATH="$HOME/tools/flutter/bin:$PATH" ./scripts/verify.sh --static` | **exit 0；pass=7 fail=0 skip=0**（Lead 修复 2 个 merge 遗留 analyze 错误后；见 `reports/T4-fix-report.md` §5） |
| L0 快速门（CI） | `./scripts/verify.sh --static` + `node --test test/unit/*.test.mjs` | `--static` 同上；Node 4/4 PASS（含 verify.sh 自检） |
| L0+L1/L2+tooling（完整 Linux 可跑） | `./scripts/verify.sh --ci` | **exit 1；pass=11 fail=1 skip=1**（CJK 字体 + `00feb7d9` HEAD 下）。fail=`dart test packages`（`packages/dsh_remote` 2 个 timeout 用例，本机 macOS 已知红，见报告 §9；heartbeat 已修复、无关）；skip=`flutter test (phase1/unit/widget)`（T7 前无目录）。**未放宽脚本** |
| 官方 fixture | `python3 -B tooling/ios/test-guest-embedding.py -v` | **5/5 OK**（`ef8eba50` 修复后；guest-embedding fixture） |
| 官方 loader | `python3 -B tooling/ios/test-native-loader.py -v` | **4/4 OK** |
| host-core 生成 | `python3 -B runtime/tests/ohos/host-core.py --ios --out /tmp/host-core-ios` 与 `--out /tmp/host-core-hap` | 两者 **exit 0**（iOS 共享基础层生成） |
| 引擎冒烟（L4 核心） | `bash test/fixtures/run_engine_smoke.sh` | **PASS**：状态 `PASS`、重启 passed（ready 3,788ms / restart 2,742ms）、approvals=8、phoneTools=13、browserTools=11、systemTools=8；真引擎 + 假模型（`tooling/ios/engine-smoke/drive.mjs`）；见 `reports/T5-ci.md` §4 |
| iOS app 构建（Phase 1 不构建 iSH） | `cd app && DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --simulator --debug`；`DSH_IOS_GUEST_BUILD=0 bash ../tooling/ios/build.sh --release --no-codesign` | **G7 PASS**：SIM_EXIT=0、224s、`build/ios/iphonesimulator/Runner.app` 508M；**G8 PASS**：DEV_EXIT=0、`build/ios/iphoneos/Runner.app`（见 `reports/tasks/T5-xcode-builds.log`）。`ios-compile.yml` 已加 workflow 级 `DSH_IOS_GUEST_BUILD=0`（Phase 1）；`verify.sh --full` 三条构建/archive 命令同样带该 env |
| Swift contracts | `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -derivedDataPath …` | 由 ios-compile CI 执行；本机 `--full` 可跑（RunnerTests；Phase1*Tests 由 T7 新增） |
| archive 形状 | `bash tooling/ios/check-archive.sh` | 由 ios-compile CI 执行（T3 已跑过 `--release --no-codesign`）；本机 `--full` 可跑 |
| Dart 包测试（L2） | `for p in packages/*/pubspec.yaml; do (cd … && dart test); done` | **已修复**：`dsh_go_heartbeat_test.dart` 的 `StreamSink is closed` 是上游测试 teardown 时序缺陷（Lead 独立 subagent 三版本实测确认，产品代码无问题），已在 `00feb7d9` 用一行 `await h.drainProbeIfSent();` 修复（未改断言/产品代码）；`dart test test/dsh_go_heartbeat_test.dart` → 8/8 passed |
| Flutter 官方子集（L2） | `flutter test app/test/{chat,session,files,remote,engine,runtime}`（排除 `*_golden_test.dart`，D5） | 本机已装 CJK 字体：`DSH-Go-iOS/.fonts/NotoSansCJK-{Light,Regular,Bold}.ttc`（Lead 决策，55M，repo 外不提交）+ `DSH_TEST_FONT_DIR="$PWD/../.fonts"`；字体 SKIP 清零。若未设置字体目录则 `verify.sh` 明确 SKIP（不假绿） |

**`verify.sh` 模式**（详见 `test-plan.md` 与 `scripts/verify.sh --help`）：
- `--static`：L0（flutter/dart analyze、l10n/guide/skill 同步、mock 自测、Node 语法、verify.sh 自检）。
- `--ci`：`--static` + `--fast`（phase1/unit/widget Flutter 测试、dart 包测试、node --test）+ 官方 tooling 门（guest-embedding/native-loader/host-core）；**不含**官方 Flutter 遗留大子集（T5 移入 `--full`：本机 ~1000+ 用例/并行 20+ tester，超过时间盒；上游 `ci.yml` 仍跑全量、`ios-compile` 跑 iOS 门）。
- `--fast`：`--static` + 测试子集（不含 tooling 门）。
- `--full`：`--ci` + **官方 Flutter 遗留子集（排除 goldens）** + xcodebuild（simulator/device）、RunnerTests、integration_test phase1（iPhone 17 Pro/SE3）、engine smoke、archive 检查。
- 所有模式 **fail-on-skip**（除非 `--allow-skip=REASON`）；`--list/--dry-run/--self-test` 见 README。

## 5. 已知限制与后续（T5 记录）

1. **heartbeat 已修复**：`dsh_go_heartbeat_test.dart` 的上游 teardown 时序缺陷由 Lead 在 `00feb7d9` 修复（一行 drainProbe；未改断言/产品代码），验证 8/8 passed。
1b. **本机已知红（非 T5）**：`packages/dsh_remote` 的 `transfer_open_cleanup_test.dart` / `settings_response_replay_test.dart` 在本机 macOS 稳定超时（5s/30s；单跑 2 文件仍红，见 `reports/tasks/T5-dart-remote-known-red.log`）；上游 ubuntu CI 未复现，Lead/T6 排查。
2. ~~Flutter 官方子集本地 SKIP（缺字体）~~ **已解决**：Lead 决策把 `NotoSansCJK-{Light,Regular,Bold}.ttc` 装到 `DSH-Go-iOS/.fonts/`（repo 外），本地用 `DSH_TEST_FONT_DIR="$PWD/../.fonts"`；未设置时仍明确 SKIP（不假绿）。Official subset 按 D5 排除 `*_golden_test.dart`。
3. **engine smoke 前置**：需要 `app/ios/Engine/.ready` + `runtime.zip` + Node 24.22.1 缓存 + 模拟器；wrapper 在缺失时 exit 4 → `verify.sh --full` 记 SKIP（附原因），不会假失败/假绿。
4. **iOS 重门只在 macOS runner**：`ios-compile.yml` 90–120 分钟；Phase 1 开发循环用 `--static`/本地 `run_engine_smoke.sh`，合并前跑 `--full`。
5. **免费 CI 触发**：workflow 无 secrets；是否启用 fork 的 Actions（`m1ng-wym/dsh-Go` 需为 public 且 Actions 开启）由 Lead 决定，本任务不 push/不触发。

## 6. 文件清单（T5 改动，未 commit）

- 改：`.github/workflows/{ios-compile,ios-guest,ohos-compile,ios-ui-tour}.yml`（触发/禁用 + 注释；ios-compile 保持 CRLF）
- 新增：`.github/workflows/phase1-verify.yml`、`test/fixtures/run_engine_smoke.sh`（+x）、`docs/specs/phase1/ci.md`（本文件）
- 改：`scripts/verify.sh`（`--ci` 模式、tooling 门、engine-smoke 接线、字体/目录 SKIP 语义）
- 改（允许的增补）：`docs/specs/phase1/verification-baseline.md` §8 CI 映射（逐条列在报告）

*T5 · 2026-11-10。*


## 7. T22a 自动化门接线（2026-11-11）

> 依据：计划 §7.1（自动化门全绿、无 skip）、`verification-baseline.md` §8、T22a 实测（`reports/T22/T22a-report.md`）。本节只记录门禁接线，不改变 Phase 1 能力范围。

### 7.1 `--fast`：真实存在的 Phase 1 测试目录

T7–T21 的 L1/L2 用例集中在能力子目录，不是 `test/unit`/`test/widget`：

```bash
flutter test test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1
```

`scripts/verify.sh --fast` 逐目录运行它们（仍保留字体前置检查与 exit 4 → SKIP 语义），fail-on-skip / PASS=0 失败不变。

### 7.2 L4：`integration_test/phase1_test.dart` + canonical mock

- 新增 `app/integration_test/phase1_test.dart`：真实 App + 真实 NodeMobile 引擎 + mock 模型，覆盖首屏/引导、install（含已安装幂等）、start 到 running、自定义渠道 + 模型选择、新对话发送、流式器与结束态；不 skip，失败带 `[phase1-e2e]` 原因与可见文本转储。
- 新增 `app/integration_test/run_phase1_e2e.sh`：解析设备名→UDID、启动/复用 `test/fixtures/mock_model_server.mjs`（127.0.0.1:3901）、`simctl uninstall` 保证首次启动、`DSH_IOS_GUEST_BUILD=0`、运行测试并在失败时输出 mock 日志。
- 该测试使用 mock 的 **模型名后缀**（`mock-phase1-model:slow`）触发慢速流，因为 DSH 引擎会自动发起 session title 生成请求，一次性 `POST /__mock/scenario` 会被 title 请求消费（T22a 实测证据）。
- 引擎 stop→installed 的 L4 仍由 `tooling/ios/engine-smoke`（T8/T22）覆盖；`phase1_test` 不调用 stop，以规避已记录的 iOS phone-bridge NSURLSession 竞态崩溃（见 T22a 报告"风险"）。

### 7.3 L3：RunnerTests

- 命令：`xcodebuild test … -only-testing:RunnerTests -skip-testing:RunnerTests/NativeToolsTests/testSystemTools`。
- 2026-11-11 实测：过滤前 363 个用例中 **362 pass + 1 fail**，唯一失败 `NativeToolsTests.testSystemTools`（60.4s 超时，`reports/T22/t22a-runnertests.log`）依赖系统提醒事项/通讯录/定位权限与系统工具，属 Phase 1 **D6 deferred**（`verification-baseline.md` §3 #33/#35/#37、§5），因此最小过滤只排除该用例；其余官方 suite 全部保留执行。过滤后 `--full` 实测 **363 passed / 0 failed / TEST SUCCEEDED**（`reports/T22/t22a-verify-full-1222.log`）。
- destination 使用解析后的 UDID（本机存在两个同名 iPhone 17 Pro，按名字会歧义）。

### 7.4 官方 Flutter 子集与 archive 检查（T22a 实测调整）

- `--full` 的官方 Flutter 子集（`test/{chat,session,files,remote,engine,runtime}`）在 macOS 上**排除所有引用 `matchesGoldenFile` 的文件**：golden 按 Linux 字体渲染生成，本机像素基线不一致（T5 已记录；`session_detail_test`/`chat_features_test` 等 72 项失败均为 `Pixel test failed`）。部分文件混有行为测试与 golden，且 golden 名称不总含 "golden"，所以按文件排除：实测 72 个失败分布在 14 个文件；子集共 262 个测试文件，排除 13 个 `*_golden_test.dart` 与 14 个混有 golden 的文件（共 **27 个**，保留 **235 个**，其余约 2272 个用例 PASS/~12 个 live 环境 SKIP）；Phase 1 行为覆盖仍由 `--fast` 的 phase1 目录与保留的官方文件保证。
- `test/chat/stop_reconnect_test.dart` 在数百个测试并行时有时序 flake（全量下 P12 B1/B2 偶发失败，隔离运行 3/3、本次 16/16 PASS），因此从大子集移出并在**独立进程**中单独运行，不丢覆盖。
- `archive shape check` 依赖 `DshGuest.framework`/`DshGuestBridge.framework` 及其 source/license notices，只有 iSH guest 构建才产生；Phase 1 deferred（计划 §1、`verification-baseline.md` §5）。因此该步在 guest 产物缺失时输出明确 `SKIP`（exit 4），`--full` 需以 `--allow-skip="Phase 1 iSH guest deferred: check-archive needs DshGuest"` 运行，并把该 deferral 写入报告；不做假绿。本机还需要 `RUNNER_TEMP`（CI 自带），verify.sh 已在调用前补临时目录。
- `scripts/verify.sh --full` 的构建/engine smoke 步骤保持不变（带 `DSH_IOS_GUEST_BUILD=0`）。
- `VERIFY_STEP_LOG_DIR=<dir>` 可选：`run_step_skip4` 会把每步完整输出写入 `<dir>/<step>.log`，供 T22 记录。

本机（macOS）完整命令：

```bash
cd repo
DSH_TEST_FONT_DIR="$PWD/../.fonts" \
VERIFY_STEP_LOG_DIR="$PWD/../reports/T22/steps" \
  ./scripts/verify.sh --full --allow-skip="Phase 1 iSH guest deferred: check-archive needs DshGuest"
```

`--full` 的 PASS 条件因此是：除 archive 的 guest deferral 外全部步骤 PASS；任何其它 SKIP 仍会让命令 exit 1。

## 8. T36：Linux fast lane、生成物 drift 与 skip 审计（2026-11-12）

> 依据：计划 §4 W6 T36、`verification-baseline.md` §1.1、`test-plan.md` §1.1 第 5 条、T36 brief。基线 `fc671d2a`；证据在 `reports/phase1-completion/T36/`，skip 审计在 `reports/phase1-completion/skip-audit.md`。本节只记录 CI 门与审计结果，不改 `scripts/verify.sh`（T35b 所有），不改其它 `docs/specs/**`。

### 8.1 Linux Phase 1 fast lane（`phase1-verify.yml` 新 job）

`phase1-verify.yml` 保留 `static` job（L0 + Node tests），新增并行 job `linux-fast-lane`：

- runner：`ubuntu-24.04`，`timeout-minutes: 30`；无 secrets、无签名、无真机、无 macOS runner。
- Flutter：`3.47.7` 固定版本 + 固定 Linux archive SHA256（与 `static` 相同）。
- 字体：`apt-get install fonts-noto-cjk fonts-noto-cjk-extra`，`DSH_TEST_FONT_DIR=/usr/share/fonts/opentype/noto`。`fonts-noto-cjk` 只有 Regular/Bold；widget 测试加载的 Light 在 `fonts-noto-cjk-extra`（`app/test/support/test_fonts.dart` 会因缺字体直接失败，不会静默降级）。安装后显式 `test -f` 三个 face 并 `fc-list :lang=zh`。
- Flutter 测试命令（与 T35 的 `--fast` 子集一致；不跑 goldens，goldens 归 T35a）：

  ```bash
  cd app
  flutter test --no-pub test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1
  ```

  本机（macOS，CJK 字体目录）2026-11-12 实测：`+88`、`All tests passed!`、22s（`T36/05-flutter-fast-lane-local.log`）。
- Dart 包测试（timebox 15 min，两个包都跑；失败不会静默）：

  ```bash
  for p in packages/dsh_client packages/dsh_remote; do (cd "$p" && dart test); done
  ```

  本机实测：`dsh_client +836 ~31`、`dsh_remote +499 ~4`，两者 exit 0（`T36/06-dart-tests-local.log`）；`~31/~4` 是包内 live/external skip，见 skip 审计 appendix A，T35/T38 决定是否接入 `--real/--remote` 或显式排除。CI 上若超过 step timeout 会红，不会跳过。
- 触发 paths 增加 `scripts/check-generated-drift.sh`（push 与 PR）。

### 8.2 生成物 drift 守卫（最终口径）

新增 `scripts/check-generated-drift.sh`（可执行）。CI 在依赖解析之后运行：

```bash
./scripts/check-generated-drift.sh
```

脚本只把**确定性生成输出**作为硬门：

```bash
python3 app/tool/l10n_merge.py          # parts 合并 + flutter gen-l10n
git diff --exit-code -- app/lib/l10n    # 任何变化的 tracked 生成物 = FAIL
```

**不**把环境相关文件放进硬门（它们是宿主/镜像的解析产物，不是跨平台 oracle；提交它们会让 CI 每次红）：

- `app/analysis_options.yaml`（Flutter 3.47.7 的 project migrator 会补 `ios/**`）
- `app/pubspec.lock` / `packages/*/pubspec.lock`（pub.dev vs mirror、analyzer 版本随宿主变化）

需要额外观察时用 `DRIFT_WITH_PUB_GET=1 ./scripts/check-generated-drift.sh`：脚本会跑 `flutter pub get`/`dart pub get`，把上述文件的变化打印为 **WARN**，永不作为失败。

本任务用实际 drift 做了 RED，再修复后 GREEN：

- RED（临时把 `engine_zh.arb` / `engine_en.arb` 各加一个未生成的 key）：`l10n_merge` 成功，但 `app/lib/l10n/{app_*.arb,gen/*}` 出现 diff → `exit 1`，日志 `T36/08-revised-drift-red.log`。
- GREEN（还原 ARB 输入，干净树重跑）：`exit 0`，`T36/08-revised-drift-clean.log`。
- 另做一次"手改生成物"实验：直接追加 `gen/app_localizations.dart` 后重跑，生成器把它恢复为 HEAD，`exit 0`——符合预期（drift 指"重新生成后与 HEAD 不同"，不是"手改过"）。
- 早期 `01-drift-red-dirty.log` / `02-drift-green-clean*.log` 是旧口径（把 pub get 产物当硬门）的留档；**不作为最终证据**。

CI 里该 step 失败会直接红，并带 `::error title=Generated-file drift::`；修复方式是重跑生成器并提交生成物，禁止手改。环境相关文件不得提交，提交前 `git status` 必须干净。

### 8.3 Skip 审计

完整分类、代码位置、golden 清单与闭合任务见 `reports/phase1-completion/skip-audit.md`。摘要：

- app Phase 1 相关目录共 **9 个 `skip:` 点**：7 个 `live_ssh_test.dart` 测试 + 5 个 `workspace_live_test.dart` 测试（12 个环境门控，class A，T33 开启/T25 提供 sshd/live harness），2 个 `Platform.isWindows` 条件测试（class B，Linux/macOS 上实际执行）。
- golden 排除：`verify.sh --full` 实际排除 **27** 个文件（13 个 `*_golden_test.dart` + 14 个含 `matchesGoldenFile` 的混合文件），**inventory 的 26 少算了** `test/remote/remote_golden_test.dart`（它用 `goldenBoth` 辅助函数，不出现字面量 `matchesGoldenFile`）。全部 class A，由 **T35a** 用平台 comparator + 基线真跑。
- `RunnerTests/NativeToolsTests/testSystemTools` 的 `-skip-testing`（class A，**T35** 补权限或 verifier 批准的显式范围）；iSH archive 的 `--allow-skip`（class B，iSH 属 Phase 2，默认 `--full` 不再包含，只保留 opt-in `--guest`，**T35**）。
- 目标：默认 `scripts/verify.sh --full` **skip=0 且不需要 `--allow-skip`**；`--real`/`--remote` 缺前置条件必须 FAIL。任何新 skip 必须进 `skip-audit.md` 并由 T38 复核。
- 额外发现：`dart test` 的包级 live 测试还有 35 个 skipped case（`dsh_client` 31、`dsh_remote` 4），不在 inventory 范围内；已在审计 appendix A 标记为 class B，T35/T38 必须显式决定，不能以 `~N` 静默通过。

### 8.4 iOS compile（`ios-compile.yml`）dispatch 计划

现状（`T36/07-ios-compile-dispatch-readiness.log`）：

- `ios-compile.yml` 只有 `workflow_dispatch:`，无 push/PR 触发；`compile` / `engine` job 保留，`phone-protocol` 与 iSH/guest/phone-runner steps 为 `if: false`（Phase 2）。
- 本 worktree 分支 `phase1/c-ci` **未 push**；`origin` 只有 `phase1/base`，没有 `phase1/completion`；因此**本任务未执行 dispatch**，也没有修改签名/真机部分。
- 最近 `ios-compile` run 都在 `feat/ios-foundation`（最近成功 `42546357246`）；`phase1/completion` 尚无 run。

T41 在 `phase1/completion` 已 push 后执行（不要用当前未 push 的分支）：

```bash
# 前置检查
gh auth status
git ls-remote --exit-code --heads origin phase1/completion
gh workflow view ios-compile.yml

# 触发（唯一允许的方式；不带任何 secrets）
gh workflow run ios-compile.yml --ref phase1/completion

# 跟踪
gh run list --workflow ios-compile.yml --branch phase1/completion --limit 1
gh run watch <run-id> --exit-status
```

期望前置条件：

- GitHub Actions 已启用，workflow 在默认分支可被 `workflow_dispatch` 发现；`phase1/completion` 已 push 到 `origin`（fork `m1ng-wym/dsh-Go`）。
- runner `macos-26` 提供 `Xcode 26.6`（`DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`）；Flutter 固定 `3.47.7` + macOS arm64 archive SHA256 `dd9da574c3168460550117eb0e8dd0313ae934fabf64a82a6d557fff5fd1422e`。
- `engine` job 的 `tooling/ios/prepare-engine.sh` 可在 runner 上联网下载：Node 24.22.1（nodejs.org）、NodeMobile 24.22.1-0（GitHub release）、require-builtin addon（codeload）、runtime composition；需要 `python3 >= 3.11`、`curl`，并把 `runtime.zip`/`.ready` 生成到 `app/ios/Engine/`。
- 无 secrets、无签名、无真机；`DSH_IOS_GUEST_BUILD=0`；iSH 步骤保持 `if: false`。
- job 超时：`compile` 90 min、`engine` 120 min；concurrency `ios-compile-${{ github.ref }}` 会取消同 ref 的旧 run。

T41 只看 `compile` 与 `engine`；`phone-protocol` 应显示 skipped（`if: false`，不是失败）。若 runner 镜像/Xcode/Flutter pin/engine 下载任一不满足，记录为基础设施阻塞，不改 workflow 的签名或真机步骤。

### 8.5 T36 验证命令与证据

```bash
# YAML：PyYAML 可用时
python3 - <<'PY'
import yaml
wf = yaml.safe_load(open('.github/workflows/phase1-verify.yml'))
assert {'static', 'linux-fast-lane'} <= set(wf['jobs'])
print('YAML OK:', sorted(wf['jobs']))
PY
file .github/workflows/phase1-verify.yml scripts/check-generated-drift.sh

# drift：干净树必须 exit 0；临时 dirty fixture 必须 exit 1
./scripts/check-generated-drift.sh

# 本机 fast-lane 命令（macOS 把 DSH_TEST_FONT_DIR 指向仓库外装有
# NotoSansCJK-{Light,Regular,Bold}.ttc 的目录；Linux CI 用 /usr/share/fonts/opentype/noto）
(cd app && DSH_TEST_FONT_DIR="${DSH_TEST_FONT_DIR:?set to the Noto CJK directory}" \
  flutter test --no-pub test/phase1 test/chat/phase1 test/engine/phase1 test/files/phase1)
```

证据：`T36/00-red-expectations.log`（扩展前红）、`T36/01-drift-red-dirty.log`（drift 红）、`T36/02-drift-green-clean.log`（干净树绿）、`T36/02b-drift-dirty-fixture.log` / `02c-drift-clean-fixture.log`（temp fixture 红/绿）、`T36/04-yaml-lint.log`、`T36/05-flutter-fast-lane-local.log`、`T36/06-dart-tests-local.log`、`T36/07-ios-compile-dispatch-readiness.log`。

### 8.6 T36 改动文件

- 改：`.github/workflows/phase1-verify.yml`（drift step + `linux-fast-lane` job + 触发 path；static/Node 保留）
- 新增：`scripts/check-generated-drift.sh`（`+x`）
- 改：`docs/specs/phase1/ci.md`（本节）
- **不提交**环境相关文件：`app/analysis_options.yaml`、`app/pubspec.lock`、`packages/*/pubspec.lock`（Lead 复核后修正；提交它们会让 drift 门在干净树上红）
- 未改：`scripts/verify.sh`（T35b）、其它 workflow、`docs/specs/**` 其它文件、签名/真机部分

*T36 · 2026-11-12。*
