# poc-technical-validation · 设计

## Context

canglin 长期架构为五层（驱动插件层 / DataX 式引擎层 / 元数据层 / 智能层 / 应用层），本 change 只验证其最底两层与应用壳的可行性。仓库为全新 monorepo，本机工具链（Cangjie SDK 1.0.5 LTS mac-aarch64、DevEco Studio）需在本 change 内安装。前序对话已完成五层架构分析与 DataX 概念移植方案，本设计仅覆盖 POC 范围。

## Goals / Non-Goals

**Goals:**
- 三个生死验证点各出量化结论：驱动连通（三库建连/查询/元数据）、内核原型（1 万行同步零丢行 + 吞吐基线）、桌面壳（三栏 + Monaco 可编辑 + 桥接通信）
- monorepo 骨架定型，Phase 1 可直接续建

**Non-Goals:**
- 金仓/达梦驱动（无测试环境；金仓 PG 协议兼容假设留待 Phase 2 验证）
- 数据网格、数据编辑提交、连接凭据加密存储、生产级 UI
- 作业分片/限速/断点续传（DataX 完整内核属 Phase 2）
- 智能层（CangjieMagic 集成属 Phase 3）

## Decisions

### D1: 仓库结构 —— monorepo 三区
```
canglin/
├── kernel/     # 引擎内核（cjpm workspace：record / channel / spi / job）
├── drivers/    # 驱动适配（cjpm：driver-api + mysql / pg 适配器）
└── app/        # 桌面壳（DevEco/hvigor 工程，ArkUI-Cangjie）
```
- 备选：双仓（引擎独立仓）——被否：POC 阶段一体化迭代更快，验证后再拆代价低
- `drivers/driver-api` 定义统一驱动接口，`kernel` 仅依赖 `driver-api` 不依赖具体驱动（依赖倒置，对应 spec"驱动 SPI 隔离"）

### D2: 驱动选型 —— 社区库直用 + fork 预案
- MySQL 系用 mysqlclient4cj，PG/openGauss 用 opengauss-driver
- 若发现阻塞性缺陷：fork 到仓内 `drivers/vendor/` 自维护，POC 结论中必须记录库成熟度评估

### D3: 内核概念映射（DataX → 仓颉）
| DataX | 仓颉实现 |
|---|---|
| Record/Column | `enum Column` + `struct Record`（enum 表七类列含 NULL） |
| Channel | 有界阻塞队列，仓颉协程天然适合（spawn + 同步原语） |
| Reader/Writer 插件 | `interface Reader { func read(ch: Channel) }` 等，编译期注册表（仓颉无运行时类加载，不照搬 DataX classloader 隔离） |
| 统计 | 作业对象聚合原子计数（成功/失败/耗时） |

### D4: SQL 编辑器 —— webview + 本地打包 Monaco
- Monaco 资产随应用打包，离线加载；桥接用 webview message 通道
- 备选：自绘编辑器——被否：语法高亮/补全工作量远超 POC 范围

### D5: 测试环境 —— Docker 三容器
- `docker/mysql:8`、`postgres:16`、`opengauss/opengauss`（官方镜像），compose 文件入库（`env/docker-compose.yml`），初始化 SQL 脚本生成 1 万行源表
- 备选：云端实例——被否：本机 colima 已就绪，成本零

## Risks / Trade-offs

- [社区驱动不成熟：连接池缺失/协议 bug] → POC 点 1 直接暴露；fork 预案 D2
- [openGauss 镜像与 opengauss-driver 版本错配] → 固定镜像 tag 与驱动版本组合，记录兼容矩阵
- [ArkUI-Cangjie 桌面 API 缺位（鸿蒙电脑特性）] → POC 点 3 首日冒烟；若 webview 不可用，降级为移动端模拟器验证并记录限制
- [Monaco 体积拖慢启动] → 记录冷启动耗时作为 POC 数据点，不阻塞
- [仓颉协程 + 有界队列的背压语义与预期不符] → 通道行为单测先行（先测后建）

## Migration Plan

不适用（全新仓库，无存量迁移）。POC 结论直接决定 Phase 1 change 的架构输入。

## Open Questions

- openGauss 官方镜像的默认密码策略与驱动兼容组合（实施任务 2.1 内解决）
- Monaco 本地打包在鸿蒙 webview 的资源路径访问方式（实施任务 4.2 内解决）
