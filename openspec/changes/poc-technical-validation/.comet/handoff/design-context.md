# Comet Design Handoff

- Change: poc-technical-validation
- Phase: design
- Mode: compact
- Context hash: ac33622c436794c1475618b60cfa02afb47c0c5d4ea4f18d3acc282baa818180

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/poc-technical-validation/proposal.md

- Source: openspec/changes/poc-technical-validation/proposal.md
- Lines: 1-32
- SHA256: 820081b241b784f0e0a8bf27b693f74752b4afac27a2a6ef2a9f9bf7fc72db05

```md
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
```

## openspec/changes/poc-technical-validation/design.md

- Source: openspec/changes/poc-technical-validation/design.md
- Lines: 1-66
- SHA256: d1f638adc2dabac40c3df77dc4c4feb7230faf07cbed0a85eaf73b8f3418fd25

```md
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
```

## openspec/changes/poc-technical-validation/tasks.md

- Source: openspec/changes/poc-technical-validation/tasks.md
- Lines: 1-38
- SHA256: a543e1a6186404babe8f538256d00c6b59eabb2481c7c5e36d97f090ca419426

```md
# poc-technical-validation · 任务

## 1. 工具链与环境

- [ ] 1.1 安装 Cangjie SDK 1.0.5 LTS（mac-aarch64）并验证 cjc/cjpm 可用
- [ ] 1.2 安装 DevEco Studio（含 ArkUI-Cangjie 支持与鸿蒙模拟器/预览器）
- [ ] 1.3 编写 env/docker-compose.yml（MySQL 8 / PostgreSQL 16 / openGauss 固定 tag）及初始化 SQL（含 1 万行源表），启动并验证三容器健康

## 2. 驱动连通（driver-connectivity）

- [ ] 2.1 确定 mysqlclient4cj / opengauss-driver 获取方式（中心仓或源码依赖）与版本组合，记录兼容矩阵
- [ ] 2.2 搭建 drivers/ cjpm 工程：driver-api 统一接口（连接/查询/元数据）
- [ ] 2.3 实现 MySQL 适配器：建连/SELECT 行集/库表列元数据，密码脱敏日志
- [ ] 2.4 实现 PG/openGauss 适配器：同 2.3 口径
- [ ] 2.5 错误分类验证：错误密码与不可达主机返回可区分错误，编写并跑通对应单测
- [ ] 2.6 输出驱动连通验证结论（三库 × 三能力通过矩阵 + 驱动成熟度评估）

## 3. 同步内核（sync-kernel）

- [ ] 3.1 搭建 kernel/ cjpm workspace：record/channel/spi/job 模块骨架
- [ ] 3.2 实现 Column/Record 中立模型 + 列类型装载单测（四类列含 NULL）
- [ ] 3.3 实现有界 Channel，单测先行验证满阻塞/空阻塞/不丢不重
- [ ] 3.4 实现 Reader/Writer SPI 与内存假实现，验证单侧可替换
- [ ] 3.5 接通 MySQL Reader 与 PG Writer，跑 1 万行同步：零丢行、零失败行、记录吞吐基线与耗时
- [ ] 3.6 混入脏行验证：失败行计数、跳过不中断
- [ ] 3.7 输出内核验证结论（吞吐行/秒、内存占用、仓颉协程模型适用性评价）

## 4. 桌面壳（desktop-shell）

- [ ] 4.1 搭建 app/ DevEco 工程（ArkUI-Cangjie），三栏布局占位渲染
- [ ] 4.2 Monaco 本地打包与 webview 离线加载，SQL 高亮与编辑可用
- [ ] 4.3 实现 webview↔仓颉 桥接：编辑区文本回传仓颉侧接收一致
- [ ] 4.4 记录冷启动耗时与 webview 兼容性观察，输出桌面壳验证结论

## 5. POC 汇总

- [ ] 5.1 汇总三验证点量化结论（通过矩阵/吞吐基线/启动耗时），写入 docs/superpowers/specs/ POC 结论文档
- [ ] 5.2 明确 Phase 1 架构输入：按结论确认或修正五层架构假设，形成 go/no-go 建议
```

## openspec/changes/poc-technical-validation/specs/desktop-shell/spec.md

- Source: openspec/changes/poc-technical-validation/specs/desktop-shell/spec.md
- Lines: 1-21
- SHA256: 6e80433419a6b68eae147a75d354619ddc9442d1f32c7d81d25c6ef7ccd28a98

```md
# desktop-shell

## ADDED Requirements

### Requirement: 三栏桌面布局
应用 SHALL 在鸿蒙桌面端（ArkUI-Cangjie）呈现三栏布局：左侧连接/对象栏、中部编辑区、右侧结果区，三栏 SHALL 可见且不重叠。

#### Scenario: 三栏渲染
- **WHEN** 应用启动
- **THEN** 三栏布局渲染完成，各栏显示占位内容

### Requirement: webview 内嵌 Monaco 编辑器
中部编辑区 SHALL 通过 webview 加载本地打包的 Monaco Editor（无网络依赖），SHALL 支持 SQL 语法高亮与文本编辑。

#### Scenario: Monaco 离线加载与编辑
- **WHEN** 应用启动后进入编辑区输入 SQL 文本
- **THEN** Monaco 正常渲染，SQL 关键字高亮，文本可编辑修改

#### Scenario: webview 与仓颉层通信
- **WHEN** 在 Monaco 中触发"执行"动作（如按钮或命令）
- **THEN** 编辑区文本经 webview 桥接传回仓颉侧并被接收（内容一致即可，不要求真实执行）
```

## openspec/changes/poc-technical-validation/specs/driver-connectivity/spec.md

- Source: openspec/changes/poc-technical-validation/specs/driver-connectivity/spec.md
- Lines: 1-42
- SHA256: 529220581b875d1bf18d520d78453431d508b43e958794394a27b4114fc84276

```md
# driver-connectivity

## ADDED Requirements

### Requirement: 数据库建连
系统 SHALL 通过统一连接入口建立到 MySQL 8、PostgreSQL 16、openGauss 的连接，连接参数 SHALL 包含主机、端口、库名、用户、密码，密码不得写入日志。

#### Scenario: 三库建连成功
- **WHEN** 使用 Docker 测试矩阵实例的正确连接参数调用连接入口
- **THEN** 对 MySQL/PostgreSQL/openGauss 各返回可用连接对象

#### Scenario: 错误参数给出可区分错误
- **WHEN** 使用错误密码或不可达主机调用连接入口
- **THEN** 返回包含错误类别的失败结果（认证失败/网络不可达），而非裸异常或 panic

### Requirement: 查询执行
系统 SHALL 对已建立的连接执行任意 SELECT 语句，结果 SHALL 以驱动无关的行结构返回，覆盖整型、浮点、字符串、NULL 四类列。

#### Scenario: 查询含四类列的结果集
- **WHEN** 对测试库执行包含整型、浮点、字符串、NULL 列的 SELECT
- **THEN** 返回行数正确的驱动无关行结构，四类列值可正确读取

### Requirement: 元数据读取
系统 SHALL 读取库/表/列三级元数据：列出数据库（schema）、列出表、读取列名与类型，供下游对象树消费。

#### Scenario: 读取表与列元数据
- **WHEN** 对已建连实例请求指定 schema 的表清单及任一表的列定义
- **THEN** 返回表名列表与列名/类型映射，与测试库 DDL 一致

### Requirement: 驱动 SPI 隔离
上层 SHALL 仅依赖统一驱动接口（连接/查询/元数据），不感知具体驱动类型；更换或新增驱动 SHALL 不修改上层代码。

#### Scenario: 上层代码驱动无关
- **WHEN** 用同一上层调用分别访问 MySQL 与 PostgreSQL
- **THEN** 仅连接参数中的驱动类型标识不同，调用代码完全一致

### Requirement: 连接关闭
连接 SHALL 支持显式关闭以释放资源，close SHALL 幂等——对已关闭连接再次调用不抛异常。

#### Scenario: 连接关闭幂等
- **WHEN** 对已建立的连接调用 close 后再次调用 close
- **THEN** 不抛异常，连接资源已释放
```

## openspec/changes/poc-technical-validation/specs/sync-kernel/spec.md

- Source: openspec/changes/poc-technical-validation/specs/sync-kernel/spec.md
- Lines: 1-35
- SHA256: 0299ad1a3396d18e7293cbc085d172124ccfba7501db05af4cbf329457faaf95

```md
# sync-kernel

## ADDED Requirements

### Requirement: Record 中立行模型
内核 SHALL 提供驱动无关的行模型：一行由有序列组成，每列 SHALL 为枚举类型（整型/浮点/字符串/字节/布尔/日期/NULL）之一，读写两侧不感知具体数据库类型系统。

#### Scenario: 列类型无损装载
- **WHEN** 将含整型、浮点、字符串、NULL 的查询行装入 Record
- **THEN** 列类型与值可完整读出，NULL 列显式可判

### Requirement: Channel 传输管道
内核 SHALL 提供有界内存管道连接读侧与写侧，满时读侧阻塞、空时写侧阻塞，MUST 不丢行、不重复行。

#### Scenario: 有界背压
- **WHEN** 读侧生产速度持续高于写侧消费速度且管道达到容量上限
- **THEN** 读侧阻塞等待，全程无行丢失或重复

### Requirement: Reader/Writer SPI
内核 SHALL 定义 Reader 与 Writer 接口：Reader 负责从源拉取行并写入 Channel，Writer 负责从 Channel 取出并写入目标；MUST 可独立替换单侧实现。

#### Scenario: 双侧插件独立替换
- **WHEN** 以 MySQL Reader + PostgreSQL Writer 组合，替换其中任一侧为内存假实现
- **THEN** 另一侧无需修改即可继续工作

### Requirement: 作业执行与统计
内核 SHALL 以单作业形态驱动 Reader-Channel-Writer 流水线直至完成，SHALL 输出成功行数、失败行数与耗时统计。

#### Scenario: 万行同步完整完成
- **WHEN** 执行 MySQL→PostgreSQL 的 1 万行同步作业
- **THEN** 作业正常结束，成功行数 = 10000，失败行数 = 0，并输出吞吐（行/秒）基线数据

#### Scenario: 脏行不中断作业
- **WHEN** 源数据中混入少量类型不兼容行
- **THEN** 该行计入失败统计并被跳过，其余行继续同步，作业不中断
```

