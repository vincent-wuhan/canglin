---
change: poc-technical-validation
design-doc: docs/superpowers/specs/2026-11-09-poc-technical-validation-design.md
base-ref: a65673b44d997e48201b269bf1187dc2d557775b
---

# POC Technical Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 验证 canglin 三个生死技术假设（社区驱动可用性 / DataX 式内核在仓颉协程下的可行性 / ArkUI+webview-Monaco 桌面形态），产出量化 POC 结论。

**Architecture:** monorepo 三区——`kernel/`（record/channel/spi/job，cjpm workspace）、`drivers/`（driver-api + mysql/pg 适配器）、`app/`（DevEco ArkUI-Cangjie 壳）+ `cli/`（验证入口）+ `env/`（Docker 测试矩阵）。kernel 只依赖 driver-api（依赖倒置）。

**Tech Stack:** Cangjie 1.0.5 LTS（cjpm）、mysqlclient4cj、opengauss-driver、DevEco Studio（ArkUI-Cangjie + webview + Monaco）、Docker(colima) MySQL8/PG16/openGauss。

**执行者须知（语言细节不确定性）**：本计划中的仓颉代码以 1.0.5 语法写成，但断言 API（std.unittest）、并发原语（std.sync 条件变量具体类名）、驱动库公开接口以本机 SDK 与中心仓库源码为准。每个任务的第一步若标注「校准」，先对照 SDK 文档/库源码校准再继续；结构不变，具体签名允许微调。

---

## File Structure

```
canglin/
├── kernel/
│   ├── cjpm.toml                    # workspace 根
│   ├── src/record/column.cj         # Column 枚举
│   ├── src/record/record.cj         # Record
│   ├── src/channel/bounded_channel.cj
│   ├── src/spi/spi.cj               # Reader/Writer/统计
│   ├── src/job/job_runner.cj
│   └── src/test/*.cj                # L1 单测
├── drivers/
│   ├── driver-api/{cjpm.toml, src/*.cj}
│   ├── driver-mysql/{cjpm.toml, src/*.cj, src/test/*.cj}
│   └── driver-pg/{cjpm.toml, src/*.cj, src/test/*.cj}
├── cli/{cjpm.toml, src/main.cj}     # 连通矩阵 + 万行同步入口
├── env/{docker-compose.yml, init/*.sql}
├── app/entry/                       # DevEco 工程（任务内创建）
└── docs/superpowers/specs/2026-11-09-poc-conclusion.md  # POC 结论（最后任务）
```

---

### Task 1: 工具链与环境（tasks.md 1.1–1.3）

**Files:**
- Create: `env/docker-compose.yml`, `env/init/01-mysql.sql`, `env/init/02-pg.sql`

- [ ] **Step 1: 安装 Cangjie SDK 1.0.5 LTS**

从 https://cangjie-lang.cn/download/1.0.5 下载 `cangjie-sdk-mac-aarch64-1.0.5.tar.gz`，解压到 `~/cangjie-sdk`，按官方安装指南设置 `CANGJIE_HOME` 与 PATH。校验：

```bash
cjc --version   # 期望输出 1.0.5 系列
cjpm --version
```

- [ ] **Step 2: 安装 DevEco Studio**

从华为开发者官网下载 mac 版 DevEco Studio（含仓颉插件与 HarmonyOS 模拟器），拖入 /Applications，首次启动完成 SDK/工具链下载。校验：新建 Empty Ability(Cangjie) 工程可编译。

- [ ] **Step 3: 编写 docker-compose 测试矩阵**

```yaml
# env/docker-compose.yml
services:
  mysql:
    image: mysql:8.4
    environment: { MYSQL_ROOT_PASSWORD: canglin123, MYSQL_DATABASE: canglin_src }
    ports: ["3306:3306"]
    volumes:
      - ./init/01-mysql.sql:/docker-entrypoint-initdb.d/01.sql
  pg:
    image: postgres:16
    environment: { POSTGRES_PASSWORD: canglin123, POSTGRES_DB: canglin_src }
    ports: ["5432:5432"]
    volumes:
      - ./init/02-pg.sql:/docker-entrypoint-initdb.d/02.sql
  opengauss:
    image: opengauss/opengauss:7.0.0-RC1   # tag 以任务 Step4 实测可用为准
    environment: { GS_PASSWORD: Canglin@123 }
    ports: ["5433:5432"]
```

`01-mysql.sql`（源表 + 1 万行，用存储过程生成）：

```sql
USE canglin_src;
CREATE TABLE src_users (
  id BIGINT PRIMARY KEY, name VARCHAR(64), score DOUBLE,
  note TEXT, created_at DATETIME
);
DELIMITER $$
CREATE PROCEDURE seed()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 10000 DO
    INSERT INTO src_users VALUES (i, CONCAT('user_', i), i * 0.5,
      IF(i % 100 = 0, NULL, CONCAT('note_', i)), NOW());
    SET i = i + 1;
  END WHILE;
END$$
CALL seed();
```

`02-pg.sql`（目标库空表，列类型与源对齐）：

```sql
CREATE TABLE dst_users (
  id BIGINT PRIMARY KEY, name VARCHAR(64), score DOUBLE PRECISION,
  note TEXT, created_at TIMESTAMP
);
```

- [ ] **Step 4: 启动并验证**

```bash
cd env && docker compose up -d && docker compose ps   # 三容器 healthy/running
docker exec -i $(docker compose ps -q mysql) mysql -pcanglin123 -e "SELECT COUNT(*) FROM canglin_src.src_users;"  # 期望 10000
```

openGauss 首启失败则更换 tag 重试，最终把可用组合记录进 POC 结论。

- [ ] **Step 5: Commit**

```bash
git add env/
git commit -m "env: Docker 测试矩阵（MySQL8/PG16/openGauss）与万行源数据"
```

---

### Task 2: kernel workspace + Column/Record（tasks.md 3.1–3.2）

**Files:**
- Create: `kernel/cjpm.toml`, `kernel/src/record/column.cj`, `kernel/src/record/record.cj`, `kernel/src/test/record_test.cj`

- [ ] **Step 1: 校准** 打开 SDK 的 std.unittest 文档，确认测试声明与断言写法（`@Test` + 断言函数），后续测试统一用该写法。

- [ ] **Step 2: 建workspace 并写失败测试**

`kernel/src/test/record_test.cj`：

```cangjie
package kernel.test

import kernel.record.*
import std.unittest.*

@Test
func testColumnLoad() {
    let cols = ArrayList<Column>([Column.Long(42), Column.Double(0.5),
        Column.Str("hi"), Column.Null])
    let r = Record(cols)
    @Assert(r.size() == 4)
    match (r.get(0)) {
        case Long(v) => @Assert(v == 42)
        case _ => @Assert(false)
    }
    @Assert(r.get(3) is Null)   // 按校准后的类型判断语法调整
}
```

`cjpm test` 期望：编译失败（kernel.record 不存在）。

- [ ] **Step 3: 最小实现**

```cangjie
// kernel/src/record/column.cj
package kernel.record

public enum Column {
    | Long(Int64) | Double(Float64) | Str(String)
    | Bytes(Array<Byte>) | Bool(Bool) | Date(DateTime) | Null
}

// kernel/src/record/record.cj
package kernel.record
import std.collection.*

public struct Record {
    let columns: ArrayList<Column>
    public init(cols: ArrayList<Column>) { columns = cols }
    public func size(): Int64 { return columns.size }
    public func get(i: Int64): Column { return columns[i] }
}
```

`cjpm.toml`（workspace，src-layout）按 cjpm 文档初始化，模块名 `kernel`。

- [ ] **Step 4: `cjpm test` 通过**

- [ ] **Step 5: Commit** `git commit -m "kernel: Column/Record 中立行模型 + 单测"`

---

### Task 3: BoundedChannel（tasks.md 3.3，先测后建）

**Files:**
- Create: `kernel/src/channel/bounded_channel.cj`, `kernel/src/test/channel_test.cj`

- [ ] **Step 1: 写失败测试（背压 + 关闭 + 不丢不重）**

```cangjie
package kernel.test

import kernel.channel.*
import kernel.record.*
import std.unittest.*
import std.sync.*
import std.time.*

@Test
func testBoundedBlocksWhenFull() {
    let ch = BoundedChannel(2)
    ch.send(mockRecord(1))
    ch.send(mockRecord(2))
    let start = DateTime.now()
    let fut = spawn { ch.send(mockRecord(3)) }   // 应阻塞
    sleep(Duration.millisecond * 100)
    @Assert(!ch.isClosed())
    // 取走一条后 fut 应能完成
    let got = ch.recv()
    @Assert(got.getOrThrow().get(0) == Column.Long(1)) // 视 Record API 微调
}

@Test
func testCloseDeliversEof() {
    let ch = BoundedChannel(2)
    ch.send(mockRecord(1))
    ch.close()
    @Assert(ch.recv().getOrThrow() != None)  // 先取到数据
    @Assert(ch.recv() == None)               // 关闭后 EOF 返回 None
}

func mockRecord(id: Int64): Record {
    return Record(ArrayList<Column>([Column.Long(id)]))
}
```

语义约定：`recv()` 返回 `Option<Record>`；`None` 即 EOF；`close` 后 send 抛错。缓冲区残留行在 close 后仍可 recv 直至取空。

- [ ] **Step 2: `cjpm test` 确认失败**

- [ ] **Step 3: 实现**

基于 `std.sync.Mutex` + 条件同步原语（按 SDK 实际类名，如 Condition/MultiCondSync）实现环形数组或 ArrayList 缓冲 + close 标志。若标准库已提供并发有界队列则薄封装之，语义测试保持不变。

- [ ] **Step 4: `cjpm test` 全绿（含 Task 2 用例回归）**

- [ ] **Step 5: Commit** `git commit -m "kernel: 有界 Channel（背压/关闭EOF/不丢不重）"`

---

### Task 4: Reader/Writer SPI + 假实现（tasks.md 3.4）

**Files:**
- Create: `kernel/src/spi/spi.cj`, `kernel/src/test/spi_test.cj`

- [ ] **Step 1: 失败测试（单侧替换）**

```cangjie
@Test
func testReplaceOneSide() {
    // 内存 Reader 产 100 行 → Channel → 内存 Writer 消费
    // 再换 FileMockReader 跑一遍：Writer 不变仍正确计数
}
```

- [ ] **Step 2: 实现**

```cangjie
// kernel/src/spi/spi.cj
package kernel.spi
import kernel.channel.*

public interface Reader {
    func read(out: Channel): Unit        // 完成后必须 out.close()
}
public interface Writer {
    func write(in: Channel): WriteStat   // recv 到 None 退出
}
public struct WriteStat {
    public let ok: Int64
    public let dirty: Int64
    public init(ok: Int64, dirty: Int64) { this.ok = ok; this.dirty = dirty }
}
```

假实现：`MemoryReader(n)` 产 n 行；`MemoryWriter()` 计数并可在第 k 行产生脏行（供 Task 5 脏行场景复用）。

- [ ] **Step 3: 测试通过后 Commit** `git commit -m "kernel: Reader/Writer SPI 与内存假实现"`

---

### Task 5: JobRunner + 统计（tasks.md 3.5/3.7 的执行器部分）

**Files:**
- Create: `kernel/src/job/job_runner.cj`, `kernel/src/test/job_test.cj`

- [ ] **Step 1: 失败测试**：JobRunner(MemoryReader(100), MemoryWriter()) 跑完 → `stat.ok == 100, stat.dirty == 0`；脏行注入变体 → `dirty == 注入数, ok == 100 - 注入数`，作业不抛错。

- [ ] **Step 2: 实现**：`spawn` reader 与 writer 两个协程，join 后汇总 WriteStat + 耗时（`DateTime.now()` 差值，毫秒）。

- [ ] **Step 3: 测试通过，Commit** `git commit -m "kernel: JobRunner 双协程流水线与统计"`

---

### Task 6: driver-api 定义（tasks.md 2.2）

**Files:**
- Create: `drivers/driver-api/cjpm.toml`, `drivers/driver-api/src/api.cj`, `drivers/driver-api/src/error.cj`

- [ ] **Step 1: 实现（接口即规格，编译即验证）**

```cangjie
// drivers/driver-api/src/error.cj
package driver.api
public enum DbError {
    | NetworkUnreachable(String) | AuthFailed(String)
    | ProtocolError(String) | QueryError(String)
}

// drivers/driver-api/src/api.cj
package driver.api
public struct ConnConfig {
    public let driver: String        // "mysql" | "pg" | "opengauss"
    public let host: String; public let port: UInt16
    public let database: String; public let user: String
    public let password: String      // 日志输出必须脱敏
}
public struct ColumnDef { public let name: String; public let typeName: String }
public struct RowSet { public let columns: Array<ColumnDef>; public let rows: Array<Array<driver.api.RawCell>> }
public enum RawCell { | I64(Int64) | F64(Float64) | S(String) | B(Array<Byte>) | N }

public interface Connection {
    func query(sql: String): Result<RowSet, DbError>
    func listSchemas(): Result<Array<String>, DbError>
    func listTables(schema: String): Result<Array<String>, DbError>
    func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError>
    func close(): Unit    // 幂等
}
public interface DbDriver { func connect(cfg: ConnConfig): Result<Connection, DbError> }
```

（RawCell 与 kernel.record.Column 的映射函数放各适配器——见 Task 7。）

- [ ] **Step 2: `cjpm build` 通过，Commit** `git commit -m "drivers: driver-api 统一接口与四类错误"`

---

### Task 7: MySQL 适配器（tasks.md 2.1–2.3）

**Files:**
- Create: `drivers/driver-mysql/{cjpm.toml, src/mysql_driver.cj, src/cell_map.cj, src/test/mysql_it.cj}`

- [ ] **Step 1: 引入并校准 mysqlclient4cj**：通过中心仓（cjpm 依赖）或源码依赖引入；阅读其 README/示例确认连接、查询、元数据 API 与异常类型。把「版本 + 接入方式 + 关键 API」记入 `env/driver-notes.md`。

- [ ] **Step 2: L2 集成测试（Docker 前置，无 Docker 显式跳过）**

```cangjie
@Test
func testConnectQueryMeta() {
    let drv = MysqlDriver()
    let conn = (drv.connect(cfg("mysql", "127.0.0.1", 3306u16, ...)).getOrThrow())
    defer { conn.close() }
    let rs = (conn.query("SELECT id, name, score, note FROM src_users WHERE id <= 10").getOrThrow())
    @Assert(rs.rows.size == 10)
    // NULL note 行（id=100 的行）单独验证 RawCell.N 装载
    @Assert((conn.listTables("canglin_src").getOrThrow()).contains("src_users"))
    // 错误分类见 Task 9 统一测试
}
```

- [ ] **Step 3: 适配器实现**：connect/query/元数据映射到 driver-api；`cell_map.cj` 完成 RawCell→Column（BIGINT→Long、DOUBLE→Double、VARCHAR/TEXT→Str、DATETIME→Date、NULL→Null）。连接错误按驱动异常信息归类到四类 DbError。

- [ ] **Step 4: `cjpm test`（Docker 在跑）通过，Commit** `git commit -m "drivers: MySQL 适配器（连通/查询/元数据/NULL装载）"`

---

### Task 8: PG/openGauss 适配器（tasks.md 2.4）

**Files:**
- Create: `drivers/driver-pg/{cjpm.toml, src/pg_driver.cj, src/cell_map.cj, src/test/pg_it.cj}`

同 Task 7 口径：opengauss-driver 引入 → 校准 API → L2 测试（PG 5432、openGauss 5433 两套 ConnConfig 跑同一测试函数）→ 映射实现 → Commit `git commit -m "drivers: PG/openGauss 适配器"`。openGauss 端口/密码策略差异记入 `env/driver-notes.md`。

---

### Task 9: 错误分类 + 关闭幂等（tasks.md 2.5）

**Files:**
- Modify: `drivers/driver-mysql/src/test/mysql_it.cj`, `drivers/driver-pg/src/test/pg_it.cj`

- [ ] **Step 1: 失败测试（对两适配器各跑）**

```cangjie
@Test
func testErrorClassification() {
    // 错密码 → AuthFailed
    // 127.0.0.1:59999 不可达端口 → NetworkUnreachable
    // SELECT * FROM not_exist → QueryError
}
@Test
func testCloseIdempotent() {
    let conn = ...
    conn.close(); conn.close()   // 不抛异常即通过
}
```

- [ ] **Step 2: 按需在适配器补错误归类映射 → 测试通过 → Commit** `git commit -m "drivers: 错误四分类与关闭幂等"`

---

### Task 10: 万行同步 CLI（tasks.md 3.5–3.7 验证收口）

**Files:**
- Create: `cli/{cjpm.toml, src/main.cj}`
- Modify: 无（kernel/drivers 已备）

- [ ] **Step 1: 实现**：MySQLReader（分页 SELECT id<=10000 ORDER BY id，每批 500 行 → Record → Channel）+ PgWriter（INSERT，万行用事务分批提交）；main 组装 JobRunner 跑完打印：`ok/dirty/耗时ms/吞吐行每秒`。CLI 参数从 env 读连接串。

- [ ] **Step 2: 冒烟**

```bash
cd cli && cjpm run -- sync
# 期望输出 ok=10000 dirty=0，吞吐记录进 env/driver-notes.md
psql 验证: docker exec -i $(cd ../env && docker compose ps -q pg) psql -U postgres \
  -d canglin_src -c "SELECT COUNT(*) FROM dst_users;"   # 期望 10000
```

- [ ] **Step 3: 脏行变体**：源表 UPDATE 50 行 note 为非法长文本（超 dst 列宽不可行则改用类型错配方案：临时表实验），验证 `dirty=50, ok=9950`，作业不中断。

- [ ] **Step 4: Commit** `git commit -m "cli: MySQL→PG 万行同步冒烟（吞吐基线）"`

---

### Task 11: app 三栏壳（tasks.md 4.1）

**Files:**
- Create: `app/`（DevEco Empty Ability(Cangjie) 工程生成后入库，裁剪示例代码）

- [ ] **Step 1: DevEco 新建仓颉工程**（应用名 Canglin），三栏首页：

```cangjie
// 结构示意——以 DevEco 生成的仓颉 UI 模板语法为准
Row {
    Column { Text("连接/对象") }.width("20%").backgroundColor(0xF2F3F5)
    Column { /* 编辑区占位，Task 12 换 webview */ Text("编辑区") }.layoutWeight(1)
    Column { Text("结果区") }.width("30%").backgroundColor(0xF2F3F5)
}.height("100%")
```

- [ ] **Step 2: 模拟器/预览器验证三栏不重叠 → Commit** `git commit -m "app: ArkUI-Cangjie 三栏桌面壳"`

---

### Task 12: Monaco + 桥接（tasks.md 4.2–4.3）

**Files:**
- Create: `app/entry/src/main/resources/rawfile/monaco/`（monaco-editor min 版资产 + index.html）
- Modify: app 首页（编辑区换 Web 组件）、桥接处理

- [ ] **Step 1: 下载 monaco-editor 发行包**（0.5x min 版），`package.json`+dist 精简放入 rawfile；index.html 内联初始化，`monaco.editor.create` 绑定 SQL 高亮，postMessage 桥约定 `{id, type: "exec", payload}`。

- [ ] **Step 2: Web 组件加载 `$rawfile('monaco/index.html')`，注册 message 回调**：收到 exec → 回发 `{id, type:"execResult", payload: <原文回显>}`。

- [ ] **Step 3: 手测**：输入 SQL 高亮正常、编辑可改、触发 exec 后编辑器内/日志中确认回显一致；记录冷启动耗时。

- [ ] **Step 4: Commit** `git commit -m "app: webview 内嵌 Monaco（离线）与 exec 桥接回显"`

---

### Task 13: POC 结论汇总（tasks.md 5.1–5.2）

**Files:**
- Create: `docs/superpowers/specs/2026-11-09-poc-conclusion.md`

- [ ] **Step 1: 写结论**：三验证点通过矩阵（三库×建连/查询/元数据/错误/关闭）、吞吐基线（行/秒、耗时、粗测内存）、冷启动耗时、驱动成熟度评估（是否触发 fork 预案）、五层架构 go/no-go 意见与修正项。

- [ ] **Step 2: Commit** `git commit -m "docs: POC 技术验证结论与 Phase 1 go/no-go 建议"`

---

## Self-Review 记录

- Spec 覆盖：driver-connectivity 4 需求→Task 6-10；sync-kernel 4 需求→Task 2-5,10；desktop-shell 2 需求→Task 11-12 ✓
- tasks.md 22 项全部映射到 Task 1-13（1.1→T1S1, 1.2→T1S2, 1.3→T1S3-4, 2.x→T6-9, 3.x→T2-5/T10, 4.x→T11-12, 5.x→T13）✓
- 类型一致性：Channel.recv 返回 Option<Record>、Reader.close 语义、WriteStat{ok,dirty} 全文一致 ✓
- 诚实的未知项均以「校准」步骤显式暴露（unittest 断言、并发原语、驱动 API、ArkUI-Cangjie 模板语法），非占位符
