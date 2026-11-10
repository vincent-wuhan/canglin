package kernel.record

import std.time.DateTime

// 说明：判等/打印为手写 extend，未使用 @Derive[Equatable, ToString]。
// 原因：仓颉 1.0.5 std.deriving 宏对反引号构造器名（本枚举的 `Bool`）生成的
// 辅助函数名 check_`Bool`_N 是非法 token 序列，编译失败；实测仅 @Derive[ToString]
// 同样失败（同一根因，已最小复现验证）。而 Array<Byte>/DateTime 的
// Equatable/ToString conformance 均满足：在非反引号构造器名的等价枚举上
// @Derive[Equatable, ToString] 编译通过。下方实现与该宏生成的代码一致。

public enum Column {
    | Long(Int64) | Double(Float64) | Str(String)
    | Bytes(Array<Byte>) | `Bool`(Bool) | Date(DateTime) | Null
}

extend Column <: Equatable<Column> {
    public operator func ==(other: Column): Bool {
        return match ((this, other)) {
            case (Long(l), Long(r)) => l == r
            case (Double(l), Double(r)) => l == r
            case (Str(l), Str(r)) => l == r
            case (Bytes(l), Bytes(r)) => l == r
            case (`Bool`(l), `Bool`(r)) => l == r
            case (Date(l), Date(r)) => l == r
            case (Null, Null) => true
            case _ => false
        }
    }
    public operator func !=(other: Column): Bool {
        return !(this == other)
    }
}

extend Column <: ToString {
    public func toString(): String {
        let sb = StringBuilder()
        sb.append("Column")
        match (this) {
            case Long(v) =>
                sb.append(".Long")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case Double(v) =>
                sb.append(".Double")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case Str(v) =>
                sb.append(".Str")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case Bytes(v) =>
                sb.append(".Bytes")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case `Bool`(v) =>
                sb.append(".`Bool`")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case Date(v) =>
                sb.append(".Date")
                sb.append("(")
                sb.append(v.toString())
                sb.append(")")
            case Null =>
                sb.append(".Null")
        }
        return sb.toString()
    }
}
