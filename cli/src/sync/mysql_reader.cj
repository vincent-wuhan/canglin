package canglin_cli.sync

import driver.api.*
import kernel.channel.Channel
import kernel.spi.Reader
import mysql_driver.*

/// MySQL 读侧：分页 SELECT → Record → Channel。
///
/// 每页 batchRows 行，按主键列升序 + LIMIT/OFFSET 翻页——分页必须有确定序，
/// 否则翻页期间源表变动会导致漏读/重读。
/// 产出完毕后必须 close 管道，消费方据此收到 EOF 退出（见 kernel.spi.Reader）。
public class MysqlReader <: Reader {
    private let conn: Connection
    private let table: String
    private let columns: Array<String>
    private let orderBy: String
    private let batchRows: Int64
    private var produced: Int64 = 0

    public init(conn: Connection, table: String, columns: Array<String>, orderBy: String, batchRows: Int64) {
        this.conn = conn
        this.table = table
        this.columns = columns
        this.orderBy = orderBy
        this.batchRows = batchRows
        this.produced = 0
    }

    public func read(out: Channel): Unit {
        var offset: Int64 = 0
        while (true) {
            match (this.conn.query(pageSql(offset))) {
                case Ok(rs) =>
                    if (rs.rows.size == 0) {
                        break
                    }
                    for (rec in mapRowSet(rs)) {
                        out.send(rec)
                        produced += 1
                    }
                    // 末页：行数不足一页 → 读完
                    if (rs.rows.size < this.batchRows) {
                        break
                    }
                    offset += this.batchRows
                case Err(e) =>
                    throw Exception("MySQL 分页读取失败（表 ${table}，offset=${offset}）：${e}")
            }
        }
        out.close()
    }

    /// 已产出的行数（诊断用）。
    public func producedRows(): Int64 {
        return produced
    }

    /// 一页的 SELECT 语句。
    private func pageSql(offset: Int64): String {
        let sb = StringBuilder()
        sb.append("SELECT ")
        for (i in 0..columns.size) {
            if (i > 0) {
                sb.append(", ")
            }
            sb.append(quoteMySqlIdentifier(columns[i]))
        }
        sb.append(" FROM ")
        sb.append(quoteMySqlIdentifier(table))
        sb.append(" ORDER BY ")
        sb.append(quoteMySqlIdentifier(orderBy))
        sb.append(" LIMIT ")
        sb.append(this.batchRows.toString())
        sb.append(" OFFSET ")
        sb.append(offset.toString())
        return sb.toString()
    }
}

/// MySQL 标识符加反引号。
public func quoteMySqlIdentifier(name: String): String {
    return "`" + name + "`"
}
