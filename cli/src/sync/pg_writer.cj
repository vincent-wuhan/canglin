package canglin_cli.sync

import driver.api.*
import kernel.channel.Channel
import kernel.record.*
import kernel.spi.*
import std.collection.*

/// PG 写侧：逐行判定 → 批量事务写入。
///
/// 脏行口径：行级判定不通过（类型错配、超长、NULL 进 NOT NULL 列）的行不落库，
/// 计入 dirty 并跳过，作业不中断（spec：脏行不中断作业）。
///
/// 写入口径：一批一个事务（BEGIN → 多行 INSERT → COMMIT）。
/// 整批失败时回滚并逐行重试——把真正被目标库拒绝的那行单独判脏，
/// 其余行照常落库（不让一行坏数据拖垮整批）。
public class PgWriter <: Writer {
    private let conn: Connection
    private let table: String
    private let columnNames: Array<String>
    private let bindings: Array<ColumnBinding>
    private let batchRows: Int64
    private let samples: ArrayList<String>
    private var pending: ArrayList<Array<String>>
    private var okCount: Int64 = 0
    private var dirtyCount: Int64 = 0
    private var lastError: String = ""

    public init(conn: Connection, schema: String, table: String, columnNames: Array<String>,
        bindings: Array<ColumnBinding>, batchRows: Int64) {
        this.conn = conn
        this.table = qualifiedName(schema, table)
        this.columnNames = columnNames
        this.bindings = bindings
        this.batchRows = batchRows
        this.samples = ArrayList<String>()
        this.pending = ArrayList<Array<String>>()
    }

    public func write(src: Channel): WriteStat {
        while (true) {
            match (src.recv()) {
                case Some(rec) => accept(rec)
                case None => break
            }
        }
        // 收尾：把不足一批的余量落库
        flush()
        return WriteStat(okCount, dirtyCount)
    }

    /// 脏行原因样本（最多 5 条，供日志定位）。
    public func dirtySamples(): Array<String> {
        return samples.toArray()
    }

    /// 收到的最后一条错误（目标库拒绝写入时的原因）。
    public func lastErrorText(): String {
        return lastError
    }

    private func accept(rec: Record): Unit {
        match (encodeRow(rec, bindings)) {
            case Encoded(values) =>
                pending.add(values)
                if (pending.size >= this.batchRows) {
                    flush()
                }
            case Rejected(reason) =>
                dirtyCount += 1
                addSample(reason)
        }
    }

    /// 落库一批。
    private func flush(): Unit {
        if (pending.size == 0) {
            return
        }
        let rows = pending.toArray()
        pending = ArrayList<Array<String>>()
        if (execBatch(rows)) {
            okCount += rows.size
            return
        }
        // 整批失败：回滚后逐行重试，把真正出错的那行单独判脏
        execStatement("ROLLBACK")
        for (r in rows) {
            let single = ArrayList<Array<String>>()
            single.add(r)
            if (execBatch(single.toArray())) {
                okCount += 1
            } else {
                execStatement("ROLLBACK")
                dirtyCount += 1
                addSample("目标库拒绝该行：${lastError}")
            }
        }
    }

    /// 一个事务写一批；成功返回 true，失败返回 false（错误记在 lastError）。
    private func execBatch(rows: Array<Array<String>>): Bool {
        execStatement("BEGIN")
        match (conn.query(buildInsertSql(table, columnNames, rows))) {
            case Ok(_) =>
                execStatement("COMMIT")
                return true
            case Err(e) =>
                lastError = e.toString()
                return false
        }
    }

    /// 执行一条控制语句（事务控制/清表）；失败只记错误，不抛。
    private func execStatement(sql: String): Unit {
        match (conn.query(sql)) {
            case Ok(_) => ()
            case Err(e) => lastError = e.toString()
        }
    }

    private func addSample(text: String): Unit {
        if (samples.size < 5) {
            samples.add(text)
        }
    }
}
