package kernel.test

// 语义契约（openspec sync-kernel spec「作业执行与统计」）：
//   - 单作业形态：Reader → Channel → Writer 流水线，跑完即结束
//   - 输出成功行数、失败行数与耗时
//   - 脏行不中断作业：行级成败由 Writer 判定并计入 WriteStat，
//     JobRunner 只搬运与汇总，不参与行级判定
//
// 本文件只依赖 kernel.spi 的接口契约（Reader / Writer / WriteStat）：
// 干净路径用 PT4 提供的内存假实现（MemoryReader / MemoryWriter）；
// 脏行注入需要一个「指定行为脏行」的 Writer——PT4 的脏行注入入口形态
// 尚未固化，故此处按 SPI 契约自实现 DirtySkipWriter。

import kernel.channel.*
import kernel.job.*
import kernel.spi.*
import std.unittest.*

/// 脏行 Writer：每 dirtyEvery 行判一行脏（模拟类型不兼容），
/// 脏行跳过并计入 dirty，其余行计入 ok；不抛错、不中断作业。
class DirtySkipWriter <: Writer {
    private let dirtyEvery: Int64

    public init(dirtyEvery: Int64) {
        this.dirtyEvery = dirtyEvery
    }

    public func write(ch: Channel): WriteStat {
        var ok: Int64 = 0
        var dirty: Int64 = 0
        var index: Int64 = 0
        while (true) {
            match (ch.recv()) {
                case Some(_) =>
                    index += 1
                    if (dirtyEvery > 0 && index % dirtyEvery == 0) {
                        dirty += 1 // 脏行：跳过，不计成功
                    } else {
                        ok += 1
                    }
                case None => break // EOF：消费完毕
            }
        }
        return WriteStat(ok, dirty)
    }
}

@Test
func testJobRunClean() {
    let runner = JobRunner()
    let stat = runner.run(MemoryReader(100), MemoryWriter())
    @Assert(stat.ok == 100)
    @Assert(stat.dirty == 0)
    @Assert(stat.elapsedMs >= 0)
}

@Test
func testJobRunTenThousandRows() {
    // spec「万行同步完整完成」的内核侧断言：成功 10000 行、失败 0 行。
    // MySQL→PG 端到端与真实库吞吐基线属 PT10 范围，这里给内存管道的基线。
    let runner = JobRunner()
    let stat = runner.run(MemoryReader(10000), MemoryWriter())
    @Assert(stat.ok == 10000)
    @Assert(stat.dirty == 0)
    var ms = stat.elapsedMs
    if (ms < 1) {
        ms = 1
    }
    println("[baseline] 10000 rows in ${stat.elapsedMs} ms, ${10000 * 1000 / ms} rows/s")
}

@Test
func testJobRunWithDirtyRows() {
    let runner = JobRunner()
    // 100 行中每 30 行判一行脏 → 第 30/60/90 行共 3 行脏
    let stat = runner.run(MemoryReader(100), DirtySkipWriter(30))
    @Assert(stat.dirty == 3)
    @Assert(stat.ok == 97)
    @Assert(stat.elapsedMs >= 0)
}
