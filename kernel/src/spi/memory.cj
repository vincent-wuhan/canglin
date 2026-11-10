package kernel.spi

// PT4 内存假实现：用于单侧替换测试，也供 PT5 作业执行层复用。
// 语义契约：
//   Reader 产出完毕后必须 close（消费方 recv 到 None 才能退出）；
//   Writer 消费到 None 为止，脏行计入 dirty 并跳过，不计入 ok，作业不中断。

import kernel.channel.Channel
import kernel.record.*
import std.collection.*

/// 内存 Reader：产出 rows 行，行内容为首列 Long(序号)、次列 Str("row-<序号>")。
public class MemoryReader <: Reader {
    private let rows: Int64

    public init(rows: Int64) {
        this.rows = rows
    }

    public func read(out: Channel): Unit {
        var i: Int64 = 0
        while (i < rows) {
            out.send(Record(ArrayList<Column>([Column.Long(i), Column.Str("row-${i}")])))
            i += 1
        }
        // 产出完毕必须 close：否则消费方 recv 永远阻塞，作业挂死
        out.close()
    }
}

/// 文件源替身 Reader：每行一个字符串列，用于验证「换读侧不影响写侧」。
public class FileMockReader <: Reader {
    private let lines: ArrayList<String>

    public init(lines: ArrayList<String>) {
        this.lines = lines
    }

    public func read(out: Channel): Unit {
        for (line in lines) {
            out.send(Record(ArrayList<Column>([Column.Str(line)])))
        }
        out.close()
    }
}

/// 内存 Writer：只统计成功行数与脏行数。
/// dirtyAt > 0 时，第 dirtyAt 条收到的行判为脏行（计入 dirty 并跳过）。
public class MemoryWriter <: Writer {
    private let dirtyAt: Int64
    private var consumed: Int64 = 0
    private var okCount: Int64 = 0
    private var dirtyCount: Int64 = 0

    /// 无脏行。
    public init() {
        this.dirtyAt = 0
    }

    /// 第 dirtyAt 条收到的行判为脏行。
    public init(dirtyAt: Int64) {
        this.dirtyAt = dirtyAt
    }

    public func write(src: Channel): WriteStat {
        while (true) {
            match (src.recv()) {
                case Some(_) =>
                    consumed += 1
                    if (dirtyAt > 0 && consumed == dirtyAt) {
                        // 脏行：计入 dirty 并跳过，作业继续
                        dirtyCount += 1
                    } else {
                        okCount += 1
                    }
                case None => break
            }
        }
        return WriteStat(okCount, dirtyCount)
    }
}

/// 收集型 Writer：除统计外保留写入的行，用于断言「不丢不重」。
/// 脏行不写入，故 rows() 只含成功行。
public class CollectingWriter <: Writer {
    private let dirtyAt: Int64
    private let collected: ArrayList<Record>
    private var consumed: Int64 = 0
    private var okCount: Int64 = 0
    private var dirtyCount: Int64 = 0

    /// 无脏行。
    public init() {
        this.dirtyAt = 0
        collected = ArrayList<Record>()
    }

    /// 第 dirtyAt 条收到的行判为脏行。
    public init(dirtyAt: Int64) {
        this.dirtyAt = dirtyAt
        collected = ArrayList<Record>()
    }

    public func write(src: Channel): WriteStat {
        while (true) {
            match (src.recv()) {
                case Some(rec) =>
                    consumed += 1
                    if (dirtyAt > 0 && consumed == dirtyAt) {
                        // 脏行：计入 dirty 并跳过，不写入目标
                        dirtyCount += 1
                    } else {
                        okCount += 1
                        collected.add(rec)
                    }
                case None => break
            }
        }
        return WriteStat(okCount, dirtyCount)
    }

    /// 已成功写入的行（脏行不在其中）。
    public func rows(): ArrayList<Record> {
        return collected
    }
}
