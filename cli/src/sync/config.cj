package canglin_cli.sync

import std.collection.*
import std.convert.*
import std.env.*

/// 连接端点：一端数据库的连接参数（口令不落日志）。
public struct Endpoint {
    /// 驱动标识："mysql" | "pg"。
    public let driver: String
    public let host: String
    public let port: UInt16
    public let database: String
    public let user: String
    /// 明文口令，仅用于建连。
    public let password: String

    public init(driver: String, host: String, port: UInt16, database: String, user: String, password: String) {
        this.driver = driver
        this.host = host
        this.port = port
        this.database = database
        this.user = user
        this.password = password
    }
}

/// 口令脱敏后的连接串描述（供日志打印）。
public func describeEndpoint(e: Endpoint): String {
    return "${e.driver}://${e.user}@${e.host}:${e.port}/${e.database}"
}

/// 同步作业的运行参数。
public struct SyncOptions {
    public let source: Endpoint
    public let target: Endpoint
    /// 源表名（MySQL 侧）。
    public let srcTable: String
    /// 目标表名（PG 侧）。
    public let dstTable: String
    /// 目标表所在 schema（PG 侧）。
    public let dstSchema: String
    /// 每批行数（读侧分页大小 / 写侧事务提交批量）。
    public let batchRows: Int64
    /// 同步前是否清空目标表（默认清空，让作业可重复执行）。
    public let truncateTarget: Bool

    public init(source: Endpoint, target: Endpoint, srcTable: String, dstTable: String, dstSchema: String,
        batchRows: Int64, truncateTarget: Bool) {
        this.source = source
        this.target = target
        this.srcTable = srcTable
        this.dstTable = dstTable
        this.dstSchema = dstSchema
        this.batchRows = batchRows
        this.truncateTarget = truncateTarget
    }
}

/// 环境变量读取器：便于测试注入固定值。
public type EnvLookup = (String) -> Option<String>

/// 缺省连接串（与 env/docker-compose.yml 的矩阵一致）。
public const DEFAULT_MYSQL_DSN = "mysql://root:canglin123@127.0.0.1:3306/canglin_src"
public const DEFAULT_PG_DSN = "postgres://postgres:canglin123@127.0.0.1:5432/canglin_src"

/// 按驱动名取缺省端口（DSN 里没写端口时用）。
private func defaultPort(driver: String): UInt16 {
    match (driver) {
        case "mysql" | "mariadb" => return 3306u16
        case "pg" | "postgres" | "opengauss" => return 5432u16
        case _ => return 0u16
    }
}

/// 解析连接串：scheme://user:password@host:port/database。
///
/// 口令里的 @ : / 等保留字符走百分号编码（RFC 3986）。
/// 形态不合要求时返回 None——宁可启动失败，也不要拿半截参数去建连。
public func parseDsn(raw: String): Option<Endpoint> {
    let schemeEnd = match (raw.indexOf("://")) {
        case Some(i) => i
        case None => return None
    }
    let scheme = raw[0..schemeEnd].toAsciiLower()
    if (scheme.isEmpty()) {
        return None
    }
    let rest = raw[schemeEnd + 3..raw.size]

    // userinfo 与 host 部分以最后一个 '@' 分界（未编码的 @ 落在口令里也能解析）
    let at = lastIndexOfByte(rest, b'@')
    if (at < 0) {
        return None
    }
    let userinfo = rest[0..at]
    let hostpart = rest[at + 1..rest.size]

    // userinfo 内以第一个 ':' 分界
    let colon = match (userinfo.indexOf(":")) {
        case Some(i) => i
        case None => return None
    }
    let user = match (percentDecode(userinfo[0..colon])) {
        case Some(v) => v
        case None => return None
    }
    let password = match (percentDecode(userinfo[colon + 1..userinfo.size])) {
        case Some(v) => v
        case None => return None
    }

    // host 部分与库名以第一个 '/' 分界
    let slash = match (hostpart.indexOf("/")) {
        case Some(i) => i
        case None => return None
    }
    let hostPort = hostpart[0..slash]
    let database = match (percentDecode(hostpart[slash + 1..hostpart.size])) {
        case Some(v) => v
        case None => return None
    }
    if (hostPort.isEmpty() || database.isEmpty()) {
        return None
    }

    // host:port —— 端口取最后一个 ':' 之后的部分
    var host = hostPort
    var port = defaultPort(scheme)
    let portColon = lastIndexOfByte(hostPort, b':')
    if (portColon >= 0) {
        host = hostPort[0..portColon]
        let portText = hostPort[portColon + 1..hostPort.size]
        match (UInt16.tryParse(portText)) {
            case Some(p) => port = p
            case None => return None
        }
    }
    if (host.isEmpty() || port == 0u16) {
        return None
    }
    return Some(Endpoint(scheme, host, port, database, user, password))
}

/// 百分号解码：%XX → 字节，再按 UTF-8 解码；遇到非法转义返回 None。
public func percentDecode(text: String): Option<String> {
    let bytes = ArrayList<Byte>()
    let raw = text.toArray()
    var i: Int64 = 0
    while (i < raw.size) {
        let b = raw[i]
        if (b == b'%') {
            if (i + 2 >= raw.size) {
                return None
            }
            let hi = hexValue(raw[i + 1])
            let lo = hexValue(raw[i + 2])
            match ((hi, lo)) {
                case (Some(h), Some(l)) => bytes.add(UInt8(Int64(h) * 16 + Int64(l)))
                case _ => return None
            }
            i += 3
        } else {
            bytes.add(b)
            i += 1
        }
    }
    try {
        return Some(String.fromUtf8(bytes.toArray()))
    } catch (e: Exception) {
        return None
    }
}

/// 单个十六进制字符的数值。
private func hexValue(b: Byte): Option<UInt8> {
    if (b >= b'0' && b <= b'9') {
        return Some(b - b'0')
    }
    if (b >= b'a' && b <= b'f') {
        return Some(b - b'a' + 10)
    }
    if (b >= b'A' && b <= b'F') {
        return Some(b - b'A' + 10)
    }
    return None
}

/// 字节在字符串里的最后一次出现位置；没有则返回 -1。
private func lastIndexOfByte(text: String, target: Byte): Int64 {
    var found: Int64 = -1
    let raw = text.toArray()
    var i: Int64 = 0
    while (i < raw.size) {
        if (raw[i] == target) {
            found = i
        }
        i += 1
    }
    return found
}

/// 装载作业参数：命令行参数覆盖环境变量，环境变量覆盖缺省值。
///
/// 支持的参数：
///   --src-table=NAME   源表名
///   --dst-table=NAME   目标表名
///   --dst-schema=NAME  目标 schema
///   --batch=N          每批行数
///   --keep-target      同步前不清空目标表
public func loadOptions(getEnv: EnvLookup, args: Array<String>): Option<SyncOptions> {
    let mysqlDsn = match (getEnv("CANGLIN_MYSQL_DSN")) {
        case Some(v) => v
        case None => DEFAULT_MYSQL_DSN
    }
    let pgDsn = match (getEnv("CANGLIN_PG_DSN")) {
        case Some(v) => v
        case None => DEFAULT_PG_DSN
    }
    let source = match (parseDsn(mysqlDsn)) {
        case Some(v) => v
        case None => return None
    }
    let target = match (parseDsn(pgDsn)) {
        case Some(v) => v
        case None => return None
    }

    var srcTable = "src_users"
    var dstTable = "dst_users"
    var dstSchema = "public"
    var batchRows: Int64 = 500
    var truncateTarget = true

    for (arg in args) {
        if (arg == "--keep-target") {
            truncateTarget = false
        } else if (arg.startsWith("--src-table=")) {
            srcTable = arg["--src-table=".size..arg.size]
        } else if (arg.startsWith("--dst-table=")) {
            dstTable = arg["--dst-table=".size..arg.size]
        } else if (arg.startsWith("--dst-schema=")) {
            dstSchema = arg["--dst-schema=".size..arg.size]
        } else if (arg.startsWith("--batch=")) {
            match (Int64.tryParse(arg["--batch=".size..arg.size])) {
                case Some(v) => batchRows = v
                case None => return None
            }
        }
    }

    // 表名/schema 会被拼进 SQL：只接受普通标识符，杜绝注入。
    if (!isSafeIdentifier(srcTable) || !isSafeIdentifier(dstTable) || !isSafeIdentifier(dstSchema)) {
        return None
    }
    if (batchRows <= 0) {
        return None
    }
    return Some(SyncOptions(source, target, srcTable, dstTable, dstSchema, batchRows, truncateTarget))
}

/// 进程环境变量读取器。
public func systemEnv(key: String): Option<String> {
    return getVariable(key)
}

/// 标识符白名单：字母、数字、下划线，且不以数字开头。
public func isSafeIdentifier(name: String): Bool {
    if (name.isEmpty()) {
        return false
    }
    let raw = name.toArray()
    for (b in raw) {
        let ok = (b >= b'a' && b <= b'z') || (b >= b'A' && b <= b'Z') || (b >= b'0' && b <= b'9') || b == b'_'
        if (!ok) {
            return false
        }
    }
    let first = raw[0]
    return !(first >= b'0' && first <= b'9')
}
