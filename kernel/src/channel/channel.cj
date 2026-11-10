package kernel.channel

// 传输管道抽象（PT4 SPI 依赖的最小契约）。
// 具体实现见 bounded_channel.cj（BoundedChannel）；本文件只定义接口，
// 不改动 PT3 的实现文件。
//
// 为什么需要这层抽象：Reader/Writer SPI 的签名只认 Channel 接口，
// 不认 BoundedChannel 具体类——否则换一条管道实现就要改 SPI 与全部插件。

import kernel.record.Record

/// 传输管道：Reader 写入、Writer 读取。
/// 语义契约与 BoundedChannel 一致（背压 / EOF / close 后禁写）。
public interface Channel {
    /// 写入一行；管道满时阻塞（背压）；已关闭时抛 ChannelClosedException。
    func send(rec: Record): Unit
    /// 读取一行；空且未关闭时阻塞；已关闭且取空后返回 None（EOF）。
    func recv(): Option<Record>
    /// 关闭管道；由生产方（Reader）在产出完毕后调用。
    func close(): Unit
}

/// BoundedChannel 已实现接口要求的全部成员，此处只补接口一致性，
/// 不重复实现成员（接口扩展不允许重复实现已有成员）。
extend BoundedChannel <: Channel {}
