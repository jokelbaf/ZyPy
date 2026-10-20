const py = @import("zypy");

pub fn range(n: u32) !py.List {
    const list = try py.List.init();
    errdefer list.deinit();

    for (0..n) |i| try list.append(i);
    return list;
}

pub fn squares() !py.List {
    return py.List.fromSlice([_]i64{ 1, 4, 9, 16 });
}

pub fn double(list: py.List) !void {
    for (0..list.len()) |i| try list.set(i, try list.get(i64, i) *% 2);
}

pub fn first(list: py.List) !?py.Object {
    if (list.len() == 0) return null;
    return try list.get(py.Object, 0);
}

pub fn appendOwned(list: py.List) !void {
    const text = try py.Str.init("owned");
    defer text.deinit();

    try list.append(text);
    try list.append([_]bool{ true, false });
}

pub fn seqSum(xs: py.Sequence(f64)) !f64 {
    var total: f64 = 0;
    for (0..xs.len()) |i| total += try xs.get(i);
    return total;
}

pub fn sumPairs(xs: py.Sequence(struct { py.Str, i64 })) !i64 {
    var total: i64 = 0;
    for (0..xs.len()) |i| {
        _, const n = try xs.get(i);
        total +%= n;
    }
    return total;
}

pub fn materialize(xs: py.Sequence(py.Object)) py.Sequence(py.Object) {
    return xs;
}

pub fn nestedSum(xs: py.Sequence(py.Sequence(i64))) !i64 {
    var total: i64 = 0;
    for (0..xs.len()) |i| {
        const inner = try xs.get(i);
        defer inner.deinit();

        for (0..inner.len()) |j| total +%= try inner.get(j);
    }
    return total;
}

pub fn makeUser(name: py.Str, age: u8) !py.Dict {
    const user = try py.Dict.init();
    errdefer user.deinit();

    try user.set("name", name);
    try user.set("age", age);
    try user.set("scores", [_]f64{ 9.5, 7.0 });
    try user.set("active", true);
    try user.set("visits", 0);
    return user;
}

pub fn getAge(user: py.Dict) !?i64 {
    return user.get(i64, "age");
}

pub fn countWords(words: py.Sequence(py.Object)) !py.Dict {
    const counts = try py.Dict.init();
    errdefer counts.deinit();

    for (0..words.len()) |i| {
        const word = try words.get(i);
        const n = try counts.get(i64, word) orelse 0;
        try counts.set(word, n + 1);
    }
    return counts;
}

pub fn sumValues(d: py.Dict) !f64 {
    var total: f64 = 0;
    var entries = d.iterator(py.Object, f64);
    while (try entries.next()) |entry| total += entry.value;
    return total;
}

/// Return the first key, which converting its value may remove from the dict.
pub fn firstKey(d: py.Dict) !?py.Object {
    var entries = d.iterator(py.Object, i64);
    const entry = try entries.next() orelse return null;
    return entry.key;
}

pub fn invert(d: py.Dict) !py.Dict {
    const out = try py.Dict.init();
    errdefer out.deinit();

    var entries = d.iterator(py.Object, py.Object);
    while (try entries.next()) |entry| try out.set(entry.value, entry.key);
    return out;
}

pub fn has(d: py.Dict, key: py.Object) !bool {
    return d.contains(key);
}

pub fn smallSet() !py.Set {
    return py.Set.fromSlice([_]i64{ 1, 2, 3 });
}

pub fn changeSet(set: py.Set) !struct { bool, bool, bool, usize } {
    try set.add(4);
    const removed = try set.discard(1);
    const missing = try set.discard(100);
    return .{ try set.contains(4), removed, missing, set.len() };
}

pub fn letters() !py.FrozenSet {
    return py.FrozenSet.fromSlice([_]*const [1:0]u8{ "a", "b", "a" });
}

pub fn emptyFrozenSet() !py.FrozenSet {
    return py.FrozenSet.init();
}

pub fn frozenSum(set: py.FrozenSet) !i64 {
    const items = try set.iterator(i64);
    defer items.deinit();

    var total: i64 = 0;
    while (try items.next()) |x| total +%= x;
    return total;
}

pub fn hasItem(set: py.FrozenSet, item: py.Object) !bool {
    return set.contains(item);
}

pub fn iterSum(items: py.Iterator(i64)) !i64 {
    var total: i64 = 0;
    while (try items.next()) |x| total +%= x;
    return total;
}

pub fn firstTwo(items: py.Iterator(py.Object)) !struct { ?py.Object, ?py.Object } {
    // Keep an owned reference because next() releases the previous item.
    const first_item = if (try items.next()) |item| item.newRef() else null;
    errdefer if (first_item) |item| item.deinit();

    return .{ first_item, try items.next() };
}

pub fn callIterSum(f: py.Object) !i64 {
    const items = try f.call(py.Iterator(i64), .{});
    defer items.deinit();

    return iterSum(items);
}

pub fn sameIterator(items: py.Iterator(py.Object)) py.Iterator(py.Object) {
    return items;
}

pub fn listOps(list: py.List) !struct { i64, py.List } {
    try list.insert(0, 10);
    try list.insert(100, 99);
    const popped = try list.pop(i64, 1);
    return .{ popped, try list.slice(1, 3) };
}

pub fn popAt(list: py.List, index: usize) !py.Object {
    return list.pop(py.Object, index);
}

pub fn clearList(list: py.List) void {
    list.clear();
}

pub fn dictOps(dict: py.Dict) !struct { bool, bool, ?i64, ?i64 } {
    return .{ try dict.remove("a"), try dict.remove("missing"), try dict.pop(i64, "b"), try dict.pop(i64, "missing") };
}

pub fn popValue(dict: py.Dict, key: py.Object) !?py.Object {
    return dict.pop(py.Object, key);
}

pub fn clearDict(dict: py.Dict) void {
    dict.clear();
}

pub fn squaresTuple(n: usize) !py.Tuple {
    const tuple = try py.Tuple.init(n);
    errdefer tuple.deinit();

    for (0..n) |i| try tuple.set(i, i * i);
    return tuple;
}

pub fn tupleSum(tuple: py.Tuple) !f64 {
    var total: f64 = 0;
    for (0..tuple.len()) |i| total += try tuple.get(f64, i);
    return total;
}

pub fn tupleItem(tuple: py.Tuple, index: usize) !py.Object {
    return tuple.get(py.Object, index);
}

pub fn halvesTuple() !py.Tuple {
    return py.Tuple.fromSlice([_]f64{ 0.5, 1.5 });
}

pub fn emptyTuple() !py.Tuple {
    return py.Tuple.init(0);
}

pub fn setShared(tuple: py.Tuple) !void {
    try tuple.set(0, 1);
}

pub fn listItem(list: py.List, index: usize) !py.Object {
    return list.get(py.Object, index);
}

/// Read the first item, then call Python, which may remove it from the list.
pub fn readThenCall(list: py.List, callback: py.Object) !py.Object {
    const item = try list.get(py.Object, 0);
    try callback.call(void, .{});
    return item;
}

/// Look up `key`, then call Python, which may remove it from the dict.
pub fn lookupThenCall(d: py.Dict, key: py.Object, callback: py.Object) !?py.Object {
    const value = try d.get(py.Object, key);
    try callback.call(void, .{});
    return value;
}

/// Sum the lengths of up to 64 strings while other threads replace list items.
pub fn totalLength(list: py.List) !usize {
    var items: [64]py.Str = undefined;
    const count = @min(list.len(), items.len);
    for (items[0..count], 0..) |*item, i| item.* = try list.get(py.Str, i);

    var total: usize = 0;
    for (items[0..count]) |item| total += (try item.utf8()).len;
    return total;
}

pub fn setListItem(list: py.List, index: usize, value: py.Object) !void {
    try list.set(index, value);
}

/// Read the first item in a separate borrow scope each round, then check retained references.
pub fn scopedReads(list: py.List, rounds: usize, check: py.Object) !void {
    for (0..rounds) |_| {
        const scope: py.BorrowScope = .begin();
        defer scope.end();

        _ = try list.get(py.Object, 0);
    }
    try check.call(void, .{});
}

/// Read the first item `rounds` times without scopes, then call `check`.
pub fn unscopedReads(list: py.List, rounds: usize, check: py.Object) !void {
    for (0..rounds) |_| _ = try list.get(py.Object, 0);
    try check.call(void, .{});
}

/// Read items in nested scopes, then check that ending the inner scope releases only its reads.
pub fn nestedScopes(list: py.List, check: py.Object) !void {
    const outer: py.BorrowScope = .begin();
    defer outer.end();

    _ = try list.get(py.Object, 0);
    {
        const inner: py.BorrowScope = .begin();
        defer inner.end();

        for (0..10) |_| _ = try list.get(py.Object, 0);
    }
    try check.call(void, .{});
}
