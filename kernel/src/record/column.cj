package kernel.record

import std.time.DateTime

public enum Column {
    | Long(Int64) | Double(Float64) | Str(String)
    | Bytes(Array<Byte>) | `Bool`(Bool) | Date(DateTime) | Null
}
