#!/usr/bin/env bash
#
# make-resolve-proxies.sh
#
# Parallel DaVinci Resolve proxy generator for macOS/Linux.
#
# VIDEO:
#   - Mirrors the source folder hierarchy.
#   - 720p HEVC/H.265 Main, 8-bit 4:2:0.
#   - VideoToolbox hardware encoding.
#   - 2700 kb/s constant bitrate.
#   - Embedded audio -> AAC 128 kb/s per audio stream.
#   - Maps video + all audio streams.
#   - Sony rtmd timecode -> QuickTime timecode/tmcd.
#
# AUDIO-ONLY:
#   - WAV/AIFF/FLAC/M4A/MP3/AAC are copied byte-for-byte.
#
# RESUME:
#   - Up to PARALLEL_JOBS jobs run simultaneously.
#   - Existing valid proxies are skipped.
#   - Incomplete/invalid proxies are rebuilt.
#   - Audio copies are skipped when byte size matches.
#
# STATUS:
#   - Overall progress by file count.
#   - Overall progress by source bytes.
#   - Active job source size.
#   - Active video-job progress estimated from:
#
#         proxy-part size / (source size / PROXY_SIZE_RATIO)
#
#     capped at 100%.
#
#   - Audio-copy progress uses:
#
#         copy-part size / source size
#
# Usage:
#   ./make-resolve-proxies.sh SOURCE_ROOT PROXY_ROOT
#
#   PARALLEL_JOBS=6 \
#   ./make-resolve-proxies.sh SOURCE_ROOT PROXY_ROOT
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


# ========================
# ===== Configuration ====
# ========================

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 SOURCE_ROOT PROXY_ROOT"
  exit 2
fi

SRC_ROOT="${1%/}"
PROXY_ROOT="${2%/}"

HEIGHT="${HEIGHT:-720}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
PARALLEL_JOBS="${PARALLEL_JOBS:-6}"

# Estimated source/proxy size ratio used ONLY for progress display.
# 100 Mbps / (2700 kbps + 128kbps) is roughly 33.
# 18 for ax53 footages as it's about 50 Mbps
PROXY_SIZE_RATIO="${PROXY_SIZE_RATIO:-33}"

# How often the live job progress is refreshed.
STATUS_REFRESH_SECONDS="${STATUS_REFRESH_SECONDS:-1}"

# Default skip list: skip-folders.txt in the current working directory.
SKIP_FILE="${SKIP_FILE:-$HOME/skip-paths.txt}"

if [[ ! -f "$SKIP_FILE" ]]; then
  echo "ERROR: skip path file does not exist: $SKIP_FILE"
  exit 2
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PARALLEL_JOBS must be a positive integer."
  exit 2
fi

if ! [[ "$PROXY_SIZE_RATIO" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PROXY_SIZE_RATIO must be a positive integer."
  exit 2
fi


# ========================
# ===== Skip folders =====
# ========================

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


should_skip() {
  local path="$1"
  local skip

  # Bash 3.2 + set -u can fail when expanding an empty array.
  set +u

  for skip in "${SKIP_FOLDERS[@]}"; do
    if [[ "$path" == *"$skip"* ]]; then
      set -u
      return 0
    fi
  done

  set -u
  return 1
}


# ========================
# ========= Logs =========
# ========================

LOG_ROOT="$PROXY_ROOT/_proxy_logs"
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_DIR="$LOG_ROOT/$STAMP"

LOG_FILE="$LOG_DIR/main.log"
FAILED_FILE="$LOG_DIR/failed.txt"

mkdir -p "$PROXY_ROOT" "$LOG_DIR"

# Create exactly one log file per worker slot.
for ((i=1; i<=PARALLEL_JOBS; i++)); do
  : > "$LOG_DIR/worker-$i.log"
done


log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}


# ========================
# ===== File helpers =====
# ========================

file_size() {
  # macOS stat first; GNU/Linux fallback.
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null
}


human_size() {
  awk -v bytes="$1" '
    BEGIN {
      split("B KiB MiB GiB TiB PiB", unit, " ")
      size = bytes + 0
      i = 1

      while (size >= 1024 && i < 6) {
        size /= 1024
        i++
      }

      if (i == 1)
        printf "%.0f %s", size, unit[i]
      else
        printf "%.2f %s", size, unit[i]
    }
  '
}


human_duration() {
  local seconds="${1:-0}"

  if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s' '--'
    return
  fi

  local days=$((seconds / 86400))
  local hours=$(((seconds % 86400) / 3600))
  local minutes=$(((seconds % 3600) / 60))

  if [[ "$days" -gt 0 ]]; then
    printf '%dd %dh %dm' "$days" "$hours" "$minutes"
  elif [[ "$hours" -gt 0 ]]; then
    printf '%dh %dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}


# ========================
# ==== Background jobs ===
# ========================

JOB_PIDS=()
JOB_NAMES=()
JOB_SLOTS=()
JOB_SIZES=()
JOB_TMP_PATHS=()
JOB_TYPES=()

STATUS_DRAWN=0
JOB_PROGRESS_COLUMN=1

# 1 progress line
# 1 PROCESSING line
# PARALLEL_JOBS active/blank lines
STATUS_LINES=$((PARALLEL_JOBS + 3))


interrupt_all() {
  clear_status

  printf '\nInterrupted by user; stopping all active jobs...\n'
  log "Interrupted by user; stopping all active jobs"

  local pid

  set +u

  for pid in "${JOB_PIDS[@]}"; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done

  sleep 0.2

  for pid in "${JOB_PIDS[@]}"; do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done

  set -u

  exit 130
}


trap interrupt_all INT TERM

# Always restore cursor when the script exits.
trap 'printf "\033[?25h"' EXIT

# Clear terminal screen and iTerm2 scrollback.
if [[ -t 1 ]]; then
  printf '\033[2J\033[H'
  printf '\033]1337;ClearScrollback\a'
fi

# Hide terminal cursor for the duration of the script.
printf '\033[?25l'

printf '\033[1mDaVinci Resolve Proxy Generator\033[0m\n\n'
printf 'Source: %s\n' "$SRC_ROOT"
printf 'Proxy:  %s\n' "$PROXY_ROOT"
printf 'Jobs:   %s parallel\n' "$PARALLEL_JOBS"
printf '\nScanning source files and calculating total size...\n'


clear_status() {
  local i

  [[ "$STATUS_DRAWN" -eq 1 ]] || return 0

  for ((i=0; i<STATUS_LINES; i++)); do
    printf '\033[1A\r\033[2K'
  done
}


job_progress() {
  local type="$1"
  local src_size="$2"
  local tmp="$3"

  local tmp_size=0

  if ! [[ "$src_size" =~ ^[0-9]+$ ]] || [[ "$src_size" -le 0 ]]; then
    printf '%s' '--'
    return 0
  fi

  if [[ -f "$tmp" ]]; then
    tmp_size="$(file_size "$tmp")"

    if ! [[ "$tmp_size" =~ ^[0-9]+$ ]]; then
      tmp_size=0
    fi
  fi

  if [[ "$type" == "video" ]]; then
    awk \
      -v current="$tmp_size" \
      -v source="$src_size" \
      -v ratio="$PROXY_SIZE_RATIO" '
      BEGIN {
        p = (current * ratio / source) * 100

        if (p > 100)
          p = 100

        if (p < 0)
          p = 0

        printf "%.1f%%", p
      }
    '
  else
    awk \
      -v current="$tmp_size" \
      -v source="$src_size" '
      BEGIN {
        p = (current / source) * 100

        if (p > 100)
          p = 100

        if (p < 0)
          p = 0

        printf "%.1f%%", p
      }
    '
  fi
}


calculate_eta() {
  if [[ "$PROCESS_START_EPOCH" -eq 0 || "$processed_bytes" -le 0 ]]; then
    printf '%s' '--'
    return
  fi

  local now
  local elapsed
  local remaining
  local eta_seconds

  now="$(date +%s)"
  elapsed=$((now - PROCESS_START_EPOCH))

  # finished_bytes still includes verified/skipped files,
  # so they are removed from the remaining workload.
  remaining=$((TOTAL_BYTES - finished_bytes))

  if [[ "$remaining" -le 0 ]]; then
    printf '%s' '0m'
    return
  fi

  if [[ "$elapsed" -le 0 ]]; then
    printf '%s' '--'
    return
  fi

  eta_seconds="$(
    awk \
      -v processed="$processed_bytes" \
      -v elapsed="$elapsed" \
      -v remaining="$remaining" '
      BEGIN {
        speed = processed / elapsed

        if (speed <= 0) {
          print 0
          exit
        }

        printf "%.0f", remaining / speed
      }
    '
  )"

  human_duration "$eta_seconds"
}


draw_status() {
  local i
  local name_width=0
  local size_width=0
  local name
  local size_text
  local progress_text

  local terminal_width=120
  local max_name_width

  terminal_width="$(
    stty size < /dev/tty 2>/dev/null |
      awk '{print $2}'
  )"

  if [[ -z "$terminal_width" || ! "$terminal_width" =~ ^[0-9]+$ ]]; then
    terminal_width="$(tput cols 2>/dev/null || printf '120')"
  fi

  # Reserve space for:
  #   indentation
  #   source size
  #   job percentage
  max_name_width=$((terminal_width - 27))

  if [[ "$max_name_width" -lt 20 ]]; then
    max_name_width=20
  fi

  set +u

  # Calculate alignment widths.
  for ((i=0; i<${#JOB_NAMES[@]}; i++)); do
    name="${JOB_NAMES[$i]}"
    size_text="$(human_size "${JOB_SIZES[$i]}")"

    if [[ "${#name}" -gt "$name_width" ]]; then
      name_width="${#name}"
    fi

    if [[ "${#size_text}" -gt "$size_width" ]]; then
      size_width="${#size_text}"
    fi
  done

  set -u

  if [[ "$name_width" -gt "$max_name_width" ]]; then
    name_width="$max_name_width"
  fi

  # Give the column some width even if no active jobs exist yet.
  if [[ "$name_width" -lt 1 ]]; then
    name_width=1
  fi

  if [[ "$size_width" -lt 1 ]]; then
    size_width=1
  fi

  JOB_PROGRESS_COLUMN=$((name_width + size_width + 7))

  printf '\033[1mPROGRESS: %s / %s (%s%%) | SIZE: %s / %s (%s%%) | FAILED: %s | ETA: %s\033[0m\n' \
    "$finished" \
    "$TOTAL_FILES" \
    "$percent" \
    "$(human_size "$finished_bytes")" \
    "$(human_size "$TOTAL_BYTES")" \
    "$byte_percent" \
    "$failed" \
    "$(calculate_eta)"

  printf '\n'
  printf '\033[1mPROCESSING:\033[0m\n'

  set +u

  for ((i=0; i<PARALLEL_JOBS; i++)); do
    if [[ "$i" -lt "${#JOB_NAMES[@]}" ]]; then
      name="${JOB_NAMES[$i]}"
      size_text="$(human_size "${JOB_SIZES[$i]}")"

      progress_text="$(
        job_progress \
          "${JOB_TYPES[$i]}" \
          "${JOB_SIZES[$i]}" \
          "${JOB_TMP_PATHS[$i]}"
      )"

      # Keep the rightmost part of long paths.
      if [[ "${#name}" -gt "$name_width" ]]; then
        name="…${name: -$((name_width - 1))}"
      fi

      printf '  %-*s  %*s  %6s\n' \
        "$name_width" \
        "$name" \
        "$size_width" \
        "$size_text" \
        "$progress_text"
    else
      printf '\n'
    fi
  done

  set -u

  STATUS_DRAWN=1
}


update_job_progress_only() {
  local i
  local progress_text

  [[ "$STATUS_DRAWN" -eq 1 ]] || return 0

  # Cursor is one line below the complete status block.
  # Move up to the first job row.
  printf '\033[%dA' "$PARALLEL_JOBS"

  set +u

  for ((i=0; i<PARALLEL_JOBS; i++)); do
    if [[ "$i" -lt "${#JOB_NAMES[@]}" ]]; then
      progress_text="$(
        job_progress \
          "${JOB_TYPES[$i]}" \
          "${JOB_SIZES[$i]}" \
          "${JOB_TMP_PATHS[$i]}"
      )"

      # Move directly to the existing percentage field
      # and overwrite exactly 6 characters.
      printf '\033[%dG%6s' \
        "$JOB_PROGRESS_COLUMN" \
        "$progress_text"
    fi

    # Move down one row, back to column 1.
    printf '\n'
  done

  set -u
}


refresh_status() {
  clear_status
  draw_status
}


get_free_slot() {
  local slot
  local i
  local used

  set +u

  for ((slot=1; slot<=PARALLEL_JOBS; slot++)); do
    used=0

    for ((i=0; i<${#JOB_SLOTS[@]}; i++)); do
      if [[ "${JOB_SLOTS[$i]}" -eq "$slot" ]]; then
        used=1
        break
      fi
    done

    if [[ "$used" -eq 0 ]]; then
      set -u
      printf '%s\n' "$slot"
      return 0
    fi
  done

  set -u
  return 1
}


job_finished() {
  local bytes="${1:-0}"
  local actually_processed="${2:-1}"

  finished=$((finished + 1))
  finished_bytes=$((finished_bytes + bytes))

  if [[ "$actually_processed" -eq 1 ]]; then
    processed_bytes=$((processed_bytes + bytes))
  fi

  percent="$(
    awk \
      -v done="$finished" \
      -v total="$TOTAL_FILES" '
      BEGIN {
        if (total > 0)
          printf "%.1f", (done / total) * 100
        else
          printf "100.0"
      }
    '
  )"

  byte_percent="$(
    awk \
      -v done="$finished_bytes" \
      -v total="$TOTAL_BYTES" '
      BEGIN {
        if (total > 0)
          printf "%.1f", (done / total) * 100
        else
          printf "100.0"
      }
    '
  )"
}


reap_finished_jobs() {
  local new_pids=()
  local new_names=()
  local new_slots=()
  local new_sizes=()
  local new_tmp_paths=()
  local new_types=()

  local i
  local pid
  local name
  local slot
  local size
  local tmp_path
  local type
  local rc
  local stat

  local reaped=0

  set +u

  for ((i=0; i<${#JOB_PIDS[@]}; i++)); do
    pid="${JOB_PIDS[$i]}"
    name="${JOB_NAMES[$i]}"
    slot="${JOB_SLOTS[$i]}"
    size="${JOB_SIZES[$i]}"
    tmp_path="${JOB_TMP_PATHS[$i]}"
    type="${JOB_TYPES[$i]}"

    stat="$(
      ps -o stat= -p "$pid" 2>/dev/null |
        tr -d ' '
    )"

    # Only reap ONE completed job per invocation.
    # This keeps the visible overall progress incrementing one at a time.
    if [[ "$reaped" -eq 0 && ( -z "$stat" || "$stat" == Z* ) ]]; then
      wait "$pid"
      rc=$?

      if [[ "$rc" -eq 10 ]]; then
        # Existing proxy/audio was verified and skipped.
        # Count it toward overall progress, but NOT processing speed.
        job_finished "$size" 0

      elif [[ "$rc" -eq 0 ]]; then
        # File was actually processed during this run.
        job_finished "$size" 1

      else
        failed=$((failed + 1))

        printf '[%s] JOB FAILED: %s\n' \
          "$(date '+%F %T')" \
          "$name" \
          >> "$LOG_DIR/worker-$slot.log"

        printf '[%s] JOB FAILED: %s\n' \
          "$(date '+%F %T')" \
          "$name" \
          >> "$LOG_FILE"

        # Preserve your existing behavior: failed files still advance
        # overall progress, but don't count toward processing speed.
        job_finished "$size" 0
      fi

      reaped=1
      continue
    fi

    new_pids+=("$pid")
    new_names+=("$name")
    new_slots+=("$slot")
    new_sizes+=("$size")
    new_tmp_paths+=("$tmp_path")
    new_types+=("$type")
  done

  JOB_PIDS=("${new_pids[@]}")
  JOB_NAMES=("${new_names[@]}")
  JOB_SLOTS=("${new_slots[@]}")
  JOB_SIZES=("${new_sizes[@]}")
  JOB_TMP_PATHS=("${new_tmp_paths[@]}")
  JOB_TYPES=("${new_types[@]}")

  set -u

  if [[ "$reaped" -eq 1 ]]; then
    refresh_status
  fi
}


wait_for_job_slot() {
  while [[ "${#JOB_PIDS[@]}" -ge "$PARALLEL_JOBS" ]]; do
    reap_finished_jobs

    if [[ "${#JOB_PIDS[@]}" -ge "$PARALLEL_JOBS" ]]; then
      update_job_progress_only
      sleep "$STATUS_REFRESH_SECONDS"
    fi
  done
}


start_job() {
  local src="$1"
  local type="$2"

  local rel="${src#$SRC_ROOT/}"

  wait_for_job_slot

  if [[ "$PROCESS_START_EPOCH" -eq 0 ]]; then
    PROCESS_START_EPOCH="$(date +%s)"
  fi

  local slot
  slot="$(get_free_slot)"

  local job_log="$LOG_DIR/worker-$slot.log"

  local src_size
  src_size="$(file_size "$src")"

  if ! [[ "$src_size" =~ ^[0-9]+$ ]]; then
    src_size=0
  fi

  local tmp_path

  if [[ "$type" == "video" ]]; then
    local rel_dir
    local filename
    local stem

    rel_dir="$(dirname "$rel")"
    filename="$(basename "$src")"
    stem="${filename%.*}"

    tmp_path="$PROXY_ROOT/$rel_dir/.$stem.proxy-part.mov"
  else
    tmp_path="$PROXY_ROOT/$rel.copy-part"
  fi

  {
    printf '\n============================================================\n'
    printf '[%s] SLOT %s: %s\n' \
      "$(date '+%F %T')" \
      "$slot" \
      "$rel"
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
  JOB_SIZES+=("$src_size")
  JOB_TMP_PATHS+=("$tmp_path")
  JOB_TYPES+=("$type")

  printf '[%s] QUEUED %s [%s]: %s\n' \
    "$(date '+%F %T')" \
    "$type" \
    "$pid" \
    "$rel" \
    >> "$job_log"

  refresh_status
}


wait_for_all_jobs() {
  while [[ "${#JOB_PIDS[@]}" -gt 0 ]]; do
    reap_finished_jobs

    if [[ "${#JOB_PIDS[@]}" -gt 0 ]]; then
      update_job_progress_only
      sleep "$STATUS_REFRESH_SECONDS"
    fi
  done
}


# ========================
# ===== ffprobe helpers ==
# ========================

probe_duration() {
  ffprobe \
    -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" \
    2>/dev/null |
    head -n 1
}


probe_fps() {
  ffprobe \
    -v error \
    -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" \
    2>/dev/null |
    head -n 1
}


probe_video_pix_fmt() {
  ffprobe \
    -v error \
    -select_streams v:0 \
    -show_entries stream=pix_fmt \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" \
    2>/dev/null |
    head -n 1
}


probe_video_height() {
  ffprobe \
    -v error \
    -select_streams v:0 \
    -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" \
    2>/dev/null |
    head -n 1
}


probe_audio_signature() {
  ffprobe \
    -v error \
    -select_streams a \
    -show_entries stream=sample_rate,channels \
    -of csv=p=0:s='|' \
    "$1" \
    2>/dev/null
}


probe_audio_stream_count() {
  ffprobe \
    -v error \
    -select_streams a \
    -show_entries stream=index \
    -of csv=p=0 \
    "$1" \
    2>/dev/null |
    wc -l |
    tr -d ' '
}


probe_rtmd_count() {
  ffprobe \
    -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" \
    2>/dev/null |
    awk '
      $0=="rtmd" {
        n++
      }

      END {
        print n+0
      }
    '
}


probe_rtmd_timecode() {
  # Sony FX3/XAVC timecode is stored in the rtmd data stream.

  ffprobe \
    -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string:stream_tags=timecode \
    -of compact=p=0:nk=1 \
    "$1" \
    2>/dev/null |
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

  tc="$(
    ffprobe \
      -v error \
      -select_streams v:0 \
      -show_entries stream_tags=timecode \
      -of default=noprint_wrappers=1:nokey=1 \
      "$1" \
      2>/dev/null |
      head -n 1
  )"

  if [[ -n "$tc" ]]; then
    printf '%s\n' "$tc"
    return 0
  fi

  ffprobe \
    -v error \
    -select_streams d \
    -show_entries stream=codec_tag_string:stream_tags=timecode \
    -of compact=p=0:nk=1 \
    "$1" \
    2>/dev/null |
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


# ========================
# ===== Verification =====
# ========================

verify_proxy() {
  local src="$1"
  local dst="$2"

  [[ -s "$dst" ]] || {
    log "VERIFY FAIL: proxy missing or empty: $dst"
    return 1
  }

  local src_dur
  local dst_dur
  local src_fps
  local dst_fps

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

  awk \
    -v a="$src_dur" \
    -v b="$dst_dur" '
    BEGIN {
      d = a - b

      if (d < 0)
        d = -d

      exit !(d <= 0.10)
    }
  ' || {
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

  local src_audio_count
  local dst_audio_count

  src_audio_count="$(probe_audio_stream_count "$src")"
  dst_audio_count="$(probe_audio_stream_count "$dst")"

  [[ "$src_audio_count" == "$dst_audio_count" ]] || {
    log "VERIFY FAIL: audio stream count mismatch (source=$src_audio_count proxy=$dst_audio_count)"
    return 1
  }

  local src_audio_sig
  local dst_audio_sig

  src_audio_sig="$(probe_audio_signature "$src")"
  dst_audio_sig="$(probe_audio_signature "$dst")"

  [[ "$src_audio_sig" == "$dst_audio_sig" ]] || {
    log "VERIFY FAIL: audio signature mismatch"
    log "  source: $src_audio_sig"
    log "  proxy:  $dst_audio_sig"
    return 1
  }

  local src_tc
  local dst_tc

  src_tc="$(probe_rtmd_timecode "$src")"
  dst_tc="$(probe_proxy_timecode "$dst")"

  if [[ -n "$src_tc" && "$src_tc" != "$dst_tc" ]]; then
    log "VERIFY FAIL: timecode mismatch (source=$src_tc proxy=$dst_tc)"
    return 1
  fi

  return 0
}


# ========================
# ===== Audio copying ====
# ========================

copy_audio_file() {
  local src="$1"
  local rel="${src#$SRC_ROOT/}"

  local dst="$PROXY_ROOT/$rel"
  local tmp="${dst}.copy-part"

  mkdir -p "$(dirname "$dst")"

  if [[ -f "$dst" ]]; then
    local src_size
    local dst_size

    src_size="$(file_size "$src")"
    dst_size="$(file_size "$dst")"

    if [[ -n "$src_size" && "$src_size" == "$dst_size" ]]; then
      log "SKIP audio: $rel"
      return 10
    fi

    log "RECOPY audio (size mismatch): $rel"
    rm -f "$dst"
  fi

  rm -f "$tmp"

  log "COPY audio: $rel"

  if cp -p "$src" "$tmp" >> "$LOG_FILE" 2>&1; then
    local src_size
    local tmp_size

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


# ========================
# ===== Video encoding ===
# ========================

process_video_file() {
  local src="$1"
  local rel="${src#$SRC_ROOT/}"

  local rel_dir
  rel_dir="$(dirname "$rel")"

  local filename
  filename="$(basename "$src")"

  local stem="${filename%.*}"

  local out_dir="$PROXY_ROOT/$rel_dir"

  local dst="$out_dir/$stem.mov"
  local tmp="$out_dir/.$stem.proxy-part.mov"

  mkdir -p "$out_dir"

  if [[ -s "$dst" ]]; then
    if verify_proxy "$src" "$dst"; then
      log "SKIP verified: $rel"
      return 10
    else
      log "REBUILD invalid existing proxy: $rel"
      rm -f "$dst"
    fi
  fi

  rm -f "$tmp"

  local src_tc
  src_tc="$(probe_rtmd_timecode "$src")"

  log "START video: $rel"

  local cmd=(
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
    -constant_bit_rate true
    -tag:v hvc1

    -c:a aac
    -b:a "$AUDIO_BITRATE"
  )

  # Only add timecode when the Sony source actually has one.
  if [[ -n "$src_tc" ]]; then
    cmd+=(
      -timecode "$src_tc"
    )
  fi

  cmd+=(
    -movflags +faststart
    -f mov
    "$tmp"
  )

  if "${cmd[@]}" >> "$LOG_FILE" 2>&1; then
    if verify_proxy "$src" "$tmp"; then
      mv -f "$tmp" "$dst"

      log "DONE video: $rel"
      return 0
    else
      log "FAIL verification: $rel"

      {
        echo "  source duration: $(probe_duration "$src")"
        echo "  proxy duration:  $(probe_duration "$tmp")"
        echo "  source fps:       $(probe_fps "$src")"
        echo "  proxy fps:        $(probe_fps "$tmp")"
        echo "  proxy height:     $(probe_video_height "$tmp")"
        echo "  proxy pix_fmt:    $(probe_video_pix_fmt "$tmp")"
        echo "  source rtmd:      $(probe_rtmd_count "$src")"
        echo "  source timecode:  $(probe_rtmd_timecode "$src")"
        echo "  proxy timecode:   $(probe_proxy_timecode "$tmp")"
      } >> "$LOG_FILE"

      rm -f "$tmp"

      printf '%s\n' "$src" >> "$FAILED_FILE"

      return 1
    fi
  else
    log "FAIL ffmpeg: $rel"

    rm -f "$tmp"

    printf '%s\n' "$src" >> "$FAILED_FILE"

    return 1
  fi
}


# ========================
# ========== Main ========
# ========================

for required_cmd in ffmpeg ffprobe; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "ERROR: $required_cmd is not installed."
    echo "On macOS with Homebrew:"
    echo "  brew install ffmpeg"
    exit 1
  fi
done


log "Source: $SRC_ROOT"
log "Proxy: $PROXY_ROOT"
log "Video: ${HEIGHT}p HEVC Main 8-bit 4:2:0, 2700 kb/s CBR"
log "Embedded audio: AAC $AUDIO_BITRATE per stream"
log "Sony rtmd: timecode converted to QuickTime tmcd"
log "Standalone audio: copy unchanged"
log "Parallel jobs: $PARALLEL_JOBS"
log "Proxy progress estimate ratio: source / $PROXY_SIZE_RATIO"

if [[ -f "$SKIP_FILE" ]]; then
  log "Skip list: $SKIP_FILE"
else
  log "Skip list: none"
fi


count=0
finished=0
failed=0

percent="0.0"

finished_bytes=0
processed_bytes=0
byte_percent="0.0"

PROCESS_START_EPOCH=0

# First pass:
# Count files + source bytes.
TOTAL_FILES=0
TOTAL_BYTES=0

while IFS= read -r src; do
  if should_skip "$src"; then
    continue
  fi

  TOTAL_FILES=$((TOTAL_FILES + 1))

  size="$(file_size "$src")"

  if [[ "$size" =~ ^[0-9]+$ ]]; then
    TOTAL_BYTES=$((TOTAL_BYTES + size))
  fi

  # Update scan progress in place.
  printf '\r\033[2KScanned: %s files | Size: %s' \
    "$TOTAL_FILES" \
    "$(human_size "$TOTAL_BYTES")"

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

# Final scan result.
printf '\r\033[2KScanned: %s files | Size: %s\n' \
  "$TOTAL_FILES" \
  "$(human_size "$TOTAL_BYTES")"


log "Total files: $TOTAL_FILES"
log "Total source size: $(human_size "$TOTAL_BYTES") ($TOTAL_BYTES bytes)"

# Replace startup/scanning message with the live status display.

printf '\n'

draw_status


# Second pass:
# Actual processing.
#
# Newline-delimited filenames are used for readable lexical ordering.
# This assumes filenames do not contain literal newline characters.
while IFS= read -r src; do
  if should_skip "$src"; then
    continue
  fi

  count=$((count + 1))

  ext="${src##*.}"
  ext="$(
    printf '%s' "$ext" |
      tr '[:upper:]' '[:lower:]'
  )"

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
  \) |
    LC_ALL=C sort
)


wait_for_all_jobs


clear_status
draw_status


log "Finished. Files attempted: $count; failures: $failed"


# Remove empty failed list.
if [[ ! -s "$FAILED_FILE" ]]; then
  rm -f "$FAILED_FILE"
fi


if [[ "$failed" -gt 0 ]]; then
  log "Failed-file list: $FAILED_FILE"
  exit 1
fi


# Remove all logs after a completely successful run.
rm -rf "$LOG_ROOT"

exit 0
