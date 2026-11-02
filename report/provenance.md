# 来源与版本关系

最终运行版本：sparse_matrix_full.bit/hwh，硬件 ID 0x4e533201。当前 src 包含计算 RTL、AXI 接口和 PS Python，不需要早期版本覆盖。

移植代码.zip：早期固定输入上板阶段；ZCU104_dynamic_board.zip：动态输入过渡阶段。保留其输入包哈希于 input_inventory.json，便于区分版本。旧版本未作为最终 board 入口，避免不同寄存器协议和硬件混用。

原始核心项目：由队伍提供的原工程发展而来；作者、来源、使用授权及成员贡献需要队伍如实说明。代码文件中已有版权声明不得擅自删除。此次只整理已完成版本，不宣称从零原创全部核心。

PYNQ 目录中的 ZCU104-4.0.0.img 是 SD 系统镜像，不纳入代码上传包；复现环境版本已记录。大文件缓存、Vivado 安装程序、重复旧 bitstream 不属最终源码依赖。

历史 evidence 下的旧项目名称、机器路径、日期保留用于追溯，不是当前作品标题。当前新板测保存在 evidence/submission_board。
