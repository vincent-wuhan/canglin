package kernel.spi

// PT4 Reader/Writer SPI 定义。
//
// 术语契约（极易弄反）：Reader = 生产方（send，产出后必须 close）；
// Writer = 消费方（recv 到 None 即退出）。
// openspec sync-kernel spec「Reader/Writer SPI」要求：两侧实现可独立替换，
// 换任一侧为内存假实现时，另一侧无需修改即可继续工作。

import kernel.channel.Channel

/// 生产方：从数据源拉取行并写入管道。
/// 实现约定：产出全部行后必须调用 out.close()——消费方据此收到 EOF 退出；
/// 未 close 会让消费方永久阻塞。
public interface Reader {
    func read(out: Channel): Unit
}

/// 消费方：从管道取行并写入目标。
/// 实现约定：持续 recv 直至返回 None（EOF），返回本次处理的行数统计。
public interface Writer {
    /// 参数名与任务书不同：任务书写 write(in: Channel)，但 `in` 是仓颉
    /// 保留关键字（见 dev-guide Appendix/keyword.md），无法作为形参名，
    /// 此处改名为 src，语义不变。
    func write(src: Channel): WriteStat
}

/// 一次写入的统计：成功行数与脏行数（脏行被跳过，不计入 ok）。
public struct WriteStat {
    /// 成功处理的行数。
    public let ok: Int64
    /// 判定为脏行并跳过的行数。
    public let dirty: Int64

    public init(ok: Int64, dirty: Int64) {
        this.ok = ok
        this.dirty = dirty
    }
}
