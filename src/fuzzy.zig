const std = @import("std");

pub const FuzzyFinder = struct {
    arena: *std.heap.ArenaAllocator,
    matrix: ?[][]i8,

    pub fn init(arena: *std.heap.ArenaAllocator) FuzzyFinder {
        return .{
            .arena = arena,
            .matrix = null,
        };
    }

    fn getMatrix(self: *@This(), rows: usize, cols: usize) ![][]i8 {
        const alloc = self.arena.allocator();

        if (self.matrix) |matrix| {
            const cur_rows = matrix.len;
            const cur_cols = matrix[0].len;

            if (rows > cur_rows or cols > cur_cols) {
                const new_matrix = try alloc.realloc(matrix, rows);
                for (new_matrix, 0..) |*el, i| {
                    el.* = try alloc.alloc(i8, cols);
                    if (i == 0) {
                        @memset(el.*, 0);
                    } else {
                        el.*[0] = 0;
                    }
                }
                self.matrix = new_matrix;
            }
        } else {
            self.matrix = try alloc.alloc([]i8, rows);
            for (self.matrix.?, 0..) |*el, i| {
                el.* = try alloc.alloc(i8, cols);
                if (i == 0) {
                    @memset(el.*, 0);
                } else {
                    el.*[0] = 0;
                }
            }
        }

        return self.matrix.?;
    }

    pub fn alignmentScore(self: *@This(), target: []const u8, query: []const u8) !u8 {
        const alloc = self.arena.allocator();

        var t_iter = (try std.unicode.Utf8View.init(target)).iterator();
        var t_points = try std.ArrayList(u21).initCapacity(alloc, target.len);
        while (t_iter.nextCodepoint()) |codepoint| {
            try t_points.append(alloc, codepoint);
        }

        var q_iter = (try std.unicode.Utf8View.init(query)).iterator();
        var q_points = try std.ArrayList(u21).initCapacity(alloc, query.len);
        while (q_iter.nextCodepoint()) |codepoint| {
            try q_points.append(alloc, codepoint);
        }

        const match: i8 = 2;
        const mismatch: i8 = -1;
        const gap: i8 = -1;

        const rows = t_points.items.len + 1;
        const cols = q_points.items.len + 1;
        var matrix = try self.getMatrix(rows, cols);

        var maxScore: i8 = 0;
        var i: usize = 1;
        while (i < rows) : (i += 1) {
            var j: usize = 1;
            while (j < cols) : (j += 1) {
                var score: i8 = mismatch;
                if (t_points.items[i - 1] == q_points.items[j - 1]) {
                    score = match;
                }

                matrix[i][j] = @max(
                    0,
                    matrix[i - 1][j - 1] +| score, // Diagonal
                    matrix[i][j - 1] + gap, // Up
                    matrix[i - 1][j] + gap, // Left
                );

                if (matrix[i][j] > maxScore) {
                    maxScore = matrix[i][j];
                }
            }
        }

        return @intCast(maxScore);
    }
};

test "score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const target = "ACACACTA";
    const query = "AGCAC";

    var fzf = FuzzyFinder.init(&arena);
    const res = try fzf.alignmentScore(target, query);
    try std.testing.expect(res == 7);
}
