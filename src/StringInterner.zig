// strings are interned in one big array, so only one call needed to free it
// the strings are in a gstring like format, but its id based, so there is more space for the prefix
// short strings are passed on the stack as is
// strings are referenced counted
// strings are stored in a freelist like format,
// free space created by freed strings, will be repopulated, picking the smallest available slot

// NOTE: maybe make a compact function, it will make all strings invalid, but will compact the memory space
//       or have some stable index system

const std = @import("std");
const assert = std.debug.assert;

// this being a u40 should allow for about 1tb of total memory, should be enough for most use cases
const IndexType = enum(u40) {
    _,
    pub inline fn toBase(self: IndexType) usize {
        return @intFromEnum(self);
    }
};
const LenType = u32;

// TODO: benchmark for best value
const defaultSlotMergeThreshold: u16 = 256;

storage: std.ArrayList(u8),
// Map: Span(Index, Len) -> Usage(u32)
storedStrings: std.HashMapUnmanaged(Span, u32, InternerContext, 80),
slots: std.ArrayList(Span),
// NOTE: maybe switch to a soa
//       also store a second list sorted by index to make merging faster
// NOTE: another potential optimization is to drop the slots lists and use an ArrayHashMap, it will make inserts slower though

/// The amount of holes that are needed to exist before a merge will happen automatically
slotMergeThreshold: u16 = defaultSlotMergeThreshold,

gpa: std.mem.Allocator,
const Interner = @This();

// Key for the HashMap (Index + Length)
// This is also used for the free slots
const Span = struct {
    index: IndexType,
    len: LenType,

    fn end(self: Span) usize {
        return self.index.toBase() + self.len;
    }

    fn orderByLenLt(_: void, a: Span, b: Span) bool {
        return a.len < b.len;
    }

    fn orderByIdxLt(_: void, a: Span, b: Span) bool {
        return a.index.toBase() < b.index.toBase();
    }
};

fn getContext(self: *const Interner) InternerContext {
    return .{ .storage = self.storage.items };
}

// Context for the HashMap that resolves Indices to Strings via Storage
const InternerContext = struct {
    storage: []const u8,

    pub fn hash(self: InternerContext, key: anytype) u64 {
        const T = @TypeOf(key);
        const str = switch (T) {
            Span => self.storage[key.index.toBase() .. key.index.toBase() + key.len],
            []const u8 => key,
            else => @compileError("InternerContext.hash: Unsupported key type '" ++ @typeName(T) ++ "'"),
        };
        return std.hash.Wyhash.hash(0, str);
    }

    pub fn eql(self: InternerContext, a: anytype, b: anytype) bool {
        const strA: []const u8 = switch (@TypeOf(a)) {
            Span => self.storage[a.index.toBase() .. a.index.toBase() + a.len],
            []const u8 => a,
            else => @compileError("InternerContext.eql: Unsupported type for A '" ++ @typeName(@TypeOf(a)) ++ "'"),
        };
        const strB: []const u8 = switch (@TypeOf(b)) {
            Span => self.storage[b.index.toBase() .. b.index.toBase() + b.len],
            []const u8 => b,
            else => @compileError("InternerContext.eql: Unsupported type for B '" ++ @typeName(@TypeOf(b)) ++ "'"),
        };
        return std.mem.eql(u8, strA, strB);
    }
};

pub fn initEmpty(gpa: std.mem.Allocator) Interner {
    return Interner{
        .gpa = gpa,
        .storage = .empty,
        .storedStrings = .empty,
        .slots = .empty,
    };
}

pub fn initCapacity(gpa: std.mem.Allocator, stringCapacity: u40, holeCapacity: u32, hashMapCapacity: u32) !Interner {
    var interner = initEmpty(gpa);
    try interner.ensureTotalCapacity(stringCapacity, holeCapacity, hashMapCapacity);
    return interner;
}

pub fn init(gpa: std.mem.Allocator) !Interner {
    // 4 mb of storage, that can store 1000 strings and have 256 (merge threshold) + 1 holes
    return initCapacity(gpa, 4 * 1024 * 1024, defaultSlotMergeThreshold + 1, 1000);
}

pub fn ensureTotalCapacity(self: *Interner, stringCapacity: u40, holeCapacity: u32, hashMapCapacity: u32) !void {
    try self.storage.ensureTotalCapacity(self.gpa, stringCapacity);
    try self.slots.ensureTotalCapacity(self.gpa, holeCapacity);
    try self.storedStrings.ensureTotalCapacityContext(self.gpa, hashMapCapacity, self.getContext());
}

pub fn ensureUnusedCapacity(self: *Interner, stringCapacity: u40, holeCapacity: u32, hashMapCapacity: u32) !void {
    try self.storage.ensureUnusedCapacity(self.gpa, stringCapacity);
    try self.slots.ensureUnusedCapacity(self.gpa, holeCapacity);
    try self.storedStrings.ensureUnusedCapacityContext(self.gpa, hashMapCapacity, self.getContext());
}

pub fn deinit(self: *Interner) void {
    self.storedStrings.deinit(self.gpa);
    self.storage.deinit(self.gpa);
    self.slots.deinit(self.gpa);
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

pub fn release(self: *Interner, s: String) bool {
    if (s.isShort()) return true;

    return self.releaseKey(.{
        .index = s.payload.interned.index,
        .len = s.len,
    });
}

fn releaseKey(self: *Interner, key: Span) bool {
    const ctx = self.getContext();
    const usage = self.storedStrings.getPtrContext(key, ctx) orelse return false;
    usage.* -= 1;
    if (usage.* > 0) return true;

    // Remove from map
    _ = self.storedStrings.removeContext(key, ctx);

    assert(key.end() <= self.storage.items.len);

    @memset(self.storage.items[key.index.toBase()..key.end()], undefined);

    defer if (self.slots.items.len > self.slotMergeThreshold) self.mergeSlots();

    // easy case
    const is_at_end = key.end() == self.storage.items.len;
    if (is_at_end) {
        self.storage.items.len -= key.len;
        return true;
    }

    // Best effort slot creation
    if (self.slots.ensureUnusedCapacity(self.gpa, 1)) {
        const el = self.slots.addOneAssumeCapacity();
        el.index = key.index;
        el.len = key.len;
    } else |_| {
        // If we can't allocate a slot, we leak this hole.
        // But we prevented the map entry leak.
        // This is acceptable for OOM handling.
    }

    return true;
}

fn load(self: *Interner, s: []const u8) !IndexType {
    // get existing
    const ctx = self.getContext();
    const result = try self.storedStrings.getOrPutContextAdapted(self.gpa, s, ctx, ctx);
    if (result.found_existing) {
        result.value_ptr.* += 1;
        return result.key_ptr.index;
    }
    errdefer _ = self.storedStrings.removeByPtr(result.key_ptr);

    var idx: IndexType = undefined;

    const needMoreSpace = if (self.peekMaxSlot()) |slot| slot.len < s.len else true;
    if (needMoreSpace) {
        // append to the end
        if (self.storage.items.len + s.len > std.math.maxInt(u40)) return error.OutOfMemory;
        idx = @enumFromInt(self.storage.items.len);
        try self.storage.appendSlice(self.gpa, s);
    } else {
        // there _will_ be a slot with space to hold the string
        var found_slot_index: usize = undefined;
        var slot_entry: Span = undefined;
        // for debugging
        var found = false;

        for (self.slots.items, 0..) |slot, i| {
            if (slot.len >= s.len) {
                found_slot_index = i;
                slot_entry = slot;
                found = true;
                break;
            }
        }
        assert(found);

        idx = slot_entry.index;
        self.storage.replaceRangeAssumeCapacity(idx.toBase(), s.len, s);

        // consume slot
        if (s.len == slot_entry.len) {
            _ = self.slots.orderedRemove(found_slot_index);
        } else {
            self.slots.items[found_slot_index].index = @enumFromInt(@intFromEnum(slot_entry.index) + s.len);
            self.slots.items[found_slot_index].len = slot_entry.len - @as(LenType, @truncate(s.len));
            // since the hole shrunk, we only have to sort the items that are below it
            std.mem.sortUnstable(Span, self.slots.items[0 .. found_slot_index + 1], {}, Span.orderByLenLt);
        }
    }

    // fill info for map
    result.key_ptr.* = .{ .index = idx, .len = @intCast(s.len) };
    result.value_ptr.* = 1;

    return idx;
}

pub fn mergeSlots(self: *Interner) void {
    if (self.slots.items.len == 0) return;
    // very slow, find a better way
    // maybe also don't sort every time ?
    std.mem.sortUnstable(Span, self.slots.items, {}, Span.orderByIdxLt);

    var write_idx: usize = 0;
    var current = self.slots.items[0];

    for (self.slots.items[1..]) |next_range| {
        if (current.end() >= next_range.index.toBase()) {
            // Merge
            assert(next_range.end() >= current.end());
            current.len = @intCast(next_range.end() - current.index.toBase());
            self.slots.items.len -= 1;
        } else {
            // Save current and move to next
            self.slots.items[write_idx] = current;
            write_idx += 1;
            current = next_range;
        }
    }
    self.slots.items[write_idx] = current;
    write_idx += 1;

    // merge with end
    if (current.end() == self.storage.items.len) {
        self.storage.items.len -= current.len;
        self.slots.items.len -= 1;
    }

    std.mem.sortUnstable(Span, self.slots.items, {}, Span.orderByLenLt);
}

fn peekMaxSlot(self: Interner) ?Span {
    if (self.slots.items.len == 0) return null;
    return self.slots.items[self.slots.items.len - 1];
}
fn peekMinSlot(self: Interner) ?Span {
    if (self.slots.items.len == 0) return null;
    return self.slots.items[0];
}

pub const String = packed struct {
    // not using the gstrings implementation because this needs to be index based

    const containerSize = @sizeOf(u64);
    const restSize = (2 * containerSize) - @sizeOf(LenType);
    const prefixLength = restSize - (@bitSizeOf(IndexType) / 8);

    const BufferType = std.meta.Int(.unsigned, restSize * 8);
    const PrefixType = std.meta.Int(.unsigned, prefixLength * 8);

    pub const length_max_long = std.math.maxInt(LenType);
    pub const length_prefix_long = prefixLength;
    pub const length_max_short = restSize;

    comptime {
        const strSize = @sizeOf(String);
        if (strSize != (2 * containerSize)) {
            @compileError("String does not fit in 2 of container");
        }
    }

    len: LenType,
    payload: packed union {
        content: BufferType,
        interned: packed struct { prefix: PrefixType, index: IndexType },
    },

    pub fn deinit(
        self: *const String,
        interner: *Interner,
    ) void {
        if (!interner.release(self.*)) return;
        // make the callers value be undefined, this is only for debugging to help catch use after frees
        var selfNonConst = @constCast(self);
        selfNonConst = undefined;
    }

    pub fn isShort(self: String) bool {
        return self.len <= length_max_short;
    }

    pub fn eql(
        lhs: String,
        rhs: String,
    ) bool {
        if (lhs.len != rhs.len) return false;
        if (lhs.isShort()) {
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
        if (!self.isShort()) {
            const index: usize = self.payload.interned.index.toBase();
            return interner.storage.items[index .. index + self.len];
        }

        assert(self.isShort());
        const payload_ptr = self.getAnyArray("payload");
        return payload_ptr[0..self.len];
    }

    /// get the data immediately available on the stack
    pub fn prefix(self: *const String) []const u8 {
        const payload_ptr = self.getAnyArray("payload");
        const len = if (self.isShort()) self.len else length_prefix_long;
        return payload_ptr[0..len];
    }
};

const testing = std.testing;

fn releaseStr(self: *Interner, str: []const u8) bool {
    const ctx = self.getContext();
    const entry = self.storedStrings.getEntryAdapted(str, ctx) orelse return false;
    // Entry key_ptr points to the Key stored in the map
    const key = entry.key_ptr.*;
    return self.releaseKey(key);
}

test "interning" {
    var i = try Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = try i.intern("some string 1");
    const string2 = try i.intern("some string 2");
    const string3 = try i.intern("some string 1");
    const string4 = try i.intern("short");

    try testing.expect(string1.eql(string3));
    try testing.expect(!string1.eql(string2));
    try testing.expectEqual(.gt, String.order(i, string1, string4));

    try testing.expectEqualStrings("some string 1", string1.slice(i));
    try testing.expectEqualStrings("some string 2", string2.slice(i));
    try testing.expectEqualStrings("some string 1", string3.slice(i));
    try testing.expectEqualStrings("short", string4.slice(i));

    try testing.expectEqualStrings("some st", string1.prefix());
    try testing.expectEqualStrings("some st", string2.prefix());
    try testing.expectEqualStrings("some st", string3.prefix());
    try testing.expectEqualStrings("short", string4.prefix());

    try testing.expectEqualStrings("some string 1some string 2", i.storage.items);
}

test "reuse" {
    var i = try Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = try i.intern("some string 1");
    const string2 = try i.intern("some string 2");

    try testing.expectEqualStrings("some string 1some string 2", i.storage.items);

    _ = i.release(string2);

    try testing.expectEqualStrings("some string 1", i.storage.items);

    _ = try i.intern("a different second string");

    try testing.expectEqualStrings("some string 1a different second string", i.storage.items);

    // deinit also works, and does not return success bool
    string1.deinit(&i);

    _ = try i.intern("same length s");

    try testing.expectEqualStrings("same length sa different second string", i.storage.items);
}

test "holes" {
    var i = try Interner.init(testing.allocator);
    defer i.deinit();

    const string1 = "aaaaaaaaaaaa";
    _ = try i.load(string1);
    const string2 = "b";
    _ = try i.load(string2);
    // aaaaaaaaaaaab
    try testing.expectEqualStrings("aaaaaaaaaaaab", i.storage.items);
    try testing.expectEqual(null, i.peekMaxSlot());
    try testing.expectEqual(null, i.peekMinSlot());

    _ = i.releaseStr(string1);
    i.mergeSlots();
    // ____________b

    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(1, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 12, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 12, .index = @enumFromInt(0) }, i.peekMinSlot().?);

    const string3 = "cccccccc";
    _ = try i.load(string3);
    const string4 = "dd";
    _ = try i.load(string4);
    // ccccccccdd__b
    try testing.expectEqual(1, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 2, .index = @enumFromInt(10) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 2, .index = @enumFromInt(10) }, i.peekMinSlot().?);

    _ = i.releaseStr(string3);
    i.mergeSlots();
    // ________dd__b
    try testing.expectEqual(2, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 8, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 2, .index = @enumFromInt(10) }, i.peekMinSlot().?);

    const string5 = "eeee";
    _ = try i.load(string5);

    _ = try i.load("fff");
    // eeeefff_dd__b
    try testing.expectEqual(2, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 2, .index = @enumFromInt(10) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 1, .index = @enumFromInt(7) }, i.peekMinSlot().?);

    _ = i.releaseStr(string5);
    i.mergeSlots();
    // ____fff_dd__b
    try testing.expectEqual(3, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 1, .index = @enumFromInt(7) }, i.peekMinSlot().?);

    const string6 = "g";
    _ = try i.load(string6);
    // ____fffgdd__b
    try testing.expectEqual(2, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 2, .index = @enumFromInt(10) }, i.peekMinSlot().?);

    _ = i.releaseStr(string6);

    _ = i.releaseStr(string4);
    i.mergeSlots();
    // ____fff_____b
    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(2, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 5, .index = @enumFromInt(7) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMinSlot().?);

    _ = i.releaseStr(string2);
    i.mergeSlots();
    // ____fff
    try testing.expectEqual(7, i.storage.items.len);
    try testing.expectEqual(1, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMinSlot().?);

    _ = try i.load("hhhhhh");
    // ____fffhhhhhh
    try testing.expectEqual(13, i.storage.items.len);
    try testing.expectEqual(1, i.slots.items.len);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMaxSlot().?);
    try testing.expectEqualDeep(Span{ .len = 4, .index = @enumFromInt(0) }, i.peekMinSlot().?);
}
