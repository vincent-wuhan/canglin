package mysql_driver

import std.collection.*
import std.database.sql.Connection as SqlConnection
import std.database.sql.Datasource
import std.database.sql.DriverManager
import std.database.sql.QueryResult
import std.time.DateTime
import driver.api.*
// 引用 mariadb.cdbc 以触发其包级语句 DriverManager.register("mariadb", MariaDBDriver())：
// MariaDBDriver 的 init 是 protected，驱动实例只能经 DriverManager 取得。
import mariadb.cdbc.MariaDBDriver

// MySQL 适配器：社区库 mysqlclient4cj（Cangjie-SIG 的 MariaDB/MySQL CDBC 驱动）。
//
// 接入方式（PT7 校准结论）：
// - 驱动实现位于 mariadb.cdbc 包，模块级语句 DriverManager.register("mariadb", MariaDBDriver())
//   在包初始化时完成注册；而 MariaDBDriver 的 init 是 protected，下游不能直接 new——
//   故只能经 DriverManager.getDriver("mariadb") 取驱动实例。
// - open() 的 URL scheme 必须是 "mariadb"；口令走 options 的 "password" 键，不进 URL，
//   免得口令出现在连接串或日志里。
// - 驱动的连接/协议实现（mariadb.connection / mariadb.protocol）是 protected package，
//   下游既看不到也 import 不到其异常类型——故只能按异常消息归类到 driver.api 的四类 DbError。

/// MySQL 连接工厂。
public class MysqlDriver <: DbDriver {
    public init() {}

    public func connect(cfg: ConnConfig): Result<Connection, DbError> {
        let target = maskedTarget(cfg)
        try {
            let drv = match (DriverManager.getDriver("mariadb")) {
                case Some(d) =>
                    // 注册项应为 mysqlclient4cj 的 MariaDBDriver：引用该类型既校验注册表内容，
                    // 也确保 mariadb.cdbc 包被链接初始化（驱动注册是包级副作用）。
                    if (d is MariaDBDriver) {
                        d
                    } else {
                        throw IllegalStateException("mariadb 注册项不是 mysqlclient4cj 的 MariaDBDriver")
                    }
                case None => throw IllegalStateException("mysqlclient4cj 驱动未注册（mariadb.cdbc 包未初始化）")
            }
            let opts: Array<(String, String)> = [
                ("username", cfg.user),
                ("password", cfg.password),
                ("database", cfg.database),
                // POC 走本机明文 TCP；TLS 不在 PT7 范围（spec 未要求加密传输）。
                ("ssl.mode", "disabled")
            ]
            let ds: Datasource = drv.open("mariadb://${cfg.host}:${cfg.port}", opts)
            let inner = ds.connect()
            logLine("INFO", "connected ${target}")
            return Ok(MysqlConnection(inner))
        } catch (e: Exception) {
            let err = classifyDbError(redactSecret(e.message, cfg.password))
            logLine("ERROR", "connect ${target} failed: ${err}")
            return Err(err)
        }
    }
}

/// 已建立的 MySQL 连接。
public class MysqlConnection <: Connection {
    private let inner: SqlConnection
    private var closed: Bool = false

    public init(inner: SqlConnection) {
        this.inner = inner
    }

    public func query(sql: String): Result<RowSet, DbError> {
        return runQuery(sql, [])
    }

    public func listSchemas(): Result<Array<String>, DbError> {
        return queryStrings("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME", [])
    }

    public func listTables(schema: String): Result<Array<String>, DbError> {
        return queryStrings(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME",
            [schema]
        )
    }

    public func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError> {
        match (runQuery(
            "SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
            [schema, table]
        )) {
            case Ok(rs) =>
                let cols = ArrayList<ColumnDef>()
                for (row in rs.rows) {
                    cols.add(ColumnDef(cellText(row, 0), cellText(row, 1).toAsciiUpper()))
                }
                return Ok(cols.toArray())
            case Err(e) => return Err(e)
        }
    }

    /// 关闭连接；幂等——重复调用不抛异常，资源只释放一次。
    public func close(): Unit {
        if (closed) {
            return
        }
        closed = true
        try {
            inner.close()
        } catch (e: Exception) {
            // 驱动的 close() 对已关闭连接会抛异常；此处吞掉以保证幂等。
        }
    }

    private func runQuery(sql: String, params: Array<String>): Result<RowSet, DbError> {
        if (closed) {
            return Err(DbError.QueryError("连接已关闭"))
        }
        try {
            let stmt = inner.prepareStatement(sql)
            for (i in 0..params.size) {
                stmt.set<String>(i + 1, params[i])
            }
            let rs = stmt.query()
            return Ok(readRowSet(rs))
        } catch (e: Exception) {
            return Err(classifyDbError(e.message))
        }
    }

    private func queryStrings(sql: String, params: Array<String>): Result<Array<String>, DbError> {
        match (runQuery(sql, params)) {
            case Ok(rs) =>
                let out = ArrayList<String>()
                for (row in rs.rows) {
                    out.add(cellText(row, 0))
                }
                return Ok(out.toArray())
            case Err(e) => return Err(e)
        }
    }
}

/// 读取结果集：驱动侧列信息 → driver.api 的 ColumnDef/RawCell。
private func readRowSet(rs: QueryResult): RowSet {
    let columns = ArrayList<ColumnDef>()
    for (info in rs.columnInfos) {
        columns.add(ColumnDef(info.name, sqlTypeName(info.typeName)))
    }
    let rows = ArrayList<Array<RawCell>>()
    while (rs.next()) {
        let row = ArrayList<RawCell>()
        for (i in 0..columns.size) {
            row.add(readCell(rs, columns[i].typeName, i + 1))
        }
        rows.add(row.toArray())
    }
    return RowSet(columns.toArray(), rows.toArray())
}

/// 读取单元格：按列类型选驱动取值器，统一收敛成 RawCell。
private func readCell(rs: QueryResult, typeName: String, index: Int): RawCell {
    if (isIntegerType(typeName)) {
        match (rs.getOrNull<Int64>(index)) {
            case Some(v) => return I64(v)
            case None => return N
        }
    }
    if (isFloatType(typeName)) {
        match (rs.getOrNull<Float64>(index)) {
            case Some(v) => return F64(v)
            case None => return N
        }
    }
    if (isDateType(typeName)) {
        match (rs.getOrNull<DateTime>(index)) {
            // RawCell 无日期变体：DATETIME 以 yyyy-MM-dd HH:mm:ss 文本承载，由 cell_map 还原为 Column.Date。
            case Some(v) => return S(v.format(DATE_TIME_FORMAT))
            case None => return N
        }
    }
    if (isTextType(typeName)) {
        match (rs.getOrNull<Array<Byte>>(index)) {
            case Some(bytes) => return decodeText(bytes)
            case None => return N
        }
    }
    match (rs.getOrNull<String>(index)) {
        case Some(v) => return S(v)
        case None => return N
    }
}

/// 字节列解码：UTF-8 文本 → 字符串；非文本 → 原样字节。
private func decodeText(bytes: Array<Byte>): RawCell {
    try {
        return S(String.fromUtf8(bytes))
    } catch (e: Exception) {
        return B(bytes)
    }
}

private func cellText(row: Array<RawCell>, index: Int): String {
    return match (row[index]) {
        case S(v) => v
        case _ => ""
    }
}

private func isIntegerType(typeName: String): Bool {
    return typeName == "BIGINT" || typeName == "INT" || typeName == "INTEGER" ||
        typeName == "SMALLINT" || typeName == "TINYINT" || typeName == "MEDIUMINT"
}

private func isFloatType(typeName: String): Bool {
    return typeName == "DOUBLE" || typeName == "FLOAT" || typeName == "REAL" ||
        typeName == "DECIMAL" || typeName == "NUMERIC"
}

private func isDateType(typeName: String): Bool {
    return typeName == "DATETIME" || typeName == "TIMESTAMP"
}

private func isTextType(typeName: String): Bool {
    return typeName == "TEXT" || typeName == "TINYTEXT" || typeName == "MEDIUMTEXT" ||
        typeName == "LONGTEXT" || typeName == "BLOB" || typeName == "TINYBLOB" ||
        typeName == "MEDIUMBLOB" || typeName == "LONGBLOB" || typeName == "BINARY" ||
        typeName == "VARBINARY"
}

/// 按驱动异常消息归类到 driver.api 的四类 DbError。
///
/// mysqlclient4cj 的异常类型在 protected package 里，下游无法 import，
/// 故按消息关键字归类：
/// - 认证（口令/账号被拒）→ AuthFailed
/// - 网络（不可达/超时/连接被拒/域名解析失败）→ NetworkUnreachable
/// - SQL（表不存在/语法错/服务端错误码）→ QueryError
/// - 其余（报文格式、协议不兼容等）→ ProtocolError
public func classifyDbError(message: String): DbError {
    let m = message.toAsciiLower()
    if (m.contains("access denied") || m.contains("authentication") || m.contains("auth failed") ||
        m.contains("password") || m.contains("command denied") ||
        // 服务端拒绝该来源主机访问（账号/来源被拒，属认证类而非协议类）
        m.contains("not allowed to connect")) {
        return DbError.AuthFailed(message)
    }
    if (m.contains("connection refused") || m.contains("failed to connect") || m.contains("timed out") ||
        m.contains("timeout") || m.contains("unreachable") || m.contains("no route to host") ||
        m.contains("connection reset") || m.contains("broken pipe") ||
        // 域名解析失败：驱动报 "Failed to resolve address <host>."，同属网络不可达
        m.contains("failed to resolve") || m.contains("resolve address") ||
        m.contains("name resolution") || m.contains("unknown host") ||
        m.contains("nodename nor servname")) {
        return DbError.NetworkUnreachable(message)
    }
    if (m.contains("doesn't exist") || m.contains("does not exist") || m.contains("unknown column") ||
        m.contains("unknown table") || m.contains("syntax") || m.contains("errorcode") ||
        m.contains("duplicate entry")) {
        return DbError.QueryError(message)
    }
    return DbError.ProtocolError(message)
}

/// 连接目标的可读描述（口令脱敏）——供日志使用。
public func maskedTarget(cfg: ConnConfig): String {
    return "${cfg.driver}://${cfg.user}@${cfg.host}:${cfg.port}/${cfg.database}"
}

/// 把文本里的口令明文替换为 ***（spec：密码不得写入日志）。
public func redactSecret(text: String, secret: String): String {
    if (secret.isEmpty()) {
        return text
    }
    return text.replace(secret, "***")
}

private func logLine(level: String, message: String): Unit {
    println("[canglin.mysql.${level}] ${message}")
}
