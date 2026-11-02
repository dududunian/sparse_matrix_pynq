# 从零复现

## 环境

本次实际使用 Vivado 2018.3，未在 2025.2/2026.1 重新实现。选择旧版原因是现有可用安装与既有工程兼容；需在设计报告据实声明。器件为 ZCU104 的 xczu7ev-ffvc1156-2-e，需安装对应器件及 ZCU104 board part 1.1。必须使用匹配板型的 PYNQ 镜像；原实测为 PYNQ 4.0.0。

Windows 示例（从提交根目录打开 PowerShell，路径可替换）：

```powershell
$env:VIVADO_BIN='D:\Vivado\Vivado\2018.3\bin'
$env:NS_WORK_DIR='D:\fpga_work'
$env:TEMP=$env:NS_WORK_DIR
$env:TMP=$env:NS_WORK_DIR
python -m pip install -r requirements.txt
python sim/run_host_tests.py
python build/build.py --check-only
python sim/run_rtl_tests.py
python build/build.py
```

pip 需网络；已有 NumPy、ipywidgets 时可不安装。桌面软件检查不需要 PYNQ；板上驱动依赖 PYNQ。Linux 需设置 VIVADO_BIN 为对应 bin 目录；本包未做独立 Linux 全流程复现，不宣称已经跨平台验收。

RTL 仿真为完整计算核与 AXI 联合检查：167 个任务加 4 项数值边界。为控制仿真时长，两轮共 6 个任务完整 AXI 上传，其余在仿真中预装内存；真实板测没有这一捷径。

构建在新目录保存工程、routed.dcp、时序/资源报告和 export，日志在 NS_WORK_DIR 下。成功必须有真实成功标记、非负 setup/hold、完整布线和匹配的 bit/hwh。不要将只出现命令回显当作成功。旧证据不随重跑被覆盖；新仿真写 evidence/reproduced。

## 上板

1. 给 ZCU104 正确写入镜像、设置 SD 启动，连接电源及网络。直连时按实际网络设置访问 Jupyter；历史演示地址 192.168.2.99:9090 不是所有环境的固定地址。
2. 在 Jupyter 创建独立目录，上传 board 的文件，保持 sparse_matrix_full.bit 与 sparse_matrix_full.hwh 同名且配套。
3. 打开 matrix_demo.ipynb，运行代码单元，生成输入、加载硬件、开始计算。不要同时运行其他控制硬件的 Notebook。
4. 打开 board_acceptance.ipynb，依次解压测试数据、运行原始 28 例与 512 边界。成功标记仍使用历史协议字符串 ORIGINAL_SUITE_PASS、BOUNDARY_SUITE_PASS。
5. 保存带输出的 Notebook、环境、full_results/report.json、boundary_results/report.json 及结果 NPZ。失败时保留全部输出，不能只截成功部分。

重新构建后应将新 bit/hwh 的 SHA-256 写入新的 board_config.json，并保留对应时序证明；不可继续使用旧硬件哈希或旧 board_tested 声明。请让未参与整理的队友按本文独立复现并记录软件版本、命令和结果。
