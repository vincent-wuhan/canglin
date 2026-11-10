package canglin_cli.sync

import driver.api.*
import kernel.job.JobRunner
import std.collection.*

/// 一次同步作业的结果。
public struct SyncOutcome {
    /// 成功落库的行数。
    public let ok: Int64
    /// 判为脏行并跳过的行数。
    public let dirty: Int64
    /// 作业耗时（毫秒）。
    public let elapsedMs: Int64
    /// 脏行原因样本（最多 5 条）。
    public let dirtySamples: Array<String>

    public init(ok: Int64, dirty: Int64, elapsedMs: Int64, dirtySamples: Array<String>) {
        this.ok = ok
        this.dirty = dirty
        this.elapsedMs = elapsedMs
        this.dirtySamples = dirtySamples
    }
}

/// 跑一次同步作业：读侧分页 SELECT → 管道 → 写侧批量 INSERT。
///
/// 步骤：读源列清单 → 读目标列规格（PG information_schema）→ 按列名绑定 →
/// 可选清空目标表 → 起作业（kernel.job.JobRunner 组装 Reader/Writer）。
public func runSyncJob(srcConn: Connection, dstConn: Connection, opts: SyncOptions): Result<SyncOutcome, DbError> {
    let sourceColumns = match (srcConn.tableColumns(opts.source.database, opts.srcTable)) {
        case Ok(cols) => columnNamesOf(cols)
        case Err(e) => return Err(e)
    }
    if (sourceColumns.size == 0) {
        return Err(DbError.QueryError("源表 ${opts.srcTable} 没有列"))
    }
    let targetColumns = match (loadTargetColumns(dstConn, opts.dstSchema, opts.dstTable)) {
        case Ok(cols) => cols
        case Err(e) => return Err(e)
    }
    let bindings = match (buildBindings(sourceColumns, targetColumns)) {
        case Some(bs) => bs
        case None => return Err(DbError.QueryError(
            "源表 ${opts.srcTable}（${sourceColumns.size} 列）与目标表 ${opts.dstTable}（${targetColumns.size} 列）的列集合不一致"))
    }
    let targetNames = targetColumnNames(targetColumns)

    // 清空目标表：让作业可重复执行（--keep-target 可关闭）
    if (opts.truncateTarget) {
        match (dstConn.query("TRUNCATE TABLE ${qualifiedName(opts.dstSchema, opts.dstTable)}")) {
            case Ok(_) => ()
            case Err(e) => return Err(e)
        }
    }

    let reader = MysqlReader(srcConn, opts.srcTable, sourceColumns, orderColumnOf(sourceColumns), opts.batchRows)
    let writer = PgWriter(dstConn, opts.dstSchema, opts.dstTable, targetNames, bindings, opts.batchRows)
    let stat = try {
        JobRunner().run(reader, writer)
    } catch (e: Exception) {
        return Err(DbError.QueryError("同步作业异常终止：${e.message}"))
    }
    return Ok(SyncOutcome(stat.ok, stat.dirty, stat.elapsedMs, writer.dirtySamples()))
}

/// 目标表行数（PG COUNT(*)）。
public func countRowsInTable(conn: Connection, schema: String, table: String): Result<Int64, DbError> {
    match (conn.query("SELECT COUNT(*) FROM ${qualifiedName(schema, table)}")) {
        case Ok(rs) =>
            if (rs.rows.size == 0 || rs.rows[0].size == 0) {
                return Err(DbError.QueryError("COUNT(*) 未返回行"))
            }
            return match (rs.rows[0][0]) {
                case RawCell.I64(v) => Ok(v)
                case _ => Err(DbError.QueryError("COUNT(*) 返回的不是整型"))
            }
        case Err(e) => return Err(e)
    }
}

/// ColumnDef 列表 → 列名清单。
private func columnNamesOf(cols: Array<ColumnDef>): Array<String> {
    let out = ArrayList<String>()
    for (c in cols) {
        out.add(c.name)
    }
    return out.toArray()
}

/// 分页的排序列：有 id 用 id，否则第一列——分页必须有确定序。
private func orderColumnOf(sourceColumns: Array<String>): String {
    for (c in sourceColumns) {
        if (c == "id") {
            return c
        }
    }
    return sourceColumns[0]
}
