const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const fs = std.fs;
const print = std.debug.print;

const inDebugMode = std.options.log_level == .debug;
const EntriesLimit = 1000;

const Self = @This();
pub const FileCallbackErrors = error{InvalidFile} || anyerror;
pub const FileCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, file: [:0]const u8) FileCallbackErrors!void,

    fn call(self: FileCallback, file: [:0]const u8) FileCallbackErrors!void {
        return self.func(self.ctx, file);
    }
};

alloc: std.mem.Allocator,
text_input: vxfw.TextField,
list_view: vxfw.ListView,
children: [4]vxfw.SubSurface = undefined,

query: []u8,
dir: fs.Dir,
dir_flags: std.fs.Dir.OpenOptions,
dir_root_path: []const u8,
current_dir_path: []const u8,
dir_result: ?DirResult,
file_callback: FileCallback,

/// Helper function to return a vxfw.Widget struct
pub fn widget(self: *Self) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

pub fn init(
    alloc: std.mem.Allocator,
    flags: std.fs.Dir.OpenOptions,
    absoulte_path: ?[]const u8,
    file_callback: FileCallback,
) !*@This() {
    const model = try alloc.create(@This());
    var text_input = vxfw.TextField.init(alloc);
    text_input.userdata = model;
    text_input.onChange = onChange;
    text_input.onSubmit = onSubmit;

    // Set the initial state of list view
    const list_view: vxfw.ListView = .{
        .wheel_scroll = 3,
        .scroll = .{
            .wants_cursor = true,
            .offset = 0,
        },
        .children = .{ .slice = &.{} },
    };

    var dir_flags = flags;
    dir_flags.iterate = true;
    const dir = if (absoulte_path) |abs_path|
        try fs.openDirAbsolute(abs_path, dir_flags)
    else
        try fs.cwd().openDir(".", dir_flags);

    const dir_root_path = try dir.realpathAlloc(alloc, ".");
    errdefer alloc.free(dir_root_path);

    const current_dir_path = try alloc.dupe(u8, dir_root_path);

    model.* = .{
        .alloc = alloc,
        .text_input = text_input,
        .list_view = list_view,
        .query = &.{},
        .dir = dir,
        .dir_flags = dir_flags,
        .dir_root_path = dir_root_path,
        .current_dir_path = current_dir_path,
        .dir_result = null,
        .file_callback = file_callback,
    };

    return model;
}

pub fn deinit(self: *Self) void {
    self.alloc.free(self.query);
    self.text_input.deinit();
    self.dir.close();
    self.alloc.free(self.dir_root_path);
    self.alloc.free(self.current_dir_path);
    self.alloc.destroy(self);
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));

    switch (event) {
        .key_press => |key| {
            if (key.matches('c', .{ .ctrl = true })) {
                ctx.quit = true;
                return;
            }

            if (key.matches(vaxis.Key.up, .{}) or
                key.matches(vaxis.Key.down, .{}))
            {
                return self.list_view.handleEvent(ctx, event);
            }

            if (key.matches(vaxis.Key.backspace, .{ .ctrl = true }) or key.matches(vaxis.Key.delete, .{ .ctrl = true })) {
                const current_path = try self.dir.realpathAlloc(self.alloc, ".");
                defer self.alloc.free(current_path);

                // If reached the root: do not go level up
                if (std.mem.eql(u8, self.dir_root_path, current_path)) {
                    return ctx.consumeEvent();
                }

                const new_dir = try self.dir.openDir("..", self.dir_flags);
                try self.setNewDir(new_dir);

                return ctx.consumeAndRedraw();
            }

            return ctx.requestFocus(self.text_input.widget());
        },
        else => ctx.consumeEvent(),
    }
}

fn setNewDir(self: *Self, new_dir: fs.Dir) !void {
    self.dir.close();
    self.dir = new_dir;
    self.alloc.free(self.current_dir_path);
    self.current_dir_path = try new_dir.realpathAlloc(self.alloc, ".");
    self.list_view.cursor = 0;
}

// TODO: add debouncing to not triger this overy keystroke
fn onChange(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr.?));

    if (str.len == 0) {
        self.query = try self.alloc.realloc(self.query, 0);
        ctx.consumeAndRedraw();
        return;
    }

    if (str.len != self.query.len) {
        self.query = try self.alloc.realloc(self.query, str.len);
    }

    @memcpy(self.query, str);
    ctx.consumeAndRedraw();
}

fn onSubmit(ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
    _ = str;
    const self: *Self = @ptrCast(@alignCast(ptr.?));
    if (self.dir_result) |res| {
        if (self.list_view.cursor >= res.entries.len) {
            return ctx.consumeEvent();
        }

        const entry = res.entries[self.list_view.cursor];

        if (self.dir.openDir(entry.path(), self.dir_flags)) |new_dir| {
            try self.setNewDir(new_dir);
        } else |err| switch (err) {
            error.NotDir => {
                const path = try std.fs.path.joinZ(self.alloc, &.{ self.current_dir_path, entry.path() });
                defer self.alloc.free(path);

                self.file_callback.call(path) catch |cbErr| switch (cbErr) {
                    error.InvalidFile => {},
                    else => return cbErr,
                };
            },
            else => return err,
        }

        return ctx.consumeAndRedraw();
    }
}

const fuzzy = @import("fuzzy.zig");

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(ptr));
    // The root widget - the maximum size will always be the size of the terminal screen.
    const max_size = ctx.max.size();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var fzf = fuzzy.FuzzyFinder.init(&arena);

    self.dir_result = self.walkDir(ctx.arena, self.dir, &fzf) catch |err| {
        print("got when walking dir error: {}", .{err});
        return std.mem.Allocator.Error.OutOfMemory;
    };

    const entries = self.dir_result.?.entries;
    const list_view_children = try ctx.arena.alloc(vxfw.Widget, entries.len);
    for (0..entries.len) |i| {
        list_view_children[i] = entries[i].widget.widget();
    }

    const type_here_text = vxfw.Text{
        .text = "Type here:",
        .style = .{ .dim = true },
    };

    self.children[0] = .{
        .origin = .{ .row = 0, .col = 1 },
        .surface = try type_here_text.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = ctx.max.width, .height = 1 },
        )),
    };
    self.children[1] = .{
        .origin = .{ .row = 1, .col = 1 },
        .surface = try self.text_input.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = ctx.max.width, .height = 1 },
        )),
    };

    const meta = if (inDebugMode and self.dir_result.?.filtered_count != 0)
        try std.fmt.allocPrint(ctx.arena, "{} entries {} filtered {} highest matching score", .{
            entries.len, self.dir_result.?.filtered_count, self.dir_result.?.max_fzf_score,
        })
    else
        try std.fmt.allocPrint(
            ctx.arena,
            "{}{s} entries",
            .{ entries.len, if (entries.len == EntriesLimit) "+" else "" },
        );

    const meta_text = vxfw.Text{
        .text = meta,
        .style = .{ .dim = true },
    };
    self.children[2] = .{
        .origin = .{ .row = 2, .col = 1 },
        .surface = try meta_text.draw(ctx.withConstraints(
            ctx.min,
            .{ .width = ctx.max.width, .height = 1 },
        )),
    };

    self.list_view.children = .{ .slice = list_view_children };
    self.children[3] = .{
        .origin = .{ .row = 3, .col = 1 },
        .surface = try self.list_view.draw(ctx),
    };

    const main_content_surface: vxfw.Surface = .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = &self.children,
    };

    return main_content_surface;
}

const DirEntry = struct {
    widget: vxfw.Text,
    path_offset: u16,
    score: u8,

    pub fn path(self: *const @This()) []const u8 {
        return self.widget.text[self.path_offset..];
    }
};

const DirResult = struct {
    entries: []DirEntry,
    filtered_count: u64,
    max_fzf_score: u8,
};

fn walkDir(self: @This(), alloc: std.mem.Allocator, directory: fs.Dir, fzf: *fuzzy.FuzzyFinder) !DirResult {
    var result = DirResult{
        .entries = &.{},
        .filtered_count = 0,
        .max_fzf_score = 0,
    };

    var list: std.ArrayList(DirEntry) = .empty;

    if (self.query.len == 0) {
        // No search query: only show immediate children (1 level deep)
        var iter = directory.iterate();
        while (try iter.next()) |el| {
            if (list.items.len >= EntriesLimit) break;
            if (el.name[0] == '.') continue;
            const sound_ext = soundExtension(el.name);
            if (el.kind != .directory and sound_ext == .unknown) continue;

            const icon: u21 = switch (el.kind) {
                .directory => '📂',
                .file => switch (sound_ext) {
                    .mp3 => '🎵',
                    .wav => '🌊',
                    else => '📄',
                },
                else => '📄',
            };

            const path = try std.fmt.allocPrint(alloc, "{u} {s}", .{ icon, el.name });
            try list.append(alloc, DirEntry{
                .widget = vxfw.Text{ .text = path },
                .path_offset = @intCast(path.len - el.name.len),
                .score = 0,
            });
        }
    } else {
        // With search query: walk all depths
        var walker = try directory.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |el| {
            if (isHiddenPath(el.path)) continue;
            const sound_ext = soundExtension(el.path);
            if (el.kind != .directory and sound_ext == .unknown) continue;

            const score = try fzf.alignmentScore(el.path, self.query);
            result.max_fzf_score = @max(result.max_fzf_score, score);
            if (score < 2) {
                result.filtered_count += 1;
                continue;
            }

            const icon: u21 = switch (el.kind) {
                .directory => '📂',
                .file => switch (sound_ext) {
                    .mp3 => '🎵',
                    .wav => '🌊',
                    else => '📄',
                },
                else => '📄',
            };

            const path = try std.fmt.allocPrint(alloc, "{u} {s}", .{ icon, el.path });
            try list.append(alloc, DirEntry{
                .widget = vxfw.Text{ .text = path },
                .path_offset = @intCast(path.len - el.path.len),
                .score = score,
            });
        }
    }

    const items = try list.toOwnedSlice(alloc);
    const cmp = struct {
        fn _(_: void, a: DirEntry, b: DirEntry) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.order(u8, a.path(), b.path()) == .lt;
        }
    }._;
    std.mem.sort(DirEntry, items, {}, cmp);

    var idx = items.len;
    if (result.max_fzf_score > 4) {
        const cutoff = result.max_fzf_score / 2;

        for (items, 0..) |entry, i| {
            if (entry.score <= cutoff) {
                idx = i;
                break;
            }
        }
    }
    result.entries = items[0..idx];

    return result;
}

fn isHiddenPath(path: []const u8) bool {
    return path[0] == '.' or std.mem.indexOf(u8, path, "/.") != null;
}

const SoundExtensions = enum {
    mp3,
    wav,
    unknown,
};

fn equalExtension(path: []const u8, ext: []const u8) bool {
    return path.len > ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

fn soundExtension(path: []const u8) SoundExtensions {
    if (equalExtension(path, ".mp3")) return .mp3;
    if (equalExtension(path, ".wav")) return .wav;

    return .unknown;
}
