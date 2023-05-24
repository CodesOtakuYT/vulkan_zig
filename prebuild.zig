const std = @import("std");

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(general_purpose_allocator.deinit() == .ok);
    var arena = std.heap.ArenaAllocator.init(general_purpose_allocator.allocator());
    const allocator = arena.allocator();
    defer arena.deinit();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    const current_working_directory = std.fs.cwd();

    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "translate_cimports")) {
            const result = try std.ChildProcess.exec(.{
                .allocator = allocator,
                .argv = &.{ "zig", "translate-c", "-lc", "cimports.h" },
                .max_output_bytes = std.math.maxInt(usize),
            });

            const file = try std.fs.cwd().createFile(
                try std.fs.path.join(allocator, &.{ "src", "c.zig" }),
                .{},
            );
            defer file.close();
            try file.writeAll(result.stdout);
        } else if (std.mem.eql(u8, argument, "compile_shaders")) {
            const input_path = try std.fs.path.join(allocator, &.{ "dev", "shaders" });
            const output_path = try std.fs.path.join(allocator, &.{ "src", "res", "shaders" });

            try current_working_directory.deleteTree(output_path);

            var output_directory = try current_working_directory.makeOpenPath(output_path, .{});
            defer output_directory.close();

            var iterable_dir = try current_working_directory.openIterableDir(
                input_path,
                .{},
            );
            defer iterable_dir.close();
            var walker = try iterable_dir.walk(allocator);
            defer walker.deinit();
            while (try walker.next()) |entry| {
                if (entry.kind == .File) {
                    const result = try std.ChildProcess.exec(.{
                        .allocator = allocator,
                        .argv = &.{ "glslc", entry.basename, "-o", "-" },
                        .max_output_bytes = std.math.maxInt(usize),
                        .cwd_dir = entry.dir,
                    });

                    const output_basename = try std.mem.concat(allocator, u8, &.{ entry.basename, ".spv" });

                    const file = try output_directory.createFile(output_basename, .{});
                    defer file.close();
                    try file.writeAll(result.stdout);
                }
            }
        } else if (std.mem.eql(u8, argument, "clean")) {
            const output_path = try std.fs.path.join(allocator, &.{ "src", "res", "shaders" });
            try current_working_directory.deleteTree(output_path);
            try std.fs.cwd().deleteFile(
                try std.fs.path.join(allocator, &.{ "src", "c.zig" }),
            );
        }
    }
}
