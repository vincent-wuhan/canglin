package pgdriver

import std.database.sql.QueryResult
import driver.api.RawCell

// PT8 值映射：把上游 opengauss-driver 的类型标识与行值收敛到 driver.api 的
// 驱动无关模型（ColumnDef.typeName / RawCell）。
//
// 两套类型名的来源不同，必须区分：
// - query() 路径的类型名来自上游 ColumnInfo.typeName，即 oid2typename 的结果；
//   该函数把 oid 25(text) 与 1043(varchar) 统一归为 SqlVarchar，且对未知 oid
//   一律回落 SqlVarchar，故此路径下 TEXT 列的类型名会显示为 VARCHAR。
// - tableColumns() 路径的类型名来自 information_schema，是数据库侧的精确类型。
// 精确类型以 tableColumns() 为准。

/// 上游 ColumnInfo.typeName → 数据库侧规范类型名。
public func canonicalTypeName(driverType: String): String {
    // 上游数组类型名形如 "Array<SqlBigInt>"：元素类型自下标 6 起，末尾 '>' 独占一位，
    // 故切片取 [6, size-1)（仓颉切片右端开区间）。
    if (driverType.startsWith("Array<") && driverType.size > 7 && driverType[driverType.size - 1] == b'>') {
        return "${canonicalTypeName(driverType[6..driverType.size - 1])}[]"
    }
    match (driverType) {
        case "SqlBool" => return "BOOLEAN"
        case "SqlVarBinary" => return "BYTEA"
        case "SqlChar" => return "CHAR"
        case "SqlSmallInt" => return "SMALLINT"
        case "SqlInteger" => return "INTEGER"
        case "SqlBigInt" => return "BIGINT"
        case "SqlVarchar" => return "VARCHAR"
        case "SqlReal" => return "REAL"
        case "SqlDouble" => return "DOUBLE PRECISION"
        case "SqlDecimal" => return "NUMERIC"
        case "SqlDate" => return "DATE"
        case "SqlTime" => return "TIME"
        case "SqlTimestamp" => return "TIMESTAMP"
        case "SqlTimeTz" => return "TIMESTAMP WITH TIME ZONE"
        case _ => return driverType.toAsciiUpper()
    }
}

/// information_schema 的 data_type / udt_name → 数据库侧规范类型名。
public func dbTypeName(dataType: String, udtName: String): String {
    if (dataType == "ARRAY") {
        return arrayElementTypeName(udtName)
    }
    match (dataType) {
        case "bigint" => return "BIGINT"
        case "integer" => return "INTEGER"
        case "smallint" => return "SMALLINT"
        case "boolean" => return "BOOLEAN"
        case "character varying" => return "VARCHAR"
        case "character" => return "CHAR"
        case "text" => return "TEXT"
        case "numeric" => return "NUMERIC"
        case "real" => return "REAL"
        case "double precision" => return "DOUBLE PRECISION"
        case "date" => return "DATE"
        case "time without time zone" => return "TIME"
        case "time with time zone" => return "TIME WITH TIME ZONE"
        case "timestamp without time zone" => return "TIMESTAMP"
        case "timestamp with time zone" => return "TIMESTAMP WITH TIME ZONE"
        case "bytea" => return "BYTEA"
        case "uuid" => return "UUID"
        case "json" => return "JSON"
        case "jsonb" => return "JSONB"
        case _ => return dataType.toAsciiUpper()
    }
}

private func arrayElementTypeName(udtName: String): String {
    match (udtName) {
        case "_int2" => return "SMALLINT[]"
        case "_int4" => return "INTEGER[]"
        case "_int8" => return "BIGINT[]"
        case "_bool" => return "BOOLEAN[]"
        case "_text" => return "TEXT[]"
        case "_varchar" => return "VARCHAR[]"
        case "_float4" => return "REAL[]"
        case "_float8" => return "DOUBLE PRECISION[]"
        case "_numeric" => return "NUMERIC[]"
        case "_bytea" => return "BYTEA[]"
        case _ => return "${udtName.toAsciiUpper()}[]"
    }
}

/// 读取单个单元格并映射为驱动无关的 RawCell。
///
/// 取值类型按上游类型标识选择：布尔读 Bool、整型读 Int64、
/// 浮点与数值读 Float64、二进制读 Array<Byte>、其余读字符串（日期时间按
/// ISO 文本返回）。NULL 一律映射为 RawCell.N。
public func readCell(qr: QueryResult, index: Int, driverType: String): RawCell {
    match (driverType) {
        case "SqlBool" =>
            match (qr.getOrNull<Bool>(index)) {
                case Some(v) =>
                    let n = if (v) { 1 } else { 0 }
                    return RawCell.I64(n)
                case None => return RawCell.N
            }
        case "SqlSmallInt" | "SqlInteger" | "SqlBigInt" =>
            match (qr.getOrNull<Int64>(index)) {
                case Some(v) => return RawCell.I64(v)
                case None => return RawCell.N
            }
        case "SqlReal" | "SqlDouble" | "SqlDecimal" =>
            match (qr.getOrNull<Float64>(index)) {
                case Some(v) => return RawCell.F64(v)
                case None => return RawCell.N
            }
        case "SqlVarBinary" =>
            match (qr.getOrNull<Array<Byte>>(index)) {
                case Some(v) => return RawCell.B(v)
                case None => return RawCell.N
            }
        case _ =>
            match (qr.getOrNull<String>(index)) {
                case Some(v) => return RawCell.S(v)
                case None => return RawCell.N
            }
    }
}
