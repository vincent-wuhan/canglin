package kernel.test

// kernel 测试基建：跨用例复用的假实现。
//
// 收编口径（PT5 质量审查）：脏行注入与异常路径的假实现集中在这里，
// 各用例不再各写一套；「哪一行算脏行」的唯一口径是 kernel.spi.DirtyRule。

import kernel.channel.Channel
import kernel.record.*
import kernel.spi.*
import std.collection.*

/// 假实现抛出的异常：用于断言 JobRunner 把协程内异常原样传播给调用方，
/// 而不是吞掉或包装成别的类型。
public class FakeError <: Exception {
    public init() {
        super("fake error")
    }
}

/// 协程终止信号：spawn 的闭包不能捕获可变变量，用共享对象回传状态。
public class Signal {
    private var done: Bool = false

    public func markDone(): Unit {
        done = true
    }

    public func isDone(): Bool {
        return done
    }
}

/// 每 dirtyEvery 行判一行脏的 Writer（dirtyEvery<=0 表示无脏行）。
/// 与 kernel.spi.MemoryWriter(dirtyAt) 共用 DirtyRule 口径：
/// 前者按「每 N 行」，后者按「第 k 行」，脏行都计入 dirty、跳过、且不中断作业。
public class DirtyEveryWriter <: Writer {
    private let rule: DirtyRule

    public init(dirtyEvery: Int64) {
        this.rule = DirtyRule(every: dirtyEvery)
    }

    public func write(src: Channel): WriteStat {
        var ok: Int64 = 0
        var dirty: Int64 = 0
        var index: Int64 = 0
        while (true) {
            match (src.recv()) {
                case Some(_) =>
                    index += 1
                    if (rule.isDirty(index)) {
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

/// 产出 rows 行后抛 FakeError 的 Reader：模拟源端在同步中途失败。
public class ThrowingReader <: Reader {
    private let rows: Int64

    public init(rows: Int64) {
        this.rows = rows
    }

    public func read(out: Channel): Unit {
        var i: Int64 = 0
        while (i < rows) {
            out.send(Record(ArrayList<Column>([Column.Long(i)])))
            i += 1
        }
        throw FakeError()
    }
}

/// 消费 rows 行后抛 FakeError 的 Writer：模拟目标端写入中途失败。
public class ThrowingWriter <: Writer {
    private let rows: Int64

    public init(rows: Int64) {
        this.rows = rows
    }

    public func write(src: Channel): WriteStat {
        var got: Int64 = 0
        while (got < rows) {
            match (src.recv()) {
                case Some(_) => got += 1
                case None => break
            }
        }
        throw FakeError()
    }
}

/// 慢收尾的 Reader：产出 rows 行后进入慢收尾（sleep）再置位信号。
/// 模拟「Reader 卡在慢 I/O 里」：JobRunner 若在 Writer 失败后不 join 读侧
/// 协程，run() 抛异常时读侧协程仍在跑（信号未置位），即遗留孤儿协程。
public class SlowReader <: Reader {
    private let rows: Int64
    private let signal: Signal

    public init(rows: Int64, signal: Signal) {
        this.rows = rows
        this.signal = signal
    }

    public func read(out: Channel): Unit {
        try {
            var i: Int64 = 0
            while (i < rows) {
                out.send(Record(ArrayList<Column>([Column.Long(i)])))
                i += 1
            }
        } finally {
            // 慢 I/O 的收尾：这段时间里协程仍存活
            sleep(Duration.millisecond * 300)
            signal.markDone()
        }
    }
}
