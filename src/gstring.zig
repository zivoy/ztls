//! German / Umbra strings for better performance on short strings
//!
//! German strings are immutable and for short strings are stored entirely on the stack with no allocs
//! The size of the struct is the same as a regular zig slice (2 * usize)
//!
//! Limitations/Notes (64 bit):
//!  - The max capacity is 2^32 (4 GiB), long enough for most use cases
//!  - Short strings are 12 bytes or less, any longer and it's on the heap with a prefix on the stack
//!  - The prefix for long strings is 4 bytes, for fast comparison if the strings compared differ early
//!
//! Limitations/Notes (32 bit):
//!  - The max capacity is 2^16 (65536 bytes), but for most targets (wasm32-freestanding) this is fine
//!  - Short strings are 6 bytes or less
//!  - The prefix for long strings is only 2 bytes, so when comparing long strings going to the heap is more likely

const std = @import("std");
const builtin = @import("builtin");

// usize works just as well
// pub const String = StringType(usize);
pub const String = StringType(std.meta.Int(.unsigned, builtin.target.ptrBitWidth()));

pub fn StringType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int => |ti| {
            if (ti.signedness == .signed) @compileError("Type has to be unsigned");
            if ((ti.bits % std.mem.byte_size_in_bits) != 0) @compileError("Container has to be a full multiple of an 8 bit byte");
            if (((ti.bits / std.mem.byte_size_in_bits) % 2) != 0) @compileError("Container has to be a an even number of bytes");
            if (ti.bits < std.mem.byte_size_in_bits * 2) @compileError("Container has to be at least 2 bytes large");
        },
        else => @compileError("Invalid container type, must be unsigned int"),
    }

    // a strings length is 2 usizes long, so a length of string is half of a pointer
    // on a 64 bit arch its half of a 8 bytes (64 bits) so its 4 bytes or a u32
    const containerSize = @divExact(@bitSizeOf(T), std.mem.byte_size_in_bits);
    const LenType = std.meta.Int(.unsigned, @divExact(@bitSizeOf(T), 2));
    // on a 64 bit arch, this will result in 12 (bytes)
    const restSize = (2 * containerSize) - @divExact(@bitSizeOf(LenType), std.mem.byte_size_in_bits);
    const prefixLength = restSize - containerSize;

    const BufferType = std.meta.Int(.unsigned, restSize * std.mem.byte_size_in_bits);
    const PrefixType = std.meta.Int(.unsigned, prefixLength * std.mem.byte_size_in_bits);

    return packed struct {
        const Self = @This();

        /// Strings can be at most this length or shorter
        pub const length_max_long = std.math.maxInt(LenType);
        /// The length of a prefix for a long string
        pub const length_prefix_long = prefixLength;
        /// Short strings are either this long or shorter
        pub const length_max_short = restSize;

        comptime {
            const strSize = @sizeOf(Self);
            if (strSize != (2 * containerSize)) {
                @compileError("String does not fit in 2 of container");
            }
        }

        len: LenType,
        payload: packed union {
            content: BufferType,
            heap: packed struct { prefix: PrefixType, ptr: [*]const u8 },
        },

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.writeAll(self.slice());
        }

        /// Do not call deinit if inited using this function
        /// it will not free the provided string if it was short
        /// you will need to free the string yourself externally
        pub fn initUnmanaged(s: []const u8) Self {
            std.debug.assert(s.len <= length_max_long);
            const len: LenType = @truncate(s.len);
            if (len <= length_max_short) {
                var content: [length_max_short]u8 = @splat(0);
                @memcpy(content[0..len], s);

                return .{ .len = len, .payload = .{
                    .content = std.mem.bytesToValue(BufferType, &content),
                } };
            } else {
                var prefixArr: [length_prefix_long]u8 = @splat(0);
                @memcpy(&prefixArr, s[0..length_prefix_long]);

                return .{ .len = len, .payload = .{
                    .heap = .{
                        .prefix = std.mem.bytesToValue(PrefixType, &prefixArr),
                        .ptr = s.ptr,
                    },
                } };
            }
        }

        /// init a managed string
        /// you will have to free the provided string separately
        pub fn init(
            alloc: std.mem.Allocator,
            s: []const u8,
        ) std.mem.Allocator.Error!Self {
            return initUnmanaged(
                if (length_max_short < s.len) try alloc.dupe(u8, s) else s,
            );
        }

        /// init a managed string
        /// will free the provided string, so you do not need to free it separately
        /// does not work with slices of strings, use normal init or unmanaged for that
        pub fn initAdopt(
            alloc: std.mem.Allocator,
            s: []const u8,
        ) Self {
            const str = initUnmanaged(s);
            if (s.len <= length_max_short) alloc.free(s);
            // to prevent accidental bugs
            var strNonConst = @constCast(s);
            strNonConst = undefined;
            return str;
        }

        /// init a managed string
        /// will clear the provided array list, deinit should be safe to call on it
        pub fn initAdoptArrayList(
            alloc: std.mem.Allocator,
            s: *std.ArrayList(u8),
        ) std.mem.Allocator.Error!Self {
            const str = if (s.capacity == s.items.len) s.items else try s.toOwnedSlice(alloc);
            s.* = .empty;
            return initAdopt(alloc, str);
        }

        /// only call if inited using the regular init
        pub fn deinit(
            self: *const Self,
            alloc: std.mem.Allocator,
        ) void {
            var selfNonConst = @constCast(self);
            if (!self.isShort()) alloc.free(self.payload.heap.ptr[0..self.len]);
            selfNonConst.len = 0;
            selfNonConst.payload = undefined;
            selfNonConst = undefined;
        }

        pub fn isShort(self: Self) bool {
            return self.len <= length_max_short;
        }

        pub fn eql(self: Self, b: anytype) bool {
            return switch (@TypeOf(b)) {
                *const Self => self.eqlStrings(b.*),
                Self => self.eqlStrings(b),
                []const u8 => std.mem.eql(u8, self.slice(), b),
                else => @compileError("String.eql: Unsupported type for B '" ++ @typeName(@TypeOf(b)) ++ "'"),
            };
        }

        pub fn eqlStrings(
            lhs: Self,
            rhs: Self,
        ) bool {
            if (lhs.len != rhs.len) return false;
            // TODO: compare prefix by bit offset first for fewer branches

            if (lhs.isShort()) {
                return lhs.payload.content == rhs.payload.content;
            }

            if (lhs.payload.heap.prefix != rhs.payload.heap.prefix) return false;

            std.debug.assert(lhs.len == rhs.len);
            const len = lhs.len;
            return std.mem.eql(
                u8,
                lhs.payload.heap.ptr[0..len],
                rhs.payload.heap.ptr[0..len],
            );
        }

        pub fn order(a: anytype, b: anytype) std.math.Order {
            const sa = switch (@TypeOf(a)) {
                *const Self => a.*,
                Self => a,
                []const u8 => initUnmanaged(a),
                else => @compileError("String.Order: Unsupported type for A '" ++ @typeName(@TypeOf(a)) ++ "'"),
            };
            const sb = switch (@TypeOf(b)) {
                *const Self => b.*,
                Self => b,
                []const u8 => initUnmanaged(b),
                else => @compileError("String.Order: Unsupported type for B '" ++ @typeName(@TypeOf(b)) ++ "'"),
            };
            return orderStrings(sa, sb);
        }

        pub fn orderStrings(lhs: Self, rhs: Self) std.math.Order {
            // check the first 4 bytes that always are present
            const lhs_prefix = lhs.getAnyArray("payload")[0..length_prefix_long];
            const rhs_prefix = rhs.getAnyArray("payload")[0..length_prefix_long];

            const ord = std.mem.order(u8, lhs_prefix, rhs_prefix);
            // if its equal now it might change later
            if (ord != .eq) return ord;

            // compare by slice
            return std.mem.order(u8, lhs.slice(), rhs.slice());
        }

        fn getAnyArray(self: *const Self, comptime field_name: []const u8) [*]const u8 {
            const bitOffset = comptime @bitOffsetOf(Self, field_name);
            comptime std.debug.assert(bitOffset % std.mem.byte_size_in_bits == 0);
            const byteOffset = comptime bitOffset / std.mem.byte_size_in_bits;

            return @ptrFromInt(@intFromPtr(self) + byteOffset);
        }

        /// get a slice to the string
        pub fn slice(self: *const Self) []const u8 {
            if (!self.isShort()) return self.payload.heap.ptr[0..self.len];

            std.debug.assert(self.isShort());
            const payload_ptr = self.getAnyArray("payload");
            return payload_ptr[0..self.len];
        }

        /// get the data immediately available on the stack
        pub fn prefix(self: *const Self) []const u8 {
            const payload_ptr = self.getAnyArray("payload");
            const len = if (self.isShort()) self.len else length_prefix_long;
            return payload_ptr[0..len];
        }

        /// Get a ArrayList of the string, taking ownership
        /// this makes deinit not required, but safe to call
        /// works best with managed strings
        /// if used on unmanaged strings, you will need to check if the string was shorter then `length_max_short` and free the original string
        pub fn toArrayList(self: *Self, alloc: std.mem.Allocator) std.mem.Allocator.Error!std.ArrayList(u8) {
            var content = self.slice();
            if (self.isShort()) content = try alloc.dupe(u8, content);
            self.len = 0;
            return .fromOwnedSlice(@constCast(content));
        }
    };
}

test "fits in conainer" {
    const ptrSize = @sizeOf(usize);
    const strSize = @sizeOf(String);

    try std.testing.expectEqual(2 * ptrSize, strSize);

    // compare to slice
    const sliceSize = @sizeOf([]const u8);

    try std.testing.expectEqual(sliceSize, strSize);
}

test "smol string" {
    const alloc = std.testing.allocator;
    const a = try String.init(alloc, "some string");
    defer a.deinit(alloc);

    const b = try String.init(alloc, "another str");
    defer b.deinit(alloc);

    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.eql(a));
    try std.testing.expect(b.eql(b));
}

test "long string" {
    const alloc = std.testing.allocator;
    const a = try String.init(alloc, "A really long string that gets kicked out of the short opt");
    defer a.deinit(alloc);

    const strVal = a.slice();
    const b = try String.init(alloc, strVal);
    defer b.deinit(alloc);

    const c = try String.init(alloc, "Another longer string that is not short");
    defer c.deinit(alloc);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "format" {
    const alloc = std.testing.allocator;
    const a = try String.init(alloc, "some str");
    defer a.deinit(alloc);
    const b = try String.init(alloc, "a longer string here");
    defer b.deinit(alloc);

    const str = try std.fmt.allocPrint(alloc, "{f} != {f}", .{ a, b });
    defer alloc.free(str);

    try std.testing.expectEqualStrings("some str != a longer string here", str);
}

test "to slice vs copy buff" {
    const alloc = std.testing.allocator;

    {
        const str: []const u8 = "short";
        const a = try String.init(alloc, str);
        defer a.deinit(alloc);

        const slice = a.slice();

        const strB = try std.fmt.allocPrint(alloc, "{f}", .{a});
        defer alloc.free(strB);

        try std.testing.expectEqualStrings(str, slice);
        try std.testing.expectEqualStrings(str, strB);
    }

    {
        const str: []const u8 = "a longer string";
        const a = try String.init(alloc, str);
        defer a.deinit(alloc);

        const slice = a.slice();

        const strB = try std.fmt.allocPrint(alloc, "{f}", .{a});
        defer alloc.free(strB);

        try std.testing.expectEqualStrings(str, slice);
        try std.testing.expectEqualStrings(str, strB);
    }
}

test "prefix" {
    const alloc = std.testing.allocator;

    const Str = StringType(u64);
    {
        const a = try Str.init(alloc, "not long");
        defer a.deinit(alloc);

        const prefix = a.prefix();

        try std.testing.expectEqualStrings("not long", prefix);
    }

    {
        const a = try Str.init(alloc, "a relatively long string");
        defer a.deinit(alloc);

        const prefix = a.prefix();

        try std.testing.expectEqualStrings("a re", prefix);
    }
}

fn lessThan(_: void, lhs: String, rhs: String) bool {
    return lhs.order(rhs) == .lt;
}

test "ordering" {
    var strings = [_]String{
        .initUnmanaged("Some"),
        .initUnmanaged("stuff"),
        .initUnmanaged("but they are not the same"),
        .initUnmanaged("arnt like the others"),
        .initUnmanaged("Something"),
    };

    std.mem.sort(String, &strings, {}, lessThan);

    const expected = [_][]const u8{
        "Some",
        "Something",
        "arnt like the others",
        "but they are not the same",
        "stuff",
    };

    try std.testing.expectEqual(expected.len, strings.len);
    for (strings, expected) |s, e| {
        try std.testing.expectEqualStrings(e, s.slice());
    }
}

test "adoption" {
    // const allocator = std.testing.allocator;

    // there should only be 3 allocations, one for making the string, one for expanding it, and one for shrinking the array
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    const allocator = failing.allocator();

    var string1 = try String.init(allocator, "a string");
    defer string1.deinit(allocator); // safe

    var strArr = try string1.toArrayList(allocator); // alloc 1
    defer strArr.deinit(allocator);

    var string2 = try String.initAdoptArrayList(allocator, &strArr); // no alloc - short

    var strArr2 = try string2.toArrayList(allocator); // alloc 2
    errdefer strArr2.deinit(allocator);

    try strArr2.appendSlice(allocator, " with some extra stuff"); // alloc 3

    const string3 = try String.initAdoptArrayList(allocator, &strArr2); // alloc 4 - resize
    defer string3.deinit(allocator);

    try std.testing.expectEqualStrings("a string with some extra stuff", string3.slice());
}

test "allocation to managed" {
    const allocator = std.testing.allocator;
    {
        const strSlice = try allocator.dupe(u8, "short");
        defer allocator.free(strSlice);

        const string = try String.init(allocator, strSlice);
        defer string.deinit(allocator);

        try std.testing.expect(string.isShort());
    }

    {
        const strSlice = try allocator.dupe(u8, "longer string");
        defer allocator.free(strSlice);

        const string = try String.init(allocator, strSlice);
        defer string.deinit(allocator);

        try std.testing.expect(!string.isShort());
    }
}

test "allocation to unmanaged" {
    const allocator = std.testing.allocator;
    {
        const strSlice = try allocator.dupe(u8, "short");
        defer allocator.free(strSlice);

        const string = String.initUnmanaged(strSlice);

        try std.testing.expect(string.isShort());
    }

    {
        const strSlice = try allocator.dupe(u8, "longer string");
        defer allocator.free(strSlice);

        const string = String.initUnmanaged(strSlice);

        try std.testing.expect(!string.isShort());
    }
}

test "allocation to adoption" {
    const allocator = std.testing.allocator;
    {
        const strSlice = try allocator.dupe(u8, "short");
        errdefer allocator.free(strSlice);

        const string = String.initAdopt(allocator, strSlice);
        defer string.deinit(allocator);

        try std.testing.expect(string.isShort());
    }

    {
        const strSlice = try allocator.dupe(u8, "longer string");
        errdefer allocator.free(strSlice);

        const string = String.initAdopt(allocator, strSlice);
        defer string.deinit(allocator);

        try std.testing.expect(!string.isShort());
    }
}

fn testStringIsEql(s: String, r: []const u8) !void {
    const s1 = s.prefix();
    return std.testing.expectEqualStrings(r, s1);
}

test "equal function" {
    const string = try String.init(std.testing.allocator, "some string");
    defer string.deinit(std.testing.allocator);
    try testStringIsEql(string, "some string");
}

test "compare vs string" {
    const allocator = std.testing.allocator;
    const string: []const u8 = "some string that is one";
    const str = try String.init(allocator, string);
    defer str.deinit(allocator);
    const str2 = try String.init(allocator, "a short string");
    defer str2.deinit(allocator);

    try std.testing.expect(str.eql(string));
    try std.testing.expect(!str.eql(str2));
    try std.testing.expect(!str2.eql(@as([]const u8, "something")));
}

test "order vs string" {
    const allocator = std.testing.allocator;
    const string: []const u8 = "some string that is one";
    const str = try String.init(allocator, string);
    defer str.deinit(allocator);
    const str2 = try String.init(allocator, "a short string");
    defer str2.deinit(allocator);

    try std.testing.expectEqual(.eq, str.order(string));
    try std.testing.expectEqual(.gt, str.order(str2));
    try std.testing.expectEqual(.lt, str2.order(@as([]const u8, "something")));
}
