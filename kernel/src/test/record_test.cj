package kernel.test

import kernel.record.*
import std.collection.*
import std.time.*
import std.unittest.*

@Test
func testColumnLoad() {
    let cols = ArrayList<Column>([Column.Long(42), Column.Double(0.5),
        Column.Str("hi"), Column.Null])
    let r = Record(cols)
    @Assert(r.size() == 4)
    match (r.get(0)) {
        case Long(v) => @Assert(v == 42)
        case _ => @Fail("expected Long at index 0")
    }
    match (r.get(3)) {
        case Null => @Assert(true)
        case _ => @Fail("expected Null at index 3")
    }
}

@Test
func testColumnRemainingKinds() {
    let now = DateTime.now()
    let r = Record(ArrayList<Column>([Column.Bytes([1, 2]),
        Column.`Bool`(true), Column.Date(now)]))
    @Assert(r.size() == 3)
    match (r.get(0)) {
        case Bytes(bs) => @Assert(bs.size == 2)
        case _ => @Fail("expected Bytes at index 0")
    }
    match (r.get(1)) {
        case `Bool`(bv) => @Assert(bv)
        case _ => @Fail("expected Bool at index 1")
    }
    match (r.get(2)) {
        case Date(dt) => @Assert(dt == now)
        case _ => @Fail("expected Date at index 2")
    }
}
