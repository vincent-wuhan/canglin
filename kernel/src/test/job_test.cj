package kernel.test

// 语义契约（openspec sync-kernel spec「作业执行与统计」）：
//   - 单作业形态：Reader → Channel → Writer 流水线，跑完即结束
//   - 输出成功行数、失败行数与耗时
//   - 脏行不中断作业：行级成败由 Writer 判定并计入 WriteStat，
//     JobRunner 只搬运与汇总，不参与行级判定
//
// 假实现统一在 kernel/src/test/fakes_test.cj（DirtyEveryWriter / Throwing* /
// SlowReader）与 kernel.spi（MemoryReader / MemoryWriter），本文件只写断言。

import kernel.job.*
import kernel.spi.*
import std.unittest.*

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
    let stat = runner.run(MemoryReader(100), DirtyEveryWriter(30))
    @Assert(stat.dirty == 3)
    @Assert(stat.ok == 97)
    @Assert(stat.elapsedMs >= 0)
}

@Test
func testJobRunPropagatesReaderError() {
    // Reader 侧抛异常：run() 必须原样传播异常（不吞掉、不包装成别的类型），
    // 且不能挂死——带超时的 get 是看门狗，真挂死会得到 TimeoutException，
    // 而不是让整个测试套件卡住。顺带锁住平台假设：Future.get() 重抛协程内
    // 异常且保留异常类型。
    let runner = JobRunner(capacity: 8)
    let task = spawn { runner.run(ThrowingReader(3), MemoryWriter()) }
    var outcome = "no-exception"
    try {
        task.get(Duration.second * 10)
        outcome = "no-exception"
    } catch (e: FakeError) {
        outcome = "fake-error"
    } catch (e: TimeoutException) {
        outcome = "timeout"
    }
    @Assert(outcome == "fake-error")
}

@Test
func testJobRunPropagatesWriterErrorAndJoinsReader() {
    // Writer 侧抛异常：run() 传播的是 Writer 的异常（不是读侧派生的
    // ChannelClosedException），并且必须 join 读侧协程——慢收尾的 Reader 在
    // run() 抛出时已终止，不留孤儿协程。
    let runner = JobRunner(capacity: 1)
    let signal = Signal()
    let task = spawn { runner.run(SlowReader(1000, signal), ThrowingWriter(1)) }
    var outcome = "no-exception"
    try {
        task.get(Duration.second * 10)
        outcome = "no-exception"
    } catch (e: FakeError) {
        outcome = "fake-error"
    } catch (e: TimeoutException) {
        outcome = "timeout"
    }
    @Assert(outcome == "fake-error")
    @Assert(signal.isDone())
}
