package kernel.test

// PT4 Reader/Writer SPI 单测。
// 验收对应 openspec sync-kernel spec「Reader/Writer SPI」需求
// 场景「双侧插件独立替换」：替换任一侧实现，另一侧无需修改即可继续工作。
//
// 术语契约（极易弄反）：Reader = 生产方（send，产出后必须 close）；
// Writer = 消费方（recv 到 None 退出）。
//
// 管道容量刻意小于行数：必须真的走背压路径（生产方 send 阻塞等待消费方腾位），
// 同时验证两侧不丢不重。

import kernel.channel.*
import kernel.record.*
import kernel.spi.*
import std.collection.*
import std.unittest.*

@Test
func testMemoryReaderWriterRoundTrip() {
    // 基线：内存 Reader 产 100 行 → Channel → 内存 Writer 消费
    let ch = BoundedChannel(8)
    let reader = MemoryReader(100)
    let writer = MemoryWriter()
    // 读侧必须与写侧并发：容量 8 < 100 行，顺序执行会在第 9 行 send 时死锁
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.ok == 100)
    @Assert(stat.dirty == 0)
}

@Test
func testReplaceReaderSideOnly() {
    // 换读侧为 FileMockReader，写侧 CollectingWriter 一行不改。
    // 写侧换成「能收集行」的假实现，才谈得上断言到达内容与顺序：
    // 只断言行数的话，读侧发错内容（乱序、串行、列数不对）照样能过。
    let ch = BoundedChannel(4)
    let reader = FileMockReader(ArrayList<String>(["alpha", "beta", "gamma"]))
    let writer = CollectingWriter()
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.ok == 3)
    @Assert(stat.dirty == 0)
    @Assert(writer.rows().size == 3)
    // 到达内容与顺序：每行恰好一列，且依次为 alpha/beta/gamma
    @Assert(writer.rows()[0].size() == 1)
    @Assert(writer.rows()[1].size() == 1)
    @Assert(writer.rows()[2].size() == 1)
    @Assert(writer.rows()[0].get(0) == Column.Str("alpha"))
    @Assert(writer.rows()[1].get(0) == Column.Str("beta"))
    @Assert(writer.rows()[2].get(0) == Column.Str("gamma"))
}

@Test
func testReplaceWriterSideOnly() {
    // 换写侧为 CollectingWriter，读侧 MemoryReader 一行不改
    let ch = BoundedChannel(4)
    let reader = MemoryReader(20)
    let writer = CollectingWriter()
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.ok == 20)
    @Assert(stat.dirty == 0)
    // 写侧换成另一实现后，读侧产出的行仍被完整接收（不丢不重）
    @Assert(writer.rows().size == 20)
    // 行内容与顺序保持：首行为 Long(0)/Str("row-0")，末行为 Long(19)/Str("row-19")
    let first = writer.rows()[0]
    @Assert(first.get(0) == Column.Long(0))
    @Assert(first.get(1) == Column.Str("row-0"))
    let last = writer.rows()[19]
    @Assert(last.get(0) == Column.Long(19))
    @Assert(last.get(1) == Column.Str("row-19"))
}

@Test
func testDirtyRowCountedAndSkipped() {
    // 第 5 行判为脏行：计入 dirty 并跳过，其余行继续处理，作业不中断
    let ch = BoundedChannel(4)
    let reader = MemoryReader(10)
    let writer = MemoryWriter(5)
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.dirty == 1)
    @Assert(stat.ok == 9)
    @Assert(stat.ok + stat.dirty == 10)
}

@Test
func testCollectingWriterDirtyRowCountedAndSkipped() {
    // CollectingWriter 的 dirtyAt 分支（PT4 首版无测试锁定的死代码）：
    // 第 5 行（row-4）判脏 → 计入 dirty、跳过、不落入 rows()，其余行照常写入。
    let ch = BoundedChannel(4)
    let reader = MemoryReader(10)
    let writer = CollectingWriter(5)
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.dirty == 1)
    @Assert(stat.ok == 9)
    @Assert(stat.ok + stat.dirty == 10)
    // 脏行不写入目标：只留 9 行
    @Assert(writer.rows().size == 9)
    // 顺序保持且脏行确实缺席：row-3 之后直接是 row-5（不是 row-4）
    @Assert(writer.rows()[3].get(1) == Column.Str("row-3"))
    @Assert(writer.rows()[4].get(0) == Column.Long(5))
    @Assert(writer.rows()[4].get(1) == Column.Str("row-5"))
}

@Test
func testDirtyRowBoundaryFirstRow() {
    // 边界：dirtyAt=1 → 首行即脏
    let ch = BoundedChannel(4)
    let reader = MemoryReader(5)
    let writer = MemoryWriter(1)
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.dirty == 1)
    @Assert(stat.ok == 4)
    @Assert(stat.ok + stat.dirty == 5)
}

@Test
func testDirtyRowBoundaryLastRow() {
    // 边界：dirtyAt=总行数 → 末行即脏（写侧收集，可验证末行确实被跳过）
    let ch = BoundedChannel(4)
    let reader = MemoryReader(10)
    let writer = CollectingWriter(10)
    let producer = spawn { reader.read(ch) }
    let stat = writer.write(ch)
    producer.get()
    @Assert(stat.dirty == 1)
    @Assert(stat.ok == 9)
    @Assert(stat.ok + stat.dirty == 10)
    @Assert(writer.rows().size == 9)
    // 末行被跳过：最后写入的是第 9 行（row-8），不是 row-9
    @Assert(writer.rows()[8].get(0) == Column.Long(8))
    @Assert(writer.rows()[8].get(1) == Column.Str("row-8"))
}

@Test
func testReaderCloseEnablesWriterExit() {
    // Reader 产出完毕必须 close 管道：残留行取尽后 recv 返回 None（EOF），
    // Writer 依此退出，不会挂死
    let ch = BoundedChannel(4)
    let reader = MemoryReader(3)
    let producer = spawn { reader.read(ch) }
    producer.get() // 读侧结束（内部已 close）
    var got: Int64 = 0
    var eof = false
    while (true) {
        match (ch.recv()) {
            case Some(_) => got += 1
            case None =>
                eof = true
                break
        }
    }
    @Assert(got == 3)
    @Assert(eof)
}
