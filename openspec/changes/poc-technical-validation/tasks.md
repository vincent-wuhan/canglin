# poc-technical-validation · 任务

## 1. 工具链与环境

- [x] 1.1 安装 Cangjie SDK（基线 1.1.x：STS 1.1.0；Intel Mac 无 mac-x64 包，实装 1.1.0-beta.25）并验证 cjc/cjpm 可用 —— 见 env/driver-notes.md「工具链基线」
- [ ] 1.2 安装 DevEco Studio（含 ArkUI-Cangjie 支持与鸿蒙模拟器/预览器）<!-- DEFERRED：华为登录墙，需用户手动安装，阻塞 PT11/PT12 -->
- [x] 1.3 编写 env/docker-compose.yml（MySQL 8 / PostgreSQL 16 / openGauss 固定 tag）及初始化 SQL（含 1 万行源表），启动并验证三容器健康

## 2. 驱动连通（driver-connectivity）

- [ ] 2.1 确定 mysqlclient4cj / opengauss-driver 获取方式（中心仓或源码依赖）与版本组合，记录兼容矩阵
- [x] 2.2 搭建 drivers/ cjpm 工程：driver-api 统一接口（连接/查询/元数据）
- [x] 2.3 实现 MySQL 适配器：建连/SELECT 行集/库表列元数据，密码脱敏日志
- [ ] 2.4 实现 PG/openGauss 适配器：同 2.3 口径
- [x] 2.5 错误分类验证：错误密码与不可达主机返回可区分错误，编写并跑通对应单测
- [ ] 2.6 输出驱动连通验证结论（三库 × 三能力通过矩阵 + 驱动成熟度评估）

## 3. 同步内核（sync-kernel）

- [x] 3.1 搭建 kernel/ cjpm workspace：record/channel/spi/job 模块骨架
- [x] 3.2 实现 Column/Record 中立模型 + 列类型装载单测（四类列含 NULL）
- [x] 3.3 实现有界 Channel，单测先行验证满阻塞/空阻塞/不丢不重
- [x] 3.4 实现 Reader/Writer SPI 与内存假实现，验证单侧可替换
- [x] 3.5 接通 MySQL Reader 与 PG Writer，跑 1 万行同步：零丢行、零失败行、记录吞吐基线与耗时
- [x] 3.6 混入脏行验证：失败行计数、跳过不中断
- [ ] 3.7 输出内核验证结论（吞吐行/秒、内存占用、仓颉协程模型适用性评价）<!-- PT10 已给吞吐与内存基线（env/driver-notes.md），协程模型适用性评价随内核结论一并出 -->

## 4. 桌面壳（desktop-shell）

- [ ] 4.1 搭建 app/ DevEco 工程（ArkUI-Cangjie），三栏布局占位渲染
- [ ] 4.2 Monaco 本地打包与 webview 离线加载，SQL 高亮与编辑可用
- [ ] 4.3 实现 webview↔仓颉 桥接：编辑区文本回传仓颉侧接收一致
- [ ] 4.4 记录冷启动耗时与 webview 兼容性观察，输出桌面壳验证结论

## 5. POC 汇总

- [ ] 5.1 汇总三验证点量化结论（通过矩阵/吞吐基线/启动耗时），写入 docs/superpowers/specs/ POC 结论文档
- [ ] 5.2 明确 Phase 1 架构输入：按结论确认或修正五层架构假设，形成 go/no-go 建议
