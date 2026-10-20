const c = @import("python");

const api = @import("api.zig");

/// Lock up to two objects on free-threaded Python. Does nothing on other builds.
/// Keep the section in a local `var` until `end`.
pub const Section = struct {
    raw: if (api.free_threaded) c.PyCriticalSection2 else void = undefined,
    locked: enum { none, one, two } = .none,

    /// Lock `first` and `second`, each of which may be `null`.
    pub fn begin(self: *Section, first: ?*c.PyObject, second: ?*c.PyObject) void {
        if (!api.free_threaded) return;

        const a = first orelse second orelse return;
        const b = if (first != null) second else null;
        if (b) |other| {
            c.PyCriticalSection2_Begin(&self.raw, a, other);
            self.locked = .two;
        } else {
            c.PyCriticalSection_Begin(&self.raw._cs_base, a);
            self.locked = .one;
        }
    }

    /// Unlock what `begin` locked, if anything.
    pub fn end(self: *Section) void {
        if (!api.free_threaded) return;

        switch (self.locked) {
            .none => {},
            .one => c.PyCriticalSection_End(&self.raw._cs_base),
            .two => c.PyCriticalSection2_End(&self.raw),
        }
        self.locked = .none;
    }
};
