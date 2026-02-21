const ma = @cImport({
    @cInclude("miniaudio.h");
});
const std = @import("std");
const Audio = @This();

const Mutex = std.Thread.Mutex;

const rand = std.crypto.random;

const SoundsRC = std.AutoHashMap(*ma.ma_sound, u16);

engine: *ma.ma_engine,
resource_manager: *ma.ma_resource_manager,
allocator: std.mem.Allocator,
sounds: SoundsRC,
current_playing: ?*ma.ma_sound,
mutex: Mutex,

// initDefault result in the engine initializing a playback device using the operating system's default device.
pub fn initDefault(allocator: std.mem.Allocator) !Audio {
    var audio = Audio{
        .engine = undefined,
        .resource_manager = undefined,
        .allocator = allocator,
        .sounds = .init(allocator),
        .mutex = .{},
        .current_playing = null,
    };
    audio.engine = try allocator.create(ma.ma_engine);
    errdefer allocator.destroy(audio.engine);

    audio.resource_manager = try allocator.create(ma.ma_resource_manager);
    errdefer allocator.destroy(audio.resource_manager);

    var rm_config = ma.ma_resource_manager_config_init();
    rm_config.jobQueueCapacity = 256;
    var result = ma.ma_resource_manager_init(&rm_config, audio.resource_manager);
    if (result != ma.MA_SUCCESS) {
        std.debug.print("When initializing resource manager, got error code {d}\n", .{result});
        return error.EngineInitFailed;
    }
    errdefer ma.ma_resource_manager_uninit(audio.resource_manager);

    var engine_config = ma.ma_engine_config_init();
    engine_config.pResourceManager = audio.resource_manager;
    result = ma.ma_engine_init(&engine_config, audio.engine);
    if (result != ma.MA_SUCCESS) {
        std.debug.print("When initializing audio engine, got error code {d}\n", .{result});
        return error.EngineInitFailed;
    }
    errdefer ma.ma_engine_uninit(audio.engine);

    if (ma.ma_engine_start(audio.engine) != ma.MA_SUCCESS) {
        return error.EngineStartFailed;
    }

    return audio;
}

pub fn play(self: *Audio, file: [:0]const u8) !void {
    // TODO: change it with GC thread
    defer {
        if (rand.boolean()) {
            self.gcSounds();
        }
    }

    var result: ma.ma_result = undefined;
    const sound = try self.allocator.create(ma.ma_sound);
    errdefer self.allocator.destroy(sound);

    const flags = ma.MA_SOUND_FLAG_DECODE | ma.MA_SOUND_FLAG_ASYNC;

    result = ma.ma_sound_init_from_file(self.engine, file, flags, null, null, sound);
    switch (result) {
        ma.MA_SUCCESS => {},
        ma.MA_INVALID_FILE => return error.InvalidFile,
        else => {
            std.debug.print("When initializing a sound from {s}, got error code {d}\n", .{ file, result });
            return error.SoundInitFailed;
        },
    }
    errdefer ma.ma_sound_uninit(sound);

    if (self.current_playing) |current_playing| {
        result = ma.ma_sound_stop(current_playing);
        if (result != ma.MA_SUCCESS) {
            std.debug.print("When stopping sound, got error code {d}\n", .{result});

            return error.SoundStopFailed;
        }
    }

    result = ma.ma_sound_start(sound);
    if (result != ma.MA_SUCCESS) {
        std.debug.print("When starting a sound from a file, got error code {d}\n", .{result});

        return error.SoundStartFailed;
    }

    result = ma.ma_sound_set_end_callback(sound, Audio.onSoundEnd, @ptrCast(self));
    if (result != ma.MA_SUCCESS) {
        std.debug.print("When setting sound end callback, got error code {d}\n", .{result});

        return error.SoundEndCallbackFailed;
    }

    try self.trackSound(sound);
    self.current_playing = sound;
}

pub fn isPlaying(self: *const Audio) bool {
    if (self.current_playing) |sound| {
        if (ma.ma_sound_at_end(sound) != 0) {
            return false;
        }

        return true;
    }

    return false;
}

fn trackSound(self: *Audio, sound: *ma.ma_sound) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const res = try self.sounds.getOrPut(sound);
    if (!res.found_existing) {
        res.value_ptr.* = 0;
    }

    res.value_ptr.* += 1;
}

fn untrackSound(self: *Audio, sound: *ma.ma_sound) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    const res = try self.sounds.getOrPut(sound);
    std.debug.assert(res.found_existing);
    res.value_ptr.* -|= 1;
}

fn onSoundEnd(pUserData: ?*anyopaque, pSound: ?*ma.ma_sound) callconv(.c) void {
    const self: *Audio = @ptrCast(@alignCast(pUserData));
    self.untrackSound(pSound.?) catch unreachable;
}

fn gcSounds(self: *Audio) void {
    if (!self.mutex.tryLock()) {
        return; // If we can't lock the mutex, return
    }
    defer self.mutex.unlock();

    var it = self.sounds.iterator();
    while (it.next()) |kv| {
        const sound = kv.key_ptr.*;
        const ref_count = kv.value_ptr.*;
        if (ref_count == 0) {
            ma.ma_sound_uninit(sound);
            self.allocator.destroy(sound);
            _ = self.sounds.remove(sound);
        }
    }
}

pub fn uninit(self: *Audio) void {
    // Clean up sounds
    {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.sounds.iterator();
        while (it.next()) |kv| {
            const sound = kv.key_ptr.*;
            const ref_count = kv.value_ptr.*;
            if (ref_count != 0) {
                const result = ma.ma_sound_stop(sound);
                if (result != 0) {
                    std.debug.print("When stopping sound, got error code {d}\n", .{result});
                }
            }

            ma.ma_sound_uninit(sound);
            self.allocator.destroy(sound);
        }
        self.sounds.clearAndFree();
    }

    ma.ma_engine_uninit(self.engine);
    self.allocator.destroy(self.engine);

    ma.ma_resource_manager_uninit(self.resource_manager);
    self.allocator.destroy(self.resource_manager);
}
