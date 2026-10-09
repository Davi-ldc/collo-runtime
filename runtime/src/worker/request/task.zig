//! The request task table: one slot per request whose handler is running or
//! settling, addressed by a generational token so a settlement that arrives
//! after its request ended finds nothing instead of a reused slot. The
//! engine bridge carries the token across the C ABI, which is why its layout
//! is pinned. The table belongs to the worker's VM thread.

const std = @import("std");
const request_context = @import("context.zig");
const js_value = @import("collo_worker_js").value;

pub const TaskToken = extern struct {
    slot: u32,
    generation: u32,
};

comptime {
    if (@sizeOf(TaskToken) != 8)
        @compileError("TaskToken must stay two u32 fields");
    if (@offsetOf(TaskToken, "slot") != 0)
        @compileError("TaskToken.slot offset mismatch");
    if (@offsetOf(TaskToken, "generation") != 4)
        @compileError("TaskToken.generation offset mismatch");
}

pub const State = enum {
    created,
    invoking_handler,
    completed_sync,
    waiting_thenable,
    extracting_response,
    writing_response,
    done,
    failed,
    canceled,
    timed_out,
};

pub const RequestTask = struct {
    request_id: u64,
    request_generation: u64,
    request_ctx: *request_context.RequestContext,
    route_handler: ?js_value.JsFunctionOwned = null,
    state: State = .created,
    deadline_ns: u64 = 0,
    canceled: bool = false,
    timed_out: bool = false,
    completion_queued: bool = false,
    response_value: ?js_value.JsValueOwned = null,
    pending_thenable: ?js_value.JsValueOwned = null,
    trace: ?*request_context.RequestTrace = null,

    pub fn deinit(self: *RequestTask) void {
        if (self.pending_thenable) |*value| {
            value.deinit();
            self.pending_thenable = null;
        }
        if (self.response_value) |*value| {
            value.deinit();
            self.response_value = null;
        }
        if (self.route_handler) |*handler| {
            handler.deinit();
            self.route_handler = null;
        }
        self.* = undefined;
    }
};

const Slot = struct {
    generation: u32 = 1,
    occupied: bool = false,
    task: RequestTask = undefined,
};

pub const RequestTaskTable = struct {
    allocator: std.mem.Allocator,
    tasks: []Slot,
    free_stack: []u32,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RequestTaskTable {
        if (capacity == 0 or capacity > std.math.maxInt(u32))
            return error.InvalidTaskCapacity;

        const tasks = try allocator.alloc(Slot, capacity);
        errdefer allocator.free(tasks);
        const free_stack = try allocator.alloc(u32, capacity);
        errdefer allocator.free(free_stack);

        @memset(tasks, Slot{});
        var index: usize = capacity;
        while (index > 0) {
            index -= 1;
            free_stack[capacity - 1 - index] = @intCast(index);
        }

        return .{
            .allocator = allocator,
            .tasks = tasks,
            .free_stack = free_stack,
            .len = capacity,
        };
    }

    pub fn deinit(self: *RequestTaskTable) void {
        for (self.tasks) |*slot| {
            if (slot.occupied) {
                slot.task.deinit();
                slot.occupied = false;
            }
        }
        self.allocator.free(self.free_stack);
        self.allocator.free(self.tasks);
        self.* = undefined;
    }

    pub fn create(self: *RequestTaskTable, task: RequestTask) !TaskToken {
        if (self.len == 0)
            return error.RequestTaskTableFull;
        self.len -= 1;
        const slot_index = self.free_stack[self.len];
        const slot = &self.tasks[slot_index];
        std.debug.assert(!slot.occupied);
        slot.task = task;
        slot.occupied = true;
        return .{
            .slot = slot_index,
            .generation = slot.generation,
        };
    }

    pub fn get(self: *RequestTaskTable, token: TaskToken) ?*RequestTask {
        if (token.slot >= self.tasks.len)
            return null;
        const slot = &self.tasks[token.slot];
        if (!slot.occupied or slot.generation != token.generation)
            return null;
        return &slot.task;
    }

    pub fn activeCount(self: *const RequestTaskTable) usize {
        return self.tasks.len - self.len;
    }

    pub fn destroy(self: *RequestTaskTable, token: TaskToken) void {
        if (token.slot >= self.tasks.len)
            return;
        const slot = &self.tasks[token.slot];
        if (!slot.occupied or slot.generation != token.generation)
            return;

        slot.task.deinit();
        slot.occupied = false;
        slot.generation +%= 1;
        // Generation 0 never names a task: the bridge refuses a completion
        // token that carries it (`collo_request_task_settle_thenable`).
        if (slot.generation == 0)
            slot.generation = 1;
        self.free_stack[self.len] = token.slot;
        self.len += 1;
    }
};
