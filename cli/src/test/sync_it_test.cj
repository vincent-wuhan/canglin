package canglin_cli.test

import std.convert.*
import std.unittest.*
import driver.api.*
import mysql_driver.*
import pgdriver.*
import canglin_cli.sync.*

// PT10 L2 集成测试：MySQL → PostgreSQL 端到端。
//
// 需要本机两个实例（env/docker-compose.yml 的矩阵）：
//   MySQL  127.0.0.1:3306  库 canglin_src  root/canglin123
//   PG     127.0.0.1:5432  库 canglin_src  postgres/canglin123
//
// 依赖 env/init 的建表脚本：
//   01-mysql.sql  源表 src_users（万行）
//   02-pg.sql     目标表 dst_users
//   03-mysql-dirty.sql / 04-pg-dirty.sql  脏行变体的源表与目标表
//
// 实例不可用（网络不可达）时打印显式 SKIP 声明并跳过——沿用 PT8 的同一口径：
// std.unittest 1.1.0-beta.25 只有静态 @Skip 标记、没有运行时 skip 入口，
// 故被跳过的用例仍计入框架 PASSED 计数，SKIP 声明靠 stdout 留痕。
// 连得上但断言不成立（行数不对、脏行数不对、fixture 缺失）一律判失败，不静默放过。

private const MYSQL_HOST = "127.0.0.1"
private const MYSQL_PORT: UInt16 = 3306u16
private const MYSQL_SCHEMA = "canglin_src"
private const MYSQL_USER = "root"
private const MYSQL_PASSWORD = "canglin123"

private const PG_HOST = "127.0.0.1"
private const PG_PORT: UInt16 = 5432u16
private const PG_SCHEMA = "canglin_src"
private const PG_USER = "postgres"
private const PG_PASSWORD = "canglin123"

private func mysqlConfig(): ConnConfig {
    return ConnConfig("mysql", MYSQL_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD)
}

private func pgConfig(): ConnConfig {
    return ConnConfig("pg", PG_HOST, PG_PORT, PG_SCHEMA, PG_USER, PG_PASSWORD)
}

/// 建连：不可达 → 打印 SKIP 声明并返回 None；其余失败 → 判用例失败。
private func connectOrSkip(connect: () -> Result<Connection, DbError>, label: String): Option<Connection> {
    return match (connect()) {
        case Ok(c) => Some(c)
        case Err(e) => match (e) {
            case NetworkUnreachable(_) =>
                println("[SKIP] ${label} 实例不可达：${e}")
                println("[SKIP] 本轮端到端断言未执行；std.unittest 1.1.0-beta.25 仅有静态 @Skip 标记、" +
                    "无运行时 skip 入口，故本用例仍计入框架 PASSED 计数——实例可达后重跑")
                return None
            case _ => @Fail("${label} 建连失败：${e}")
        }
    }
}

private func connectMysql(): Option<Connection> {
    return connectOrSkip({ => MysqlDriver().connect(mysqlConfig()) },
        "MySQL ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_SCHEMA}")
}

private func connectPg(): Option<Connection> {
    return connectOrSkip({ => PgDriver().connect(pgConfig()) },
        "PG ${PG_HOST}:${PG_PORT}/${PG_SCHEMA}")
}

/// 目标表行数。
private func countRows(conn: Connection, schema: String, table: String): Int64 {
    match (conn.query("SELECT COUNT(*) FROM ${schema}.${table}")) {
        case Ok(rs) =>
            if (rs.rows.size == 0) {
                @Fail("COUNT(*) 未返回行")
            }
            return match (rs.rows[0][0]) {
                case RawCell.I64(v) => v
                case _ => @Fail("COUNT(*) 返回的不是整型")
            }
        case Err(e) => @Fail("COUNT(*) 失败：${e}")
    }
}

/// 组装作业参数。
private func options(srcTable: String, dstTable: String): SyncOptions {
    return SyncOptions(
        Endpoint("mysql", MYSQL_HOST, MYSQL_PORT, MYSQL_SCHEMA, MYSQL_USER, MYSQL_PASSWORD),
        Endpoint("pg", PG_HOST, PG_PORT, PG_SCHEMA, PG_USER, PG_PASSWORD),
        srcTable, dstTable, "public", 500, true
    )
}

/// 万行同步：ok=10000 dirty=0，PG 侧 COUNT(*)=10000。
@Test
func testSyncTenThousandRows(): Unit {
    let mysqlConn = match (connectMysql()) {
        case Some(c) => c
        case None => return
    }
    let pgConn = match (connectPg()) {
        case Some(c) => c
        case None =>
            mysqlConn.close()
            return
    }

    let outcome = match (runSyncJob(mysqlConn, pgConn, options("src_users", "dst_users"))) {
        case Ok(o) => o
        case Err(e) => @Fail("同步失败：${e}")
    }
    @Assert(outcome.ok == 10000)
    @Assert(outcome.dirty == 0)
    @Assert(countRows(pgConn, "public", "dst_users") == 10000)

    mysqlConn.close()
    pgConn.close()
}

/// 脏行变体：50 行类型错配 → dirty=50 ok=9950，作业不中断。
///
/// 脏行变体的源表 src_users_dirty 把 score 声明成 VARCHAR，
/// 其中 50 行的值不是数字（N/A）——与目标列 DOUBLE PRECISION 类型错配。
/// 源表由 env/init/03-mysql-dirty.sql 建表灌数（MySQL 适配器的 query()
/// 只支持 SELECT，建表/灌数走不了驱动，见 env/driver-notes.md）。
@Test
func testSyncWithDirtyRows(): Unit {
    let mysqlConn = match (connectMysql()) {
        case Some(c) => c
        case None => return
    }
    let pgConn = match (connectPg()) {
        case Some(c) => c
        case None =>
            mysqlConn.close()
            return
    }

    let outcome = match (runSyncJob(mysqlConn, pgConn, options("src_users_dirty", "dst_users_dirty"))) {
        case Ok(o) => o
        case Err(e) => @Fail(
            "脏行变体同步失败：${e}；请确认已执行 env/init/03-mysql-dirty.sql 与 env/init/04-pg-dirty.sql")
    }
    @Assert(outcome.ok == 9950)
    @Assert(outcome.dirty == 50)
    @Assert(countRows(pgConn, "public", "dst_users_dirty") == 9950)
    // 脏行原因要留痕，便于定位
    @Assert(outcome.dirtySamples.size >= 1)

    mysqlConn.close()
    pgConn.close()
}
