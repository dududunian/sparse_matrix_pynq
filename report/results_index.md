# 结果与证据索引

## 当前提交副本：2026-11-02 实板复测

平台 ZCU104 RevA，PYNQ 4.0.0；bit/hwh 为通过实现与历史板测的交付文件，本次未重新综合。

| 检查 | 结果 | 证据 |
|---|---|---|
| 原始 28 例 | 全通过，102 个硬件输出块 | evidence/submission_board/full_results |
| 5 项边界 | 全通过，194 个硬件输出块，含 512 阶与 K=512 | evidence/submission_board/boundary_results |
| 六组界面按钮联调 | 全通过，0 不匹配 | evidence/submission_board/demo_acceptance.json |
| 下载数据复核 | 33 个 NPZ 输出与 Golden 一致；原 28 例另外与输入夹具参考逐位比对 | evidence/submission_board/summary.json |
| 技能包板上运行 | 环境、配套文件、真实输出 16 个元素逐位比对通过 | evidence/submission_board/skill_check |

完整验收共 296 个硬件输出块。历史记录的 299 个包含另 3 个冒烟任务，两次口径不同，不将历史数字冒充本轮计数。每例 PL 时间及主机耗时见 case_metrics.csv；不是 CPU 加速比。寄存器时钟读回为 49.999 MHz。

## 原始构建及回归证据

- evidence/full_build：50 MHz，setup slack 4.186 ns，hold slack 0.010 ns；无布线错误，内部未约束端点与无时钟管脚均为零。普通警告见日志。
- 资源：LUT 186124/230400（80.78%），BRAM 70/312（22.44%），DSP 66/1728（3.82%）。
- evidence/full_rtl：167 个 RTL 任务；evidence/numerical_rtl：4 个数值任务；evidence/reproduced/numerical_rtl：统一命名后 4 个数值任务。
- evidence/board：历史 299 个任务、1224704 个物理输出检查、0 不匹配。
- evidence/demo_board：历史六组 UI 实板联调。
- evidence/reproduced：上次软件与 RTL 检查记录；当前软件检查日志见 evidence/submission_board/local_checks.log。

构建阶段 build_proof 的 board_tested=false 是该阶段原始事实，不回写；后续真实板测由独立证据证明。当前无 DMA、无 PL 直连 DDR；未测公平 CPU 基线，不能宣称端到端加速或量化优化收益。
