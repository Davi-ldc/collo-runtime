//! An intrusive binary min-heap. Each element embeds an `IntrusiveHeapField`
//! that records its index, so removing any element costs O(log n) with no
//! search and no wrapper allocation. The heap stores pointers: an element
//! must keep its address while inserted, and through one field it can sit in
//! one heap at a time. Not thread-safe.

const std = @import("std");

/// The index slot an element embeds; null while the element is in no heap.
pub fn IntrusiveHeapField(comptime T: type) type {
    _ = T;
    return struct {
        index: ?usize = null,

        pub fn inserted(self: *const @This()) bool {
            return self.index != null;
        }
    };
}

/// A heap over elements whose embedded field is named `heap`. `peek` and
/// `deleteMin` return the element `lessThan` orders first.
pub fn IntrusiveHeap(
    comptime T: type,
    comptime Context: type,
    comptime lessThan: fn (Context, *const T, *const T) bool,
) type {
    return IntrusiveHeapWithField(T, "heap", Context, lessThan);
}

pub fn IntrusiveHeapWithField(
    comptime T: type,
    comptime field_name: []const u8,
    comptime Context: type,
    comptime lessThan: fn (Context, *const T, *const T) bool,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        context: Context,
        items: std.array_list.Aligned(*T, null) = .{},

        pub fn init(allocator: std.mem.Allocator, context: Context) Self {
            return .{
                .allocator = allocator,
                .context = context,
            };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, context: Context, initial_capacity: usize) !Self {
            var self = init(allocator, context);
            errdefer self.deinit();
            try self.ensureTotalCapacity(initial_capacity);
            return self;
        }

        /// Marks every element still inside as in no heap, so it can be
        /// inserted elsewhere, then frees the pointer array.
        pub fn deinit(self: *Self) void {
            for (self.items.items) |item|
                field(item).index = null;
            self.items.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn ensureTotalCapacity(self: *Self, total_capacity: usize) !void {
            try self.items.ensureTotalCapacity(self.allocator, total_capacity);
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn capacity(self: *const Self) usize {
            return self.items.capacity;
        }

        pub fn peek(self: *const Self) ?*T {
            if (self.items.items.len == 0)
                return null;
            return self.items.items[0];
        }

        pub fn insert(self: *Self, item: *T) !void {
            if (field(item).index != null)
                return error.NodeAlreadyInserted;
            try self.items.append(self.allocator, item);
            field(item).index = self.items.items.len - 1;
            self.siftUp(self.items.items.len - 1);
        }

        pub fn insertAssumeCapacity(self: *Self, item: *T) void {
            std.debug.assert(field(item).index == null);
            self.items.appendAssumeCapacity(item);
            field(item).index = self.items.items.len - 1;
            self.siftUp(self.items.items.len - 1);
        }

        pub fn deleteMin(self: *Self) ?*T {
            if (self.items.items.len == 0)
                return null;
            return self.removeIndex(0);
        }

        /// False when `item` is not in this heap, including when it sits in
        /// another heap that uses the same field.
        pub fn remove(self: *Self, item: *T) bool {
            const index = field(item).index orelse return false;
            if (index >= self.items.items.len or self.items.items[index] != item)
                return false;
            _ = self.removeIndex(index);
            return true;
        }

        fn removeIndex(self: *Self, index: usize) *T {
            const removed = self.items.items[index];
            const last = self.items.pop().?;
            field(removed).index = null;

            if (index < self.items.items.len) {
                self.items.items[index] = last;
                field(last).index = index;
                self.fixAt(index);
            }

            return removed;
        }

        fn fixAt(self: *Self, index: usize) void {
            if (index > 0) {
                const parent = (index - 1) / 2;
                if (lessThan(self.context, self.items.items[index], self.items.items[parent])) {
                    self.siftUp(index);
                    return;
                }
            }
            self.siftDown(index);
        }

        fn siftUp(self: *Self, start_index: usize) void {
            var index = start_index;
            while (index > 0) {
                const parent = (index - 1) / 2;
                if (!lessThan(self.context, self.items.items[index], self.items.items[parent]))
                    return;
                self.swap(index, parent);
                index = parent;
            }
        }

        fn siftDown(self: *Self, start_index: usize) void {
            var index = start_index;
            while (true) {
                const left = index * 2 + 1;
                const right = left + 1;
                var smallest = index;

                if (left < self.items.items.len and lessThan(self.context, self.items.items[left], self.items.items[smallest]))
                    smallest = left;
                if (right < self.items.items.len and lessThan(self.context, self.items.items[right], self.items.items[smallest]))
                    smallest = right;
                if (smallest == index)
                    return;

                self.swap(index, smallest);
                index = smallest;
            }
        }

        fn swap(self: *Self, a: usize, b: usize) void {
            std.mem.swap(*T, &self.items.items[a], &self.items.items[b]);
            field(self.items.items[a]).index = a;
            field(self.items.items[b]).index = b;
        }

        fn field(item: *T) *IntrusiveHeapField(T) {
            return &@field(item, field_name);
        }
    };
}
