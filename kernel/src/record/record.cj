package kernel.record

import std.collection.*

public struct Record {
    let columns: ArrayList<Column>
    public init(cols: ArrayList<Column>) {
        columns = cols
    }
    public func size(): Int64 {
        return columns.size
    }
    public func get(i: Int64): Column {
        return columns[i]
    }
}
