const std = @import("std");
const assert = std.debug.assert;

const IdxType = u32;

/// A data structure with stable external ids as well as o(1) deletes
pub fn StableIndexArray(comptime T: type) type {
    // TODO: make a MultiArrayList option -- automatic?

    return struct {
        const Self = @This();

        idxList: std.ArrayListUnmanaged(IdxType),
        idList: std.ArrayListUnmanaged(IdxType),
        content: std.ArrayListUnmanaged(T),

        fn init() Self {
            return Self{
                .idList = .empty,
                .idxList = .empty,
                .content = .empty,
            };
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.idxList.deinit(allocator);
            self.idList.deinit(allocator);
            self.content.deinit(allocator);
            self.* = undefined;
        }

        /// get the internal unstable index for items from a stable external index
        fn getIdx(self: Self, idx: IdxType) IdxType {
            const res = self.idxList.items[idx];
            assert(res < self.content.items.len);
            return res;
        }
        fn get(self: Self, idx: IdxType) T {
            const internal_idx = self.getIdx(idx);
            return self.content.items[internal_idx];
        }

        fn delete(self: *Self, idx: IdxType) void {
            const internal_idx = self.getIdx(idx);
            // swap to end and pop
            self.content.items[internal_idx] = undefined; // not effective since it will get moved
            self.content.items[internal_idx] = self.content.pop().?;

            if (idx == self.content.items.len) return;

            // adjust ids
            const internal_lastIdx: IdxType = @intCast(self.content.items.len);
            const lastId = self.idList.items[internal_idx];
            self.idList.items[internal_idx] = self.idList.items[internal_lastIdx];
            self.idList.items[internal_lastIdx] = lastId;

            self.idxList.items[self.idList.items[internal_idx]] = internal_idx;
            self.idxList.items[self.idList.items[internal_lastIdx]] = internal_lastIdx;
        }

        fn append(self: *Self, allocator: std.mem.Allocator, item: T) error{OutOfMemory}!IdxType {
            const idx: IdxType = blk: {
                if (self.content.items.len < self.idList.items.len) {
                    break :blk self.idList.items[self.content.items.len];
                } else {
                    const idx: IdxType = @intCast(self.content.items.len);
                    try self.idList.append(allocator, idx);
                    errdefer self.idList.items.len -= 1;
                    try self.idxList.append(allocator, idx);

                    break :blk idx;
                }
            };

            try self.content.append(allocator, item);

            return idx;
        }
    };
}

const testing = std.testing;
test "stability" {
    var arr = StableIndexArray(u8).init();
    defer arr.deinit(testing.allocator);

    var i: IdxType = undefined;
    i = try arr.append(testing.allocator, 'a');
    try testing.expectEqual(0, i);
    i = try arr.append(testing.allocator, 'b');
    try testing.expectEqual(1, i);
    i = try arr.append(testing.allocator, 'c');
    try testing.expectEqual(2, i);

    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c' }, arr.content.items);

    arr.delete(0);

    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 0 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'c', 'b' }, arr.content.items);

    i = try arr.append(testing.allocator, 'd');
    try testing.expectEqual(0, i);
    i = try arr.append(testing.allocator, 'e');
    try testing.expectEqual(3, i);

    try testing.expectEqualSlices(u32, &.{ 2, 1, 0, 3 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 0, 3 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'c', 'b', 'd', 'e' }, arr.content.items);

    arr.delete(2);

    try testing.expectEqualSlices(u32, &.{ 2, 1, 3, 0 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 0, 2 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'e', 'b', 'd' }, arr.content.items);
}

test "pezza video" {
    var arr: StableIndexArray(u8) = .init();
    defer arr.deinit(testing.allocator);

    try arr.content.appendSlice(testing.allocator, &.{ 'd', 'g', 'e', 'f', 'a', 'b', 'c' });
    try arr.idList.appendSlice(testing.allocator, &.{ 3, 6, 4, 5, 0, 1, 2 });
    try arr.idxList.appendSlice(testing.allocator, &.{ 4, 5, 6, 0, 2, 3, 1 });

    try testing.expectEqual('d', arr.get(3));
    try testing.expectEqual('a', arr.get(0));
    try testing.expectEqual('f', arr.get(5));
    try testing.expectEqual('c', arr.get(2));

    arr.delete(0);

    try testing.expectEqualSlices(u32, &.{ 6, 5, 4, 0, 2, 3, 1 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 3, 6, 4, 5, 2, 1, 0 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'd', 'g', 'e', 'f', 'c', 'b' }, arr.content.items);

    try testing.expectEqual('c', arr.get(2));

    arr.delete(6);

    try testing.expectEqualSlices(u32, &.{ 6, 1, 4, 0, 2, 3, 5 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 4, 5, 2, 6, 0 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'd', 'b', 'e', 'f', 'c' }, arr.content.items);

    try testing.expectEqual('c', arr.get(2));

    var i: u32 = undefined;
    i = try arr.append(testing.allocator, 'h');
    try testing.expectEqual(6, i);

    i = try arr.append(testing.allocator, 'i');
    try testing.expectEqual(0, i);

    try testing.expectEqual('c', arr.get(2));

    i = try arr.append(testing.allocator, 'j');
    try testing.expectEqual(7, i);

    try testing.expectEqualSlices(u32, &.{ 6, 1, 4, 0, 2, 3, 5, 7 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 4, 5, 2, 6, 0, 7 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'd', 'b', 'e', 'f', 'c', 'h', 'i', 'j' }, arr.content.items);

    arr.delete(4);

    try testing.expectEqualSlices(u32, &.{ 6, 1, 4, 0, 7, 3, 5, 2 }, arr.idxList.items);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 7, 5, 2, 6, 0, 4 }, arr.idList.items);
    try testing.expectEqualSlices(u8, &.{ 'd', 'b', 'j', 'f', 'c', 'h', 'i' }, arr.content.items);
}
