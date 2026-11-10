package kernel.job

// 语义契约（openspec sync-kernel spec「作业执行与统计」）：
//   - 单作业形态：Reader → Channel → Writer 流水线，跑完即结束
//   - 输出成功行数、失败行数与耗时
//   - 脏行不中断作业：行级成败由 Writer 判定并计入 WriteStat，
//     JobRunner 只负责搬运与汇总，不参与行级判定
//
// SPI 术语契约（见 docs/handoff/OPC-PT4-10.md）：
//   Reader = 生产方（send，完成后 close 管道）
//   Writer = 消费方（recv 到 None 即 EOF 退出）
//
// 本任务范围（YAGNI）：单作业、单生产单消费；不做分片/限速/断点续传。

import kernel.channel.BoundedChannel
import kernel.spi.*
import std.time.*

/// 单作业执行统计：成功行数 ok、失败（脏）行数 dirty、耗时毫秒 elapsedMs。
public struct JobStat {
    public let ok: Int64
    public let dirty: Int64
    public let elapsedMs: Int64

    public init(ok: Int64, dirty: Int64, elapsedMs: Int64) {
        this.ok = ok
        this.dirty = dirty
        this.elapsedMs = elapsedMs
    }
}

/// 作业执行器：spawn Reader 与 Writer 两个协程，组装 Reader→Channel→Writer
/// 流水线，两个协程 join 后汇总 WriteStat 与耗时。
public class JobRunner {
    private let capacity: Int64

    /// capacity：管道容量，与 kernel.channel.BoundedChannel 默认一致。
    public init(capacity!: Int64 = 1024) {
        this.capacity = capacity
    }

    /// 跑完一次作业并返回统计。
    ///
    /// join 顺序固定为「先 Writer 后 Reader」：Reader 协程带 finally 兜底
    /// close（幂等），所以 Reader 抛异常时 Writer 仍能收到 EOF 而不是永久阻塞，
    /// 先 join Writer 不会出现死锁；反过来先 join Reader，则 Writer 提前失败时
    /// Reader 可能卡在 send 上永不返回。
    public func run(reader: Reader, writer: Writer): JobStat {
        let channel = BoundedChannel(capacity)
        let startedAt = DateTime.now()

        let readerTask = spawn {
            try {
                reader.read(channel)
            } finally {
                // 兜底 close：Reader 正常完成时已 close，此处重复 close 幂等；
                // Reader 异常退出时保证 Writer 能收到 EOF 而非永久阻塞。
                channel.close()
            }
        }
        let writerTask = spawn {
            writer.write(channel)
        }

        let writeStat = try {
            writerTask.get()
        } catch (e: Exception) {
            // Writer 异常退出时关闭管道，解除 Reader 阻塞在 send 上的等待，
            // 避免半个流水线挂在后台（close 幂等，正常路径不受影响）。
            channel.close()
            throw e
        }
        readerTask.get()

        let elapsed = DateTime.now() - startedAt
        return JobStat(writeStat.ok, writeStat.dirty, elapsed.toMilliseconds())
    }
}
