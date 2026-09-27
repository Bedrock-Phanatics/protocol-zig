const std = @import("std");
const options = @import("fuzz_options");

pub fn main(init: std.process.Init) !void {
    const corpus = try std.Io.Dir.cwd().readFileAlloc(init.io, options.corpus_file, init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(corpus);
    const stats = try @import("campaign.zig").run(corpus, options.iterations);
    std.debug.print("fuzz: {d} inputs, {d} decoded and round-tripped, 0 failures\n", .{ stats.inputs, stats.decoded });
}
