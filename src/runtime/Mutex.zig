const std = @import("std");
const c = @import("python");

const api = @import("api.zig");

const Mutex = @This();

const Raw = if (api.limited) std.atomic.Value(bool) else c.PyMutex;

raw: Raw = std.mem.zeroes(Raw),

pub fn lock(self: *Mutex) void {
    if (api.limited) {
        while (self.raw.swap(true, .acquire)) std.atomic.spinLoopHint();
    } else {
        c.PyMutex_Lock(&self.raw);
    }
}

pub fn unlock(self: *Mutex) void {
    if (api.limited) self.raw.store(false, .release) else c.PyMutex_Unlock(&self.raw);
}
