# poc-technical-validation

## Why

canglin（仓廪）目标是仓颉生态首个多源数据库客户端并演进为智能数据网关。投入 Phase 1 MVP（预估 3-4 个月）之前，存在三个足以改变架构路线的未验证假设：社区数据库驱动（mysqlclient4cj / opengauss-driver）是否生产可用、DataX 式同步内核在仓颉协程模型下是否成立、ArkUI-Cangjie + webview-Monaco 的桌面客户端形态是否可行。POC 失败任何一点都将推翻现有方案，越早暴露成本越低。

## What Changes

- 新建 monorepo：`kernel/`（引擎内核）+ `drivers/`（驱动适配）为 cjpm 工程，`app/`（桌面壳）为 DevEco/hvigor 工程
- 驱动连通验证：Docker 起测试矩阵（MySQL 8 / PostgreSQL 16 / openGauss），跑建连、查询、元数据读取
- 同步内核原型：移植 DataX 核心概念（Record 中立行模型 / Channel 管道 / Reader-Writer SPI），完成 MySQL→PG 1 万行同步
- 桌面壳验证：ArkUI-Cangjie 三栏布局 + webview 内嵌本地 Monaco Editor 可编辑
- 非目标：金仓/达梦驱动（无测试环境，延后）、数据编辑提交、生产级 UI 打磨、智能层

## Capabilities

### New Capabilities

- `driver-connectivity`: 数据库驱动适配与连通性验证——连接管理、查询执行、元数据读取，覆盖 MySQL/PostgreSQL/openGauss 三源
- `sync-kernel`: DataX 式同步引擎内核——Record 中立记录模型、Channel 传输管道、Reader/Writer SPI 与作业执行原型
- `desktop-shell`: ArkUI-Cangjie 桌面应用壳——三栏布局骨架与 webview 内嵌 Monaco SQL 编辑器

### Modified Capabilities

（无——全新仓库，无存量能力）

## Impact

- **代码**：全新仓库 `canglin`，无存量代码影响
- **依赖**：引入社区库 mysqlclient4cj、opengauss-driver（若不满足需求触发 fork 自维护预案）；官方 stdx
- **工具链**：需安装 Cangjie SDK 1.0.5 LTS（mac-aarch64）与 DevEco Studio（本机当前均未安装）
- **环境**：本机 Docker（colima）承载测试数据库实例
