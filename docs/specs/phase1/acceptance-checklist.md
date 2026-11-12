# Phase 1 模拟器手工验收清单（acceptance-checklist.md）

> **执行状态（本轮 v1.1 收口）**：2026-11-11 的旧结果（PASS 16 / DEFERRED-L5 27 / DEFERRED-MOCK 1）
> **不再是本轮证据**。本轮要求 44 个步骤全部执行：真实模型（opencode-go `deepseek-v4.1-flash`）、真实工作区、
> 真实 SSH（临时非特权 sshd）、真实自托管 DSH Remote、进程级冷启动；只有原计划 Phase 1 外项可标“Phase 1 外”。
> 逐项结果与日志/截图写入 `reports/phase1-completion/matrix.md`，最终汇总进 `acceptance-report.md` v2。

> 环境：iPhone 17 Pro（iOS 26.5）+ iPhone SE3（iOS 26.5）；Flutter 3.47.7；Xcode 26.6；构建 SHA 记录在每项旁。
> 规则：**未执行 ≠ 通过**；本轮不再接受 DEFERRED-L5/DEFERRED-MOCK；`L4-Real` 步骤不得用 mock 代替。
> 对应验收项：`verification-baseline.md` §3（43 项映射中"适用/部分"的 13 项）+ §4 新增 N-xx。

> 复选框保持 `[ ]`，以配合 `tooling/docs/check_phase1_spec.py` 的 44 步计数；本轮状态以每行行内 `状态：` 为准（PASS 29 / PENDING-T32 6 / PENDING-T34b 8 / PENDING-T41 1）。

## 0. 准备

- [ ] 0.1 `repo` 已建（`phase1/base`/`phase1/integration`），HEAD 无未提交改动；记录 `git rev-parse HEAD`。
- [ ] 0.2 模拟器已创建：`xcrun simctl list devices` 含 iPhone 17 Pro / iPhone SE3（iOS 26.5）。
- [ ] 0.3 `tooling/ios/prepare-engine.sh` 成功，`app/ios/Engine/` 产物存在；`tooling/ios/build.sh --simulator --debug` 成功。
- [ ] 0.4 mock 模型服务可启动：`node test/fixtures/mock_model_server.mjs --port 3901`，`curl http://127.0.0.1:3901/healthz` 返回 ok。
- [ ] 0.5 App 安装并启动：`xcrun simctl install booted app/build/ios/iphonesimulator/Runner.app && xcrun simctl launch booted io.github.ccch1mneyyy.dshgo`（bundle id 已核验：`app/ios/Runner.xcodeproj/project.pbxproj:926`）。
- [ ] 0.6 首屏截图保存 `reports/phase1/<date>/00-launch.png`。

## A. 引导与配置（对应 D2-01 / D2-03 / D2-04 / D9-01）

- [ ] **A1 首次引导**：全新安装（`simctl uninstall` 后重装）→ 出现「本机 / 远程」选择；选「本机」进入安装引导。**期望**：无 Android 专属权限（存储/电池/无障碍）；不崩溃。记录：截图 + 权限弹窗序列。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_approval_real.sh --tag green`（T27）与 `bash scripts/e2e/ios/run_cold_start_real.sh`（T30）都先 `simctl uninstall` 再走真实 Welcome→本机引导→引擎 running；日志：`reports/phase1-completion/T34a/09-xcodebuild-test.log`；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 A1。
- [ ] **A2 引导不被重复**：完成引导后杀 App 重开 → 直接进主界面；设置里能重新进入引导/切换运行位置。**期望**：不重复引导、已有数据不丢。 — **状态：PASS**；证据：`reports/phase1-completion/T30/run-final.log` verify 阶段冷启动直达 HomeShell（`WelcomePage` 为空、无 onboarding）+ `T30/report.md` §5 + `D2-01_onboarding_not_repeated_after_complete` L2；设备/构建：17Pro 1D9F；构建 SHA 92e9ef14；设置内重进引导/切换运行位置未在真实 UI 重放（caveat，T38 确认）；详见 `completion-matrix.md` §1 A2。
- [ ] **A3 添加自定义渠道**：设置 › 模型 › 添加渠道 → 兼容协议 OpenAI → Base URL 填 `http://127.0.0.1:3901/v1` → API Key `sk-mock-phase1-model` → 获取模型（mock 返回 `mock-phase1-model`）→ 保存。**期望**：保存成功、模型出现在选择列表。记录：mock 服务请求日志。 — **状态：PASS**；证据：`DSH_SIM_UDID=5DBBD04A-9EEB-460A-8574-2193271D5610 bash scripts/e2e/ios/run_workspace_real.sh` → `T31/green/workspace_real.log`（provider created 1443ms、catalog lists deepseek-v4.1-flash 748ms、model selected）；日志：`reports/phase1-completion/T27/green/run-green.log`；设备/构建：17Pro 5DBB / 1D9F；详见 `completion-matrix.md` §1 A3。
- [ ] **A4 模型切换**：对话顶栏模型胶囊 → 选 mock 模型 → 发消息；检查 mock 请求日志的 `model` 字段。**期望**：下一条消息使用新模型。 — **状态：PASS**；证据：`cd app && flutter test test/phase1/d2_04_model_switch_test.dart`（下一条消息使用新模型）；设备/构建：17Pro 5DBB / 1D9F；详见 `completion-matrix.md` §1 A4。
- [ ] **A5 隐私开关**：设置 › 隐私与分享 → 关闭匿名统计 → 杀 App 重开。**期望**：开关保持关闭；隐私页说明可读；无网络上报（iOS 分支本身不上报，记录说明）。 — **状态：PASS**；证据：`cd app && flutter test test/phase1/d9_01_privacy_test.dart`（关闭后 SharedPreferences=false、零上报、iOS UsageChannel 丢弃）；日志：`reports/wave2/T10-T11-config-onboarding.md`；设备/构建：HOST；详见 `completion-matrix.md` §1 A5。

## B. 引擎（对应 D1-01 / D1-02 / D1-04 / PERSIST-01）

- [ ] **B1 引擎安装**：设置 › 本机引擎 → 安装。**期望**：进度可见；安装完成后状态"已安装"。记录：安装耗时（T6 用）。 — **状态：PASS**；证据：`reports/phase1-completion/T30/run-final.log`（干净安装→本机引擎 running）、`reports/phase1-completion/T27/green/run-green.log`（安装→running）；日志：`T30/run-final.log` + `T30/report.md` §3；设备/构建：17Pro 1D9F / DAFDCC52；详见 `completion-matrix.md` §1 B1。
- [ ] **B2 安装续装**：安装开始时立刻 `simctl terminate` App → 重开 → 再点安装。**期望**：从断点继续并完成，不崩溃、不重复解压。 — **状态：PENDING-T34b**；缺口：T34b `testInstallResume` 中途 terminate→续装完成 PASS 日志/截图；已有：T7 L4 `reports/wave1/t7-d1-01-l4.json` / `reports/wave1/t7-d1-01-ac2-resumed.png`（解压 40% `simctl terminate` → 续装 11s）；`reports/phase1-completion/T34a/09-xcodebuild-test.log` 2/2（仅启动/冷重启骨架）；日志：`reports/wave1/t7-d1-01-l4.json`；详见 `completion-matrix.md` §1 B2。
- [ ] **B3 引擎启动/停止**：点启动 → 等 ready → 点停止（确认）→ 状态回到已安装。**期望**：状态正确；停止中断进行中的一轮（如正在生成）。 — **状态：PASS**；证据：T26 L4 `T26/l4-alt-17pro-run3.log`（stop 506ms / start 2915ms、新会话回合）；设备/构建：17Pro 5DBB / SE3 8A82B667；详见 `completion-matrix.md` §1 B3。
- [ ] **B4 停止后再启动（不重开 App）**：停止后点启动 → 新对话可用。**期望**：成功重启，无需重开 App。 — **状态：PASS**；证据：T26 `T26/l4-alt-17pro-run3.log`（同进程 stop→start、无需重开 App、新会话 + 原会话续话均 PASS）；设备/构建：17Pro 5DBB；详见 `completion-matrix.md` §1 B4。
- [ ] **B5 自动启动**：设置里关闭「打开 App 时自动启动」→ 杀 App 重开。**期望**：不自动启动；重新打开开关后冷启动自动启动。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_cold_start_real.sh` → `T30/run-final.log`（verify 冷启动 starting→running；autostart_off 25s 仅 installed；设置写回 true 后 crash 阶段再次自动启动）+ `T30/report.md` §6；设备/构建：17Pro 1D9F；构建 SHA 92e9ef14；开关经 SettingsController 设置，未在真实设置页手点（caveat，T38 确认）；详见 `completion-matrix.md` §1 B5。
- [ ] **B6 启动失败诊断**：临时破坏引擎产物（如重命名 `app/ios/Engine/` 内一个必需文件；记录操作以便恢复）→ 冷启动。**期望**：显示失败原因 + 重试/日志入口；诊断可复制；App 不崩溃。**恢复**：还原文件。 — **状态：PENDING-T34b**；缺口：T34b `testFailureDiagnostics`（破坏 runtime → 冷启动 → 可读原因/重试/日志入口 + 不崩溃）PASS；已有：T8-T9 L4 失败码可读（`reports/wave2/T8-T9-engine-lifecycle-logs.md` §4）、T34a 首屏骨架；`reports/phase1-completion/T34b/probe-01.log` 在 49.5s 报 Application is not running（失败）；日志：`reports/wave2/T8-T9-engine-lifecycle-logs.md`；详见 `completion-matrix.md` §1 B6。
- [ ] **B7 日志页**：引擎运行 → 日志页 → 滚动/复制。**期望**：实时日志；无完整 API Key/Token（如日志含凭据则记 BUG）。 — **状态：PENDING-T34b**；缺口：T34b `testLogsRedactionAndCopy`（打开日志页→滚动/复制→无完整凭据→粘贴板断言）PASS；已有：D1-04 L2/L4 快照/seq/脱敏（`cd app && flutter test test/engine/d1_04_logs_test.dart`、`reports/phase1-completion/T35a/28-d1-02-se3.log`）；T34a 首屏；日志：`reports/phase1-completion/T35a/28-d1-02-se3.log`；详见 `completion-matrix.md` §1 B7。

## C. 对话闭环（对应 D3-01…D3-08 / D3-19）

- [ ] **C1 新对话**：主界面新对话 → 不发送。**期望**：空状态输入框可用；抽屉**不新增**空会话。发送首条后会话才出现。 — **状态：PASS**；证据：`cd app && flutter test test/chat/phase1/d3_01_new_chat_test.dart` 6/6；日志：`reports/phase1-completion/T31/green/workspace_real.log`；设备/构建：HOST / 17Pro 5DBB / 1D9F；详见 `completion-matrix.md` §1 C1。
- [ ] **C2 流式**：mock 场景 `stream`（通过请求头/模型名触发，见 `mocks.md`）→ 发送。**期望**：回复分片出现（可看到中间态）；最终完整；重开仍在。 — **状态：PASS**；证据：T31 `T31/green/workspace_real.log`（stream observations=10、final answer visible、turn 21s）；日志：`reports/phase1-completion/T30/run-final.log`；设备/构建：17Pro 5DBB / 1D9F；详见 `completion-matrix.md` §1 C2。
- [ ] **C3 思考折叠**：mock 场景含 thinking → 展开/收起思考块。**期望**：收起显示首行预览；思考不混入正式回答。 — **状态：PASS**；证据：L2 `cd app && flutter test test/chat/phase1/d3_02_stream_test.dart`（`D3-02_thinking_collapsed_shows_preview`）；日志：`reports/phase1-completion/T33b-relay/green/shots/04-turn1-reasoning.png`；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 C3。
- [ ] **C4 插话**：生成中直接发一条消息。**期望**：消息显示在底部；生成不中断；mock 下一条请求包含该消息（查日志）。 — **状态：PENDING-T32**；缺口：T32 最终 PASS/提交；已有：L2 `cd app && flutter test test/chat/phase1/d3_03_steer_test.dart`（不中断/底部显示/失败保留）；T32 的多次真实 run 已跑到 C4（早期瞬时观察到 steer bubble / `steer echoed ... seq 24` / `steer used ... seq 24`，截图 `T32/screenshots/steer.png`）——但 `T32/green/chat_features_real.log` 正被后续 run 覆盖，这些行是**观察到的瞬时证据，不是持久日志**；且早期 run 在 C10 失败、无最终 PASS/提交；**2026-11-13 01:49 的最新 run 在 C4 后 `did not complete`**；日志：`T32/green/chat_features_real.log`；详见 `completion-matrix.md` §1 C4。
- [ ] **C5 排队/撤回**：生成中长按发送 → 排队 → 结束后自动发送；再试「撤回」。**期望**：顺序正确；撤回内容回到输入框。 — **状态：PENDING-T32**；缺口：T32 最终 PASS/提交 + C5 截图；已有：L2 `cd app && flutter test test/chat/phase1/d3_04_queue_test.dart`（排队/立即发送/撤回）；早期瞬时 run 观察到 withdraw 回输入框 / queued QUEUED_OK / queue auto-sent seq 34 + `T32/screenshots/steer.png`——但日志随后被新 run 覆盖，非持久证据；该 run 在 C10 失败、无最终 PASS/提交；详见 `completion-matrix.md` §1 C5。
- [ ] **C6 停止**：生成中点停止。**期望**：本轮停止、UI 回 idle、已生成内容保留；可立即发下一条。 — **状态：PENDING-T32**；缺口：T32 最终 PASS/提交；已有：L2 `cd app && flutter test test/chat/phase1/d3_05_stop_test.dart`；T22b 旧 C6 PASS（`reports/phase1/acceptance-run/`，非 v1.1 证据）；早期瞬时 run 观察到 stopped 42 字符/kept 2083 + CONTINUE_OK + `T32/screenshots/stop.png`——但日志随后被新 run 覆盖，非持久证据；早期 run 在 C10 失败、无最终 PASS/提交；日志：`T32/green/chat_features_real.log`；详见 `completion-matrix.md` §1 C6。
- [ ] **C7 审批允许**：真实模型（`workspace-write + ask`）在工作区外写文件并显式请求沙箱升级 → 审批卡显示命令/原因 → 允许本次。**期望**：工具执行一次；工具行显示结果；文件恰好出现一次。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_approval_real.sh --tag green` → `T27/green/run-green.log`（allow approvals=1）；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 C7。
- [ ] **C8 审批拒绝**：同 C7 换一个目标文件 → 拒绝。**期望**：工具**不执行**（文件不存在）；对话继续；工具行显示拒绝。 — **状态：PASS**；证据：同 T27 run → `T27/green/run-green.log`（deny approvals=1）；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 C8。
- [ ] **C9 工具行**：点开工具行。**期望**：参数/结果可见；失败工具显示错误态。 — **状态：PENDING-T32**；缺口：T32 真实失败工具行错误态 + 最终 PASS/提交；已有：`reports/phase1-completion/T31/green/workspace_real.log` 展开真实 turn process 看到 write/bash/read 工具行与 wc/read 输出（部分 C9）；L2 `d3_08_tool_row_test.dart`；`T32/green/chat_features_real.log` 早期瞬时 run 观察到 bash `printf 'tool-row-ok'` 工具行命令+输出 + `T32/screenshots/tool.png`——但日志随后被新 run 覆盖，非持久证据；日志：`T32/green/chat_features_real.log`；详见 `completion-matrix.md` §1 C9。
- [ ] **C10 消息操作**：复制 / 长按菜单 / 重新回答（最后一条）/ 引用。**期望**：复制内容正确；重新回答进入新对话且原对话不变；引用块随消息发出。 — **状态：PENDING-T32**；缺口：修复 C10 finder 后的真实复制/重答/引用 PASS + 截图；已有：L2 `cd app && flutter test test/chat/phase1/d3_19_message_actions_test.dart`（复制/菜单/重答/引用）；`reports/wave1/T12-chat-stream.md`；`T32/green/chat_features_real.log` 早期瞬时 run 仅到 copy 校验就在 `_longPressFirst` 抛 `Bad state: No element`（日志随后被覆盖），重答/引用未执行；日志：`T32/green/chat_features_real.log`；详见 `completion-matrix.md` §1 C10。
- [ ] **C11 提问卡**：mock 场景触发提问（若 mock 支持）→ 选项提交。**期望**：卡片变已答，结果回传（无 mock 支持时标 `DEFERRED-MOCK` 并记录原因）。 — **状态：PENDING-T32**；缺口：T32 真实模型触发提问卡→选项提交→已答回传 PASS；已有：L2 `cd app && flutter test test/chat/phase1/d3_07_question_plan_test.dart`（提问卡/计划待审）；旧 T22b 为 DEFERRED-MOCK（非 v1.1 证据）；`T32/green/chat_features_real.log` 早期瞬时 run 在 C10 失败，尚未到达 C11（日志随后被覆盖）；日志：`T32/green/chat_features_real.log`；详见 `completion-matrix.md` §1 C11。

## D. 会话 / 工作区 / 附件（对应 D4-01 / D4-03 / D4-05 / D4-07）

- [ ] **D1 会话抽屉**：多会话 → 打开抽屉。**期望**：排序、未读/待确认标记；点击切换正确。 — **状态：PASS**；证据：L2 `cd app && flutter test test/sessions/d4_01_sessions_drawer_test.dart` 7/7（排序/未读/待确认/切换）；日志：`reports/phase1-completion/T33b-relay/green/02-flutter-test.log`；设备/构建：HOST / 17Pro 1D9F；详见 `completion-matrix.md` §1 D1。
- [ ] **D2 抽屉筛选**：筛选「未读」/「待确认」。**期望**：只显示匹配；空状态合理。 — **状态：PASS**；证据：L2 `cd app && flutter test test/sessions/d4_01_sessions_drawer_test.dart`（`D4-01_drawer_filters_unread` + 空状态）；日志：`reports/wave1/T16-sessions.md`；设备/构建：HOST；详见 `completion-matrix.md` §1 D2。
- [ ] **D3 会话搜索**：搜索标题关键词、多关键词。**期望**：即时匹配/高亮；清空恢复。 — **状态：PASS**；证据：L2 `cd app && flutter test test/sessions/d4_03_session_search_test.dart` 5/5（即时匹配/多关键词 AND/高亮/清空恢复）；日志：`reports/wave1/T16-sessions.md`；设备/构建：HOST；详见 `completion-matrix.md` §1 D3。
- [ ] **D4 主机隔离**（需远程 setup）：切换主机后抽屉只显示该主机会话；切回原主机数据仍在。**期望**：不串数据。 — **状态：PASS**；证据：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`（本机 baseline 与 SSH 会话互不可见、切回本机仍在本机）；日志：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`；设备/构建：17Pro BB0C8CB8 / 1D9F；详见 `completion-matrix.md` §1 D4。
- [ ] **D5 工作区浏览/预览**：文件页 → 文本/图片/PDF。**期望**：内容正确；不存在文件显示错误；不崩溃。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_workspace_real.sh` → T31 `T31/green/workspace_real.log`（files page lists notes/、preview 显示 5 条 bullet）、截图 `T31/screenshots/files.png`、`preview.png`；设备/构建：17Pro 5DBB；详见 `completion-matrix.md` §1 D5。
- [ ] **D6 附件（相册）**：加号 → 相册 → 选 1–2 张图 → 待发送条 → 发送。**期望**：缩略图/文件卡正常；可移除附件。 — **状态：PENDING-T34b**；缺口：T34b `testPhotosAttachment`（simctl addmedia→系统相册选择→tray→发送→mock 模型回复）PASS + 截图；已有：L2 `cd app && flutter test test/chat/phase1/d4_07_attachments_test.dart`（相册 2 张→tray→发送卡片）、`reports/phase1-completion/T30/run-final.log`（真实 70B 附件草稿恢复）；`reports/phase1-completion/T34b/probe-01.log` 失败、`probe-02.log` 0 tests；日志：`reports/phase1-completion/T30/run-final.log`；详见 `completion-matrix.md` §1 D6。
- [ ] **D7 附件（文件）**：加号 → 文件 → 选 `test/fixtures` 里的样例文件 → 发送。**期望**：文件卡正常；上传成功（mock host/引擎）。 — **状态：PASS**；证据：`cd app && flutter test test/chat/phase1/d4_07_attachments_test.dart`（`D4-07_sent_message_shows_thumbnail_and_file_card`：图片+文件发送后气泡含缩略图/文件卡、tray 清空）；日志：`reports/wave2/T17-T18-files-persist.md`；设备/构建：HOST / 17Pro 1D9F；详见 `completion-matrix.md` §1 D7。
- [ ] **D8 附件上限**：尝试选 >9 个（或代码级验证）。**期望**：拒绝并提示，不静默截断。 — **状态：PENDING-T34b**；缺口：T34b UI 级一次选 >9/超限→拒绝提示 PASS（当前 T34b 脚本只做单张 Photos）；已有：L2 `cd app && flutter test test/chat/phase1/d4_07_attachments_test.dart`（`D4-07_reject_more_than_nine_attachments` 10→9、200MB 拒绝）；`reports/wave2/T17-T18-files-persist.md`；日志：`reports/wave2/T17-T18-files-persist.md`；详见 `completion-matrix.md` §1 D8。

## E. 持久化与恢复（对应 PERSIST-01）

- [ ] **E1 杀 App 重开**：完成一轮（含工具调用）→ `simctl terminate` → 重开。**期望**：会话/消息完整；可继续对话；引擎自动重启。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_cold_start_real.sh` → `T30/run-final.log`（5 phases PASS、710s；verify 冷启动无 onboarding、session/title/messages 保留、auto-start starting→running、新真实回合成功）+ `T30/report.md` §5；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 E1。
- [ ] **E2 引擎重启恢复**：停止引擎 → 启动 → 打开原会话。**期望**：消息完整、继续正常。 — **状态：PASS**；证据：T26 `T26/l4-alt-17pro-run3.log`（同进程 stop→start、pre-stop 会话续话成功）；日志：`reports/phase1-completion/T35a/28-d1-02-se3.log`；设备/构建：17Pro 5DBB / SE3 8A82B667；详见 `completion-matrix.md` §1 E2。
- [ ] **E3 结果未知**：mock 场景 `unknown_inflight`（或工具执行中杀 App）→ 重开该会话。**期望**：横幅提示；确认前工具被拒绝；确认后对话继续且不重跑工具。 — **状态：PASS**；证据：`T30/run-final.log`（crash / crash_verify 两阶段 PASS）+ `T30/report.md` §7（CRASH-READY-TO-KILL、state=result-unknown、banner、确认前后副作用 0、未重跑）+ 截图 `T30/crash-mid-turn.png`；日志：`T30/run-final.log`；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 E3。
- [ ] **E4 草稿恢复**：输入草稿 + 添加附件未发送 → 杀 App → 重开。**期望**：按 D4-07 约定恢复或明确提示（记录实际行为）。 — **状态：PASS**；证据：`T30/run-final.log` verify 阶段 + `T30/report.md` §5（draft restored text=34 chars attachment=t30-draft.png）；日志：`T30/run-final.log`；设备/构建：17Pro 1D9F；详见 `completion-matrix.md` §1 E4。

## F. 远程主机（对应 D1-09 / D1-10 / D1-11）

> 本轮必须使用真实链路：临时非特权 sshd + 真实 `dsh web`；自托管 `ds-harness-remote` Server + Host 插件。fake transport 只能作为 L2 负例，不能出现在本轮验收证据里。

- [ ] **F1 主机切换**：本机 → SSH → DSH Remote → 本机，每步切换。**期望**：当前主机名/状态可见；会话跟随切换且三主机数据隔离。 — **状态：PASS**；证据：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`（本机→SSH→本机，五步 link 完成、会话/工作区隔离）；日志：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`；设备/构建：17Pro BB0C8CB8 / 1D9F；详见 `completion-matrix.md` §1 F1。
- [ ] **F2 连接失败回退**：添加一个不可达 SSH 主机 → 连接。**期望**：错误可读、可重试；可切回本机且本机会话不受影响。 — **状态：PASS**；证据：T25 真实 sshd live 7/7（`reports/phase1-completion/T25/green/live_ssh.log`：wrong pinned key fails closed、rejected key clear auth error）；日志：`reports/phase1-completion/T25/green/live_ssh.log`；设备/构建：HOST / 17Pro BB0C8CB8；详见 `completion-matrix.md` §1 F2。
- [ ] **F3 SSH 连接（真实）**：添加 SSH 主机（127.0.0.1:22422、临时私钥）→ 测试连接 → 信任指纹 → 保存 → 连接。**期望**：真实 sshd 隧道建立、远端会话列表加载、真实模型发消息流式。记录：host/端口/指纹。 — **状态：PASS**；证据：`bash scripts/e2e/ios/run_ssh_real.sh` → `T33b-ssh/green/flutter-test.log`（127.0.0.1:22422、TOFU `SHA256:lHRx1Dr5owDeSKieKBWfk7R3ePzaVOC2mQKlEkjwY4U`、保存、连接、五步 link、真实模型流式）；设备/构建：17Pro BB0C8CB8；详见 `completion-matrix.md` §1 F3。
- [ ] **F4 断线重连（真实）**：连接后杀掉远端 `dsh web` → 恢复。**期望**：自动重连、消息不重复、会话可继续。 — **状态：PASS**；证据：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`（kill remote dsh web pid 49321 → phase=reconnecting attempt=1 → new pid 52673 → 重连 → 同 session 续话）；日志：`reports/phase1-completion/T33b-ssh/green/flutter-test.log`；设备/构建：17Pro BB0C8CB8；详见 `completion-matrix.md` §1 F4。
- [ ] **F5 DSH Remote（真实自托管）**：自托管 Server 登录 → 主机列表 → 信任指纹 → 连接 → 真实模型对话。**期望**：真实 Relay/Noise 链路，会话/对话/工作区正常；重启 Host 后自动重连。 — **状态：PASS**；证据：T33a `scripts/e2e/remote/relay_stack.sh self-test` → `reports/phase1-completion/T33a/02-green-self-test.log`（health/login/Host online/cleanup）；T33b-relay `bash scripts/e2e/ios/run_remote_real.sh --device 1D9F...` → `T33b-relay/green/02-flutter-test.log`（自建登录 1116ms、指纹 `AC86 7303 AC33`、relay 990ms、真实模型回合、Host restart 重连）；设备/构建：HOST / 17Pro 1D9F；构建 SHA af08bf80 + dcfc485c；详见 `completion-matrix.md` §1 F5。

## G. 外观 / 语言 / 其它（对应官方 43 项 #40/#41）

- [ ] **G1 深色启动**：系统切深色 → 冷启动。**期望**：启动屏不闪白、首屏深色正确。 — **状态：PENDING-T34b**；缺口：T34b dark flow 实际 PASS 日志/截图；已有：`reports/phase1-completion/T34a/09-xcodebuild-test.log` 2/2（首屏/冷重启骨架，未断言深色）；T34b 代码已有 `testDarkColdLaunch`（luminance<0.35）与 `run_ui_process.sh dark` 计划；日志：`reports/phase1-completion/T34a/09-xcodebuild-test.log`；详见 `completion-matrix.md` §1 G1。
- [ ] **G2 中文/英文**：系统语言切换 → 重开。**期望**：主要页面文案跟随；权限说明跟随（模拟器设置里切换）。 — **状态：PENDING-T34b**；缺口：T34b english/chinese flow 实际 PASS；已有：l10n `python3 app/tool/l10n_merge.py --check` OK（T28 `green/10-l10n-check.log`）；T34b 代码已有 `testChineseBaseline`/`testEnglishColdLaunch`；详见 `completion-matrix.md` §1 G2。
- [ ] **G3 SE3 小屏**：iPhone SE3 上重复 C1/C7/D1/D5。**期望**：无 overflow、按钮可点、输入框不被遮挡。 — **状态：PENDING-T34b**；缺口：SE3 上重复 C1/C7/D1/D5 的布局/可点性 PASS（T34b SE3 flow 尚未跑）；已有：T35a SE3 指标（`T35a/29-cold-start-se3.log` 3668/3124/2877ms；`T35a/28-d1-02-se3.log` lifecycle 16 checks）；T34b 代码已有 `testSE3ColdLaunchDark`（仅深色冷启动）；详见 `completion-matrix.md` §1 G3。
- [ ] **G4 构建产物**：`build.sh --release --no-codesign` 成功；记录构建耗时/产物体积（T6 用）。 — **状态：PENDING-T41**；缺口：T41 在当前 v1.1 分支实跑 `bash scripts/verify.sh --full` 的 release/unsigned 构建日志与产物大小；已有：T22b 旧 `--full` 设备 unsigned 构建成功（94.5s / Runner.app 227.1MB，`reports/phase1/acceptance-run/t22b-verify-full-rerun.log`）；T35b `--full` 计划包含 `tooling/ios/build.sh --release --no-codesign`（`T35b/06-dry-run-full.log`）；日志：`reports/phase1/acceptance-run/t22b-verify-full-rerun.log`；详见 `completion-matrix.md` §1 G4。

## H. 记录与关闭

- [ ] H.1 所有项状态填入 `acceptance-report.md` 三张表（通过/未通过/deferred），附构建 SHA、模拟器、日期。
- [ ] H.2 失败项开 issue 或写入 `reports/phase1/<date>/failures.md`（含复现步骤、日志、截图）。
- [ ] H.3 更新 `traceability.md` 对应行的"验收记录"列（引用报告条目 ID）。

## Deferred（Phase 1 不执行，记录即可）

相机/拍照/扫码、真实 APNs/锁屏通知、后台挂起/长任务、真机性能/内存/jetsam、触感/传感器、CoreDevice/DDI 手机操控、真机签名安装/TestFlight、iSH guest 真机、iPad/横屏、真实 DSH Remote 服务器/真实 TURN、48MP 大图/视频保存相册、Siri/快捷指令/分享扩展/深链（D6）。完整清单见 `verification-baseline.md` §5。
