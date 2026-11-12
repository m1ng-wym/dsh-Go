# Phase 1 v1.1 验收报告（acceptance-report v2）

> 生成：2026-11-13 · 分支 `phase1/completion` · 基线 `phase1/base`
> 结论：**本报告如实区分 PASS / FAIL / 未执行**。T32 已闭合；T34b 七条流程 PASS、**D6/D8（Photos 附件）因真实产品缺陷 FAIL**，
> 因此 **不宣称 Phase 1 v1.1 全部 DoD 达成，也不创建 `phase1-v1.1` tag**。
> 全部 PASS 行都给出可重跑命令与证据路径；未执行项不写成 PASS。

## 1. 通过项（PASS）

| # | DoD / 能力 | 证据（命令/日志） | 设备/层 |
|---|---|---|---|
| 1 | 可复现构建 + Linux CI 快车道 + l10n drift | `.github/workflows/phase1-verify.yml`；`scripts/check-generated-drift.sh`；T36 报告 | Linux / L0 |
| 2 | Spec v1.1：70 AC / 44 步 / matrix / traceability | `tooling/docs/check_phase1_spec.py` → OK；T37 矩阵 | L0 |
| 3 | 真实模型（opencode-go `deepseek-v4.1-flash` + `x-opencode-session`）直连 | T25 smoke；T27/T30/T31/T33b L4 日志 | L4-Real |
| 4 | 真实工作区任务（write/bash/read、文件页预览、工作区隔离） | `T31/green/workspace_real.log`；`T31/screenshots/` | 17 Pro（同型号 sim） |
| 5 | 真实审批允许 + 拒绝（真实卡、物理点击、文件副作用） | `T27/green/run-green.log` + `run-green.env.json`（result=pass） | 17 Pro 1D9F |
| 6 | 默认权限干净（workspace-write + ask，autoApprove=false） | `T27` L2 `d2_01`；真实引擎确认 | L2 + L4 |
| 7 | 进程级冷启动：会话/消息/草稿/附件/工作区 + 自动启动 + 真实 mid-turn crash 恢复 | `T30/run-strong-final.log`、`run.env.json`、5 phase logs、pid proofs | 17 Pro 1D9F |
| 8 | 真实 SSH 主机（临时 sshd、指纹信任、远端引擎、远端文件、重启重连） | `T33b-ssh/green/flutter-test.log`；`T33b-ssh/report.md` | 17 Pro（同型号 sim） |
| 9 | 真实自托管 DSH Remote（Relay/Host、连接、重连、隔离） | `T33b-relay/green/02-flutter-test.log`；`report.md` | 17 Pro 1D9F |
| 10 | 27 个 golden 文件 macOS 基线真跑 | T35a `--update-goldens` 与无更新复跑 337/337 | macOS |
| 11 | RunnerTests 无静默过滤、零 skip | T35a 367/367 PASS（串行 + 权限/定位授予） | 17 Pro 1D9F |
| 12 | T6 指标（冷启动/引擎启动/RSS/SE3 生命周期；20× 复测） | `T35a/report.md` §5/§8；`T35a/metrics/` | 17 Pro + SE3 |
| 13 | `verify.sh` 默认 `--full` 无 skip；`--real/--remote/--guest` 模式；自测 17 项 | T35b `scripts/verify.sh`；`--self-test` PASS | L0/L3 |
| 14 | 真实演示录屏（短任务/工作区/审批/SSH/DSH Remote，真实模型，无慢放） | `reports/phase1-completion/video/out/demo-phase1-v1.1.mp4` + `.md` + SHA | 17 Pro |
| 15 | T32 真实对话控制 C4/C5/C6/C9/C10/C11 | commit `b6bdddcf`；`T32/green/chat_features_real.log`（`ALL FEATURES PASSED in 222s`，22 次请求） + 5 张截图 | T32 clone（同型号 17 Pro） |
| 16 | T34b 进程级 UI：冷启动/自动启动/续装/失败诊断/日志/深色/英文/SE3 | commit `1b1bdcaf`；`T34b/{green,red,screenshots}` + `report.md` | T34b clone + SE3 |

## 2. 未通过 / 未执行（FAIL / NOT-RUN）

| # | 项 | 现状 | 证据 / 缺口 |
|---|---|---|---|
| F1 | T32 对话控制 | **已关闭（PASS）** | commit `b6bdddcf`；`T32/green/chat_features_real.log` `ALL FEATURES PASSED in 222s`；矩阵 6 步 + 8 AC 已翻 PASS。 |
| F2 | T34b Photos 附件 D6/D8 | **FAIL（真实产品缺陷）** | 七条流程 PASS（A2/B5、B2、B6、B7、G1、G2、SE3）；模型弹层选择不关闭已修复（`model_sheet.dart`，commit `49468ccd`），但 attach `+` 按钮被宠物层覆盖，面板无法打开：`The Photos entry is missing from the attach panel`（`T34b/green/photos-d6-fix/xcodebuild.log`）。D6/D8 与 AC `D4-07-AC1` FAIL；未改断言/未 mock。 |
| F3 | `verify.sh --real` 端到端全绿 | **NOT-RUN** | `--real` 数据驱动列出 6 个 L4 wrapper；`run_chat_features_real.sh` 因 T32 未合并而缺失，按设计 fail-closed（fail=1, skip=0），不能称为全绿。 |
| F4 | `verify.sh --remote` 端到端全绿 | **NOT-RUN（组件已 PASS）** | SSH/Remote 两个 wrapper 已合并且各自 PASS，但整组 `--remote` 门禁未在最终树上执行。 |
| F5 | `verify.sh --full` 最终树全绿 | **FAIL** | 修复前最终树跑过一次：`pass=22 fail=1 skip=0`（裸跑 Phase1UITests；T34b dark/SE3 需要 wrapper 逐流程准备）。已把 full 门改为 T34a smoke + T34b wrapper（commit `009301f6`）；因 D6/D8 真实失败，修复前不会全绿。日志 `T38/02-full.log`。 |
| F6 | CI（GitHub Actions）绿灯 | **NOT-RUN（需 push）** | 流程文件已合并；本地无 CI 结果，未 push 到 origin。 |
| F7 | `phase1-v1.1` tag / fork push | **BLOCKED** | 因 F1/F2 未闭合，不创建最终 tag；不伪造完成状态。 |

## 3. Phase 1 外 deferred（按既定决策，不计入本轮失败）

- 真机签名/安装、APNs、iSH 完整 Linux、后台常驻、手机控制、iPad 布局、v1.0.15 数据同步、相机/媒体保存。
- `--guest` iSH archive 门禁保留为 opt-in（Phase 2）。

## 4. 独立 verifier 与门禁

- T38 独立复核：`--static` 7/0/0、`--fast` 13/0/0（发现并修复 guest fixture env 泄漏，见 `reports/phase1-completion/T38/report.md`）、spec checker OK。
- T27/T30/T31/T33b/T35 证据由 fresh-worktree/独立运行复核；如与报告不符，以日志为准。

## 5. 结论与下一步

Phase 1 的核心基座（真实本机引擎 + 对话闭环 + 工作区 + 真实审批 + 进程级持久化 + 真实 SSH / DSH Remote + 27 golden / 367 RunnerTests / 录屏）已经打通并有真实证据；
**T32 已闭合；T34b 七条流程通过，D6/D8（Photos 附件）因真实产品缺陷（宠物层遮挡 attach 按钮）FAIL**，因此本报告不签署“Phase 1 v1.1 全部达标”。
下一步：修复宠物层对 composer/attach 面板的点击遮挡（真实产品修复 + 回归），重跑 T34b `photos` 流程；随后重跑 `--full/--real/--remote`，全绿后再合并 `phase1/base` 并打 `phase1-v1.1` tag。
