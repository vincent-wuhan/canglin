---
comet_change: poc-technical-validation
role: technical-design
canonical_spec: openspec
---

# POC 技术验证 · 技术设计

需求事实源：`openspec/changes/poc-technical-validation/`（proposal / specs / tasks）。本文档只记录实现方案与工程决策，不重复需求。

## 1. 模块结构

```
canglin/
├── kernel/src/
│   ├── record/    # Column 枚举 + Record + 驱动类型映射
│   ├── channel/   # BoundedChannel
│   ├── spi/       # Reader / Writer 接口
│   └── job/       # JobRunner（spawn 读写协程、统计汇聚）
├── drivers/
│   ├── driver-api/   # DbDriver / Connection / RowSet / DbError
│   ├── driver-mysql/ # mysqlclient4cj 适配
│   └── driver-pg/    # opengauss-driver 适配（PG + openGauss）
├── app/entry/        # hvigor + ArkUI-Cangjie 三栏壳
│   └── resources/rawfile/monaco/
├── cli/              # 验证入口：连通矩阵 / 万行同步（L3 冒烟）
└── env/              # docker-compose.yml + 初始化 SQL
```

依赖方向：`kernel → driver-api`；`cli → kernel + 具体驱动`；`app →（POC 不接 kernel，仅桥接回显）`。

## 2. 核心接口

```cangjie
// kernel/record
public enum Column { Long(Int64) | Double(Float64) | Str(String)
                   | Bytes(Array<Byte>) | Bool(Bool) | Date(DateTime) | Null }
public struct Record { columns: ArrayList<Column> }

// kernel/spi —— Channel 关闭即 EOF，Reader 完成后 close，Writer 读到 EOF 退出
public interface Reader { func read(out: Channel): Unit }
public interface Writer { func write(in: Channel): Unit }

// drivers/driver-api
public interface DbDriver { func connect(cfg: ConnConfig): Result<Connection, DbError> }
public interface Connection {
    func query(sql: String): Result<RowSet, DbError>
    func listSchemas(): Result<Array<String>, DbError>
    func listTables(schema: String): Result<Array<String>, DbError>
    func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError>
    func close(): Unit   // 幂等
}
```

驱动类型→Column 的映射收敛在各适配器的 RowSet 装载处；映射失败即脏行，这是脏行判定的唯一位置。

## 3. 运行时语义

| 语义 | 决策 |
|---|---|
| 背压 | 有界 Channel，容量默认 1024 可配置；满则 Reader 阻塞 |
| 脏行 | 原子计数 +1 后丢弃；不落盘（Phase 2 加脏行文件） |
| 取消 | POC 不实现，作业跑完即止（Open Question 留 Phase 2） |
| 错误分类 | DbError 四类：网络不可达 / 认证失败 / 协议错误 / 查询错误 |
| 日志脱敏 | ConnConfig 密码字段在任何日志输出点强制脱敏 |

## 4. 桥接协议（app）

- Monaco 资产置于 `resources/rawfile/monaco/`，webview 离线加载
- 消息格式：`{id: String, type: String, payload: String}`，type ∈ `contentChanged | exec | execResult`
- POC 的 exec 语义：仓颉侧接收文本并回显一致性校验，不真执行 SQL

## 5. 测试分层

| 层 | 覆盖 | Docker 依赖 |
|---|---|---|
| L1 单测 | record 装载 / channel 背压与关闭 / 假 Reader-Writer 单侧替换 | 无 |
| L2 集成 | 三库 × 建连/查询/元数据/错误分类/关闭幂等；Docker 不可用时显式跳过 | 有 |
| L3 冒烟 | CLI 万行同步：吞吐（行/秒）、耗时、峰值内存 | 有 |
| app 手测 | 三栏渲染 / Monaco 编辑 / 桥接回显（清单化，无自动化） | 无 |

## 6. 技术风险与对策

- [社区驱动成熟度未知] → 任务 2.1 首日验证；阻塞性缺陷触发 fork 自维护，结论必须记录
- [openGauss 镜像 × 驱动版本错配] → compose 固定 tag，兼容矩阵入 POC 结论
- [ArkUI-Cangjie 桌面能力缺位] → 任务 4.1 首日冒烟；不可用则降级模拟器验证并如实记录
- [std.sync 无现成有界队列] → 基于 Mutex+条件变量自建，行为单测先行（先测后建）

## 7. Spec Patch 记录

2026-11-09 深度设计回写 delta spec 一处：driver-connectivity 新增「连接关闭（幂等）」Requirement 及场景。其余场景无缺口。
