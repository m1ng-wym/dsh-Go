# Phase 2 Backlog（phase2-backlog.md）

- 版本：v1.0（2026-11-11，T23）
- 来源：计划 §9（Phase 2 边界）+ T22/T22b 验收记录 + 各任务报告 follow-up
- 规则：Phase 1 **不做**下列功能；优先级只是建议，进入 Phase 2 前由 Lead 重新排序并补 spec/AC
- 状态标记：`PLAN` = 尚未开工；`DEBT` = Phase 1 遗留技术债；`DONE` = Phase 1 已顺手修复，仅留档

---

## 1. 功能线（计划 §9）

| # | 功能线 | 范围 | 前置依赖/入口 | 优先级 |
|---|---|---|---|---|
| P2-1 | **手机操控** | CoreDevice/XCTest 驱动其他 App、侧载安装、权限/失败恢复；复用官方 D5 通道与 UI-CONTRACT；真机验证 | 真机 + 付费签名/侧载链路；Phase 1 的 `phone-protocol` job 已保留 `if:false` | 高 |
| P2-2 | **iSH 完整 Linux + 通知** | iSH guest 构建、`check-archive.sh` 真正执行、APNs/Live Activity、通知权限/静音/前台展示 | 官方 iSH pin（计划 §1）；Phase 1 `ios-guest.yml`/guest steps 保留未构建 | 高 |
| P2-3 | **伙伴插件** | 伙伴小屋/桌宠/Live2D、插件市场与原生插件 UI、插件 SDK 消费面 | 插件生态与 l10n/资源管线；Phase 1 未改 `sdk/plugin-kit` | 中 |
| P2-4 | **终端/网页导出** | D4-09 终端、D4-10 网页版、D4-11 导出；内置浏览器与 App 分离 | 复用官方 WebView/终端资产；Phase 1 入口已隐藏 | 中 |
| P2-5 | **媒体保存** | 图片/视频保存相册、48MP 大图、分享扩展/深链、文件 App 保存 | 真机相册权限；Phase 1 仅附件选择，不保存 | 中 |
| P2-6 | **平板适配** | iPad/横屏布局、分栏、键盘/指针 | Phase 1 iPhone only；`TARGETED_DEVICE_FAMILY=1` | 低 |
| P2-7 | **真机矩阵与性能** | 真机签名/安装、Release 性能/内存/jetsam、后台挂起/长任务、触感/传感器、SE3/多机型回归 | 无付费账号的现状先解；T6 阈值只对模拟器有效 | 高 |
| P2-8 | **上游同步常态化** | 每周/每 release `git merge upstream/main`，v1.0.15（`3edc945f`）起；冲突台账、l10n 重生成、pins 并集 | 计划 §3.1/§8；Phase 1 锁定 `aee6445` | 高 |
| P2-9 | **自动化任务** | 定时任务、后台运行、应用内更新、D9-03~07 诊断包 | 依赖后台/通知能力 | 低 |

---

## 2. Phase 1 遗留技术债

### 2.1 验收/门禁缺口

| # | 债项 | 现状 | 建议动作 | 优先级 |
|---|---|---|---|---|
| D-1 | **C7/C8 审批 L4 不可达** | 本机引擎 profile 默认 `danger-full-access`，写工具自动执行；`phase1_acceptance_test` 120s 超时，记 DEFERRED-L5 | 增加可切换的 `approval: ask` 测试 profile；补 L4 允许/拒绝各一次 + 文件系统无副作用断言；或明确以 L2 组件测试为最终证据 | 高 |
| D-2 | **D1-09-AC1 会话列表 L4** | L2 只断言“当前会话清空+主机切换+prefs”；列表行内容需 fake DSH host | 在 fake host 注入 `session/list`，断言切换后只显示该主机会话、切回数据仍在 | 中 |
| D-3 | **D2-03 profile-first 边缘** | 保存渠道时先写 profile 再写 key，极端失败可能留半成品 | 事务化/补偿删除；补故障注入测试（参考 T10-T11 报告 §7.4） | 中 |
| D-4 | **D2-04 发送时渠道被删回退** | 只覆盖“切换时引擎拒绝→回退上一模型”；切换成功后、发送前渠道被删无自动回退 | 服务端错误码/目录重读策略 + 失败回退到上一可用模型 | 中 |
| D-5 | **T6 未测项** | mock 首 token、20 次连续启动（仅 10 次）、T6 时 SE3、真机性能/内存、RSS 长稳 | Phase 2 性能专项：补可编程发 prompt 入口、20× launch、SE3、真机 | 中 |
| D-6 | **golden CI 策略** | macOS 与 Linux 字体/渲染差异；T22a 排除 27 个 golden-bearing 文件，72 个像素失败 | golden 由 Linux CI/上游承载；Phase 2 重建 iOS 基线（固定字体/设备）并恢复子集门 | 中 |
| D-7 | **v1.0.15 同步** | `upstream/main=3edc945f`（v1.0.15，7 commits）未合并 | Phase 2 首周 sync；跑 T1 冲突流程 + `--full` | 高 |
| D-8 | **R3 后 E2E stop** | 已修复 `56111af8` 并把 stop/restart 加回 T22b E2E（stop 509ms/restart 2675ms） | 保持回归；若再改 `IOSPhoneBridge` 必须重跑 `IOSPhoneHTTPTests` + E2E | DONE |
| D-9 | **D6 系统工具过滤** | `NativeToolsTests.testSystemTools` 因权限/D6 deferred 被 `-skip-testing` 排除 | Phase 2 真机补测提醒事项/通讯录/定位；不要永久隐藏 | 中 |
| D-10 | **iSH archive 门** | `check-archive.sh` 需 `DshGuest*`，Phase 1 明确 SKIP + `--allow-skip` | guest 构建后自动真正执行；保留 skip 文本以免误绿 | 中 |
| D-11 | **T7 遗留** | RED 提交树未单独复现、L2 进度断言、AC3 损坏包/磁盘满未测 | 补故障注入与 UI 进度断言 | 低 |
| D-12 | **T9 2000 环形上限** | 日志条数上限未真验 | L4/单测断言截断与 seq 连续 | 低 |
| D-13 | **T12 遗留** | D3-01 characterization、断流后 resync 恢复回归未补 | 加自动恢复回归；真引擎断流 E2E | 低 |
| D-14 | **T16 弱断言** | 部分断言容忍重复/跨日分组未验；M5/M6 时序（列表读取在途切主机）未捕获 | 补强断言与时序注入测试 | 低 |
| D-15 | **T22b C4/C5/C9/C10/C11** | 插话/排队/工具行/消息操作/提问卡未上 L4；C11 mock 不产生引擎级提问 | 扩 mock + fake host；按 acceptance-report §4 逐项转 PASS | 中 |
| D-16 | **T22b 测试脚手架** | `flutter test` 结束卸载 App，无法进程级 terminate/relaunch；截图写 App 容器被清 | 改用 `simctl` 外部驱动 + 截图到宿主机；或 XCUITest | 中 |
| D-17 | **生成物污染** | `flutter pub get/build/verify --fast` 会改 `app/analysis_options.yaml`、`packages/dsh_remote/pubspec.lock` | 提交前还原；CI 加 `git diff --exit-code` 检查（需 Lead 决定） | 低 |
| D-18 | **T23 演示录屏**（已完成） | `reports/phase1/demo-6min.mp4`（5m15s / 47.5MB，H.264；17 Pro E2E + 17 Pro acceptance + SE3 E2E 三段真实模拟器画面，ffmpeg 拼接与标题卡）；说明见 `reports/phase1/demo-6min.md` | 后续可用 `approval: ask` profile 补录 C7/C8 审批画面 | 已交付 |

### 2.2 已关闭（留档，不重复做）

| 项 | 关闭证据 |
|---|---|
| R3 stop 崩溃 | `56111af8`；RunnerTests 366/366；E2E stop/restart PASS |
| 附件空目录清理 | `34f2a6f8` + 新测试 |
| SSH 私钥泄漏 | `3ba1ccd9` + `_safeKeyFailure` 测试 |
| 流式竞态 | `fee98b1b` + 2 条回归 |
| 主机切换 `Ref after disposed` | `c7c05ecd` |
| heartbeat / dsh_remote flake | `00feb7d9` / `4cb2dbb1` |
| T22a 全量门 | `--fast` 13/0/0；`--full` 21/0/1（iSH skip 显式放行） |
| T22b 验收自动化 | 14 项自动 PASS；C7/C8 如实 deferred |

---

## 3. 建议的 Phase 2 里程碑

1. **M1 收口（1 周）**：D-6 golden 策略、D-16 测试脚手架、D-1 `approval: ask` profile、T23 录屏；把 T22b 剩余 L5 中可自动化的转 PASS。
2. **M2 真机（2 周）**：签名/侧载、真机矩阵、D-5 性能、D-9 系统工具、通知/APNs。
3. **M3 远程与同步（2 周）**：真实 sshd/DSH Remote TURN、D-2/D-4、v1.0.15 sync。
4. **M4 大功能（按需）**：手机操控、iSH、伙伴/插件、终端/网页、媒体保存、iPad。

---

## 4. 证据索引

- 计划 §9：`docs/plans/2026-11-10-phase1-b-implementation.md`
- 验收：`docs/specs/phase1/acceptance-report.md`
- 各任务 follow-up：`reports/wave1/*.md`、`reports/wave2/*.md`、`reports/T22/T22a-report.md` §8/§11、`reports/T22/T22b-report.md` §6
- 门禁/CI：`docs/specs/phase1/ci.md`、`verification-baseline.md` §8
