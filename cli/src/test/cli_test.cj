package canglin_cli.test

import std.collection.*
import std.convert.*
import std.unittest.*
import driver.api.*
import kernel.channel.BoundedChannel
import kernel.record.*
import canglin_cli.sync.*

// PT10 CLI 单元测试：不依赖数据库，永远可跑。
//
// 覆盖四块：
//   1. 连接串/参数装载（config.cj）
//   2. PG 字面量编码（literal.cj）
//   3. 行级类型判定与编码（row_encode.cj）
//   4. 读侧/写侧与目标列元数据装载（mysql_reader.cj / pg_writer.cj / schema.cj）
//
// 读侧/写侧用假 Connection 驱动：假实现记录收到的 SQL，并按需返回结果集或错误，
// 因此「分页是否翻页」「脏行是否被跳过」「整批失败是否逐行隔离」都能在无库环境断言。

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

/// 假连接：按调用顺序返回预置结果集；命中 failOn 关键字的语句返回错误。
private class FakeConn <: Connection {
    private let statements = ArrayList<String>()
    private let pages: ArrayList<RowSet>
    private let failOn: String
    private var pageIndex: Int64 = 0

    public init(pages: Array<RowSet>, failOn!: String = "") {
        this.pages = ArrayList<RowSet>(pages)
        this.failOn = failOn
    }

    public func query(sql: String): Result<RowSet, DbError> {
        statements.add(sql)
        if (!failOn.isEmpty() && sql.contains(failOn)) {
            return Err(DbError.QueryError("fake failure on statement: ${sql}"))
        }
        if (sql.startsWith("SELECT") && pageIndex < pages.size) {
            let rs = pages[pageIndex]
            pageIndex += 1
            return Ok(rs)
        }
        return Ok(emptyRowSet())
    }

    public func listSchemas(): Result<Array<String>, DbError> {
        return Ok(Array<String>())
    }

    public func listTables(schema: String): Result<Array<String>, DbError> {
        return Ok(Array<String>())
    }

    public func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError> {
        return Ok(Array<ColumnDef>())
    }

    public func close(): Unit {}

    /// 已收到的全部 SQL（按顺序）。
    public func recorded(): Array<String> {
        return statements.toArray()
    }
}

private func emptyRowSet(): RowSet {
    return RowSet(Array<ColumnDef>(), Array<Array<RawCell>>())
}

/// 构造结果集：列名 + 列类型 + 行。
private func makeRowSet(names: Array<String>, types: Array<String>, rows: Array<Array<RawCell>>): RowSet {
    let cols = ArrayList<ColumnDef>()
    for (i in 0..names.size) {
        cols.add(ColumnDef(names[i], types[i]))
    }
    return RowSet(cols.toArray(), rows)
}

/// 构造一行 Record。
private func makeRecord(cols: Array<Column>): Record {
    return Record(ArrayList<Column>(cols))
}

/// 目标列规格快捷构造。
private func target(name: String, dataType: String, maxLength!: Int64 = -1, nullable!: Bool = true): TargetColumn {
    return TargetColumn(name, dataType, maxLength, nullable)
}

/// 读取 Record 的字面量数组（断言用）。
private func literalsOf(enc: RowEncode): Array<String> {
    return match (enc) {
        case Encoded(vs) => vs
        case Rejected(_) => Array<String>()
    }
}

/// 脏行原因文本（断言用）。
private func reasonOf(enc: RowEncode): String {
    return match (enc) {
        case Encoded(_) => ""
        case Rejected(r) => r
    }
}

/// 重复拼接 n 次（构造超长文本用）。
private func repeatText(ch: String, times: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < times) {
        sb.append(ch)
        i += 1
    }
    return sb.toString()
}

/// 构造固定的环境变量读取器。
private func envOf(pairs: Array<(String, String)>): EnvLookup {
    let closure: EnvLookup = { key =>
        var found: Option<String> = None
        for (p in pairs) {
            if (p[0] == key) {
                found = Some(p[1])
            }
        }
        found
    }
    return closure
}

/// 空环境读取器。
private func noEnv(): EnvLookup {
    return { key => None }
}

/// Option 是否为空。
///
/// 不写 `opt == None`：Option 的相等比较要求元素类型实现 Equatable，
/// 而 Endpoint / SyncOptions / Array<ColumnBinding> 都不是 Equatable。
private func isNone<T>(v: Option<T>): Bool {
    return match (v) {
        case Some(_) => false
        case None => true
    }
}

// ---------------------------------------------------------------------------
// 1. 连接串与参数装载
// ---------------------------------------------------------------------------

@Test
func testParseDsnFull(): Unit {
    match (parseDsn("mysql://root:canglin123@127.0.0.1:3306/canglin_src")) {
        case Some(e) =>
            @Assert(e.driver == "mysql")
            @Assert(e.user == "root")
            @Assert(e.password == "canglin123")
            @Assert(e.host == "127.0.0.1")
            @Assert(e.port == 3306u16)
            @Assert(e.database == "canglin_src")
        case None => @Fail("合法 DSN 应解析成功")
    }
}

@Test
func testParseDsnPercentEncodedPassword(): Unit {
    // 口令里的 @ : / 走百分号编码（RFC 3986）
    match (parseDsn("mysql://root:p%40ss%3Aword%2Fx@db.internal:3307/app")) {
        case Some(e) =>
            @Assert(e.password == "p@ss:word/x")
            @Assert(e.host == "db.internal")
            @Assert(e.port == 3307u16)
            @Assert(e.database == "app")
        case None => @Fail("百分号编码的口令应解析成功")
    }
}

@Test
func testParseDsnDefaultPortByScheme(): Unit {
    match (parseDsn("postgres://postgres:pw@127.0.0.1/canglin_src")) {
        case Some(e) => @Assert(e.port == 5432u16)
        case None => @Fail("应解析成功")
    }
    match (parseDsn("mysql://root:pw@127.0.0.1/canglin_src")) {
        case Some(e) => @Assert(e.port == 3306u16)
        case None => @Fail("应解析成功")
    }
}

@Test
func testParseDsnRejectsMalformed(): Unit {
    // 缺 scheme
    @Assert(isNone(parseDsn("127.0.0.1:3306/canglin_src")))
    // 缺 userinfo 里的冒号
    @Assert(isNone(parseDsn("mysql://root@127.0.0.1:3306/canglin_src")))
    // 缺库名
    @Assert(isNone(parseDsn("mysql://root:pw@127.0.0.1:3306/")))
    // 端口不是数字
    @Assert(isNone(parseDsn("mysql://root:pw@127.0.0.1:abc/canglin_src")))
    // 端口越界（UInt16）
    @Assert(isNone(parseDsn("mysql://root:pw@127.0.0.1:70000/canglin_src")))
    // 百分号转义残缺
    @Assert(isNone(parseDsn("mysql://root:p%zz@127.0.0.1:3306/canglin_src")))
}

@Test
func testPercentDecode(): Unit {
    @Assert((percentDecode("a%20b") ?? "") == "a b")
    @Assert((percentDecode("%E4%B8%AD%E6%96%87") ?? "") == "中文")
    @Assert((percentDecode("plain") ?? "") == "plain")
    @Assert(isNone(percentDecode("%4")))
    @Assert(isNone(percentDecode("%zz")))
}

@Test
func testIsSafeIdentifier(): Unit {
    @Assert(isSafeIdentifier("src_users"))
    @Assert(isSafeIdentifier("_x1"))
    @Assert(isSafeIdentifier("A"))
    // 以数字开头
    @Assert(!isSafeIdentifier("1abc"))
    // 含 SQL 注入字符
    @Assert(!isSafeIdentifier("users;DROP TABLE x"))
    @Assert(!isSafeIdentifier("users--"))
    @Assert(!isSafeIdentifier(""))
    @Assert(!isSafeIdentifier("a b"))
}

@Test
func testLoadOptionsDefaults(): Unit {
    let opts = loadOptions(noEnv(), Array<String>())
    match (opts) {
        case Some(o) =>
            @Assert(o.srcTable == "src_users")
            @Assert(o.dstTable == "dst_users")
            @Assert(o.dstSchema == "public")
            @Assert(o.batchRows == 500)
            @Assert(o.truncateTarget)
            @Assert(o.source.host == "127.0.0.1")
            @Assert(o.target.port == 5432u16)
        case None => @Fail("缺省参数应装载成功")
    }
}

@Test
func testLoadOptionsEnvAndArgsOverride(): Unit {
    // 环境变量给连接串
    let getEnv = envOf([
        ("CANGLIN_MYSQL_DSN", "mysql://u1:p1@10.0.0.1:3306/db1"),
        ("CANGLIN_PG_DSN", "postgres://u2:p2@10.0.0.2:5432/db2")
    ])
    // 命令行覆盖表名/schema/批量/清空开关
    let opts = loadOptions(getEnv, [
        "--src-table=src_users_dirty", "--dst-table=dst_users_dirty",
        "--dst-schema=other", "--batch=250", "--keep-target"
    ])
    match (opts) {
        case Some(o) =>
            @Assert(o.srcTable == "src_users_dirty")
            @Assert(o.dstTable == "dst_users_dirty")
            @Assert(o.dstSchema == "other")
            @Assert(o.batchRows == 250)
            @Assert(!o.truncateTarget)
            @Assert(o.source.database == "db1")
            @Assert(o.target.database == "db2")
            @Assert(o.source.port == 3306u16)
        case None => @Fail("应装载成功")
    }
}

@Test
func testLoadOptionsRejectsUnsafeInput(): Unit {
    let getEnv = noEnv()
    // 表名带注入字符 → 直接失败（宁可启动失败，不拿半截参数去建连）
    @Assert(isNone(loadOptions(getEnv, ["--src-table=users;DROP TABLE x"])))
    @Assert(isNone(loadOptions(getEnv, ["--dst-table=users--"])))
    @Assert(isNone(loadOptions(getEnv, ["--dst-schema=public;drop"])))
    // 批量必须为正
    @Assert(isNone(loadOptions(getEnv, ["--batch=0"])))
    @Assert(isNone(loadOptions(getEnv, ["--batch=-1"])))
    @Assert(isNone(loadOptions(getEnv, ["--batch=abc"])))
}

@Test
func testDescribeEndpointHidesPassword(): Unit {
    let text = describeEndpoint(Endpoint("mysql", "127.0.0.1", 3306u16, "db", "root", "canglin123"))
    @Assert(!text.contains("canglin123"))
    @Assert(text.contains("root"))
    @Assert(text.contains("127.0.0.1:3306"))
}

// ---------------------------------------------------------------------------
// 2. PG 字面量编码
// ---------------------------------------------------------------------------

@Test
func testPgTextLiteralEscapes(): Unit {
    // 普通文本
    @Assert((pgTextLiteral("hello") ?? "") == "E'hello'")
    // 单引号 → 反斜杠转义
    @Assert((pgTextLiteral("it's") ?? "") == "E'it\\'s'")
    // 反斜杠自身
    @Assert((pgTextLiteral("a\\b") ?? "") == "E'a\\\\b'")
    // 换行/回车/制表
    @Assert((pgTextLiteral("a\nb") ?? "") == "E'a\\nb'")
    @Assert((pgTextLiteral("a\rb") ?? "") == "E'a\\rb'")
    @Assert((pgTextLiteral("a\tb") ?? "") == "E'a\\tb'")
    // 控制字符用三位八进制（定长，不与后继字符混淆）
    @Assert((pgTextLiteral(String.fromUtf8([0x61u8, 0x01u8, 0x62u8])) ?? "") == "E'a\\001b'")
    // NUL：PG 文本无法表示 → None
    @Assert(isNone(pgTextLiteral(String.fromUtf8([0x61u8, 0x00u8, 0x62u8]))))
}

@Test
func testPgTextLiteralKeepsUtf8(): Unit {
    @Assert((pgTextLiteral("中文") ?? "") == "E'中文'")
}

@Test
func testUtf8CharCount(): Unit {
    // PG 的 varchar(n) 按字符计，不按字节
    @Assert(utf8CharCount("abc") == 3)
    @Assert(utf8CharCount("中文") == 2)
    @Assert(utf8CharCount("a中b") == 3)
    @Assert(utf8CharCount("") == 0)
}

@Test
func testPgByteaLiteral(): Unit {
    @Assert(pgByteaLiteral([0x00u8, 0x01u8, 0xffu8]) == "E'\\x0001ff'::bytea")
}

// ---------------------------------------------------------------------------
// 3. 行级类型判定与编码
// ---------------------------------------------------------------------------

private func sampleBindings(): Array<ColumnBinding> {
    return [
        ColumnBinding(0, target("id", "bigint", nullable: false)),
        ColumnBinding(1, target("name", "character varying", maxLength: 64, nullable: false)),
        ColumnBinding(2, target("score", "double precision"))
    ]
}

private func sampleColumns(): Array<String> {
    return ["id", "name", "score"]
}

@Test
func testEncodeRowHappyPath(): Unit {
    let rec = makeRecord([Column.Long(7), Column.Str("alice"), Column.Double(88.5)])
    match (encodeRow(rec, sampleBindings())) {
        case Encoded(vs) =>
            @Assert(vs.size == 3)
            @Assert(vs[0] == "7")
            @Assert(vs[1] == "E'alice'")
            @Assert(vs[2] == "88.500000")
        case Rejected(r) => @Fail("不该判为脏行：${r}")
    }
}

@Test
func testEncodeRowNullIntoNullableColumn(): Unit {
    let rec = makeRecord([Column.Long(7), Column.Str("alice"), Column.Null])
    match (encodeRow(rec, sampleBindings())) {
        case Encoded(vs) => @Assert(vs[2] == "NULL")
        case Rejected(r) => @Fail("NULL 进可空列不该判为脏行：${r}")
    }
}

@Test
func testEncodeRowRejectsNullIntoNotNullColumn(): Unit {
    let rec = makeRecord([Column.Null, Column.Str("alice"), Column.Double(1.0)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(reasonOf(enc).contains("id"))
    @Assert(literalsOf(enc).size == 0)
}

@Test
func testEncodeRowRejectsTypeMismatch(): Unit {
    // 文本值进 bigint 列：类别不兼容 → 脏行
    let rec = makeRecord([Column.Str("not-a-number"), Column.Str("alice"), Column.Double(1.0)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(literalsOf(enc).size == 0)
    @Assert(reasonOf(enc).contains("id"))
}

@Test
func testEncodeRowRejectsOverlongText(): Unit {
    let long = repeatText("x", 100)   // 100 字符 > varchar(64)
    let rec = makeRecord([Column.Long(1), Column.Str(long), Column.Double(1.0)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(literalsOf(enc).size == 0)
    @Assert(reasonOf(enc).contains("name"))
}

@Test
func testEncodeRowWidensNumericText(): Unit {
    // 文本数值可放宽进数值列（脏行变体依赖这条路径）
    let rec = makeRecord([Column.Str("12"), Column.Str("alice"), Column.Str("88.5")])
    match (encodeRow(rec, sampleBindings())) {
        case Encoded(vs) =>
            @Assert(vs[0] == "12")
            @Assert(vs[2] == "88.500000")
        case Rejected(r) => @Fail("文本数值应可放宽：${r}")
    }
}

@Test
func testEncodeRowRejectsFractionalTextForIntegerColumn(): Unit {
    // 整型列不接受带小数的文本（不放宽浮点语义）
    let rec = makeRecord([Column.Str("12.5"), Column.Str("alice"), Column.Double(1.0)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(literalsOf(enc).size == 0)
}

@Test
func testEncodeRowRejectsNonNumericText(): Unit {
    // 文本进数值列但不是数字 → 类型错配脏行
    let rec = makeRecord([Column.Str("N/A"), Column.Str("alice"), Column.Double(1.0)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(literalsOf(enc).size == 0)
    @Assert(reasonOf(enc).contains("id"))
}

@Test
func testEncodeRowRejectsIntegerOverflow(): Unit {
    // 超出 int32 的值放不进 integer 列（放 bigint 列则放得下）
    let bindings = [
        ColumnBinding(0, target("id", "integer", nullable: false)),
        ColumnBinding(1, target("name", "character varying", maxLength: 64, nullable: false)),
        ColumnBinding(2, target("score", "double precision"))
    ]
    let rec = makeRecord([Column.Long(4294967296), Column.Str("alice"), Column.Double(1.0)])
    @Assert(literalsOf(encodeRow(rec, bindings)).size == 0)
    // 同样的值落 bigint 列 → 正常编码
    let wide = makeRecord([Column.Long(4294967296), Column.Str("alice"), Column.Double(1.0)])
    @Assert(literalsOf(encodeRow(wide, sampleBindings())).size == 3)
}

@Test
func testEncodeRowRejectsMissingColumn(): Unit {
    let rec = makeRecord([Column.Long(1)])
    let enc = encodeRow(rec, sampleBindings())
    @Assert(literalsOf(enc).size == 0)
    @Assert(reasonOf(enc).contains("列"))
}

@Test
func testBuildBindingsMatchesByName(): Unit {
    let src = ["id", "name", "score"]
    let dst = [
        target("score", "double precision"),
        target("id", "bigint", nullable: false),
        target("name", "character varying", maxLength: 64, nullable: false)
    ]
    match (buildBindings(src, dst)) {
        case Some(bs) =>
            @Assert(bs.size == 3)
            // 绑定按目标列顺序给出，sourceIndex 指向源列下标
            @Assert(bs[0].sourceIndex == 2)
            @Assert(bs[0].target.name == "score")
            @Assert(bs[1].sourceIndex == 0)
            @Assert(bs[2].sourceIndex == 1)
        case None => @Fail("同名同序的列集合应绑定成功")
    }
}

@Test
func testBuildBindingsRejectsColumnSetMismatch(): Unit {
    let dst = [target("id", "bigint"), target("name", "character varying")]
    // 源多一列 → 目标填不上
    @Assert(isNone(buildBindings(["id", "name", "extra"], dst)))
    // 目标多一列 → 源填不上
    @Assert(isNone(buildBindings(["id"], dst)))
    // 名字对不上
    @Assert(isNone(buildBindings(["id", "nickname"], dst)))
}

@Test
func testBuildInsertSqlShape(): Unit {
    let sql = buildInsertSql("\"public\".\"dst_users\"", ["id", "name"], [
        ["1", "E'a'"], ["2", "E'b'"]
    ])
    @Assert(sql == "INSERT INTO \"public\".\"dst_users\" (\"id\", \"name\") VALUES (1, E'a'), (2, E'b')")
}

@Test
func testQuoteIdentifier(): Unit {
    @Assert(quoteIdentifier("dst_users") == "\"dst_users\"")
}

@Test
func testSyncColumnsMatchInitDdl(): Unit {
    // 与 env/init/01-mysql.sql、env/init/02-pg.sql 的 DDL 对齐
    @Assert(SYNC_COLUMNS.size == 5)
    @Assert(SYNC_COLUMNS[0] == "id")
    @Assert(SYNC_COLUMNS[1] == "name")
    @Assert(SYNC_COLUMNS[2] == "score")
    @Assert(SYNC_COLUMNS[3] == "note")
    @Assert(SYNC_COLUMNS[4] == "created_at")
    // PG 时间戳字面量格式必须与 MySQL 适配器承载 DATETIME 的格式一致
    @Assert(PG_TIMESTAMP_FORMAT == "yyyy-MM-dd HH:mm:ss")
}

// ---------------------------------------------------------------------------
// 4. 目标列元数据装载 / 读侧 / 写侧
// ---------------------------------------------------------------------------

@Test
func testLoadTargetColumnsParsesInformationSchema(): Unit {
    let rs = makeRowSet(
        ["column_name", "data_type", "character_maximum_length", "is_nullable"],
        ["VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR"],
        [
            [RawCell.S("id"), RawCell.S("bigint"), RawCell.N, RawCell.S("NO")],
            [RawCell.S("name"), RawCell.S("character varying"), RawCell.I64(64), RawCell.S("NO")],
            [RawCell.S("note"), RawCell.S("text"), RawCell.N, RawCell.S("YES")]
        ]
    )
    let conn = FakeConn([rs])
    match (loadTargetColumns(conn, "public", "dst_users")) {
        case Ok(cols) =>
            @Assert(cols.size == 3)
            @Assert(cols[0].name == "id")
            @Assert(cols[0].dataType == "bigint")
            @Assert(cols[0].maxLength == -1)
            @Assert(!cols[0].nullable)
            @Assert(cols[1].dataType == "character varying")
            @Assert(cols[1].maxLength == 64)
            @Assert(cols[2].dataType == "text")
            @Assert(cols[2].maxLength == -1)
            @Assert(cols[2].nullable)
        case Err(e) => @Fail("目标列装载失败：${e}")
    }
    // 查询语句带 schema/表名过滤
    @Assert(conn.recorded()[0].contains("information_schema.columns"))
    @Assert(conn.recorded()[0].contains("dst_users"))
}

@Test
func testMysqlReaderPaginatesAndCloses(): Unit {
    let page1 = makeRowSet(
        ["id", "name"],
        ["BIGINT", "VARCHAR"],
        [
            [RawCell.I64(1), RawCell.S("a")],
            [RawCell.I64(2), RawCell.S("b")]
        ]
    )
    let page2 = makeRowSet(
        ["id", "name"],
        ["BIGINT", "VARCHAR"],
        [[RawCell.I64(3), RawCell.S("c")]]
    )
    let conn = FakeConn([page1, page2])
    let reader = MysqlReader(conn, "src_users", ["id", "name"], "id", 2)
    let channel = BoundedChannel(16)
    reader.read(channel)
    // 读完两页共 3 行，管道已关闭（消费方 recv 到 None 即退出）
    var got: Int64 = 0
    while (true) {
        match (channel.recv()) {
            case Some(rec) => got += 1
            case None => break
        }
    }
    @Assert(got == 3)
    // 分页：第一页 OFFSET 0，第二页 OFFSET 2；列与表名都带引号
    let sqls = conn.recorded()
    @Assert(sqls.size == 2)
    @Assert(sqls[0].contains("LIMIT 2 OFFSET 0"))
    @Assert(sqls[1].contains("LIMIT 2 OFFSET 2"))
    @Assert(sqls[0].contains("`src_users`"))
    @Assert(sqls[0].contains("`id`"))
}

@Test
func testPgWriterCountsDirtyRowsAndSkipsThem(): Unit {
    let conn = FakeConn([])
    let writer = PgWriter(conn, "public", "dst_users", sampleColumns(), sampleBindings(), 100)
    let channel = BoundedChannel(16)
    // 好行
    channel.send(makeRecord([Column.Long(1), Column.Str("alice"), Column.Double(1.5)]))
    // 类型错配：文本进 bigint
    channel.send(makeRecord([Column.Str("N/A"), Column.Str("bob"), Column.Double(2.5)]))
    // 超长文本
    channel.send(makeRecord([Column.Long(3), Column.Str(repeatText("x", 100)), Column.Double(3.5)]))
    // 好行
    channel.send(makeRecord([Column.Long(4), Column.Str("carol"), Column.Double(4.5)]))
    channel.close()
    let stat = writer.write(channel)
    @Assert(stat.ok == 2)
    @Assert(stat.dirty == 2)
    // 两行好数据落库；脏行一个都没进 INSERT
    let sqls = conn.recorded()
    @Assert(sqls[0] == "BEGIN")
    @Assert(sqls[1].contains("INSERT INTO"))
    @Assert(sqls[1].contains("E'alice'"))
    @Assert(sqls[1].contains("E'carol'"))
    @Assert(!sqls[1].contains("N/A"))
    @Assert(!sqls[1].contains("xxxx"))
    @Assert(sqls[2] == "COMMIT")
    @Assert(writer.dirtySamples().size >= 1)
}

@Test
func testPgWriterIsolatesBadRowOnBatchFailure(): Unit {
    // 假连接对含 BAD-ROW 的 INSERT 报错：整批失败后逐行重试，
    // 只有真正出错的那行判脏，其余行照常落库（作业不中断）。
    let conn = FakeConn([], failOn: "BAD-ROW")
    let writer = PgWriter(conn, "public", "dst_users", sampleColumns(), sampleBindings(), 100)
    let channel = BoundedChannel(16)
    channel.send(makeRecord([Column.Long(1), Column.Str("alice"), Column.Double(1.5)]))
    channel.send(makeRecord([Column.Long(2), Column.Str("BAD-ROW"), Column.Double(2.5)]))
    channel.send(makeRecord([Column.Long(3), Column.Str("carol"), Column.Double(3.5)]))
    channel.close()
    let stat = writer.write(channel)
    @Assert(stat.ok == 2)
    @Assert(stat.dirty == 1)
    // 有回滚、也有逐行重试
    var sawRollback = false
    var sawRetry = false
    for (sql in conn.recorded()) {
        if (sql == "ROLLBACK") { sawRollback = true }
        if (sql.startsWith("INSERT") && sql.contains("E'alice'")) { sawRetry = true }
    }
    @Assert(sawRollback)
    @Assert(sawRetry)
}

@Test
func testPgWriterFlushesInBatches(): Unit {
    let conn = FakeConn([])
    let writer = PgWriter(conn, "public", "dst_users", sampleColumns(), sampleBindings(), 2)
    let channel = BoundedChannel(16)
    channel.send(makeRecord([Column.Long(1), Column.Str("a"), Column.Double(1.0)]))
    channel.send(makeRecord([Column.Long(2), Column.Str("b"), Column.Double(2.0)]))
    channel.send(makeRecord([Column.Long(3), Column.Str("c"), Column.Double(3.0)]))
    channel.close()
    let stat = writer.write(channel)
    @Assert(stat.ok == 3)
    @Assert(stat.dirty == 0)
    // 两批：批大小 2 → 第一批 2 行，第二批（收尾）1 行
    var insertCount: Int64 = 0
    for (sql in conn.recorded()) {
        if (sql.startsWith("INSERT")) { insertCount += 1 }
    }
    @Assert(insertCount == 2)
}
