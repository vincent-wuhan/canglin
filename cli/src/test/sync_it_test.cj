package canglin_cli.test

import std.unittest.*
import std.fs.*
import std.time.*
import driver.api.*
import mysql_driver.*
import pgdriver.*
import canglin_cli.sync.*

// PT10 L2 集成测试：MySQL → PostgreSQL 端到端。
//
// 连接串一律来自环境变量，与 CLI 走同一套解析与缺省值（canglin_cli.sync）：
//   CANGLIN_MYSQL_DSN  缺省 mysql://root:canglin123@127.0.0.1:3306/canglin_src
//   CANGLIN_PG_DSN     缺省 postgres://postgres:canglin123@127.0.0.1:5432/canglin_src
// 测试内不再硬编码主机与端口：端口被别的服务占住时，DSN 指向的实例就是不可用的，
// 用例必须表现为「环境没就绪」，而不是「代码坏了」。
//
// 依赖 env/init 的建表脚本：
//   01-mysql.sql  源表 src_users（万行）
//   02-pg.sql     目标表 dst_users
//   03-mysql-dirty.sql / 04-pg-dirty.sql  脏行变体的源表与目标表
//
// 口径（沿用 PT8/PT10）：
//   · 建连阶段的任何失败（DSN 解析失败 / 网络不可达 / 认证失败 / 协议错）都只说明
//     环境未就绪——打印显式 [SKIP] 声明后跳过，不判用例失败；
//   · 连上之后的断言（ok / dirty 行数、PG COUNT(*)、脏行样本）一律判失败，不静默放过。
// std.unittest 1.1.0-beta.25 只有静态 @Skip 标记、没有运行时 skip 入口，
// 被跳过的用例仍计入框架 PASSED 计数；且用例执行期间 stdout/stderr 都被框架捕获、
// 通过时不回显，所以 SKIP 声明同时落盘到 target/skip-decl.log（可用 CANGLIN_SKIP_LOG 改路径）。

/// 一轮用例的两端环境：连接串 + 已建好的连接。
private class DbPair {
    let mysqlEndpoint: Endpoint
    let pgEndpoint: Endpoint
    let mysqlConn: Connection
    let pgConn: Connection

    init(mysqlEndpoint: Endpoint, pgEndpoint: Endpoint, mysqlConn: Connection, pgConn: Connection) {
        this.mysqlEndpoint = mysqlEndpoint
        this.pgEndpoint = pgEndpoint
        this.mysqlConn = mysqlConn
        this.pgConn = pgConn
    }
}

/// SKIP 声明的落盘路径：CANGLIN_SKIP_LOG 指定，缺省写到当前目录下的 target/skip-decl.log。
private func skipLogPath(): String {
    return match (systemEnv("CANGLIN_SKIP_LOG")) {
        case Some(p) => p
        case None => "target/skip-decl.log"
    }
}

/// 追加一行到 SKIP 声明文件。
///
/// std.unittest 会在用例执行期间捕获 stdout/stderr，用例通过时不回显——
/// 所以 SKIP 声明必须落盘才留得住痕迹（stdout 仅作兜底）。
private func appendSkipLog(line: String): Unit {
    let path = skipLogPath()
    try {
        File.appendTo(path, (line + "\n").toArray())
    } catch (e: Exception) {
        println("[SKIP] 声明落盘失败（${path}）：${e.message}")
    }
}

/// 打印 SKIP 声明：被跳过的用例仍计入框架 PASSED 计数，只能靠日志留痕。
private func skipDeclare(caseName: String, reason: String): Unit {
    let note = "[SKIP] ${DateTime.now()} case=${caseName}：${reason}\n" +
        "[SKIP] 本轮端到端断言未执行；std.unittest 1.1.0-beta.25 仅有静态 @Skip 标记、" +
        "无运行时 skip 入口，故本用例仍计入框架 PASSED 计数——实例可达后重跑"
    appendSkipLog(note)
    eprintln(note)
}

/// 从环境变量取连接串并解析；未设置则用缺省值，解析不出来返回 None。
private func endpointFromEnv(key: String, fallback: String): Option<Endpoint> {
    let raw = match (systemEnv(key)) {
        case Some(v) => v
        case None => fallback
    }
    return parseDsn(raw)
}

/// 建立两端连接：任一端不可用就打印 SKIP 声明并返回 None。
private func connectPair(caseName: String): Option<DbPair> {
    let mysqlEp = match (endpointFromEnv("CANGLIN_MYSQL_DSN", DEFAULT_MYSQL_DSN)) {
        case Some(e) => e
        case None =>
            skipDeclare(caseName, "CANGLIN_MYSQL_DSN 不是合法连接串" +
                "（期望 scheme://user:password@host:port/database）")
            return None
    }
    let pgEp = match (endpointFromEnv("CANGLIN_PG_DSN", DEFAULT_PG_DSN)) {
        case Some(e) => e
        case None =>
            skipDeclare(caseName, "CANGLIN_PG_DSN 不是合法连接串" +
                "（期望 scheme://user:password@host:port/database）")
            return None
    }
    let mysqlConn = match (MysqlDriver().connect(
            ConnConfig("mysql", mysqlEp.host, mysqlEp.port, mysqlEp.database,
                mysqlEp.user, mysqlEp.password))) {
        case Ok(c) => c
        case Err(e) =>
            skipDeclare(caseName, "MySQL ${describeEndpoint(mysqlEp)} 建连失败：${e}")
            return None
    }
    let pgConn = match (PgDriver().connect(
            ConnConfig("pg", pgEp.host, pgEp.port, pgEp.database, pgEp.user, pgEp.password))) {
        case Ok(c) => c
        case Err(e) =>
            skipDeclare(caseName, "PG ${describeEndpoint(pgEp)} 建连失败：${e}")
            mysqlConn.close()
            return None
    }
    return Some(DbPair(mysqlEp, pgEp, mysqlConn, pgConn))
}

/// 万行同步：ok=10000 dirty=0，PG 侧 COUNT(*)=10000。
@Test
func testSyncTenThousandRows(): Unit {
    let pair = match (connectPair("testSyncTenThousandRows")) {
        case Some(p) => p
        case None => return
    }
    let opts = SyncOptions(pair.mysqlEndpoint, pair.pgEndpoint,
        "src_users", "dst_users", "public", 500, true)

    let outcome = match (runSyncJob(pair.mysqlConn, pair.pgConn, opts)) {
        case Ok(o) => o
        case Err(e) => @Fail("同步失败：${e}")
    }
    @Assert(outcome.ok == 10000)
    @Assert(outcome.dirty == 0)
    match (countRowsInTable(pair.pgConn, "public", "dst_users")) {
        case Ok(n) => @Assert(n == 10000)
        case Err(e) => @Fail("COUNT(*) 失败：${e}")
    }

    pair.mysqlConn.close()
    pair.pgConn.close()
}

/// 脏行变体：50 行类型错配 → dirty=50 ok=9950，作业不中断。
///
/// 脏行变体的源表 src_users_dirty 把 score 声明成 VARCHAR，
/// 其中 50 行的值不是数字（N/A）——与目标列 DOUBLE PRECISION 类型错配。
/// 源表由 env/init/03-mysql-dirty.sql 建表灌数（MySQL 适配器的 query()
/// 只支持 SELECT，建表/灌数走不了驱动，见 env/driver-notes.md）。
@Test
func testSyncWithDirtyRows(): Unit {
    let pair = match (connectPair("testSyncWithDirtyRows")) {
        case Some(p) => p
        case None => return
    }
    let opts = SyncOptions(pair.mysqlEndpoint, pair.pgEndpoint,
        "src_users_dirty", "dst_users_dirty", "public", 500, true)

    let outcome = match (runSyncJob(pair.mysqlConn, pair.pgConn, opts)) {
        case Ok(o) => o
        case Err(e) => @Fail(
            "脏行变体同步失败：${e}；请确认已执行 env/init/03-mysql-dirty.sql 与 env/init/04-pg-dirty.sql")
    }
    @Assert(outcome.ok == 9950)
    @Assert(outcome.dirty == 50)
    match (countRowsInTable(pair.pgConn, "public", "dst_users_dirty")) {
        case Ok(n) => @Assert(n == 9950)
        case Err(e) => @Fail("COUNT(*) 失败：${e}")
    }
    // 脏行原因要留痕，便于定位
    @Assert(outcome.dirtySamples.size >= 1)

    pair.mysqlConn.close()
    pair.pgConn.close()
}
