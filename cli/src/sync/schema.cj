package canglin_cli.sync

import driver.api.*
import std.collection.*

/// 从 PG information_schema 读取目标表的列规格。
///
/// 目标列的类型/长度/可空性是脏行判定的依据——写侧不靠猜，靠服务端元数据：
/// 同一份源数据换一张目标表（列宽不同、可空性不同），判定结论就跟着变。
public func loadTargetColumns(conn: Connection, schema: String, table: String): Result<Array<TargetColumn>, DbError> {
    let sql = "SELECT column_name, data_type, character_maximum_length, is_nullable " +
        "FROM information_schema.columns WHERE table_schema = " + sqlLiteral(schema) +
        " AND table_name = " + sqlLiteral(table) + " ORDER BY ordinal_position"
    match (conn.query(sql)) {
        case Ok(rs) =>
            let out = ArrayList<TargetColumn>()
            for (row in rs.rows) {
                if (row.size < 4) {
                    continue
                }
                let name = cellText(row, 0)
                let dataType = cellText(row, 1).toAsciiLower()
                var maxLength: Int64 = -1
                match (row[2]) {
                    case RawCell.I64(v) => maxLength = v
                    case _ => ()
                }
                let nullable = cellText(row, 3).toAsciiUpper() == "YES"
                out.add(TargetColumn(name, dataType, maxLength, nullable))
            }
            return Ok(out.toArray())
        case Err(e) => return Err(e)
    }
}

/// 目标列名清单（按 ordinal_position）。
public func targetColumnNames(cols: Array<TargetColumn>): Array<String> {
    let out = ArrayList<String>()
    for (c in cols) {
        out.add(c.name)
    }
    return out.toArray()
}

/// 字符串字面量（PG 文本）；schema/表名已过标识符白名单，这里仍按字面量转义。
private func sqlLiteral(text: String): String {
    return pgTextLiteral(text) ?? "''"
}

/// 取单元格文本；非文本值一律按空串处理（information_schema 这几列都是文本/整型）。
private func cellText(row: Array<RawCell>, index: Int64): String {
    return match (row[index]) {
        case RawCell.S(v) => v
        case _ => ""
    }
}
