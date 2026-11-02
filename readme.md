# 稀疏矩阵计算平台 / sparse_matrix_pynq

自主选题初级组代码工程提交版。平台为 ZCU104 RevA（xczu7ev-ffvc1156-2-e）、PYNQ 4.0.0、Python 3.12.3、Vivado 2018.3，PL 目标频率 50 MHz。

支持 FP16 稀疏矩阵乘法、加法、减法。逻辑尺寸上限 512，PYNQ 调度 64×64 输出块，K≤512 在 FPGA 内完整累加。本版采用 AXI4-Lite/MMIO，没有 DMA 或 PL 直连 DDR 通路。用途为稀疏矩阵计算演示与硬件验证，不承诺端到端加速。

## 目录

- src/project/src、src/project/board：计算核心及 AXI 控制接口，保留已验证模块布局；文件名统一小写，模块标识符不改。
- src/host、src/tools：主机软件、仿真生成与数据导入工具。
- build：构建入口；src/start_build.tcl 为实际 Vivado 流程。
- sim：软件检查和完整 RTL 仿真入口。
- board：可上传到板卡的文件，含演示及原始用例/边界验收 Notebook。
- data/original_cases：原始 28 例的输入、Golden 位模式和校验清单。
- evidence：原始实现、仿真及真实板测记录；reproduced 子目录保存重新运行的检查。
- skill：队友提供的通用技能包，包含一项数值溢出修复，变更见 report/skill_changes.md。
- report：复现说明、结果索引和提交前待办。协作摘录见 ai_collaboration_review_required.md，请队伍核对。

## 快速使用

先阅读 report/reproduce.md。已提供硬件无需重新构建；将 board 下文件上传到 ZCU104 同一目录，打开 matrix_demo.ipynb 并运行代码单元。完整验收打开 board_acceptance.ipynb。

电脑检查：python sim/run_host_tests.py；python build/build.py --check-only。

## 当前验收状态

原工程历史实板验收：28 个原始用例 + 5 项边界 + 3 项冒烟，共 299 个硬件任务，1224704 个物理输出无不匹配。新演示程序另有 6 组实板联调记录。旧日志内的旧名称、绝对路径和时间原样保留，不代表提交改名后重新上板。

此次整理只改文件路径、脚本入口和界面名称，原计算 RTL 内容哈希及交付 bit/hwh 哈希须通过 build/build.py --check-only 和整理验证。重新生成的 bit 需要重新板测。

## 本次提交与复测

本次新增 evidence/submission_board，记录改名后的交付文件真实板测。历史证据不会被新测试覆盖。构建硬件内容保持原验收哈希，本次不重复综合实现。

上传操作见 report/upload_guide.md，拍摄流程见 report/video_guide.md。设计报告由队友另交，协作记录标记待核对，授权书须由队伍办理；GitHub 仓库尚未代为发布。代码包不代表全部表单材料均已提交。
