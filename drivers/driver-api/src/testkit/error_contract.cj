package driver.testkit

import driver.api.*

// 错误四分类 + 关闭幂等的**驱动无关契约探针**（PT9）。
//
// spec 要求「使用错误密码或不可达主机调用连接入口，返回包含错误类别的失败结果
// （认证失败/网络不可达），而非裸异常或 panic」，且「close SHALL 幂等」。
// 这三条语义属于 driver.api 的 SPI 契约，不属于某个具体适配器：
// MySQL 与 PG/openGauss 的异常文案、异常类型都不同，但**归类口径必须一致**。
//
// 因此把「四次失败 + 两次 close」的探测与判定收敛到本包，
// 各适配器测试只需给出自己的 DbDriver 与连接参数即可复用同一份断言，
// 避免两个适配器各写一份、各漂移一份。
//
// 说明：探针只观察适配器给出的 DbError 类别，不做文案判断——
// 文案 → 类别的映射是各适配器内部的事（mysql_driver.classifyDbError 等）。

/// 错误分类探针结果。
///
/// 每个字段都是 Option：Some(e) 表示操作按预期失败、失败类别为 e；
/// None 表示操作**竟然成功**（契约不成立，需由调用方断言失败）。
public struct ErrorClassificationReport {
    /// 错误口令建连的错误。
    public let wrongPassword: Option<DbError>
    /// 不可达端口（端口无人监听）建连的错误。
    public let unreachablePort: Option<DbError>
    /// 不可达主机（域名解析失败）建连的错误。
    public let unreachableHost: Option<DbError>
    /// 查询不存在的表返回的错误。
    public let missingTable: Option<DbError>
    /// 正确参数是否建连成功（探针前置条件；false 时 missingTable 无意义）。
    public let connected: Bool

    public init(
        wrongPassword: Option<DbError>,
        unreachablePort: Option<DbError>,
        unreachableHost: Option<DbError>,
        missingTable: Option<DbError>,
        connected: Bool
    ) {
        this.wrongPassword = wrongPassword
        this.unreachablePort = unreachablePort
        this.unreachableHost = unreachableHost
        this.missingTable = missingTable
        this.connected = connected
    }
}

/// 关闭幂等探针结果。
public struct CloseIdempotencyReport {
    /// 正确参数是否建连成功（探针前置条件）。
    public let connected: Bool
    /// 第一次 close 是否抛出异常。
    public let firstCloseThrew: Bool
    /// 第二次 close 是否抛出异常。
    public let secondCloseThrew: Bool
    /// 关闭后查询是否以错误结果返回（而非抛异常或返回成功）。
    public let queryAfterCloseFailed: Bool
    /// 关闭后读元数据是否以错误结果返回。
    public let metadataAfterCloseFailed: Bool

    public init(
        connected: Bool,
        firstCloseThrew: Bool,
        secondCloseThrew: Bool,
        queryAfterCloseFailed: Bool,
        metadataAfterCloseFailed: Bool
    ) {
        this.connected = connected
        this.firstCloseThrew = firstCloseThrew
        this.secondCloseThrew = secondCloseThrew
        this.queryAfterCloseFailed = queryAfterCloseFailed
        this.metadataAfterCloseFailed = metadataAfterCloseFailed
    }
}

/// 探测四类错误的归类：错误口令 / 不可达端口 / 不可达主机 / 查询不存在的表。
///
/// - drv：被测适配器
/// - good：正确连接参数（用于查不存在的表）
/// - wrongPassword：仅口令不同的连接参数
/// - unreachablePort：端口无人监听的连接参数
/// - unreachableHost：域名无法解析的连接参数
/// - missingTableSql：查询不存在表的 SQL
public func probeErrorClassification(
    drv: DbDriver,
    good: ConnConfig,
    wrongPassword: ConnConfig,
    unreachablePort: ConnConfig,
    unreachableHost: ConnConfig,
    missingTableSql: String
): ErrorClassificationReport {
    let authErr = connectFailure(drv, wrongPassword)
    let portErr = connectFailure(drv, unreachablePort)
    let hostErr = connectFailure(drv, unreachableHost)

    var connected = false
    var missingErr: Option<DbError> = None
    match (drv.connect(good)) {
        case Ok(conn) =>
            connected = true
            match (conn.query(missingTableSql)) {
                case Ok(_) => missingErr = None
                case Err(e) => missingErr = Some(e)
            }
            conn.close()
        case Err(_) => ()
    }

    return ErrorClassificationReport(authErr, portErr, hostErr, missingErr, connected)
}

/// 探测关闭幂等：连续两次 close 不抛异常，且关闭后连接以错误结果而非异常回应。
public func probeCloseIdempotency(drv: DbDriver, good: ConnConfig): CloseIdempotencyReport {
    var connected = false
    var firstThrew = false
    var secondThrew = false
    var queryFailed = false
    var metadataFailed = false

    match (drv.connect(good)) {
        case Ok(conn) =>
            connected = true
            try {
                conn.close()
            } catch (e: Exception) {
                firstThrew = true
            }
            try {
                conn.close()
            } catch (e: Exception) {
                secondThrew = true
            }
            match (conn.query("SELECT 1")) {
                case Ok(_) => queryFailed = false
                case Err(_) => queryFailed = true
            }
            match (conn.listSchemas()) {
                case Ok(_) => metadataFailed = false
                case Err(_) => metadataFailed = true
            }
        case Err(_) => ()
    }

    return CloseIdempotencyReport(connected, firstThrew, secondThrew, queryFailed, metadataFailed)
}

/// 建连失败时取错误类别；建连竟然成功则返回 None。
private func connectFailure(drv: DbDriver, cfg: ConnConfig): Option<DbError> {
    match (drv.connect(cfg)) {
        case Ok(conn) =>
            conn.close()
            return None
        case Err(e) => return Some(e)
    }
}

/// 错误类别判定（四个 DbError 各一）。
public func isAuthFailed(e: DbError): Bool {
    return match (e) {
        case AuthFailed(_) => true
        case _ => false
    }
}

public func isNetworkUnreachable(e: DbError): Bool {
    return match (e) {
        case NetworkUnreachable(_) => true
        case _ => false
    }
}

public func isQueryError(e: DbError): Bool {
    return match (e) {
        case QueryError(_) => true
        case _ => false
    }
}

public func isProtocolError(e: DbError): Bool {
    return match (e) {
        case ProtocolError(_) => true
        case _ => false
    }
}
