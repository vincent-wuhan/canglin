package driver.test

import driver.api.*
import std.unittest.*

// 内存假连接 / 假驱动：验证 Connection / DbDriver 接口可被实现，
// 且错误分类与关闭幂等语义在上层可表达。真实适配器（PT7/PT8）另行测试。

class FakeConnection <: Connection {
    private var closed: Bool = false
    private var closeCalls: Int64 = 0

    public func query(sql: String): Result<RowSet, DbError> {
        if (closed) {
            return Err(DbError.QueryError("connection closed: ${sql}"))
        }
        let columns = [ColumnDef("id", "BIGINT"), ColumnDef("name", "VARCHAR")]
        let rows = [[RawCell.I64(1), RawCell.S("alice")]]
        return Ok(RowSet(columns, rows))
    }

    public func listSchemas(): Result<Array<String>, DbError> {
        if (closed) {
            return Err(DbError.QueryError("connection closed"))
        }
        return Ok(["canglin_src"])
    }

    public func listTables(schema: String): Result<Array<String>, DbError> {
        if (closed) {
            return Err(DbError.QueryError("connection closed: ${schema}"))
        }
        return Ok(["src_users"])
    }

    public func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError> {
        if (closed) {
            return Err(DbError.QueryError("connection closed: ${schema}.${table}"))
        }
        return Ok([ColumnDef("id", "BIGINT"), ColumnDef("score", "DOUBLE"), ColumnDef("note", "TEXT")])
    }

    public func close(): Unit {
        closeCalls += 1
        closed = true
    }

    public func closeCallCount(): Int64 {
        return closeCalls
    }
}

class FakeDriver <: DbDriver {
    public func connect(cfg: ConnConfig): Result<Connection, DbError> {
        if (cfg.port == 59999u16) {
            return Err(DbError.NetworkUnreachable("connect refused"))
        }
        if (cfg.password == "wrong") {
            return Err(DbError.AuthFailed("access denied"))
        }
        let conn: Connection = FakeConnection()
        return Ok(conn)
    }
}

@Test
func testDbErrorFourCategories() {
    let net = DbError.NetworkUnreachable("host unreachable")
    let auth = DbError.AuthFailed("access denied")
    let proto = DbError.ProtocolError("unexpected packet")
    let query = DbError.QueryError("table not found")

    // 四类错误彼此可区分（spec：返回包含错误类别的失败结果）
    @Assert(net != auth)
    @Assert(net != proto)
    @Assert(net != query)
    @Assert(auth != proto)
    @Assert(auth != query)
    @Assert(proto != query)

    @Assert(net.toString().contains("NetworkUnreachable"))
    @Assert(auth.toString().contains("AuthFailed"))
    @Assert(proto.toString().contains("ProtocolError"))
    @Assert(query.toString().contains("QueryError"))
}

@Test
func testConnConfigMasksPassword() {
    let cfg = ConnConfig("mysql", "127.0.0.1", 3306u16, "canglin_src", "root", "s3cr3t-p@ss")

    @Assert(cfg.driver == "mysql")
    @Assert(cfg.host == "127.0.0.1")
    @Assert(cfg.port == 3306u16)
    @Assert(cfg.database == "canglin_src")
    @Assert(cfg.user == "root")
    @Assert(cfg.password == "s3cr3t-p@ss")

    // 密码不得出现在任何日志文本里（spec：密码不得写入日志）
    let text = cfg.toString()
    @Assert(!text.contains("s3cr3t"))
    @Assert(!text.contains("p@ss"))
    @Assert(text.contains("root"))
    @Assert(text.contains("127.0.0.1"))
    @Assert(text.contains("mysql"))
}

@Test
func testColumnDefAndRowSet() {
    let columns = [ColumnDef("id", "BIGINT"), ColumnDef("name", "VARCHAR")]
    let rows = [
        [RawCell.I64(1), RawCell.S("alice")],
        [RawCell.I64(2), RawCell.S("bob")]
    ]
    let rs = RowSet(columns, rows)

    @Assert(rs.columns.size == 2)
    @Assert(rs.rows.size == 2)
    @Assert(rs.columns[0].name == "id")
    @Assert(rs.columns[0].typeName == "BIGINT")
    @Assert(rs.columns[1].name == "name")
    @Assert(rs.columns[1].typeName == "VARCHAR")
    @Assert(rs.columns == [ColumnDef("id", "BIGINT"), ColumnDef("name", "VARCHAR")])

    match (rs.rows[1][0]) {
        case I64(v) => @Assert(v == 2)
        case _ => @Fail("expected I64 at row 1 col 0")
    }
    match (rs.rows[1][1]) {
        case S(v) => @Assert(v == "bob")
        case _ => @Fail("expected S at row 1 col 1")
    }
}

@Test
func testRawCellFiveVariants() {
    let bytes: Array<Byte> = [1, 2, 3]
    let cells = [RawCell.I64(-42), RawCell.F64(3.5), RawCell.S("hi"), RawCell.B(bytes), RawCell.N]

    @Assert(cells.size == 5)
    match (cells[0]) {
        case I64(v) => @Assert(v == -42)
        case _ => @Fail("expected I64")
    }
    match (cells[1]) {
        case F64(v) => @Assert(v == 3.5)
        case _ => @Fail("expected F64")
    }
    match (cells[2]) {
        case S(v) => @Assert(v == "hi")
        case _ => @Fail("expected S")
    }
    match (cells[3]) {
        case B(v) => @Assert(v.size == 3 && v[0] == 1 && v[2] == 3)
        case _ => @Fail("expected B")
    }
    match (cells[4]) {
        case N => @Assert(true)
        case _ => @Fail("expected N")
    }
}

@Test
func testConnectionContractAndCloseIdempotent() {
    let conn = FakeConnection()

    match (conn.query("SELECT id, name FROM src_users")) {
        case Ok(rs) => @Assert(rs.rows.size == 1 && rs.columns.size == 2)
        case Err(e) => @Fail("query should succeed, got ${e}")
    }
    match (conn.listSchemas()) {
        case Ok(schemas) => @Assert(schemas.contains("canglin_src"))
        case Err(e) => @Fail("listSchemas should succeed, got ${e}")
    }
    match (conn.listTables("canglin_src")) {
        case Ok(tables) => @Assert(tables.contains("src_users"))
        case Err(e) => @Fail("listTables should succeed, got ${e}")
    }
    match (conn.tableColumns("canglin_src", "src_users")) {
        case Ok(cols) => @Assert(cols.size == 3 && cols[2].typeName == "TEXT")
        case Err(e) => @Fail("tableColumns should succeed, got ${e}")
    }

    // close 幂等：重复调用不抛异常
    conn.close()
    conn.close()
    @Assert(conn.closeCallCount() == 2)
}

@Test
func testDbDriverContractAndErrorCategories() {
    let drv = FakeDriver()
    let cfg = ConnConfig("mysql", "127.0.0.1", 3306u16, "canglin_src", "root", "canglin123")

    match (drv.connect(cfg)) {
        case Ok(_) => @Assert(true)
        case Err(e) => @Fail("connect should succeed, got ${e}")
    }

    // 不可达端口 → NetworkUnreachable
    let unreachable = ConnConfig("mysql", "127.0.0.1", 59999u16, "canglin_src", "root", "canglin123")
    match (drv.connect(unreachable)) {
        case Ok(_) => @Fail("connect should fail")
        case Err(e) => match (e) {
            case NetworkUnreachable(_) => @Assert(true)
            case _ => @Fail("expected NetworkUnreachable, got ${e}")
        }
    }

    // 错误密码 → AuthFailed
    let badAuth = ConnConfig("mysql", "127.0.0.1", 3306u16, "canglin_src", "root", "wrong")
    match (drv.connect(badAuth)) {
        case Ok(_) => @Fail("connect should fail")
        case Err(e) => match (e) {
            case AuthFailed(_) => @Assert(true)
            case _ => @Fail("expected AuthFailed, got ${e}")
        }
    }
}
