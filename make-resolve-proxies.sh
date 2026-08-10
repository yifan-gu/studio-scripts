#!/usr/bin/env bash
#
# make-resolve-proxies.sh
#
# Parallel DaVinci Resolve proxy generator for macOS/Linux.
#
# VIDEO:
#   - Mirrors the source folder hierarchy.
#   - 720p HEVC/H.265 Main10, 10-bit 4:2:0.
#   - CRF 26, preset fast.
#   - Embedded audio -> AAC 96 kb/s per audio stream.
#   - Maps ALL source streams.
#   - Sony rtmd/data stream -> stream copy unchanged.
#
# AUDIO-ONLY:
#   - WAV/AIFF/FLAC/M4A/MP3/AAC are copied byte-for-byte.
#
# RESUME:
#   - Up to PARALLEL_JOBS video transcodes run simultaneously.
#   - Existing valid proxies are skipped.
#   - Incomplete/invalid proxies are rebuilt.
#   - Audio copies are skipped when byte size matches.
#
# Usage:
#   ./make-resolve-proxies.sh SOURCE_ROOT PROXY_ROOT
#   PARALLEL_JOBS=6 ./make-resolve-proxies.sh SOURCE_ROOT PROXY_ROOT
#
# Example:
#   ./make-resolve-proxies.sh \
#     "/Volumes/Archive-ZFS-8-Bay-2019-2026" \
#     "/Volumes/Oyen Workspace/Cinema Verite/ProxyMedia"
#
# Requires:
#   ffmpeg
#   ffprobe
#

set -u
set -o pipefail

SKIP_FILE="${SKIP_FILE:-${PWD}/skip-folders.txt}"
SKIP_FOLDERS=()

if [[ -f "$SKIP_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove CR from Windows-style line endings.
    line="${line%$'\r'}"

    # Ignore blank lines and comments.
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    SKIP_FOLDERS+=("$line")
  done < "$SKIP_FILE"
fi

SRC_ROOT="${1%/}"
PROXY_ROOT="${2%/}"

HEIGHT="${HEIGHT:-720}"
AUDIO_BITRATE="${AUDIO_BITRATE:-96k}"
PARALLEL_JOBS="${PARALLEL_JOBS:-6}"

LOG_ROOT="$PROXY_ROOT/_proxy_logs"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="$LOG_ROOT/$STAMP"

LOG_FILE="$LOG_DIR/main.log"
FAILED_FILE="$LOG_DIR/failed.txt"

# Background video-job pool. Compatible with macOS's older Bash (no wait -n needed).
JOB_PIDS=()
JOB_NAMES=()
JOB_SLOTS=()

STATUS_DRAWN=0
STATUS_LINES=$((PARALLEL_JOBS + 2))

mkdir -p "$PROXY_ROOT" "$LOG_DIR"

should_skip() {
  local path="$1"
  local skip

  set +u
  for skip in "${SKIP_FOLDERS[@]}"; do
    if [[ "$path" == *"$skip"* ]]; then
      return 0
    fi
  done
  set -u

  return 1
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

interrupt_all() {
  echo
  log "Interrupted by user; stopping all active jobs"

  local pid
  for pid in "${JOB_PIDS[@]}"; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done

  sleep 0.2

  for pid in "${JOB_PIDS[@]}"; do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done

  exit 130
}

trap interrupt_all INT TERM

clear_status() {
  local i

  [[ "$STATUS_DRAWN" -eq 1 ]] || return 0

  # Cursor is currently one line below the status block.
  for ((i=0; i<STATUS_LINES; i++)); do
    printf '\033[1A\r\033[2K'
  done
}

draw_status() {
  local i

  printf '\033[1mPROGRESS: %s / %s (%s%%) | FAILED: %s\033[0m\n' \
    "$finished" "$TOTAL_FILES" "$percent" "$failed"

  printf '\033[1mWORKING:\033[0m\n'

  for ((i=0; i<PARALLEL_JOBS; i++)); do
    if [[ "$i" -lt "${#JOB_NAMES[@]}" ]]; then
      printf '  %s\n' "${JOB_NAMES[$i]}"
    else
      printf '\n'
    fi
  done

  STATUS_DRAWN=1
}

refresh_status() {
  clear_status
  draw_status
}

get_free_slot() {
  local slot i used

  for ((slot=1; slot<=PARALLEL_JOBS; slot++)); do
    used=0

    for ((i=0; i<${#JOB_SLOTS[@]}; i++)); do
      if [[ "${JOB_SLOTS[$i]}" -eq "$slot" ]]; then
        used=1
        break
      fi
    done

    if [[ "$used" -eq 0 ]]; then
      printf '%s\n' "$slot"
      return 0
    fi
  done

  return 1
}

job_finished() {
  finished=$((finished + 1))

  percent="$(
    awk -v done="$finished" -v total="$TOTAL_FILES" \
      'BEGIN { printf "%.1f", (done / total) * 100 }'
  )"
}

reap_finished_jobs() {
  local new_pids=()
  local new_names=()
  local new_slots=()
  local i pid name slot rc stat
  local reaped=0

  for ((i=0; i<${#JOB_PIDS[@]}; i++)); do
    pid="${JOB_PIDS[$i]}"
    name="${JOB_NAMES[$i]}"
    slot="${JOB_SLOTS[$i]}"

    stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"

    if [[ "$reaped" -eq 0 && ( -z "$stat" || "$stat" == Z* ) ]]; then
      wait "$pid"
      rc=$?

      if [[ "$rc" -ne 0 ]]; then
        failed=$((failed + 1))

        printf '[%s] JOB FAILED: %s\n' \
          "$(date '+%F %T')" "$name" \
          >> "$LOG_DIR/worker-$slot.log"
      fi

      job_finished
      reaped=1
      continue
    fi

    new_pids+=("$pid")
    new_names+=("$name")
    new_slots+=("$slot")
  done

  set +u
  JOB_PIDS=("${new_pids[@]}")
  JOB_NAMES=("${new_names[@]}")
  JOB_SLOTS=("${new_slots[@]}")
  set -u

  if [[ "$reaped" -eq 1 ]]; then
    refresh_status
  fi
}

wait_for_job_slot() {
  while [[ "${#JOB_PIDS[@]}" -ge "$PARALLEL_JOBS" ]]; do
    reap_finished_jobs
    if [[ "${#JOB_PIDS[@]}" -ge "$PARALLEL_JOBS" ]]; then
      sleep 0.2
    fi
  done
}

start_job() {
  local src="$1"
  local type="$2"
  local rel="${src#$SRC_ROOT/}"

  wait_for_job_slot

  local slot
  slot="$(get_free_slot)"

  local job_log="$LOG_DIR/worker-$slot.log"

  # Add a separator for the new job.
  {
    printf '\n============================================================\n'
    printf '[%s] SLOT %s: %s\n' "$(date '+%F %T')" "$slot" "$rel"
    printf '============================================================\n'
  } >> "$job_log"

  if [[ "$type" == "video" ]]; then
    (
      LOG_FILE="$job_log"
      process_video_file "$src"
    ) &
  else
    (
      LOG_FILE="$job_log"
      copy_audio_file "$src"
    ) &
  fi

  local pid=$!

  JOB_PIDS+=("$pid")
  JOB_NAMES+=("$rel")
  JOB_SLOTS+=("$slot")

  printf '[%s] QUEUED %s [%s]: %s\n' \
    "$(date '+%F %T')" "$type" "$pid" "$rel" >> "$job_log"

  refresh_status
}

wait_for_all_jobs() {
  while [[ "${#JOB_PIDS[@]}" -gt 0 ]]; do
    reap_finished_jobs

    if [[ "${#JOB_PIDS[@]}" -gt 0 ]]; then
      sleep 0.2
    fi
  done
}

file_size() {
  # macOS stat first; GNU/Linux fallback.
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null
}

probe_duration() {
  ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | head -n 1
}

probe_frame_count() {
  ffprobe -v error \
    -select_streams v:0 \
    -count_frames \
    -show_entries stream=nb_read_frames \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | head -n 1
}

probe_fps() {
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | head -n 1
}

probe_video_pix_fmt() {
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=pix_fmt \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | head -n 1
}

probe_video_height() {
  ffprobe -v error \
    -select_streams v:0 \
    -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | head -n 1
}

probe_audio_signature() {
  ffprobe -v error \
    -select_streams a \
    -show_entries stream=sample_rate,channels \
    -of csv=p=0:s='|' \
    "$1" 2>/dev/null
}

probe_audio_stream_count() {
  ffprobe -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$1" 2>/dev/null | wc -l | tr -d ' '
}

probe_rtmd_count() {
  ffprobe -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null |
    awk '$0=="rtmd"{n++} END{print n+0}'
}

probe_rtmd_timecode() {
  # Sony FX3/XAVC timecode is stored on the rtmd data stream.
  # Print the first rtmd stream's timecode tag.
  ffprobe -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string:stream_tags=timecode \
    -of compact=p=0:nk=1 \
    "$1" 2>/dev/null |
    awk -F'|' '
      $1=="rtmd" {
        for (i=2; i<=NF; i++) {
          if ($i != "") {
            print $i
            exit
          }
        }
      }
    '
}

probe_proxy_timecode() {
  local tc

  # First try the video stream's timecode tag.
  tc="$(
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream_tags=timecode \
      -of default=noprint_wrappers=1:nokey=1 \
      "$1" 2>/dev/null | head -n 1
  )"

  if [[ -n "$tc" ]]; then
    printf '%s\n' "$tc"
    return 0
  fi

  # Fall back to the QuickTime tmcd data stream.
  ffprobe -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string:stream_tags=timecode \
    -of compact=p=0:nk=1 \
    "$1" 2>/dev/null |
  awk -F'|' '
    $1=="tmcd" {
      for (i=2; i<=NF; i++) {
        if ($i != "") {
          print $i
          exit
        }
      }
    }
  '
}

verify_proxy() {
  local src="$1"
  local dst="$2"

  [[ -s "$dst" ]] || {
    log "VERIFY FAIL: proxy missing or empty: $dst"
    return 1
  }

  local src_dur dst_dur src_fps dst_fps
  local src_frames dst_frames
  src_dur="$(probe_duration "$src")"
  dst_dur="$(probe_duration "$dst")"
  src_fps="$(probe_fps "$src")"
  dst_fps="$(probe_fps "$dst")"

  [[ -n "$src_dur" && -n "$dst_dur" ]] || {
    log "VERIFY FAIL: could not read duration (source=$src_dur proxy=$dst_dur)"
    return 1
  }

  [[ -n "$src_fps" && -n "$dst_fps" ]] || {
    log "VERIFY FAIL: could not read FPS (source=$src_fps proxy=$dst_fps)"
    return 1
  }

  awk -v a="$src_dur" -v b="$dst_dur" \
    'BEGIN { d=a-b; if (d<0) d=-d; exit !(d <= 0.10) }' || {
      log "VERIFY FAIL: duration mismatch (source=$src_dur proxy=$dst_dur)"
      return 1
    }

  [[ "$src_fps" == "$dst_fps" ]] || {
    log "VERIFY FAIL: FPS mismatch (source=$src_fps proxy=$dst_fps)"
    return 1
  }

  local dst_height
  dst_height="$(probe_video_height "$dst")"

  [[ "$dst_height" == "$HEIGHT" ]] || {
    log "VERIFY FAIL: height mismatch (expected=$HEIGHT actual=$dst_height)"
    return 1
  }

  local dst_pix_fmt
  dst_pix_fmt="$(probe_video_pix_fmt "$dst")"

  [[ "$dst_pix_fmt" == "yuvj420p" ]] || {
    log "VERIFY FAIL: pixel format mismatch (expected=yuvj420p actual=$dst_pix_fmt)"
    return 1
  }

  local src_audio_count dst_audio_count
  local src_audio_sig dst_audio_sig

  src_audio_count="$(probe_audio_stream_count "$src")"
  dst_audio_count="$(probe_audio_stream_count "$dst")"

  [[ "$src_audio_count" == "$dst_audio_count" ]] || {
    log "VERIFY FAIL: audio stream count mismatch (source=$src_audio_count proxy=$dst_audio_count)"
    return 1
  }

  src_audio_sig="$(probe_audio_signature "$src")"
  dst_audio_sig="$(probe_audio_signature "$dst")"

  [[ "$src_audio_sig" == "$dst_audio_sig" ]] || {
    log "VERIFY FAIL: audio signature mismatch"
    log "  source: $src_audio_sig"
    log "  proxy:  $dst_audio_sig"
    return 1
  }

  local src_tc dst_tc
  src_tc="$(probe_rtmd_timecode "$src")"
  dst_tc="$(probe_proxy_timecode "$dst")"

  if [[ -n "$src_tc" && "$src_tc" != "$dst_tc" ]]; then
    log "VERIFY FAIL: timecode mismatch (source=$src_tc proxy=$dst_tc)"
    return 1
  fi

  #log "VERIFY OK: $dst"
  return 0
}

copy_audio_file() {
  local src="$1"
  local rel="${src#$SRC_ROOT/}"
  local dst="$PROXY_ROOT/$rel"
  local tmp="${dst}.copy-part"

  mkdir -p "$(dirname "$dst")"

  if [[ -f "$dst" ]]; then
    local src_size dst_size
    src_size="$(file_size "$src")"
    dst_size="$(file_size "$dst")"

    if [[ -n "$src_size" && "$src_size" == "$dst_size" ]]; then
      log "SKIP audio: $rel"
      return 0
    fi

    log "RECOPY audio (size mismatch): $rel"
    rm -f "$dst"
  fi

  rm -f "$tmp"
  log "COPY audio: $rel"

  if cp -p "$src" "$tmp" >>"$LOG_FILE" 2>&1; then
    local src_size tmp_size
    src_size="$(file_size "$src")"
    tmp_size="$(file_size "$tmp")"

    if [[ -n "$src_size" && "$src_size" == "$tmp_size" ]]; then
      mv -f "$tmp" "$dst"
      log "DONE audio: $rel"
      return 0
    fi
  fi

  rm -f "$tmp"
  printf '%s\n' "$src" >> "$FAILED_FILE"
  log "FAIL audio: $rel"
  return 1
}

process_video_file() {
  local src="$1"
  local rel="${src#$SRC_ROOT/}"
  local rel_dir
  rel_dir="$(dirname "$rel")"

  local filename
  filename="$(basename "$src")"

  local stem="${filename%.*}"
  local out_dir="$PROXY_ROOT/$rel_dir"

  # Use mov proxy container while preserving the source filename stem.
  # If source extension is .mov/.mov this produces the same visible filename.
  local dst="$out_dir/$stem.mov"
  local tmp="$out_dir/.$stem.proxy-part.mov"

  mkdir -p "$out_dir"

  if [[ -s "$dst" ]]; then
    if verify_proxy "$src" "$dst"; then
      log "SKIP verified: $rel"
      return 0
    else
      log "REBUILD invalid existing proxy: $rel"
      rm -f "$dst"
    fi
  fi

  rm -f "$tmp"

  local src_tc src_rtmd
  src_tc="$(probe_rtmd_timecode "$src")"
  src_rtmd="$(probe_rtmd_count "$src")"

  log "START video: $rel"
  #log "  rtmd streams: $src_rtmd"
  #if [[ -n "$src_tc" ]]; then
  #  log "  rtmd timecode: $src_tc"
  #fi

  cmd=(
    ffmpeg
    -hide_banner
    -nostdin
    -y
    -hwaccel videotoolbox

    -i "$src"

    -map 0:v:0
    -map '0:a?'

    -vf "scale=-2:${HEIGHT}:in_range=full:out_range=full,format=yuv420p"

    -c:v hevc_videotoolbox
    -profile:v main
    -b:v 2700k
    -tag:v hvc1

    -c:a aac
    -b:a "$AUDIO_BITRATE"

    -timecode "$src_tc"

    -movflags +faststart
    -f mov
    "$tmp"
  )

  if "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    if verify_proxy "$src" "$tmp"; then
      mv -f "$tmp" "$dst"
      log "DONE video: $rel"
      return 0
    else
      log "FAIL verification: $rel"
      {
        echo "  source duration: $(probe_duration "$src")"
        echo "  proxy duration:  $(probe_duration "$tmp")"
        echo "  source fps:      $(probe_fps "$src")"
        echo "  proxy fps:       $(probe_fps "$tmp")"
        echo "  proxy height:    $(probe_video_height "$tmp")"
        echo "  proxy pix_fmt:   $(probe_video_pix_fmt "$tmp")"
        echo "  source rtmd:     $(probe_rtmd_count "$src")"
        echo "  proxy rtmd:      $(probe_rtmd_count "$tmp")"
        echo "  source timecode: $(probe_rtmd_timecode "$src")"
        echo "  proxy timecode:  $(probe_rtmd_timecode "$tmp")"
      } >> "$LOG_FILE"
      rm -f "$tmp"
      printf '%s\n' "$src" >> "$FAILED_FILE"
      return 1
    fi
  else
    # Print the useful tail of ffmpeg's log immediately so failures are visible
    # in the terminal, while retaining the complete log file for diagnosis.
    log "FAIL ffmpeg: $rel"
    rm -f "$tmp"
    printf '%s\n' "$src" >> "$FAILED_FILE"
    return 1
  fi
}

# ========================
# ========  Main  ========
# ========================
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 SOURCE_ROOT PROXY_ROOT"
  exit 2
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PARALLEL_JOBS must be a positive integer."
  exit 2
fi

for cmd in ffmpeg ffprobe; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is not installed."
    echo "On macOS with Homebrew:"
    echo "  brew install ffmpeg"
    exit 1
  fi
done

log "Source: $SRC_ROOT"
log "Proxy:  $PROXY_ROOT"
log "Video: ${HEIGHT}p HEVC Main10 4:2:0"
log "Embedded audio: AAC $AUDIO_BITRATE per stream"
log "Data streams: stream-copy (including Sony rtmd)"
log "Standalone audio: copy unchanged"
log "Processing: lexical path order, up to $PARALLEL_JOBS video jobs at once"

count=0
finished=0
failed=0
percent="0.0"

TOTAL_FILES=0

while IFS= read -r src; do
  if should_skip "$src"; then
    continue
  fi

  TOTAL_FILES=$((TOTAL_FILES + 1))
done < <(
  find "$SRC_ROOT" -type f \( \
    -iname '*.mp4' -o \
    -iname '*.mov' -o \
    -iname '*.mxf' -o \
    -iname '*.m4v' -o \
    -iname '*.wav' -o \
    -iname '*.wave' -o \
    -iname '*.aif' -o \
    -iname '*.aiff' -o \
    -iname '*.flac' -o \
    -iname '*.m4a' -o \
    -iname '*.mp3' -o \
    -iname '*.aac' \
  \)
)

log "Total files: $TOTAL_FILES"

draw_status

# Note: this uses newline-delimited find/sort output for readable lexical ordering.
# It assumes filenames do not contain literal newline characters.
while IFS= read -r src; do
  if should_skip "$src"; then
    continue
  fi

  count=$((count + 1))

  ext="${src##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

  case "$ext" in
    mp4|mov|mxf|m4v)
      start_job "$src" video
      ;;
    wav|wave|aif|aiff|flac|m4a|mp3|aac)
      start_job "$src" audio
      ;;
  esac
done < <(
  find "$SRC_ROOT" -type f \( \
    -iname '*.mp4' -o \
    -iname '*.mov' -o \
    -iname '*.mxf' -o \
    -iname '*.m4v' -o \
    -iname '*.wav' -o \
    -iname '*.wave' -o \
    -iname '*.aif' -o \
    -iname '*.aiff' -o \
    -iname '*.flac' -o \
    -iname '*.m4a' -o \
    -iname '*.mp3' -o \
    -iname '*.aac' \
  \) | LC_ALL=C sort
)

wait_for_all_jobs

log "Finished. Files attempted: $count; failures: $failed"

if [[ "$failed" -gt 0 ]]; then
  log "Failed-file list: $FAILED_FILE"
  exit 1
fi

# Everything completed successfully, remove the logs.
rm -rf "$LOG_ROOT"

exit 0
