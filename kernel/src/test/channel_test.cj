package kernel.test

// 语义契约（openspec sync-kernel spec「Channel 传输管道」）：
// - send：缓冲满时阻塞（背压）；close 后 send 抛 ChannelClosedException
// - recv：空且未关闭时阻塞；返回 None 即 EOF；close 后残留行仍可取，取空后 None
// - 全程不丢行、不重复行

import kernel.channel.*
import kernel.record.*
import std.collection.*
import std.unittest.*

func mockRecord(id: Int64): Record {
    return Record(ArrayList<Column>([Column.Long(id), Column.Str("row-${id}")]))
}

func isEof(o: Option<Record>): Bool {
    match (o) {
        case Some(_) => false
        case None => true
    }
}

// 仓颉限制：捕获可变变量的 lambda 不能逃逸（spawn 即逃逸），
// 故用引用类型字段作跨协程标志位。
class Flag {
    var v = false
}

@Test
func testBoundedBlocksWhenFull() {
    let ch = BoundedChannel(2)
    ch.send(mockRecord(1))
    ch.send(mockRecord(2))
    let thirdSent = Flag()
    let f = spawn {
        ch.send(mockRecord(3))
        thirdSent.v = true
    }
    sleep(Duration.millisecond * 200)
    @Assert(!thirdSent.v) // 缓冲已满：第三次 send 必须仍在阻塞（背压）
    match (ch.recv()) {
        case Some(r) => @Assert(r.get(0) == Column.Long(1))
        case None => @Fail("不应 EOF")
    }
    f.get() // 腾出槽位后第三次 send 应能完成
    @Assert(thirdSent.v)
    match (ch.recv()) {
        case Some(r) => @Assert(r.get(0) == Column.Long(2))
        case None => @Fail("不应 EOF")
    }
    match (ch.recv()) {
        case Some(r) => @Assert(r.get(0) == Column.Long(3))
        case None => @Fail("不应 EOF")
    }
}

@Test
func testCloseDeliversEof() {
    let ch = BoundedChannel(2)
    ch.send(mockRecord(1))
    ch.close()
    match (ch.recv()) {
        case Some(r) => @Assert(r.get(0) == Column.Long(1)) // close 后残留行仍可取
        case None => @Fail("close 后残留行应仍可接收")
    }
    @Assert(isEof(ch.recv())) // 取空 → EOF
    @Assert(isEof(ch.recv())) // EOF 稳定
    // close 后 send 是错误：抛 ChannelClosedException
    var threw = false
    try {
        ch.send(mockRecord(9))
    } catch (e: ChannelClosedException) {
        threw = true
    }
    @Assert(threw)
}

@Test
func testNoLossNoDuplication() {
    let n = 100
    let ch = BoundedChannel(8) // 容量 < 总数：反复触发背压与唤醒
    let sender = spawn {
        for (i in 1..=n) {
            ch.send(mockRecord(i))
        }
        ch.close()
    }
    let counts = Array<Int64>(n + 1, {_ => 0})
    var got: Int64 = 0
    while (true) {
        match (ch.recv()) {
            case Some(r) =>
                match (r.get(0)) {
                    case Long(v) => counts[v] += 1
                    case _ => @Fail("首列应为 Long")
                }
                got += 1
            case None => break
        }
    }
    @Assert(got == n)
    for (i in 1..=n) {
        @Assert(counts[i] == 1) // 每行恰好一次：不丢、不重
    }
    sender.get()
}
