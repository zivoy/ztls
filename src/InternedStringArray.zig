// idea store strings in one interned array
// pass out gstrings for the data
// will need a custom allocator (?) so that freeing a string will allow its space to be be reused
// have strings be referenced counted and be in the format of
// [users][bytes...]

// have storage be freelist like, it will free then strings can populate the smallest available slot

// NOTE: maybe make a compact function, it will make all strings invalid, but will compact the memory space
//       or have some stable index system

const std = @import("std");
const assert = std.debug.assert;

const IndexType = enum(u32) {
    _,
    pub inline fn toBase(self: IndexType) u32 {
        return @intFromEnum(self);
    }
};
const LenType = u32;

const StoredString = struct {
    index: IndexType,
    len: LenType, // not used for anything, but could be useful for serialization and debugging
    usage: u32,
};

const StorageSlot = struct {
    index: IndexType,
    len: LenType,

    fn end(self: StorageSlot) u32 {
        return self.index.toBase() + self.len;
    }

    fn orderByLen(_: void, a: StorageSlot, b: StorageSlot) std.math.Order {
        return std.math.order(a.len, b.len);
    }
    fn orderByLenLt(_: void, a: StorageSlot, b: StorageSlot) bool {
        return orderByLen({}, a, b) == .lt;
    }

    fn orderByIdx(_: void, a: StorageSlot, b: StorageSlot) std.math.Order {
        return std.math.order(a.index.toBase(), b.index.toBase());
    }
    fn orderByIdxLt(_: void, a: StorageSlot, b: StorageSlot) bool {
        return orderByIdx({}, a, b) == .lt;
    }
};

// can this be simplified, do we need all 3 items?
storage: std.ArrayList(u8),
storedStrings: std.StringArrayHashMapUnmanaged(StoredString),
slots: std.PriorityDequeue(StorageSlot, void, StorageSlot.orderByLen),
// NOTE: maybe switch to a soa and implement manually
//       also store a second list sorted by index to make merging faster

allocator: std.mem.Allocator,
const Interner = @This();

pub fn init(allocator: std.mem.Allocator) Interner {
    return Interner{
        .allocator = allocator,
        .storage = .empty,
        .storedStrings = .empty,
        .slots = .init(allocator, {}),
    };
}

pub fn deinit(self: *Interner) void {
    self.storedStrings.deinit(self.allocator);
    self.storage.deinit(self.allocator);
    self.slots.deinit();
}

pub fn intern(self: *Interner, s: []const u8) !String {
    assert(s.len <= String.length_max_long);
    const len: LenType = @truncate(s.len);
    if (len <= String.length_max_short) {
        var content: [String.length_max_short]u8 = @splat(0);
        @memcpy(content[0..len], s);

        return .{ .len = len, .payload = .{
            .content = std.mem.bytesToValue(String.BufferType, &content),
        } };
    }

    // long string
    assert(String.length_max_short < s.len);
    var prefixArr: [String.length_prefix_long]u8 = @splat(0);
    @memcpy(&prefixArr, s[0..String.length_prefix_long]);

    // intern string
    const index = try self.load(s);

    return .{ .len = len, .payload = .{
        .interned = .{
            .prefix = std.mem.bytesToValue(String.PrefixType, &prefixArr),
            .index = index,
        },
    } };
}

pub fn release(self: *Interner, s: *const String) bool {
    if (s.len <= String.length_max_short) return true;

    const str = s.slice(self.*);
    return self.releaseStr(str);
}
fn releaseStr(self: *Interner, str: []const u8) bool {
    const usage = self.storedStrings.getPtr(str) orelse return false;
    usage.usage -= 1;
    if (usage.usage > 0) return true;

    const index = usage.index;
    if (!self.storedStrings.swapRemove(str)) return false;
    @memset(self.storage.items[index.toBase() .. index.toBase() + str.len], undefined);

    defer self.mergeSlots();

    // easy case
    if (index.toBase() + str.len == self.storage.items.len) {
        self.storage.items.len -= str.len;
        return true;
    }

    // NOTE: maybe find an available slot and expand it?
    self.slots.add(.{
        .index = index,
        .len = @truncate(str.len),
    }) catch return false;

    return true;
}

fn load(self: *Interner, s: []const u8) !IndexType {
    if (self.storedStrings.getPtr(s)) |stored| {
        assert(s.len == stored.len);
        stored.usage += 1;
        return stored.index;
    }

    const needMore = if (self.slots.peekMax()) |slot| slot.len < s.len else true;
    if (needMore) {
        // no slot is big enough, allocate more
        const idx: IndexType = @enumFromInt(self.storage.items.len);
        try self.storage.appendSlice(self.allocator, s);
        errdefer self.storage.items.len -= s.len;
        assert(s.len < String.length_max_long);
        try self.storedStrings.put(self.allocator, s, .{
            .index = idx,
            .len = @truncate(s.len),
            .usage = 1,
        });
        return idx;
    }

    var ittr = self.slots.iterator();
    while (ittr.next()) |slot| {
        // first match
        if (slot.len < s.len) continue;
        assert(s.len <= slot.len);

        const idx = slot.index;
        self.storage.replaceRangeAssumeCapacity(idx.toBase(), s.len, s);
        try self.storedStrings.put(self.allocator, s, .{
            .index = idx,
            .len = @truncate(s.len),
            .usage = 1,
        });

        // consomme the slot
        const slotIndex = ittr.count - 1;
        _ = self.slots.removeIndex(slotIndex);
        if (s.len != slot.len) {
            self.slots.add(.{
                .index = @enumFromInt(@intFromEnum(slot.index) + s.len),
                .len = slot.len - @as(LenType, @truncate(s.len)),
            }) catch unreachable;
            // self.slots.items[slotIndex].index = @enumFromInt(@intFromEnum(slot.index) + s.len);
            // self.slots.items[slotIndex].len = slot.len - @as(LenType, @truncate(s.len));
        }

        return idx;
    }
    unreachable;
}

fn mergeSlots(self: *Interner) void {
    if (self.slots.len == 0) return;
    // very slow, find a better way
    // maybe also don't sort every time ?
    var slots = self.slots.items[0..self.slots.len];
    std.mem.sortUnstable(StorageSlot, slots, {}, StorageSlot.orderByIdxLt);

    var write_idx: usize = 0;
    var current = slots[0];

    for (slots[1..]) |next_range| {
        if (current.end() >= next_range.index.toBase()) {
            // Merge
            const new_end = @max(current.end(), next_range.end());
            current.len = new_end - current.index.toBase();
            self.slots.len -= 1;
        } else {
            // Save current and move to next
            slots[write_idx] = current;
            write_idx += 1;
            current = next_range;
        }
    }
    slots[write_idx] = current;
    write_idx += 1;

    // merge with end
    if (current.end() == self.storage.items.len) {
        self.storage.items.len -= current.len;
        self.slots.len -= 1;
    }

    std.mem.sortUnstable(StorageSlot, self.slots.items[0..self.slots.len], {}, StorageSlot.orderByLenLt);
}

pub const String = packed struct {
    // not using the gstrings implementation because this needs to be index based

    const containerSize = @sizeOf(u64);
    const restSize = (2 * containerSize) - @sizeOf(LenType);
    const prefixLength = restSize - @sizeOf(IndexType);

    const BufferType = std.meta.Int(.unsigned, restSize * 8);
    const PrefixType = std.meta.Int(.unsigned, prefixLength * 8);

    pub const length_max_long = std.math.maxInt(LenType);
    pub const length_prefix_long = prefixLength;
    pub const length_max_short = restSize;

    len: LenType,
    payload: packed union {
        content: BufferType,
        interned: packed struct { prefix: PrefixType, index: IndexType },
    },

    pub fn deinit(
        self: *const String,
        interner: *Interner,
    ) void {
        if (!interner.release(self)) return;
        var selfNonConst = @constCast(self);
        selfNonConst.len = 0;
        selfNonConst.payload = undefined;
        selfNonConst = undefined;
    }

    pub fn eql(
        lhs: String,
        rhs: String,
    ) bool {
        if (lhs.len != rhs.len) return false;
        if (lhs.len <= length_max_short) {
            return lhs.payload.content == rhs.payload.content;
        }
        // since the strings are interned, equality is easy
        return lhs.payload.interned.index == rhs.payload.interned.index;
    }

    pub fn order(interner: Interner, lhs: String, rhs: String) std.math.Order {
        // check the first 8 bytes that always are present
        const lhs_prefix = lhs.getAnyArray("payload")[0..length_prefix_long];
        const rhs_prefix = rhs.getAnyArray("payload")[0..length_prefix_long];

        const ord = std.mem.order(u8, lhs_prefix, rhs_prefix);
        if (ord != .eq) return ord;

        return std.mem.order(u8, lhs.slice(interner), rhs.slice(interner));
    }

    fn getAnyArray(self: *const String, comptime field_name: []const u8) [*]const u8 {
        const bitOffset = comptime @bitOffsetOf(String, field_name);
        comptime std.debug.assert(bitOffset % std.mem.byte_size_in_bits == 0);
        const byteOffset = comptime bitOffset / std.mem.byte_size_in_bits;

        return @ptrFromInt(@intFromPtr(self) + byteOffset);
    }

    /// get a slice to the string
    pub fn slice(self: *const String, interner: Interner) []const u8 {
        if (self.len > length_max_short) {
            const index: usize = self.payload.interned.index.toBase();
            return interner.storage.items[index .. index + self.len];
        }

        assert(self.len <= length_max_short);
        const payload_ptr = self.getAnyArray("payload");
        return payload_ptr[0..self.len];
    }

    /// get the data immediately available on the stack
    pub fn prefix(self: *const String) []const u8 {
        const payload_ptr = self.getAnyArray("payload");
        const len = if (self.len > length_max_short) length_prefix_long else self.len;
        return payload_ptr[0..len];
    }
};

const testing = std.testing;

test "interning" {
    var i = Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = try i.intern("some string 1");
    const string2 = try i.intern("some string 2");
    const string3 = try i.intern("some string 1");
    const string4 = try i.intern("short");

    try testing.expect(string1.eql(string3));
    try testing.expect(!string1.eql(string2));

    try testing.expectEqualStrings("some string 1", string1.slice(i));
    try testing.expectEqualStrings("some string 2", string2.slice(i));
    try testing.expectEqualStrings("some string 1", string3.slice(i));
    try testing.expectEqualStrings("short", string4.slice(i));

    try testing.expectEqualStrings("some str", string1.prefix());
    try testing.expectEqualStrings("some str", string2.prefix());
    try testing.expectEqualStrings("some str", string3.prefix());
    try testing.expectEqualStrings("short", string4.prefix());

    try testing.expectEqualStrings("some string 1some string 2", i.storage.items);
}

test "reuse" {
    var i = Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = try i.intern("some string 1");
    const string2 = try i.intern("some string 2");

    try testing.expectEqualStrings("some string 1some string 2", i.storage.items);

    string2.deinit(&i);

    try testing.expectEqualStrings("some string 1", i.storage.items);

    _ = try i.intern("a different second string");

    try testing.expectEqualStrings("some string 1a different second string", i.storage.items);

    string1.deinit(&i);

    _ = try i.intern("same length s");

    try testing.expectEqualStrings("same length sa different second string", i.storage.items);
}

test "holes" {
    var i = Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = "aaaaaaaaaaaa";
    _ = try i.load(string1);
    const string2 = "b";
    _ = try i.load(string2);
    // aaaaaaaaaaaab
    try testing.expectEqualStrings("aaaaaaaaaaaab", i.storage.items);
    try testing.expectEqual(null, i.slots.peekMax());
    try testing.expectEqual(null, i.slots.peekMin());

    _ = i.releaseStr(string1);
    // ____________b
    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(1, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 12, .index = @enumFromInt(0) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 12, .index = @enumFromInt(0) }, i.slots.peekMin().?);

    const string3 = "cccccccc";
    _ = try i.load(string3);
    const string4 = "dd";
    _ = try i.load(string4);
    // ccccccccdd__b
    try testing.expectEqual(1, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 2, .index = @enumFromInt(10) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 2, .index = @enumFromInt(10) }, i.slots.peekMin().?);

    _ = i.releaseStr(string3);
    // ________dd__b
    try testing.expectEqual(2, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 8, .index = @enumFromInt(0) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 2, .index = @enumFromInt(10) }, i.slots.peekMin().?);

    const string5 = "eeee";
    _ = try i.load(string5);

    _ = try i.load("fff");
    // eeeefff_dd__b
    try testing.expectEqual(2, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 2, .index = @enumFromInt(10) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 1, .index = @enumFromInt(7) }, i.slots.peekMin().?);

    _ = i.releaseStr(string5);
    // ____fff_dd__b
    try testing.expectEqual(3, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 1, .index = @enumFromInt(7) }, i.slots.peekMin().?);

    _ = i.releaseStr(string4);
    // ____fff_____b
    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(2, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 5, .index = @enumFromInt(7) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMin().?);

    _ = i.releaseStr(string2);
    // ____fff
    try testing.expectEqual(7, i.storage.items.len);
    try testing.expectEqual(1, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMin().?);

    _ = try i.load("gggggg");
    // ____fffgggggg
    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(1, i.slots.len);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMax().?);
    try testing.expectEqualDeep(StorageSlot{ .len = 4, .index = @enumFromInt(0) }, i.slots.peekMin().?);
}
