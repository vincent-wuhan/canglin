package canglin_cli.sync

import kernel.record.*
import std.collection.*
import std.convert.*

/// 目标表列规格（来自 PG information_schema）。
public struct TargetColumn {
    /// 列名。
    public let name: String
    /// 数据库侧类型名（小写，如 "character varying" / "bigint" / "timestamp without time zone"）。
    public let dataType: String
    /// 字符数上限（character_maximum_length）；-1 表示不限。
    public let maxLength: Int64
    /// 是否可空。
    public let nullable: Bool

    public init(name: String, dataType: String, maxLength: Int64, nullable: Bool) {
        this.name = name
        this.dataType = dataType
        this.maxLength = maxLength
        this.nullable = nullable
    }
}

/// 源列 → 目标列的绑定：一个源列下标 + 目标列规格。
public struct ColumnBinding {
    public let sourceIndex: Int64
    public let target: TargetColumn

    public init(sourceIndex: Int64, target: TargetColumn) {
        this.sourceIndex = sourceIndex
        this.target = target
    }
}

/// 一行的编码结果：编码成功（得到各列字面量）或被判为脏行（带原因）。
public enum RowEncode {
    | Encoded(Array<String>)
    | Rejected(String)
}

/// PG 时间戳字面量的文本格式。
///
/// 必须与 MySQL 适配器承载 DATETIME 的格式一致（mysql_driver.DATE_TIME_FORMAT），
/// 否则源侧读出的时间会以另一种文本形态进目标库。测试里有一条断言钉住这个约定。
public const PG_TIMESTAMP_FORMAT = "yyyy-MM-dd HH:mm:ss"

/// 同步的列清单：源表与目标表同名同序。
/// 与 env/init/01-mysql.sql、env/init/02-pg.sql 的 DDL 对齐。
public let SYNC_COLUMNS: Array<String> = ["id", "name", "score", "note", "created_at"]

/// 源列 → 目标列的绑定表。
///
/// 两侧列集合必须完全一致：源列在目标缺列 = 数据丢失，目标列在源缺列 = 目标有
/// 源填不上的必填列。任一情况都直接失败，不做静默丢列。
public func buildBindings(sourceColumns: Array<String>, targetColumns: Array<TargetColumn>): Option<Array<ColumnBinding>> {
    let bindings = ArrayList<ColumnBinding>()
    for (t in targetColumns) {
        var found = false
        for (i in 0..sourceColumns.size) {
            if (sourceColumns[i] == t.name) {
                bindings.add(ColumnBinding(i, t))
                found = true
                break
            }
        }
        if (!found) {
            return None
        }
    }
    if (bindings.size != sourceColumns.size) {
        return None
    }
    return Some(bindings.toArray())
}

/// 一行 → 目标列字面量列表。
///
/// 类型不兼容（类型错配）、超长、NULL 落到 NOT NULL 列的行走 Rejected 分支，
/// 由写侧计入脏行并跳过——作业不中断。
public func encodeRow(rec: Record, bindings: Array<ColumnBinding>): RowEncode {
    let values = ArrayList<String>()
    for (b in bindings) {
        if (b.sourceIndex >= rec.size()) {
            return Rejected("源行只有 ${rec.size()} 列，取不到第 ${b.sourceIndex} 列")
        }
        let col = rec.get(b.sourceIndex)
        match (literalOf(col, b.target)) {
            case Some(v) => values.add(v)
            case None => return Rejected(rejectReason(col, b.target))
        }
    }
    return Encoded(values.toArray())
}

/// 源值类型与目标列类型是否兼容（类别级判定）。
///
/// 口径是「一一对应 + 无损放宽」：整型列收整型、浮点列收浮点、字符列收字符串、
/// 时间列收日期时间、二进制列收字节；整型可放宽进浮点/数值。
/// 文本进数值列属于**条件兼容**：类别可放宽，但具体值解析不出来就是脏行，
/// 值级判定在 literalOf 里做。
public func typeCompatible(col: Column, target: TargetColumn): Bool {
    match (col) {
        case Column.Null => return target.nullable
        case Column.Long(_) => return isNumericTarget(target.dataType)
        case Column.Double(_) => return isFloatTarget(target.dataType)
        case Column.Str(_) => return isTextTarget(target.dataType) || isNumericTarget(target.dataType)
        case Column.`Bool`(_) => return target.dataType == "boolean"
        case Column.Date(_) => return isTemporalTarget(target.dataType)
        case Column.Bytes(_) => return target.dataType == "bytea"
    }
}

/// 源值 → PG 字面量（值级判定：类别兼容 + 值本身可表示）。
public func literalOf(col: Column, target: TargetColumn): Option<String> {
    match (col) {
        case Column.Null =>
            if (!target.nullable) {
                return None
            }
            return Some("NULL")
        case Column.Long(v) =>
            if (!isNumericTarget(target.dataType)) {
                return None
            }
            if (target.dataType == "integer" && !fitsInt32(v)) {
                return None
            }
            if (target.dataType == "smallint" && !fitsInt16(v)) {
                return None
            }
            return Some(v.toString())
        case Column.Double(v) =>
            if (!isFloatTarget(target.dataType)) {
                return None
            }
            return Some(v.toString())
        case Column.Str(s) =>
            if (isNumericTarget(target.dataType)) {
                return numericLiteralOf(s, target)
            }
            if (!isTextTarget(target.dataType)) {
                return None
            }
            if (target.maxLength >= 0 && utf8CharCount(s) > target.maxLength) {
                return None
            }
            return pgTextLiteral(s)
        case Column.`Bool`(b) =>
            if (target.dataType != "boolean") {
                return None
            }
            return Some(if (b) { "TRUE" } else { "FALSE" })
        case Column.Date(d) =>
            if (!isTemporalTarget(target.dataType)) {
                return None
            }
            return pgTextLiteral(d.format(PG_TIMESTAMP_FORMAT))
        case Column.Bytes(bs) =>
            if (target.dataType != "bytea") {
                return None
            }
            return Some(pgByteaLiteral(bs))
    }
}

/// 文本 → 数值列字面量（放宽路径）：解析不出来返回 None（判为类型错配脏行）。
private func numericLiteralOf(text: String, target: TargetColumn): Option<String> {
    let trimmed = text.trimAscii()
    if (trimmed.isEmpty()) {
        return None
    }
    if (isIntegerTarget(target.dataType)) {
        match (Int64.tryParse(trimmed)) {
            case Some(v) =>
                if (target.dataType == "integer" && !fitsInt32(v)) {
                    return None
                }
                if (target.dataType == "smallint" && !fitsInt16(v)) {
                    return None
                }
                return Some(v.toString())
            case None => return None
        }
    }
    match (Float64.tryParse(trimmed)) {
        case Some(v) => return Some(v.toString())
        case None => return None
    }
}

/// 整型是否落在 int32 范围内。
private func fitsInt32(v: Int64): Bool {
    return v >= -2147483648 && v <= 2147483647
}

/// 整型是否落在 int16 范围内。
private func fitsInt16(v: Int64): Bool {
    return v >= -32768 && v <= 32767
}

/// 目标列是否是整型。
public func isIntegerTarget(dataType: String): Bool {
    return dataType == "bigint" || dataType == "integer" || dataType == "smallint"
}

/// 目标列是否是浮点/数值型。
public func isFloatTarget(dataType: String): Bool {
    return dataType == "double precision" || dataType == "real" || dataType == "numeric"
}

/// 目标列是否是数值型（整型也算）。
public func isNumericTarget(dataType: String): Bool {
    return isIntegerTarget(dataType) || isFloatTarget(dataType)
}

/// 目标列是否是字符型。
public func isTextTarget(dataType: String): Bool {
    return dataType == "character varying" || dataType == "character" || dataType == "text"
}

/// 目标列是否是时间型。
public func isTemporalTarget(dataType: String): Bool {
    return dataType == "timestamp without time zone" || dataType == "timestamp with time zone" ||
        dataType == "date"
}

/// 源值类型的短名（用于脏行原因说明）。
public func columnTypeName(col: Column): String {
    match (col) {
        case Column.Null => return "Null"
        case Column.Long(_) => return "Long"
        case Column.Double(_) => return "Double"
        case Column.Str(_) => return "Str"
        case Column.`Bool`(_) => return "Bool"
        case Column.Date(_) => return "Date"
        case Column.Bytes(_) => return "Bytes"
    }
}

/// 脏行原因（值级判定失败时的说明）。
public func rejectReason(col: Column, target: TargetColumn): String {
    match (col) {
        case Column.Null =>
            return "列 ${target.name} 是 NOT NULL，源值为 NULL"
        case Column.Long(v) =>
            if (isIntegerTarget(target.dataType)) {
                return "列 ${target.name}（${target.dataType}）的值 ${v} 超出该类型取值范围"
            }
            return "列 ${target.name}（${target.dataType}）与源值类型 ${columnTypeName(col)} 不兼容"
        case Column.Str(s) =>
            if (isTextTarget(target.dataType)) {
                if (target.maxLength >= 0 && utf8CharCount(s) > target.maxLength) {
                    return "列 ${target.name} 的值长度 ${utf8CharCount(s)} 字符，超出目标上限 ${target.maxLength}"
                }
            } else if (isNumericTarget(target.dataType)) {
                return "列 ${target.name}（${target.dataType}）类型错配：源值文本「${ellipsis(s)}」无法解析为数值"
            }
            return "列 ${target.name}（${target.dataType}）与源值类型 ${columnTypeName(col)} 不兼容"
        case _ =>
            return "列 ${target.name}（${target.dataType}）与源值类型 ${columnTypeName(col)} 不兼容"
    }
}

/// 截断长文本（脏行原因里只留头一段，避免日志刷屏）。
private func ellipsis(text: String): String {
    let limit: Int64 = 32
    if (utf8CharCount(text) <= limit) {
        return text
    }
    let bytes = text.toArray()
    let sb = StringBuilder()
    var i: Int64 = 0
    var chars: Int64 = 0
    while (i < bytes.size && chars < limit) {
        sb.append(bytes[i])
        // 跳过 UTF-8 续字节
        if ((bytes[i] & 0xC0) != 0x80) {
            chars += 1
        }
        i += 1
    }
    return "${sb.toString()}..."
}

/// 拼 INSERT 语句：INSERT INTO 表 (列...) VALUES (...), (...)。
///
/// 表名与列名都来自已校验的标识符白名单或服务端元数据，值都是编好的字面量。
public func buildInsertSql(table: String, columns: Array<String>, rows: Array<Array<String>>): String {
    let sb = StringBuilder()
    sb.append("INSERT INTO ")
    sb.append(table)
    sb.append(" (")
    for (i in 0..columns.size) {
        if (i > 0) {
            sb.append(", ")
        }
        sb.append(quoteIdentifier(columns[i]))
    }
    sb.append(") VALUES ")
    for (r in 0..rows.size) {
        if (r > 0) {
            sb.append(", ")
        }
        sb.append("(")
        for (c in 0..rows[r].size) {
            if (c > 0) {
                sb.append(", ")
            }
            sb.append(rows[r][c])
        }
        sb.append(")")
    }
    return sb.toString()
}

/// 标识符加双引号（PG 标准写法）；调用方已保证标识符本身安全。
public func quoteIdentifier(name: String): String {
    return "\"" + name + "\""
}

/// schema.表 的限定名（PG 写法）。
public func qualifiedName(schema: String, table: String): String {
    return "${quoteIdentifier(schema)}.${quoteIdentifier(table)}"
}
