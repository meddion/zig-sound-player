const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fs = std.fs;
const print = std.debug.print;

const Debug = true;
const EntriesLimit = 1000;

const FileExplorer = @import("FileExplorer.zig");

const FocusWidget = enum {
    file_explorer,
    music_player,
};

/// Our main application state
const Model = struct {
    alloc: std.mem.Allocator,
    file_explorer: *FileExplorer,
    music_panel: ?vxfw.Text,
    children: [2]vxfw.SubSurface = undefined,

    focus: FocusWidget,
    audio: *Audio,
    current_playing: []const u8,

    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    pub fn init(
        alloc: std.mem.Allocator,
        dir_opts: fs.Dir.OpenOptions,
        abs_path: ?[]const u8,
    ) !*@This() {
        const model = try alloc.create(@This());

        var audio = try alloc.create(Audio);
        audio.* = try Audio.initDefault(alloc);
        errdefer audio.uninit();

        const cb: FileExplorer.FileCallback = .{
            .ctx = model,
            .func = playCallback,
        };
        const file_explorer = try FileExplorer.init(alloc, dir_opts, abs_path, cb);
        errdefer file_explorer.deinit();

        model.* = .{
            .alloc = alloc,
            .file_explorer = file_explorer,
            .music_panel = null,
            .audio = audio,
            .focus = .file_explorer,
            .current_playing = "",
        };

        return model;
    }

    fn playCallback(ctx: *anyopaque, file: [:0]const u8) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ctx));

        if (self.current_playing.len != 0) self.alloc.free(self.current_playing);
        const file_name = fs.path.basename(file);
        self.current_playing = try self.alloc.dupe(u8, file_name);

        return self.audio.play(file);
    }

    pub fn deinit(self: *Model) void {
        self.file_explorer.deinit();
        self.audio.uninit();
        self.alloc.destroy(self.audio);
        if (self.current_playing.len != 0) self.alloc.free(self.current_playing);
        self.alloc.destroy(self);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));

        switch (event) {
            .init => {
                try ctx.requestFocus(self.file_explorer.widget());
                return;
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }

                if (key.matches('j', .{ .ctrl = true }) or key.matches('k', .{ .ctrl = true })) {
                    self.focus = switch (self.focus) {
                        .file_explorer => if (self.music_panel != null) .music_player else .file_explorer,
                        .music_player => .file_explorer,
                    };
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        var num_children: u8 = 1;
        if (self.audio.isPlaying()) {
            const col_pos: i17 = if (ctx.max.width) |w| @intCast(w / 2 - self.current_playing.len / 2) else 0;
            self.music_panel = vxfw.Text{
                .text = self.current_playing,
                .style = .{
                    .bold = true,
                    .blink = true,
                    .ul_style = .single,
                },
            };
            self.children[1] = vxfw.SubSurface{
                .origin = .{ .row = 0, .col = col_pos },
                .surface = try self.music_panel.?.widget().draw(ctx),
                .z_index = 1,
            };

            num_children += 1;
        }

        self.children[0] = vxfw.SubSurface{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try self.file_explorer.widget().draw(ctx.withConstraints(ctx.min, ctx.max)),
            .z_index = 0,
        };

        return vxfw.Surface{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .children = self.children[0..num_children],
            .buffer = &.{},
        };
    }
};

fn validateDirectory(dir_path: []const u8) bool {
    var dir = fs.cwd().openDir(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("Directory '{s}' not found.", .{dir_path});
            return false;
        },
        error.NotDir => {
            std.log.err("Path '{s}' is a file, not a directory.", .{dir_path});
            return false;
        },
        else => {
            std.log.err("Can't open the '{s}' directory path.", .{dir_path});
            fs.accessAbsolute(dir_path, .{}) catch return false;
            return true;
        },
    };
    dir.close();

    return true;
}

const Audio = @import("Audio.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    //TODO: set these from CLI flags
    const dir_opts = std.fs.Dir.OpenOptions{};

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var abs_path: ?[]const u8 = null; // Default is cwd
    if (args.len > 1) {
        if (!validateDirectory(args[1])) {
            return error.InvalidDirectoryArgument;
        }

        abs_path = args[1];
    }

    var root = try Model.init(allocator, dir_opts, abs_path);
    defer root.deinit();

    try app.run(root.widget(), .{});
}
