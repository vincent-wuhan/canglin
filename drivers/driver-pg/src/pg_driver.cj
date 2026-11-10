package pgdriver

import std.collection.ArrayList
import std.database.sql.{DriverManager, Driver}
import driver.api.{ColumnDef, ConnConfig, DbDriver, DbError, RawCell, RowSet, Result, Connection as ApiConnection}
import cangjie_tpc::opengauss.driver.{PGDriver, PGConnection as UpstreamPgConnection, Stmt}

// PT8：PostgreSQL / openGauss 适配器。
//
// 上游 opengauss-driver 对两种服务端共用一套 PG 线协议实现，差异集中在启动
// 握手（DBType.Postgres / DBType.OpenGauss），因此这里用同一个适配器承载
// PG 与 openGauss 两个端点：cfg.driver 决定注册名，进而决定上游握手分支。
//
// 错误一律收敛到 driver.api 的四类 DbError（见 classifyError），不向外抛裸异常。

/// PG / openGauss 驱动工厂。
public class PgDriver <: DbDriver {
    public init() {}

    public func connect(cfg: ConnConfig): Result<ApiConnection, DbError> {
        let name = driverNameOf(cfg)
        if (name == "") {
            return Err(DbError.ProtocolError("unsupported driver: ${cfg.driver}"))
        }
        try {
            let drv = resolveDriver(name)
            let ds = drv.open(buildUrl(cfg))
            // 接口 → 具体实现是受检转换（as 返回 Option）
            let conn = match (ds.connect() as UpstreamPgConnection) {
                case Some(c) => c
                case None => throw Exception("unexpected connection implementation")
            }
            return Ok(PgConnection(conn))
        } catch (e: Exception) {
            return Err(classifyError(scrub(e.message, cfg.password)))
        }
    }
}

/// cfg.driver → 上游 DriverManager 注册名；不支持的驱动名返回空串。
private func driverNameOf(cfg: ConnConfig): String {
    match (cfg.driver) {
        case "pg" | "postgres" => return "postgres"
        case "opengauss" => return "opengauss"
        case _ => return ""
    }
}

/// 取出上游驱动；上游包初始化时已注册 postgres / opengauss，这里做兜底注册。
private func resolveDriver(name: String): Driver {
    // 引用上游 PGDriver 会触发 opengauss 驱动包初始化（其包级初始化向
    // DriverManager 注册了 postgres / opengauss），故先取引用再查注册表。
    let drv = PGDriver(name)
    match (DriverManager.getDriver(name)) {
        case Some(d) => return d
        case None =>
            DriverManager.register(name, drv)
            return drv
    }
}

/// 构造上游连接 URL。
///
/// sslmode=disable：POC 阶段两个端点都在本机/内网。上游驱动对 sslmode=prefer
/// 并不会在服务端拒绝 TLS 时回落到明文（直接抛 "server refused TLS connection"），
/// 因此这里显式关闭 TLS；生产化需改为 verify-full 并配置证书，见 env/driver-notes.md。
private func buildUrl(cfg: ConnConfig): String {
    let scheme = if (driverNameOf(cfg) == "opengauss") { "opengauss" } else { "postgres" }
    return "${scheme}://${cfg.user}:${percentEncode(cfg.password)}@${cfg.host}:${cfg.port}/${cfg.database}" +
        "?sslmode=disable&connection_timeout=5000&read_timeout=30000"
}

private const HEX_DIGITS = "0123456789ABCDEF"

/// 百分号编码。
///
/// 上游 URL 解析器只对 password 做解码（username 原样取用），故账号需为不含
/// 保留字符的普通账号；口令按 RFC 3986 未保留字符集逐字节编码。
private func percentEncode(raw: String): String {
    let out = ArrayList<Byte>()
    for (i in 0..raw.size) {
        let c = raw[i]
        let unreserved = (c >= b'A' && c <= b'Z') || (c >= b'a' && c <= b'z') ||
            (c >= b'0' && c <= b'9') || c == b'-' || c == b'.' || c == b'_' || c == b'~'
        if (unreserved) {
            out.add(c)
        } else {
            out.add(b'%')
            out.add(HEX_DIGITS[Int64(c >> 4)])
            out.add(HEX_DIGITS[Int64(c & 0x0f)])
        }
    }
    return String.fromUtf8(out.toArray())
}

/// 把消息中的口令替换为 ***（spec：密码不得写入日志）。
public func scrub(message: String, secret: String): String {
    if (secret.isEmpty()) {
        return message
    }
    return message.replace(secret, "***")
}

/// 把上游异常消息归入 driver.api 的四类错误。
///
/// 上游把服务端错误统一包成 SqlException，消息形如
/// "FATAL: password authentication failed for user \"x\" (SQLSTATE 28P01)"；
/// 连接阶段失败则是 "host:port: <底层套接字异常>"；SQL 本身出错则带 SQLSTATE
/// （如 42P01 不存在表）。
public func classifyError(message: String): DbError {
    let m = message.toAsciiLower()
    // 认证：SQLSTATE 28P01 / 28000，或认证相关关键字
    if (m.contains("sqlstate 28p01") || m.contains("sqlstate 28000") ||
        m.contains("password authentication failed") || m.contains("authentication failed") ||
        m.contains("permission denied for user")) {
        return DbError.AuthFailed(message)
    }
    // 协议：握手/报文层与驱动预期不符
    if (m.contains("not support message") || m.contains("invalid authentication") ||
        m.contains("expected authentication") || m.contains("server not response") ||
        m.contains("server refused tls") || m.contains("protocol")) {
        return DbError.ProtocolError(message)
    }
    // 网络：目标不可达 / 超时 / 连接被拒 / 域名解析失败
    //
    // 解析失败同属网络不可达（与 MySQL 适配器同一口径）：上游把「Failed to
    // resolve address <host>」与「Connection refused」并列作为套接字层失败，
    // 若不单列会落到兜底的 QueryError 类别。
    if (m.contains("refused") || m.contains("unreachable") || m.contains("timed out") ||
        m.contains("timeout") || m.contains("no route to host") || m.contains("connection reset") ||
        m.contains("connect error") || m.contains("connect failed") || m.contains("broken pipe") ||
        m.contains("failed to resolve") || m.contains("resolve address") ||
        m.contains("name resolution") || m.contains("unknown host") ||
        m.contains("nodename nor servname")) {
        return DbError.NetworkUnreachable(message)
    }
    // 其余归为 SQL / 元数据请求错误
    return DbError.QueryError(message)
}

/// 已建立的 PG / openGauss 连接。
public class PgConnection <: ApiConnection {
    private var conn: UpstreamPgConnection
    private var closed: Bool = false

    public init(conn: UpstreamPgConnection) {
        this.conn = conn
    }

    /// 执行一条 SQL 并返回驱动无关行集。
    ///
    /// DDL/DML 也走这条路径：上游 simpleExec 对无 RowDescription 的命令会返回
    /// 空列集，不影响调用方。
    public func query(sql: String): Result<RowSet, DbError> {
        if (this.closed) {
            return Err(DbError.QueryError("connection already closed"))
        }
        try {
            let qr = this.conn.query(sql)
            let infos = qr.columnInfos
            let columns = ArrayList<ColumnDef>()
            for (info in infos) {
                columns.add(ColumnDef(info.name, canonicalTypeName(info.typeName)))
            }
            let rows = ArrayList<Array<RawCell>>()
            while (qr.next()) {
                let row = ArrayList<RawCell>()
                for (i in 0..infos.size) {
                    row.add(readCell(qr, i, infos[i].typeName))
                }
                rows.add(row.toArray())
            }
            return Ok(RowSet(columns.toArray(), rows.toArray()))
        } catch (e: Exception) {
            return Err(classifyError(e.message))
        }
    }

    public func listSchemas(): Result<Array<String>, DbError> {
        match (this.query("SELECT schema_name FROM information_schema.schemata ORDER BY schema_name")) {
            case Ok(rs) => return Ok(firstColumnStrings(rs))
            case Err(e) => return Err(e)
        }
    }

    public func listTables(schema: String): Result<Array<String>, DbError> {
        if (this.closed) {
            return Err(DbError.QueryError("connection already closed"))
        }
        try {
            // 走预备语句参数绑定，避免把 schema 名拼进 SQL
            let stmt = match (this.conn.prepareStatement(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = ? ORDER BY table_name") as Stmt) {
                case Some(s) => s
                case None => throw Exception("unexpected statement implementation")
            }
            stmt.set<String>(0, schema)
            let qr = stmt.query()
            let out = ArrayList<String>()
            while (qr.next()) {
                out.add(qr.get<String>(0))
            }
            stmt.close()
            return Ok(out.toArray())
        } catch (e: Exception) {
            return Err(classifyError(e.message))
        }
    }

    public func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError> {
        if (this.closed) {
            return Err(DbError.QueryError("connection already closed"))
        }
        try {
            let stmt = match (this.conn.prepareStatement(
                "SELECT column_name, data_type, udt_name FROM information_schema.columns " +
                "WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position") as Stmt) {
                case Some(s) => s
                case None => throw Exception("unexpected statement implementation")
            }
            stmt.set<String>(0, schema)
            stmt.set<String>(1, table)
            let qr = stmt.query()
            let out = ArrayList<ColumnDef>()
            while (qr.next()) {
                out.add(ColumnDef(qr.get<String>(0), dbTypeName(qr.get<String>(1), qr.get<String>(2))))
            }
            stmt.close()
            return Ok(out.toArray())
        } catch (e: Exception) {
            return Err(classifyError(e.message))
        }
    }

    /// 关闭连接；幂等（spec：连接关闭幂等）。
    public func close(): Unit {
        if (this.closed) {
            return
        }
        this.closed = true
        try {
            this.conn.close()
        } catch (e: Exception) {
            // 关闭失败不再向上抛：连接已标记为关闭，重复 close 仍是安全的
            ()
        }
    }
}

/// 取结果集第一列的字符串值。
private func firstColumnStrings(rs: RowSet): Array<String> {
    let out = ArrayList<String>()
    for (row in rs.rows) {
        if (row.size > 0) {
            match (row[0]) {
                case RawCell.S(v) => out.add(v)
                case _ => ()
            }
        }
    }
    return out.toArray()
}
