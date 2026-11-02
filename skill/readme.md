# 通用 PYNQ 环境、Overlay 配套校验与 Golden 验证技能包

本目录面向参赛队伍与开发者，可以整体复制到其他题目中使用。无需安装 Codex，也不依赖本队稀疏矩阵代码、ZCU104、固定地址或固定频率。

## 比赛要求与本包定位

依据用户提供的 2026 AMD 选题指南第 3.3.2、3.3.5.2 节：技能包需包含适用范围、使用方法、失效条件、已验证效果和经验来源，评价核心是陌生队伍是否可直接复用。提示词工作流、案例模板、校验脚本和踩坑清单都可作为提交形式。通用 PYNQ Skill 另行加分，不能仅以本队题目的操作手册代替。

本包采用校验脚本、工作流和踩坑清单三种形式。它是可继续完善的参赛初版；不宣称已获加分或完成跨板实测。具体评分仍以赛事评分细则为准。

## 能力与边界

| 能力 | 适用场景 | 使用方法 | 失效或不覆盖条件 | 已验证效果 |
| --- | --- | --- | --- | --- |
| 环境采集 | 嵌入式 PYNQ 的 Python 环境确认 | `scripts/probe_environment.py` | 不判断硬件下载权限和器件匹配；remote/XRT 需专门适配 | Windows 无 PYNQ 时可输出报告；ARM32/64、部分 API 缺失已用软件测试验证 |
| Overlay 配套文件校验 | 传统 Zynq / Zynq UltraScale+ 的同名 bit/hwh | `scripts/check_overlay.py` | 不解析 bitstream 器件语义，不证明布局布线收敛；不支持 PDI/XCLBIN 流程 | 名称、非空文件、HWH XML、声明哈希通过/故障路径；本项目真实交付文件验证见 evidence |
| Golden 自动比对 | 向量、图像展开数组、DSP、矩阵等硬件输出 | `scripts/compare_golden.py` | JSON 仅一维有限数值；hex 仅原始无符号位模式；不解码 FP16、不处理文件内地址跳转 | 正确、错误、长度不符、空数据、非法 hex、浮点容差等离线用例 |
| 部署与排错流程 | PYNQ Overlay 首次加载与连续任务验证 | `workflow.md`、`pitfalls.md` | 寄存器、时钟、复位、DMA 协议必须来自用户实际设计 | 基于本队真实仿真/实现问题提炼；新板实测尚待补充 |

仅需 Python 3.8+ 标准库即可运行离线工具。环境脚本应在板上实际使用的 Notebook 内核或相同 Python 环境运行。输出的 JSON 报告便于纳入自动化；报告参数指定的文件会被更新，应为每次实验选择独立输出路径。

## 从零试用：无需板卡

在本 `skill/` 目录打开终端：

```text
python -B -m unittest discover -s tests -v
python scripts/compare_golden.py --actual examples/vector_add_actual.json --golden examples/vector_add_golden.json --format json --source-kind example
python scripts/compare_golden.py --actual examples/threshold_actual.json --golden examples/threshold_golden.json --format json --source-kind example
```

两个例子分别采用向量加法和阈值分类，验证同一接口可处理不同题目的输出。这些数据由软件构造，不代表两种硬件已实现或跨板验证。修改任意 actual 数值后应得到失败。所有工具都不硬编码板型。

`compare_golden.py` 与 `check_overlay.py` 退出码：0 表示各自声明范围内的检查通过，1 表示发现不匹配，2 表示命令参数或输入读取错误。环境 probe 只采集信息，退出 0 不等于 PYNQ 已就绪。

## 用到自己的工程

### 1. 板上采集环境

```text
python scripts/probe_environment.py --output environment.json
```

脚本不加载 Overlay、不访问 MMIO、不修改时钟。已有同名输出时拒绝覆盖。Notebook 可用 `%run scripts/probe_environment.py --output environment.json`，以检查当前内核。

### 2. 校验自己的 Overlay 文件

将同次构建产生的 `accelerator.bit` 与 `accelerator.hwh` 配对。构建时记录可信的哈希配置：

```json
{
  "bit_sha256": "填写实际bit文件的64位SHA256",
  "hwh_sha256": "填写实际hwh文件的64位SHA256"
}
```

```text
python scripts/check_overlay.py --bit accelerator.bit --hwh accelerator.hwh --config bundle.json --report overlay_check.json
```

不提供 config 时也能检查文件和 HWH XML，但 `declared_pair_verified` 为 false。哈希只证明与给定声明一致；如果声明本身错配，哈希不能证明来自同次构建。`offline_checks_passed` 不是 PYNQ 解析或上板成功标志。

### 3. 按自身协议运行并导出结果

按 `workflow.md` 完成真实 PYNQ 加载、地址/时钟核对和任务运行。本包不替用户猜寄存器地址，也不自动发起硬件任务。可沿用已有驱动，将结果导出为平铺 JSON 或 hex。

```text
python scripts/compare_golden.py --actual output.hex --golden reference.hex --format hex --bits 16 --source-kind simulation --report comparison.json
python scripts/compare_golden.py --actual output.json --golden reference.json --format json --mode numeric --atol 0.00001 --rtol 0.0001 --report comparison_float.json
```

`--bits 16` 是该命令的示例参数，不是所有项目的默认精度。hex 按原始位模式比较，适合明确要求逐位一致的 FP16/整数输出；需要数值容差时先用项目自己的格式解码至 JSON。`--source-kind board` 只是提交者声明，不能自动认证结果来源。

## 换题与换板

换题时替换 Golden、输出数据格式和展平顺序，必要时调整容差。换板时替换相应镜像、匹配器件的硬件文件及板级运行步骤。脚本无需修改 ZCU104 地址或稀疏矩阵参数，因为它们从未内置这些参数。

当前具备接口层面的可迁移性和两个不同任务的离线复用例子。实际跨板可用性仍需在第二块板执行相同流程并保存环境、文件哈希和输出；不得将软件 mock 测试写成跨板实测。

## 经验来源与证据

见 `pitfalls.md`，每项均列出观察、提炼、验证方法和限制。`evidence/validation.json` 记录本次实际执行的离线检查结果。当前证据支持工具行为和本项目文件核查，尚不支持真实板测、干净 PYNQ 镜像部署或跨板迁移成功的声明。

本技能包由开发过程中的大模型协作整理而来，不包含完整原始聊天记录。最终作品仍需在报告材料中提交真实的提示词、回答和自我纠错记录；本 README 不能代替它们。


## 2026-11-02 当前板卡补充验证

在 ZCU104、PYNQ 4.0.0 中实际运行三个脚本：环境采集、当前 sparse_matrix_full.bit/hwh 哈希配套检查、完整板测 spmm_small4_manual 结果 16 个 FP16 位模式与 Golden 对比，全部通过。证据见 ../evidence/submission_board/skill_check。

这些脚本自身不加载硬件，因此 overlay.json 中 board_tested=false 和环境中的 hardware_tested=false 保持原样；真实计算来源由同目录上级 full_results 及执行 Notebook 关联证明。上述旧离线验证说明是早期范围，本次补充不表示第二种板卡已测试。


