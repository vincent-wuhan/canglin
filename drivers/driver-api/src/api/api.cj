package driver.api

// PT6 统一驱动接口。上层（CLI / 内核）只依赖本包的类型，不感知具体驱动实现：
// 更换或新增驱动（MySQL / PG / openGauss）不需要改上层代码。
//
// 术语：Connection = 已建立的连接（可查询/读元数据）；DbDriver = 连接工厂。
// 错误一律以值形式返回（Result 的 Err），不抛裸异常——上层据此区分
// 「重试 / 改密码 / 报协议不兼容 / 当作 SQL 错误」四种处置。

/// 驱动无关的返回值：成功携带 T，失败携带错误类别 E。
///
/// 仓颉标准库未提供 Rust 风格的 Result/Ok/Err（实测 std 各包均未导出 Ok/Err
/// 构造器），故本包自定义此类型以承载「失败结果而非裸异常」的语义。
public enum Result<T, E> {
    | Ok(T)
    | Err(E)
}

/// 连接参数。
public struct ConnConfig {
    /// 驱动标识："mysql" | "pg" | "opengauss"。
    public let driver: String
    public let host: String
    public let port: UInt16
    public let database: String
    public let user: String
    /// 明文口令，仅用于建连；禁止写入日志（见 toString 的脱敏实现）。
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

/// 日志安全描述：口令脱敏。
///
/// spec 要求「密码不得写入日志」。struct 默认没有 toString（不能直接打印），
/// 这里显式提供脱敏版本，使打印连接参数这一常见动作不会泄露口令。
extend ConnConfig <: ToString {
    public func toString(): String {
        return "ConnConfig(driver: ${driver}, host: ${host}, port: ${port}, database: ${database}, user: ${user}, password: ***)"
    }
}

/// 列定义：列名 + 数据库侧类型名（如 "BIGINT" / "VARCHAR" / "TEXT"）。
public struct ColumnDef {
    public let name: String
    public let typeName: String

    public init(name: String, typeName: String) {
        this.name = name
        this.typeName = typeName
    }
}

extend ColumnDef <: Equatable<ColumnDef> {
    public operator func ==(other: ColumnDef): Bool {
        return name == other.name && typeName == other.typeName
    }
    public operator func !=(other: ColumnDef): Bool {
        return !(this == other)
    }
}

extend ColumnDef <: ToString {
    public func toString(): String {
        return "ColumnDef(${name}: ${typeName})"
    }
}

/// 查询结果集：列定义 + 行。行的每个单元格是 RawCell。
///
/// 行列数由适配器保证一致（rows[i].size == columns.size）。
public struct RowSet {
    public let columns: Array<ColumnDef>
    public let rows: Array<Array<RawCell>>

    public init(columns: Array<ColumnDef>, rows: Array<Array<RawCell>>) {
        this.columns = columns
        this.rows = rows
    }
}

/// 驱动无关的单元格值：整型 / 浮点 / 字符串 / 字节 / NULL。
///
/// 与 kernel.record.Column 的映射函数放在各适配器内（见 PT7），本包不依赖 kernel。
public enum RawCell {
    | I64(Int64)
    | F64(Float64)
    | S(String)
    | B(Array<Byte>)
    | N
}

extend RawCell <: Equatable<RawCell> {
    public operator func ==(other: RawCell): Bool {
        return match ((this, other)) {
            case (I64(l), I64(r)) => l == r
            case (F64(l), F64(r)) => l == r
            case (S(l), S(r)) => l == r
            case (B(l), B(r)) => l == r
            case (N, N) => true
            case _ => false
        }
    }
    public operator func !=(other: RawCell): Bool {
        return !(this == other)
    }
}

extend RawCell <: ToString {
    public func toString(): String {
        let sb = StringBuilder()
        sb.append("RawCell")
        match (this) {
            case I64(v) =>
                sb.append(".I64(")
                sb.append(v.toString())
                sb.append(")")
            case F64(v) =>
                sb.append(".F64(")
                sb.append(v.toString())
                sb.append(")")
            case S(v) =>
                sb.append(".S(")
                sb.append(v)
                sb.append(")")
            case B(v) =>
                sb.append(".B(")
                sb.append(v.size.toString())
                sb.append(" bytes)")
            case N =>
                sb.append(".N")
        }
        return sb.toString()
    }
}

/// 已建立的连接。
///
/// 实现约定：close 幂等——重复调用不抛异常，资源只释放一次（spec：连接关闭幂等）。
public interface Connection {
    /// 执行 SELECT，返回驱动无关的行集。
    func query(sql: String): Result<RowSet, DbError>
    /// 列出数据库（schema）清单。
    func listSchemas(): Result<Array<String>, DbError>
    /// 列出指定 schema 下的表清单。
    func listTables(schema: String): Result<Array<String>, DbError>
    /// 读取指定表的列定义（列名与类型）。
    func tableColumns(schema: String, table: String): Result<Array<ColumnDef>, DbError>
    /// 关闭连接并释放资源；幂等。
    func close(): Unit
}

/// 连接工厂：按连接参数建立连接。
public interface DbDriver {
    func connect(cfg: ConnConfig): Result<Connection, DbError>
}
