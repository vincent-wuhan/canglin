package pgdriver.test

import std.convert.*
import std.env.getVariable
import std.fs.*
import std.time.*
import std.unittest.*
import driver.api.*
import driver.testkit.*
import pgdriver.*

// PT8 集成测试：同一份端点无关用例体，对 PostgreSQL(5432) 与 openGauss(5433)
// 两个端点各跑一次（issue 要求「同一测试函数跑双端点」）。
//
// 端点参数走环境变量，默认对齐 env/docker-compose.yml：
//   CANGLIN_PG_HOST / CANGLIN_PG_PORT / CANGLIN_PG_DATABASE / CANGLIN_PG_USER / CANGLIN_PG_PASSWORD
//   CANGLIN_OPENGAUSS_HOST / CANGLIN_OPENGAUSS_PORT / CANGLIN_OPENGAUSS_DATABASE
//   CANGLIN_OPENGAUSS_USER / CANGLIN_OPENGAUSS_PASSWORD
//
// setup 自带建表/插数：使用 PT8 独立表 pt8_probe_users，不写 dst_users（PT10 保留）。
//
// 错误分类与关闭幂等走 driver.testkit 的驱动无关契约探针（PT9 交付），
// 与 MySQL 适配器共用同一份断言口径。
//
// 端点是否真跑过必须有据可查：std.unittest 会捕获用例里的 stdout/stderr 且通过时不回显
// （PT11 实测），故 [RUN]/[DONE]/[SKIP] 声明一律**落盘**到 target/pg-driver-it.log
// （路径可用 CANGLIN_SKIP_LOG 改），stdout 只作兜底。

private const PROBE_TABLE = "pt8_probe_users"
private const UNRESOLVABLE_HOST = "no-such-host.invalid"

// 端点运行/跳过声明的落盘路径：CANGLIN_SKIP_LOG 指定，缺省写到 target/pg-driver-it.log。
private func itLogPath(): String {
    return match (getVariable("CANGLIN_SKIP_LOG")) {
        case Some(p) => p
        case None => "target/pg-driver-it.log"
    }
}

/// 追加一行运行声明到日志文件。
///
/// std.unittest 通过时不回显 stdout，所以声明必须落盘才留得住痕迹。
private func appendItLog(line: String): Unit {
    let path = itLogPath()
    try {
        File.appendTo(path, (line + "\n").toArray())
    } catch (e: Exception) {
        println("[WARN] 声明落盘失败（${path}）：${e.message}")
    }
}

/// 同时落盘并打印一行运行声明。
private func declare(line: String): Unit {
    appendItLog(line)
    println(line)
}

// ---------------------------------------------------------------------------
// 端点差异画像：DATE 列
//
// 真机实测（PostgreSQL 14 与 openGauss 5.0.0）两个端点对 DATE 的呈现**一致**：
//   - 类型 OID 都是 1082（date），query() 路径类型名都是 DATE，
//     tableColumns() 路径 information_schema 的 data_type/udt_name 都是 date；
//   - 取值文本都是 "2026-01-02"，openGauss 侧没有 " 00:00:00" 后缀；
//   - openGauss 的 information_schema.columns 对 DATE 列给出
//     data_type=date、datetime_precision=0，format_type() 也是 date。
//
// 即：先前「openGauss 把 DATE 实现为 timestamp(0)、类型名 TIMESTAMP」的判断
// 在 openGauss 5.0.0 上不成立，**适配器无需做任何 DATE 归一化**。
//
// 这里仍保留按端点给断言的口径（两个常量当前取值相同）：断言与端点画像一一对应，
// 若后续换用确实把 DATE 折叠成 timestamp 的 openGauss 版本，只需改 OG_* 两个常量，
// 不必改断言体。详见 env/driver-notes.md「DATE 端点画像实测」一节。
// ---------------------------------------------------------------------------

private const PG_DATE_TYPE = "DATE"
private const PG_DATE_VALUE = "2026-01-02"
private const OG_DATE_TYPE = "DATE"
private const OG_DATE_VALUE = "2026-01-02"

private func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

private func envPort(name: String, fallback: UInt16): UInt16 {
    match (getVariable(name)) {
        case Some(v) => return UInt16.tryParse(v.trimAscii()) ?? fallback
        case None => return fallback
    }
}

private func pgConfig(): ConnConfig {
    ConnConfig(
        "pg",
        envOr("CANGLIN_PG_HOST", "127.0.0.1"),
        envPort("CANGLIN_PG_PORT", 5432u16),
        envOr("CANGLIN_PG_DATABASE", "canglin_src"),
        envOr("CANGLIN_PG_USER", "postgres"),
        envOr("CANGLIN_PG_PASSWORD", "canglin123")
    )
}

private func openGaussConfig(): ConnConfig {
    ConnConfig(
        "opengauss",
        envOr("CANGLIN_OPENGAUSS_HOST", "127.0.0.1"),
        envPort("CANGLIN_OPENGAUSS_PORT", 5433u16),
        envOr("CANGLIN_OPENGAUSS_DATABASE", "canglin_src"),
        envOr("CANGLIN_OPENGAUSS_USER", "canglin"),
        envOr("CANGLIN_OPENGAUSS_PASSWORD", "Canglin@123")
    )
}

// ---------------------------------------------------------------------------
// 纯函数单测：不依赖数据库，始终可跑
// ---------------------------------------------------------------------------

@Test
func testCanonicalTypeName(): Unit {
    @Assert(canonicalTypeName("SqlBool") == "BOOLEAN")
    @Assert(canonicalTypeName("SqlVarBinary") == "BYTEA")
    @Assert(canonicalTypeName("SqlChar") == "CHAR")
    @Assert(canonicalTypeName("SqlSmallInt") == "SMALLINT")
    @Assert(canonicalTypeName("SqlInteger") == "INTEGER")
    @Assert(canonicalTypeName("SqlBigInt") == "BIGINT")
    @Assert(canonicalTypeName("SqlVarchar") == "VARCHAR")
    @Assert(canonicalTypeName("SqlReal") == "REAL")
    @Assert(canonicalTypeName("SqlDouble") == "DOUBLE PRECISION")
    @Assert(canonicalTypeName("SqlDecimal") == "NUMERIC")
    @Assert(canonicalTypeName("SqlDate") == "DATE")
    @Assert(canonicalTypeName("SqlTimestamp") == "TIMESTAMP")
    @Assert(canonicalTypeName("Array<SqlBigInt>") == "BIGINT[]")
}

@Test
func testDbTypeName(): Unit {
    @Assert(dbTypeName("bigint", "int8") == "BIGINT")
    @Assert(dbTypeName("character varying", "varchar") == "VARCHAR")
    @Assert(dbTypeName("text", "text") == "TEXT")
    @Assert(dbTypeName("double precision", "float8") == "DOUBLE PRECISION")
    @Assert(dbTypeName("numeric", "numeric") == "NUMERIC")
    @Assert(dbTypeName("bytea", "bytea") == "BYTEA")
    @Assert(dbTypeName("timestamp without time zone", "timestamp") == "TIMESTAMP")
    @Assert(dbTypeName("ARRAY", "_int8") == "BIGINT[]")
}

@Test
func testClassifyErrorCategories(): Unit {
    // 认证失败：服务端 FATAL + SQLSTATE 28P01
    @Assert(isAuthFailed(classifyError("FATAL: password authentication failed for user \"postgres\" (SQLSTATE 28P01)")))
    // 账号不存在（PT9 交接表：role "..." does not exist 归 AuthFailed）
    @Assert(isAuthFailed(classifyError("FATAL: role \"canglin\" does not exist")))
    @Assert(isAuthFailed(classifyError("FATAL: invalid password for user \"canglin\"")))
    // 目标不可达
    @Assert(isNetworkUnreachable(classifyError("127.0.0.1:59999: Connection refused")))
    @Assert(isNetworkUnreachable(classifyError("could not connect to server")))
    @Assert(isNetworkUnreachable(classifyError("Name or service not known")))
    // 域名解析失败同属网络不可达（与 MySQL 适配器同一口径）
    @Assert(isNetworkUnreachable(classifyError(
        "no-such-host.invalid:5432: SocketException: Failed to resolve address no-such-host.invalid.")))
    // SQL 本身出错（relation 不存在不能被误判成账号问题）
    @Assert(isQueryError(classifyError("ERROR: relation \"pt8_missing_xyz\" does not exist (SQLSTATE 42P01)")))
    // 协议层不兼容
    @Assert(isProtocolError(classifyError("not support message(B) in startup stage")))
}

@Test
func testPasswordNeverLeaksIntoMessages(): Unit {
    // spec：连接参数中的密码不得写入日志。适配器在把上游异常收敛成 DbError 前
    // 会把口令替换掉，这里锁定该行为。
    @Assert(scrub("connect failed for canglin123", "canglin123") == "connect failed for ***")
    @Assert(scrub("Canglin@123 rejected", "Canglin@123") == "*** rejected")
    @Assert(scrub("nothing to hide", "") == "nothing to hide")
}

// ---------------------------------------------------------------------------
// 端点共享用例体
// ---------------------------------------------------------------------------

/// 端点无关的共享用例体：PG 与 openGauss 两个端点跑同一份断言。
///
/// allowSkip=true：连接阶段判定为「网络不可达」时打印显式 SKIP 声明并跳过
/// （用于 openGauss 容器缺席的环境）；此时该端点的数据断言一条未跑。
/// allowSkip=false：任何连接失败都判为用例失败，避免假成功。
///
/// dateType/dateValue：该端点 DATE 列应有的类型名与取值文本（服务端差异，见文件头画像说明）。
private func runEndpointSuite(
    cfg: ConnConfig,
    label: String,
    allowSkip: Bool,
    dateType: String,
    dateValue: String
): Unit {
    let drv = PgDriver()
    match (drv.connect(cfg)) {
        case Ok(conn) => runSuiteOn(conn, cfg, label, dateType, dateValue)
        case Err(e) => match (e) {
            case NetworkUnreachable(_) =>
                if (allowSkip) {
                    declare("[SKIP] ${DateTime.now()} ${label} 端点 ${cfg.host}:${cfg.port} 不可达：${e}")
                    declare("[SKIP] 该端点本轮数据断言未执行；std.unittest 1.1.0-beta.25 仅有静态 @Skip " +
                        "标记、无运行时 skip 入口，故本用例仍计入框架 PASSED 计数——双端点覆盖待实例可达后重跑")
                    return
                }
                @Fail("${label} 端点不可达：${e}")
            case _ => @Fail("${label} 端点连接失败：${e}")
        }
    }
}

private func runSuiteOn(
    conn: Connection,
    cfg: ConnConfig,
    label: String,
    dateType: String,
    dateValue: String
): Unit {
    declare("[RUN ] ${DateTime.now()} ${label} 端点 ${cfg.host}:${cfg.port} 共享用例开始")

    // --- setup：PT8 独立表，不写 dst_users（PT10 保留） ---
    execOk(conn, "DROP TABLE IF EXISTS ${PROBE_TABLE}")
    execOk(conn, "CREATE TABLE ${PROBE_TABLE} (" +
        "id BIGINT PRIMARY KEY, name VARCHAR(64), score DOUBLE PRECISION, " +
        "ratio NUMERIC(10,2), active BOOLEAN, born DATE, payload BYTEA, note TEXT)")
    execOk(conn, "INSERT INTO ${PROBE_TABLE} " +
        "(id, name, score, ratio, active, born, payload, note) VALUES " +
        "(1, 'alice', 88.5, 12.25, TRUE, DATE '2026-01-02', decode('0102', 'hex'), 'first'), " +
        "(2, 'bob', 77.25, 8.50, FALSE, DATE '2026-02-03', decode('0304', 'hex'), 'second'), " +
        "(3, NULL, 66.0, 1.00, TRUE, DATE '2026-03-04', NULL, NULL)")

    // --- 查询行集与列类型 ---
    var rs = RowSet(Array<ColumnDef>(), Array<Array<RawCell>>())
    match (conn.query(
        "SELECT id, name, score, ratio, active, born, payload, note FROM ${PROBE_TABLE} ORDER BY id")) {
        case Ok(r) => rs = r
        case Err(e) => @Fail("${label} 查询失败：${e}")
    }

    @Assert(rs.columns.size == 8)
    @Assert(rs.columns[0].name == "id")
    @Assert(rs.columns[0].typeName == "BIGINT")
    @Assert(rs.columns[1].name == "name")
    @Assert(rs.columns[1].typeName == "VARCHAR")
    @Assert(rs.columns[2].typeName == "DOUBLE PRECISION")
    @Assert(rs.columns[3].typeName == "NUMERIC")
    @Assert(rs.columns[4].typeName == "BOOLEAN")
    @Assert(rs.columns[5].typeName == dateType)
    @Assert(rs.columns[6].typeName == "BYTEA")
    // 上游 oid2typename 把 oid 25(text) 与 1043(varchar) 统一归为 SqlVarchar，
    // 故 query() 路径下 TEXT 列的类型名显示为 VARCHAR；精确类型见 tableColumns 断言。
    @Assert(rs.columns[7].typeName == "VARCHAR")

    @Assert(rs.rows.size == 3)
    expectI64(rs.rows[0][0], 1, "row0.id")
    expectStr(rs.rows[0][1], "alice", "row0.name")
    expectF64(rs.rows[0][2], 88.5, "row0.score")
    expectF64(rs.rows[0][3], 12.25, "row0.ratio")
    expectI64(rs.rows[0][4], 1, "row0.active")
    expectStr(rs.rows[0][5], dateValue, "row0.born")
    expectBytes(rs.rows[0][6], 2, "row0.payload")
    expectStr(rs.rows[0][7], "first", "row0.note")

    expectI64(rs.rows[1][0], 2, "row1.id")
    expectStr(rs.rows[1][1], "bob", "row1.name")
    expectI64(rs.rows[1][4], 0, "row1.active")
    expectBytes(rs.rows[1][6], 2, "row1.payload")

    // NULL 值统一映射为 RawCell.N
    expectNull(rs.rows[2][1], "row2.name")
    expectNull(rs.rows[2][6], "row2.payload")
    expectNull(rs.rows[2][7], "row2.note")
    expectF64(rs.rows[2][2], 66.0, "row2.score")

    // --- 元数据 ---
    var schemas = Array<String>()
    match (conn.listSchemas()) {
        case Ok(s) => schemas = s
        case Err(e) => @Fail("${label} listSchemas 失败：${e}")
    }
    @Assert(schemas.contains("public"))

    var tables = Array<String>()
    match (conn.listTables("public")) {
        case Ok(t) => tables = t
        case Err(e) => @Fail("${label} listTables 失败：${e}")
    }
    @Assert(tables.contains(PROBE_TABLE))

    var cols = Array<ColumnDef>()
    match (conn.tableColumns("public", PROBE_TABLE)) {
        case Ok(c) => cols = c
        case Err(e) => @Fail("${label} tableColumns 失败：${e}")
    }
    @Assert(cols.size == 8)
    @Assert(cols[0] == ColumnDef("id", "BIGINT"))
    @Assert(cols[1] == ColumnDef("name", "VARCHAR"))
    @Assert(cols[2] == ColumnDef("score", "DOUBLE PRECISION"))
    @Assert(cols[3] == ColumnDef("ratio", "NUMERIC"))
    @Assert(cols[4] == ColumnDef("active", "BOOLEAN"))
    @Assert(cols[5] == ColumnDef("born", dateType))
    @Assert(cols[6] == ColumnDef("payload", "BYTEA"))
    @Assert(cols[7] == ColumnDef("note", "TEXT"))

    // --- SQL 错误归类 ---
    match (conn.query("SELECT * FROM pt8_missing_table_zzz")) {
        case Ok(_) => @Fail("${label} 查询不存在的表应当失败")
        case Err(e) => match (e) {
            case QueryError(_) => @Assert(true)
            case _ => @Fail("${label} 期望 QueryError，实际 ${e}")
        }
    }

    // --- 清理（连接关闭前） ---
    match (conn.query("DROP TABLE IF EXISTS ${PROBE_TABLE}")) {
        case Ok(_) => ()
        case Err(e) => declare("[WARN] ${label} 清理 ${PROBE_TABLE} 失败：${e}")
    }

    // --- 关闭幂等 ---
    conn.close()
    conn.close()

    declare("[DONE] ${DateTime.now()} ${label} 端点 ${cfg.host}:${cfg.port} 共享用例通过")
}

private func execOk(conn: Connection, sql: String): Unit {
    match (conn.query(sql)) {
        case Ok(_) => ()
        case Err(e) => @Fail("执行失败：${sql} -> ${e}")
    }
}

private func expectI64(cell: RawCell, expected: Int64, what: String): Unit {
    match (cell) {
        case RawCell.I64(v) => @Assert(v == expected)
        case _ => @Fail("${what}：期望 I64(${expected})，实际 ${cell}")
    }
}

private func expectF64(cell: RawCell, expected: Float64, what: String): Unit {
    match (cell) {
        case RawCell.F64(v) => @Assert(v == expected)
        case _ => @Fail("${what}：期望 F64(${expected})，实际 ${cell}")
    }
}

private func expectStr(cell: RawCell, expected: String, what: String): Unit {
    match (cell) {
        case RawCell.S(v) => @Assert(v == expected)
        case _ => @Fail("${what}：期望 S(${expected})，实际 ${cell}")
    }
}

private func expectBytes(cell: RawCell, expectedSize: Int64, what: String): Unit {
    match (cell) {
        case RawCell.B(v) => @Assert(v.size == expectedSize)
        case _ => @Fail("${what}：期望 B(${expectedSize} 字节)，实际 ${cell}")
    }
}

private func expectNull(cell: RawCell, what: String): Unit {
    match (cell) {
        case RawCell.N => @Assert(true)
        case _ => @Fail("${what}：期望 N，实际 ${cell}")
    }
}

// ---------------------------------------------------------------------------
// 用例入口
// ---------------------------------------------------------------------------

@Test
func testPgAndOpenGaussEndpoints(): Unit {
    // 同一测试函数跑双端点：同一份端点无关用例体（runEndpointSuite）依次跑
    // PostgreSQL(5432) 与 openGauss(5433)，两个端点只有连接参数不同——
    // 对应 spec「上层代码驱动无关：仅连接参数中的驱动类型标识不同，调用代码完全一致」。
    //
    // PG 端点任何连接失败都判失败；openGauss 端点在容器缺席时打印显式 SKIP 声明后跳过。
    //
    // 两个端点当前只有 DATE 列按端点画像给断言（实测两个端点取值相同，见文件头说明）。
    runEndpointSuite(pgConfig(), "PostgreSQL", false, PG_DATE_TYPE, PG_DATE_VALUE)
    runEndpointSuite(openGaussConfig(), "openGauss", true, OG_DATE_TYPE, OG_DATE_VALUE)
}

@Test
func testErrorClassificationAgainstLiveServer(): Unit {
    // 走 driver.testkit 的驱动无关契约探针：与 MySQL 适配器同一份断言口径。
    let good = pgConfig()
    let report = probeErrorClassification(
        PgDriver(),
        good,
        // 错误口令 → AuthFailed
        ConnConfig("pg", good.host, good.port, good.database, good.user, "pt8-wrong-password"),
        // 不可达端口（本地无人监听）→ NetworkUnreachable
        ConnConfig("pg", good.host, 59999u16, good.database, good.user, good.password),
        // 不可达主机（域名解析失败）→ NetworkUnreachable
        ConnConfig("pg", UNRESOLVABLE_HOST, good.port, good.database, good.user, good.password),
        // 不存在的表 → QueryError
        "SELECT * FROM pt8_missing_table_zzz"
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

@Test
func testCloseIdempotent(): Unit {
    let report = probeCloseIdempotency(PgDriver(), pgConfig())
    @Assert(report.connected)
    @Assert(!report.firstCloseThrew)
    @Assert(!report.secondCloseThrew)
    // 关闭后连接以错误结果回应，而不是抛异常或返回成功
    @Assert(report.queryAfterCloseFailed)
    @Assert(report.metadataAfterCloseFailed)
}

@Test
func testPasswordNotExposedInLogText(): Unit {
    let cfg = pgConfig()
    @Assert(!cfg.toString().contains(cfg.password))
    @Assert(!scrub("failed with ${cfg.password}", cfg.password).contains(cfg.password))
    @Assert(cfg.toString().contains(cfg.host))
    @Assert(cfg.toString().contains(cfg.user))
}
