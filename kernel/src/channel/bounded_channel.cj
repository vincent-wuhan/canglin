package kernel.channel

// 有界 Channel —— DataX Channel 概念的仓颉实现（PT3）。
// 语义契约（openspec sync-kernel spec「Channel 传输管道」）：
//   send(rec)      缓冲满时阻塞（背压）
//   recv()         空且未关闭时阻塞；返回 None 即 EOF
//   close()        close 后缓冲残留行仍可 recv 直至取空，取空后 recv 返回 None；
//                  close 后 send 抛 ChannelClosedException（行为选择：抛异常，
//                  而非返回错误值——理由见 ChannelClosedException 注释）
//
// std.sync 原语校准结论（1.0.5 实测）：
//   - MultiCondSync 在本 SDK 不存在；Monitor 存在但已 deprecated（提示改用
//     Condition 接口）。实际可用的组合是 MultiConditionMonitor：
//     lock()/unlock() + 持锁调 newCondition(): ConditionID，
//     wait(cid)/notifyAll(cid)（无 notifyOne），Mesa 语义，wait 释放锁。
//   - spawn 返回 Future<T>，f.get() 阻塞取结果。
//
// TODO: 多生产/消费场景 notifyAll 有惊群开销，Phase 2 作业分片前评估

import kernel.record.Record
import std.collection.*
import std.sync.*

/// close 后调用 send 抛出的异常。
/// 行为选择（spec 允许「抛异常或返回错误」二选一）：选抛异常。
/// 理由：send 的正常返回类型是 Unit，若改为 Result 会把「写已关闭管道」这种
/// 协议违规强加到所有正常调用点上（send 由生产方调用——SPI 中即 Reader；
/// PT5 JobRunner 的 reader 循环里 send 只发生在 close 之前）。close 后
/// send 属于编程错误，应 fail-fast。
public class ChannelClosedException <: Exception {
    public init() {
        super("send on closed channel")
    }
}

/// 有界 Channel：容量固定，多协程安全。
/// 实现：MultiConditionMonitor（互斥 + 双条件变量 notFull/notEmpty）
/// 守护 ArrayList 缓冲；closed 标志实现 EOF 语义。
/// close 幂等：重复调用安全（实现为重复置位 + 重复广播），
/// PT5 JobRunner 的 finally 兜底 close 依赖此保证。
public class BoundedChannel {
    private let capacity: Int64
    private let mon: MultiConditionMonitor
    private let notFull: ConditionID
    private let notEmpty: ConditionID
    private let buf: ArrayList<Record>
    private var closed = false

    public init(capacity: Int64) {
        if (capacity <= 0) {
            throw IllegalArgumentException("BoundedChannel capacity must be positive, got ${capacity}")
        }
        this.capacity = capacity
        mon = MultiConditionMonitor()
        buf = ArrayList<Record>()
        mon.lock()
        // newCondition 要求调用方已持锁（实测未持锁抛 IllegalSynchronizationStateException）
        notFull = mon.newCondition()
        notEmpty = mon.newCondition()
        mon.unlock()
    }

    /// 写入一行。缓冲满时阻塞（背压）；管道已关闭时抛 ChannelClosedException。
    public func send(rec: Record): Unit {
        mon.lock()
        try {
            while (buf.size >= capacity && !closed) {
                mon.wait(notFull)
            }
            if (closed) {
                throw ChannelClosedException()
            }
            buf.add(rec)
            mon.notifyAll(notEmpty)
        } finally {
            mon.unlock()
        }
    }

    /// 读取一行。缓冲空且未关闭时阻塞；关闭且取空后返回 None（EOF）。
    public func recv(): Option<Record> {
        mon.lock()
        try {
            while (buf.size == 0 && !closed) {
                mon.wait(notEmpty)
            }
            if (buf.size == 0) {
                return None // closed && 空 → EOF；close 前不会走到这里
            }
            // TODO: O(n) 搬移，PT7 万行吞吐基线出来后决定是否换环形缓冲
            let rec = buf.remove(at: 0)
            mon.notifyAll(notFull)
            return Some(rec)
        } finally {
            mon.unlock()
        }
    }

    /// 关闭管道。由生产方（SPI Reader）在产出完毕后调用；消费方（SPI Writer）
    /// 持续 recv，残留行取尽后返回 None 即退出信号；此后 send 抛异常。
    public func close(): Unit {
        mon.lock()
        try {
            closed = true
            mon.notifyAll(notEmpty) // 唤醒阻塞在 recv 的消费方（SPI Writer）→ 重新检查后返回 EOF
            mon.notifyAll(notFull) // 唤醒阻塞在 send 的生产方（SPI Reader）→ 重新检查后抛错
        } finally {
            mon.unlock()
        }
    }
}
