#!/usr/bin/env bash
# Toggle a region screen recording.
#   first press : pick a region, start recording
#   press again : stop, finalize the file, copy its path to the clipboard
#
# Encoding runs on the CPU (--no-hw) on purpose. This machine's AMD VCN block
# page-faults during VA-API encode ("Faulty UTCL2 client ID: VCNRD" ->
# "ring vcn_unified_0 timeout" -> ring reset), which aborts wl-screenrec
# mid-recording and leaves an unplayable 48-byte file. Software encoding is
# unaffected and costs ~5 cores at 720p.

statefile="${XDG_RUNTIME_DIR:-/tmp}/screenrecord-toggle.state"
lockfile="${XDG_RUNTIME_DIR:-/tmp}/screenrecord-toggle.lock"
logfile="${XDG_RUNTIME_DIR:-/tmp}/screenrecord-toggle.log"

# Serialise presses. Without this, a fast double-tap runs two copies of the
# script, both take the start branch, and you get two slurp overlays.
exec 9>"$lockfile"
flock -n 9 || exit 0

if [ -f "$statefile" ]; then
    pid=""
    file=""
    read -r pid file < "$statefile" || true

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Stop. SIGINT is the graceful stop; wl-screenrec then needs up to a
        # couple of seconds to flush the encoder and write the moov atom, so
        # wait for the process to actually exit instead of guessing.
        kill -INT "$pid"
        for _ in {1..150}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done

        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            rm -f "$statefile"
            notify-send -u critical "Recording stuck" "Force-killed; $file is likely corrupt"
            exit 1
        fi

        rm -f "$statefile"
        # A crashed encoder still leaves a 48-byte ftyp/mdat stub, so check for
        # real content rather than mere existence.
        if [ "$(stat -c %s "$file" 2>/dev/null || echo 0)" -gt 1024 ]; then
            printf '%s' "$file" | wl-copy 9>&-
            notify-send "Recording saved" "$file"
            exit 0
        fi

        rm -f "$file"
        notify-send -u critical "Recording failed" "The encoder wrote no data"
        exit 1
    fi

    # The tracked recorder is gone, so it died on its own. Report it and reset.
    # Deliberately do NOT start a new recording here: silently falling through
    # to the start branch is what made a stop-press look like it did nothing.
    rm -f "$statefile"
    # Bin the stub a crashed encoder leaves behind, but keep anything with real
    # content: it has no moov atom so it won't play, yet it may be recoverable.
    if [ -n "$file" ] && [ "$(stat -c %s "$file" 2>/dev/null || echo 0)" -le 1024 ]; then
        rm -f "$file"
    fi
    notify-send -u critical "Recording crashed" "Nothing was saved. Press again to start a new one."
    exit 1
fi

# Not recording: select a region and start.
region="$(slurp)" || exit 0   # cancelled with Escape

# The x264 encoder (used by --no-hw) requires width and height to be even
# numbers for 4:2:0 chroma subsampling. Round them DOWN to avoid pushing the
# region off the edge of the monitor.
if [[ "$region" =~ ^([0-9]+),([0-9]+)\ ([0-9]+)x([0-9]+)$ ]]; then
    rx="${BASH_REMATCH[1]}"
    ry="${BASH_REMATCH[2]}"
    rw="${BASH_REMATCH[3]}"
    rh="${BASH_REMATCH[4]}"
    rw=$((rw - (rw % 2)))
    rh=$((rh - (rh % 2)))
    [ "$rw" -eq 0 ] && rw=2
    [ "$rh" -eq 0 ] && rh=2
    region="${rx},${ry} ${rw}x${rh}"
fi
dir="${XDG_VIDEOS_DIR:-$HOME/Videos}/Recordings"
mkdir -p "$dir"
file="$dir/recording-$(date +%Y%m%d-%H%M%S).mp4"

# 9>&- keeps the recorder from inheriting (and holding) the lock once we exit.
wl-screenrec --no-hw -g "$region" -f "$file" --ffmpeg-encoder-options crf=23 >"$logfile" 2>&1 9>&- &
pid=$!
printf '%s %s' "$pid" "$file" > "$statefile"

# Confirm it survived startup so a failure surfaces now, not on the next press.
sleep 1
if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$statefile" "$file"
    notify-send -u critical "Recording failed to start" "$(tail -n 2 "$logfile")"
    exit 1
fi

notify-send "Recording started" "$file"
