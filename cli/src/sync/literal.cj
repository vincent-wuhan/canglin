package canglin_cli.sync

import std.collection.*

/// PG 字面量编码。
///
/// 写侧把值编成 SQL 字面量而不是绑定参数——driver.api 的 Connection 目前只有
/// query(sql) 语义（PG 适配器明确支持 DDL/DML 走这条路径），所以取值必须自己
/// 编成**服务端能安全解析的字面量**，不能直接拼原始文本。
///
/// 文本统一用 E'' 转义串：E'' 的转义规则不随 standard_conforming_strings 开关
/// 变化，跨服务端配置行为一致（普通引号串在 off 模式下反斜杠会被当转义符）。

/// 十六进制数字表（bytea 字面量用）。
private let HEX_BYTES: Array<Byte> = "0123456789abcdef".toArray()

/// 文本 → PG 字符串字面量；含 NUL 字节时返回 None（PG 文本无法表示 NUL）。
public func pgTextLiteral(text: String): Option<String> {
    let out = ArrayList<Byte>()
    out.add(b'E')
    out.add(b'\'')
    for (b in text.toArray()) {
        match (b) {
            case b'\\' =>
                out.add(b'\\')
                out.add(b'\\')
            case b'\'' =>
                out.add(b'\\')
                out.add(b'\'')
            case b'\n' =>
                out.add(b'\\')
                out.add(b'n')
            case b'\r' =>
                out.add(b'\\')
                out.add(b'r')
            case b'\t' =>
                out.add(b'\\')
                out.add(b't')
            case 0x08 =>
                out.add(b'\\')
                out.add(b'b')
            case 0x0c =>
                out.add(b'\\')
                out.add(b'f')
            case 0x00 =>
                // PG 文本不能含 NUL：这行没法用字面量表达
                return None
            case _ =>
                if (b < 0x20) {
                    // 其余控制字符用三位八进制转义（长度固定，不会与后继字符混淆）
                    out.add(b'\\')
                    out.add(octalDigit(Int64(b) >> 6))
                    out.add(octalDigit((Int64(b) >> 3) & 0x07))
                    out.add(octalDigit(Int64(b) & 0x07))
                } else {
                    out.add(b)
                }
        }
    }
    out.add(b'\'')
    return Some(String.fromUtf8(out.toArray()))
}

/// 一个八进制数字对应的 ASCII 字节。
private func octalDigit(value: Int64): Byte {
    return UInt8(Int64(b'0') + value)
}

/// 字节 → PG bytea 字面量（十六进制输入格式）。
public func pgByteaLiteral(bytes: Array<Byte>): String {
    let out = ArrayList<Byte>()
    out.add(b'E')
    out.add(b'\'')
    out.add(b'\\')
    out.add(b'x')
    for (b in bytes) {
        out.add(HEX_BYTES[Int64(b) >> 4])
        out.add(HEX_BYTES[Int64(b) & 0x0f])
    }
    out.add(b'\'')
    out.add(b':')
    out.add(b':')
    out.add(b'b')
    out.add(b'y')
    out.add(b't')
    out.add(b'e')
    out.add(b'a')
    return String.fromUtf8(out.toArray())
}

/// UTF-8 字符数（PG 的 varchar(n) 按字符计，不按字节）。
///
/// Cangjie 的 String.size 是**字节数**，直接拿来比 PG 的 character_maximum_length
/// 会在多字节文本上误判（中文 1 字 = 3 字节）。这里按 UTF-8 规则数：不是
/// 10xxxxxx 续字节的字节各算一个字符。
public func utf8CharCount(text: String): Int64 {
    var count: Int64 = 0
    for (b in text.toArray()) {
        if ((b & 0xC0) != 0x80) {
            count += 1
        }
    }
    return count
}
