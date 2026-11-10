package driver.api

// 四类驱动错误：上层据此决定处置方式，且调用方可据类别区分失败原因
// （spec：返回包含错误类别的失败结果，而非裸异常或 panic）。
//
// - NetworkUnreachable：主机/端口不可达，连接阶段失败，可重试。
// - AuthFailed：口令或账号被拒，需人工改配置，不重试。
// - ProtocolError：协议层不兼容（握手/报文格式），属驱动成熟度问题。
// - QueryError：SQL 或元数据请求本身出错（如表不存在）。
//
// 说明：判等/打印为手写 extend，未用 @Derive——与 kernel.record.Column 同风格，
// 避免依赖派生宏对枚举构造器的命名假设。

public enum DbError {
    /// 网络不可达：连接目标地址无响应。
    | NetworkUnreachable(String)
    /// 认证失败：账号或口令被拒。
    | AuthFailed(String)
    /// 协议错误：握手或报文不符合驱动预期。
    | ProtocolError(String)
    /// 查询错误：SQL 执行或元数据获取失败。
    | QueryError(String)
}

extend DbError <: Equatable<DbError> {
    public operator func ==(other: DbError): Bool {
        return match ((this, other)) {
            case (NetworkUnreachable(l), NetworkUnreachable(r)) => l == r
            case (AuthFailed(l), AuthFailed(r)) => l == r
            case (ProtocolError(l), ProtocolError(r)) => l == r
            case (QueryError(l), QueryError(r)) => l == r
            case _ => false
        }
    }
    public operator func !=(other: DbError): Bool {
        return !(this == other)
    }
}

extend DbError <: ToString {
    public func toString(): String {
        let sb = StringBuilder()
        sb.append("DbError")
        match (this) {
            case NetworkUnreachable(msg) =>
                sb.append(".NetworkUnreachable(")
                sb.append(msg)
                sb.append(")")
            case AuthFailed(msg) =>
                sb.append(".AuthFailed(")
                sb.append(msg)
                sb.append(")")
            case ProtocolError(msg) =>
                sb.append(".ProtocolError(")
                sb.append(msg)
                sb.append(")")
            case QueryError(msg) =>
                sb.append(".QueryError(")
                sb.append(msg)
                sb.append(")")
        }
        return sb.toString()
    }
}
