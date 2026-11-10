package mysql_driver

import std.collection.*
import std.time.DateTime
import driver.api.*
import kernel.record.Column
import kernel.record.Record

// RawCell → kernel.record.Column 的映射收敛在适配器（PT7 要求）：
// BIGINT→Long、DOUBLE→Double、VARCHAR/TEXT→Str、DATETIME→Date、NULL→Null。
//
// driver.api.RawCell 只有 I64/F64/S/B/N 五种取值，没有日期变体，
// 所以 DATETIME 在适配层以文本（yyyy-MM-dd HH:mm:ss）承载，由本层还原成 Column.Date。

/// DATETIME 在 RawCell 侧的文本格式（与 mysqlclient4cj 自身的日期格式一致）。
public const DATE_TIME_FORMAT: String = "yyyy-MM-dd HH:mm:ss"

/// 驱动侧类型名（仓颉类型）→ 数据库类型名。
///
/// mysqlclient4cj 按协议类型给出仓颉类型名：Int64 / Float64 / String / DateTime / Array<Byte>。
/// MySQL 协议把 TEXT 与 BLOB 都编码为 0xFC，驱动无法区分，故此处统一记为 TEXT；
/// 真正的二进制内容由取值时的 UTF-8 解码失败识别（保留为字节）。
public func sqlTypeName(driverType: String): String {
    return match (driverType) {
        case "Int8" => "TINYINT"
        case "Int16" => "SMALLINT"
        case "Int32" => "INT"
        case "Int64" => "BIGINT"
        case "UInt8" => "TINYINT"
        case "UInt16" => "SMALLINT"
        case "UInt32" => "INT"
        case "UInt64" => "BIGINT"
        case "Float32" => "FLOAT"
        case "Float64" => "DOUBLE"
        case "String" => "VARCHAR"
        case "DateTime" => "DATETIME"
        case "Decimal" => "DECIMAL"
        case "Array<Byte>" => "TEXT"
        case other => other.toAsciiUpper()
    }
}

/// 单个单元格映射：RawCell + 列类型 → kernel.record.Column。
public func mapCell(cell: RawCell, typeName: String): Column {
    return match (cell) {
        case N => Column.Null
        case I64(v) => Column.Long(v)
        case F64(v) => Column.Double(v)
        case S(v) => mapTextCell(v, typeName)
        case B(v) => Column.Bytes(v)
    }
}

/// DATETIME 文本还原为日期；形态不匹配时按字符串保留，不丢数据。
private func mapTextCell(text: String, typeName: String): Column {
    if (typeName != "DATETIME" && typeName != "TIMESTAMP") {
        return Column.Str(text)
    }
    try {
        return Column.Date(DateTime.parse(text, DATE_TIME_FORMAT))
    } catch (e: Exception) {
        return Column.Str(text)
    }
}

/// 行映射：RawCell 行 → kernel.record.Record。
public func mapRow(columns: Array<ColumnDef>, row: Array<RawCell>): Record {
    let cells = ArrayList<Column>()
    for (i in 0..columns.size) {
        cells.add(mapCell(row[i], columns[i].typeName))
    }
    return Record(cells)
}

/// 结果集映射：RowSet → Record 列表（下游同步管线的入口）。
public func mapRowSet(rs: RowSet): Array<Record> {
    let out = ArrayList<Record>()
    for (row in rs.rows) {
        out.add(mapRow(rs.columns, row))
    }
    return out.toArray()
}
