package canglin_cli

import driver.api.*
import mysql_driver.*
import pgdriver.*
import canglin_cli.sync.*

// PT10 CLI：MySQL → PostgreSQL 万行同步与吞吐基线。
//
// 用法：
//   cjpm run --                 同步（源 src_users → 目标 dst_users）
//   cjpm run -- count           只打印目标表行数（COUNT(*)）
//   cjpm run -- --src-table=src_users_dirty --dst-table=dst_users_dirty   脏行变体
//
// 连接串走环境变量 CANGLIN_MYSQL_DSN / CANGLIN_PG_DSN（缺省见 sync/config.cj）。
// 表名/schema 走命令行参数，只接受普通标识符。

main(args: Array<String>): Int64 {
    if (args.contains("--help")) {
        printUsage()
        return 0
    }
    let opts = match (loadOptions(systemEnv, args)) {
        case Some(o) => o
        case None =>
            println("[canglin.cli] 参数非法（表名/schema 只接受普通标识符，批量必须为正）")
            printUsage()
            return 1
    }

    let mysqlConn = match (MysqlDriver().connect(
        ConnConfig("mysql", opts.source.host, opts.source.port, opts.source.database,
            opts.source.user, opts.source.password))) {
        case Ok(c) => c
        case Err(e) =>
            println("[canglin.cli] MySQL 建连失败（${describeEndpoint(opts.source)}）：${e}")
            return 1
    }
    let pgConn = match (PgDriver().connect(
        ConnConfig("pg", opts.target.host, opts.target.port, opts.target.database,
            opts.target.user, opts.target.password))) {
        case Ok(c) => c
        case Err(e) =>
            println("[canglin.cli] PG 建连失败（${describeEndpoint(opts.target)}）：${e}")
            mysqlConn.close()
            return 1
    }

    if (args.contains("count")) {
        match (countRowsInTable(pgConn, opts.dstSchema, opts.dstTable)) {
            case Ok(n) => println("[canglin.cli] count=${n}")
            case Err(e) =>
                println("[canglin.cli] 统计行数失败：${e}")
                pgConn.close()
                mysqlConn.close()
                return 1
        }
        pgConn.close()
        mysqlConn.close()
        return 0
    }

    println("[canglin.cli] 源=${describeEndpoint(opts.source)}/${opts.srcTable}")
    println("[canglin.cli] 目标=${describeEndpoint(opts.target)}/${opts.dstSchema}.${opts.dstTable}")
    match (runSyncJob(mysqlConn, pgConn, opts)) {
        case Ok(o) =>
            println("[canglin.cli] ok=${o.ok} dirty=${o.dirty} elapsed_ms=${o.elapsedMs} " +
                "throughput_rows_per_sec=${throughputOf(o)}")
            for (s in o.dirtySamples) {
                println("[canglin.cli] 脏行样本：${s}")
            }
            pgConn.close()
            mysqlConn.close()
            return 0
        case Err(e) =>
            println("[canglin.cli] 同步失败：${e}")
            pgConn.close()
            mysqlConn.close()
            return 1
    }
}

/// 吞吐（行/秒）：成功行数 ÷ 作业耗时。
private func throughputOf(o: SyncOutcome): Float64 {
    if (o.elapsedMs <= 0) {
        return 0.0
    }
    return Float64(o.ok) * 1000.0 / Float64(o.elapsedMs)
}

private func printUsage(): Unit {
    println("[canglin.cli] 用法：canglin_cli [count] [--src-table=NAME] [--dst-table=NAME] " +
        "[--dst-schema=NAME] [--batch=N] [--keep-target]")
    println("[canglin.cli] 环境变量：CANGLIN_MYSQL_DSN / CANGLIN_PG_DSN")
}
