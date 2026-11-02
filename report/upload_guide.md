# 上传清单（按本次提交页面）

代码包为 sparse_matrix_pynq_code.rar，真正 RAR 格式。解压后根目录 sparse_matrix_pynq。

| 表单栏 | 填写/上传 | 状态 |
|---|---|---|
| 作品名称 | 建议“基于 PYNQ 的 FPGA 稀疏矩阵计算平台” | 与设计报告、视频标题保持一致 |
| 三个关键词 | 稀疏矩阵计算；FPGA 软硬件协同；PYNQ 可视化验证 | 可直接填写 |
| 演示视频 | demo_video.mp4；H.264，≤3 分钟，≤300 MB | 按 video_guide.md 录制 |
| 技术文档 | 队友按官方模板完成 design_report.pdf；≤50 MB | 队友提供，勿用本文替代 |
| 上传全部代码 | sparse_matrix_pynq_code.rar；≤200 MB | 本次工程交付 |
| 承诺及使用授权书 | 官网模板，按要求填写签署后 PDF；≤50 MB | 队伍本人办理，不能代签 |
| GitHub 链接 | 指向真实项目仓库，可访问源码 | 必填，尚未由本次整理创建 |
| 海报（选填） | PDF 或 PPT，≤50 MB | 当前提交页可选；决赛要求另核对 |

## 优先检查

1. report/ai_collaboration_review_required.md：真实对话节选和总结，待队伍核对。可放报告附录；并非编造的人工分工。
2. 原核心作者与授权由队伍核实。仓库发布前确认允许再分发，不擅自给已有源代码套用 MIT 协议。
3. 设计报告、视频不得出现学校名称、教师姓名或无关身份信息。公开仓库也建议检查个人资料与文件元信息。
4. 设计报告按官方模板说明 Vivado 2018.3，解释与推荐工具版本不同；引用 report/results_index.md 和最新 evidence/submission_board。
5. 本次整理不替代队友撰写的设计报告、签署授权书、录视频和提交表单。

## 没有仓库时

在 GitHub 创建 sparse_matrix_pynq 仓库，确认源码授权后上传代码包解压后的项目文件。保持 src、board、build、data、sim、skill、report、evidence 和 readme.md 完整。提交链接指向该仓库，退出登录后检查评委能访问。不要上传 SD 镜像、Vivado 缓存、私密原始聊天摘录或账号凭据。

若修改协作记录等文件，请从工程父目录重新用 WinRAR 创建 RAR（不是改 ZIP 后缀）；同时更新 manifest.json 文件哈希。原包留作备份。
