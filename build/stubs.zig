const std = @import("std");
const py = @import("zypy");
const extension = @import("extension");

/// Prevent `py.exportModule` from exporting an extension while this program generates stubs.
pub const zypy_stub_generator = true;

pub fn main(init: std.process.Init) !void {
    if (!@hasDecl(extension, "module")) {
        @compileError("zypy: to generate type stubs, declare the module as pub const module = py.module(...) " ++
            "in the extension's root file (or pass .stubs = false to zypy.addExtension)");
    }

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[1], .{});
    defer directory.close(init.io);

    try py.stubs.write(extension.module, init.io, directory, init.gpa);
}
