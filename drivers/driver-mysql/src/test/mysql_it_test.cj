package mysql_driver.test

import std.unittest.*
import driver.api.*
import driver.testkit.*
import kernel.record.*
import mysql_driver.*

// L2 集成测试：需要 127.0.0.1:3306 上的 MySQL 8 实例
// （env/docker-compose.yml 的 mysql 服务：root/口令，库 canglin_src，
//  表 src_users 万行、note 每 100 行一个 NULL）。
// 实例不可用时本文件用例直接失败并给出环境提示——不做静默跳过，
// 避免 cjpm test 出现「TOTAL>0 但一条没跑」的假绿。
//
// 注：本仓颉版本（1.1.0-beta.25）没有 defer 语法，连接在用例末尾显式关闭。

const MYSQL_HOST = "127.0.0.1"
const MYSQL_PORT: UInt16 = 3306u16
const MYSQL_SCHEMA = "canglin_src"
const MYSQL_USER = "root"
const MYSQL_PASSWORD = "canglin123"
const MYSQL_TABLE = "src_users"
// 保留域名（RFC 2606 .invalid 永不可解析）——用于「不可达主机」场景，
// 解析立即失败，不会像不可路由 IP 那样等 TCP 超时。
const UNRESOLVABLE_HOST = "no-such-host.invalid"

func mysqlConfig(): ConnConfig {
    return ConnConfig("mysql", MYSQL_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD)
}

func connectOrFail(): Connection {
    return match (MysqlDriver().connect(mysqlConfig())) {
        case Ok(c) => c
        case Err(e) => @Fail("L2 需要 ${MYSQL_HOST}:${MYSQL_PORT} 上的 MySQL 实例（用户 ${MYSQL_USER}，库 ${MYSQL_SCHEMA}）；建连失败：${e}")
    }
}

func queryOrFail(conn: Connection, sql: String): RowSet {
    return match (conn.query(sql)) {
        case Ok(rs) => rs
        case Err(e) => @Fail("查询失败（${sql}）：${e}")
    }
}

// 错误类别的四个判定来自 driver.testkit（与 PG 适配器共用同一口径），
// 本文件不再自带副本，避免两份实现各自漂移。

// ---- 建连 / 查询（L2） ----

@Test
func testConnectAndQueryRowShape() {
    let conn = connectOrFail()

    let rs = queryOrFail(conn, "SELECT id, name, score, note, created_at FROM ${MYSQL_TABLE} ORDER BY id LIMIT 3")
    @Assert(rs.rows.size == 3)
    @Assert(rs.columns.size == 5)

    // 列名与类型（驱动类型名 → 数据库类型名）
    @Assert(rs.columns[0].name == "id")
    @Assert(rs.columns[0].typeName == "BIGINT")
    @Assert(rs.columns[1].name == "name")
    @Assert(rs.columns[1].typeName == "VARCHAR")
    @Assert(rs.columns[2].typeName == "DOUBLE")
    @Assert(rs.columns[3].typeName == "TEXT")
    @Assert(rs.columns[4].typeName == "DATETIME")

    // 首行取值：整型 / 字符串 / 浮点 / 文本
    match (rs.rows[0][0]) {
        case I64(v) => @Assert(v == 1)
        case other => @Fail("id 应为 I64，实际 ${other}")
    }
    match (rs.rows[0][1]) {
        case S(v) => @Assert(v == "user_00001")
        case other => @Fail("name 应为 S，实际 ${other}")
    }
    match (rs.rows[0][2]) {
        case F64(v) => @Assert(v >= 0.0 && v <= 100.0)
        case other => @Fail("score 应为 F64，实际 ${other}")
    }
    match (rs.rows[0][3]) {
        case S(v) => @Assert(v == "note for user_1")
        case other => @Fail("note 应为 S，实际 ${other}")
    }
    // created_at 是 DATETIME：适配器以文本承载，格式 yyyy-MM-dd HH:mm:ss
    match (rs.rows[0][4]) {
        case S(v) => @Assert(v.size == 19)
        case other => @Fail("created_at 应为 S，实际 ${other}")
    }

    conn.close()
}

@Test
func testNullNoteLoadsAsNull() {
    let conn = connectOrFail()

    let rs = queryOrFail(conn, "SELECT id, note FROM ${MYSQL_TABLE} WHERE id = 100")
    @Assert(rs.rows.size == 1)
    match (rs.rows[0][0]) {
        case I64(v) => @Assert(v == 100)
        case other => @Fail("id 应为 I64，实际 ${other}")
    }
    // NULL note → RawCell.N
    match (rs.rows[0][1]) {
        case N => @Assert(true)
        case other => @Fail("id=100 的 note 应为 NULL，实际 ${other}")
    }
    // 映射层：NULL → Column.Null
    match (mapCell(rs.rows[0][1], rs.columns[1].typeName)) {
        case Column.Null => @Assert(true)
        case other => @Fail("映射后应为 Column.Null，实际 ${other}")
    }

    conn.close()
}

@Test
func testSeedVolume() {
    let conn = connectOrFail()

    let total = queryOrFail(conn, "SELECT COUNT(*) FROM ${MYSQL_TABLE}")
    match (total.rows[0][0]) {
        case I64(v) => @Assert(v == 10000)
        case other => @Fail("总行数应为 I64，实际 ${other}")
    }
    let nulls = queryOrFail(conn, "SELECT COUNT(*) FROM ${MYSQL_TABLE} WHERE note IS NULL")
    match (nulls.rows[0][0]) {
        case I64(v) => @Assert(v == 100)
        case other => @Fail("NULL 行数应为 I64，实际 ${other}")
    }

    conn.close()
}

// ---- 元数据（L2） ----

@Test
func testMetadataSchemasTablesColumns() {
    let conn = connectOrFail()

    let schemas = match (conn.listSchemas()) {
        case Ok(v) => v
        case Err(e) => @Fail("listSchemas 失败：${e}")
    }
    @Assert(schemas.contains(MYSQL_SCHEMA))

    let tables = match (conn.listTables(MYSQL_SCHEMA)) {
        case Ok(v) => v
        case Err(e) => @Fail("listTables 失败：${e}")
    }
    @Assert(tables.contains(MYSQL_TABLE))

    let cols = match (conn.tableColumns(MYSQL_SCHEMA, MYSQL_TABLE)) {
        case Ok(v) => v
        case Err(e) => @Fail("tableColumns 失败：${e}")
    }
    // 与 env/init/01-mysql.sql 的 DDL 一致
    @Assert(cols.size == 5)
    @Assert(cols[0] == ColumnDef("id", "BIGINT"))
    @Assert(cols[1] == ColumnDef("name", "VARCHAR"))
    @Assert(cols[2] == ColumnDef("score", "DOUBLE"))
    @Assert(cols[3] == ColumnDef("note", "TEXT"))
    @Assert(cols[4] == ColumnDef("created_at", "DATETIME"))

    conn.close()
}

// ---- RawCell → Column 映射（单元） ----

@Test
func testRawCellToColumnMapping() {
    match (mapCell(I64(42), "BIGINT")) {
        case Column.Long(v) => @Assert(v == 42)
        case other => @Fail("BIGINT 应映射为 Long，实际 ${other}")
    }
    match (mapCell(F64(3.5), "DOUBLE")) {
        case Column.Double(v) => @Assert(v == 3.5)
        case other => @Fail("DOUBLE 应映射为 Double，实际 ${other}")
    }
    match (mapCell(S("alice"), "VARCHAR")) {
        case Column.Str(v) => @Assert(v == "alice")
        case other => @Fail("VARCHAR 应映射为 Str，实际 ${other}")
    }
    match (mapCell(S("note for user_1"), "TEXT")) {
        case Column.Str(v) => @Assert(v == "note for user_1")
        case other => @Fail("TEXT 应映射为 Str，实际 ${other}")
    }
    match (mapCell(S("2026-11-10 18:07:13"), "DATETIME")) {
        case Column.Date(d) =>
            @Assert(d.year == 2026)
            @Assert(d.hour == 18)
            @Assert(d.minute == 7)
        case other => @Fail("DATETIME 应映射为 Date，实际 ${other}")
    }
    match (mapCell(N, "TEXT")) {
        case Column.Null => @Assert(true)
        case other => @Fail("NULL 应映射为 Null，实际 ${other}")
    }
    match (mapCell(B([1, 2, 3]), "BLOB")) {
        case Column.Bytes(v) => @Assert(v.size == 3)
        case other => @Fail("字节列应映射为 Bytes，实际 ${other}")
    }
}

@Test
func testMapRowSetFromLiveQuery() {
    let conn = connectOrFail()

    let rs = queryOrFail(conn, "SELECT id, name, score, note, created_at FROM ${MYSQL_TABLE} WHERE id = 100")
    let records = mapRowSet(rs)
    @Assert(records.size == 1)
    let rec = records[0]
    @Assert(rec.size() == 5)

    match (rec.get(0)) {
        case Column.Long(v) => @Assert(v == 100)
        case other => @Fail("id 应映射为 Long，实际 ${other}")
    }
    match (rec.get(1)) {
        case Column.Str(v) => @Assert(v == "user_00100")
        case other => @Fail("name 应映射为 Str，实际 ${other}")
    }
    // id=100 的 note 是 NULL
    match (rec.get(3)) {
        case Column.Null => @Assert(true)
        case other => @Fail("note 应映射为 Null，实际 ${other}")
    }
    match (rec.get(4)) {
        case Column.Date(_) => @Assert(true)
        case other => @Fail("created_at 应映射为 Date，实际 ${other}")
    }

    conn.close()
}

@Test
func testDriverTypeNameToSqlTypeName() {
    @Assert(sqlTypeName("Int64") == "BIGINT")
    @Assert(sqlTypeName("Float64") == "DOUBLE")
    @Assert(sqlTypeName("String") == "VARCHAR")
    @Assert(sqlTypeName("DateTime") == "DATETIME")
    @Assert(sqlTypeName("Array<Byte>") == "TEXT")
}

// ---- 错误四分类 ----

@Test
func testErrorClassificationByMessage() {
    @Assert(isAuthFailed(classifyDbError("Access denied for user 'root'@'localhost' (using password: YES)")))
    @Assert(isNetworkUnreachable(classifyDbError("Failed to connect 61: Connection refused.")))
    @Assert(isNetworkUnreachable(classifyDbError("connect timeout")))
    // 域名解析失败同属网络不可达（PT9 补：原先误落 ProtocolError）
    @Assert(isNetworkUnreachable(classifyDbError("Failed to resolve address no-such-host.invalid.")))
    @Assert(isQueryError(classifyDbError("Table 'canglin_src.no_such_table_xyz' doesn't exist, errorCode: 0")))
    @Assert(isProtocolError(classifyDbError("unexpected packet sequence")))
}

@Test
func testCanonicalErrorMessageTable() {
    // 跨适配器共用的口径表（driver.testkit）：同一句文案在 MySQL 与 PG 适配器
    // 必须落到同一类别，任何一边改了归类映射而没同步另一边，这里就红。
    for (c in canonicalErrorCases()) {
        let actual = categoryOf(classifyDbError(c.message))
        @Assert(actual == c.category)
    }
}

@Test
func testErrorClassificationAgainstLiveServer() {
    // 走 driver.testkit 的驱动无关契约探针：与 PG 适配器同一份断言口径。
    let report = probeErrorClassification(
        MysqlDriver(),
        mysqlConfig(),
        // 错误口令 → AuthFailed
        ConnConfig("mysql", MYSQL_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, "wrong-password"),
        // 不可达端口（本地无人监听）→ NetworkUnreachable
        ConnConfig("mysql", MYSQL_HOST, 59999u16, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD),
        // 不可达主机（域名解析失败）→ NetworkUnreachable
        ConnConfig("mysql", UNRESOLVABLE_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD),
        // 不存在的表 → QueryError
        "SELECT * FROM no_such_table_xyz"
    )
    @Assert(report.connected)

    match (report.wrongPassword) {
        case Some(e) => @Assert(isAuthFailed(e))
        case None => @Fail("错误口令不应建连成功")
    }
    match (report.unreachablePort) {
        case Some(e) => @Assert(isNetworkUnreachable(e))
        case None => @Fail("不可达端口不应建连成功")
    }
    match (report.unreachableHost) {
        case Some(e) => @Assert(isNetworkUnreachable(e))
        case None => @Fail("不可达主机不应建连成功")
    }
    match (report.missingTable) {
        case Some(e) => @Assert(isQueryError(e))
        case None => @Fail("不存在的表不应查询成功")
    }
}

// ---- 关闭幂等 ----

@Test
func testCloseIdempotent() {
    let report = probeCloseIdempotency(MysqlDriver(), mysqlConfig())
    @Assert(report.connected)
    @Assert(!report.firstCloseThrew)
    @Assert(!report.secondCloseThrew)
    // 关闭后连接以错误结果回应，而不是抛异常或返回成功
    @Assert(report.queryAfterCloseFailed)
    @Assert(report.metadataAfterCloseFailed)
}

// ---- 口令脱敏 ----

@Test
func testPasswordNotExposedInLogText() {
    let cfg = ConnConfig("mysql", MYSQL_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD)
    let target = maskedTarget(cfg)
    @Assert(!target.contains(MYSQL_PASSWORD))
    @Assert(!cfg.toString().contains(MYSQL_PASSWORD))
    @Assert(target.contains(MYSQL_HOST))
    @Assert(target.contains(MYSQL_SCHEMA))
    @Assert(target.contains(MYSQL_USER))
}
