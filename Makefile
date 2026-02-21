fast:
	zig build --release=fast

run:
	zig build run -- ~/work/personal/music / 2> errors.log;  cat errors.log
