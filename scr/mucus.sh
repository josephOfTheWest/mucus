#!/usr/bin/env bash
# mucus.sh — Media Universal Compression Utility Script
#
# Re-encodes video files using FFmpeg with AV1 hardware acceleration.
# Mirrors mucus.ps1 behavior on Linux and macOS.
#
# Requirements:
#   bash 4+       (associative arrays; macOS: brew install bash)
#   ffmpeg        (5.1+ with AV1 support)
#   ffprobe       (bundled with ffmpeg)
#   jq            (JSON parsing for ffprobe output)
#   flock         (log-safe parallel writes; Linux built-in, macOS: brew install util-linux)
#   nvidia-smi    (NVIDIA VRAM detection, optional)
#   rocm-smi      (AMD VRAM detection, optional)
#   lspci         (GPU vendor detection; pciutils package)

set -euo pipefail
IFS=$'\n\t'

# =========================================================================
# COLOR CODES  (suppressed when stdout is not a terminal)
# =========================================================================
if [[ -t 1 ]]; then
    C_CYAN="\033[0;36m"
    C_YELLOW="\033[0;33m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_RESET="\033[0m"
else
    C_CYAN="" C_YELLOW="" C_RED="" C_GREEN="" C_RESET=""
fi

# =========================================================================
# DEFAULT PARAMETER VALUES
# =========================================================================
SOURCE_DIR=""
TARGET_DIR=""
LOG_DIR="$(pwd)/encode_logs"   # overridden by --log-dir
CQ=""                          # empty = use profile default
PRESET=""                      # empty = use profile default
ADJUST_CQ=""                   # empty = no adjustment; integer offset applied to profile CQ
ADJUST_PRESET=""               # empty = no adjustment; integer offset applied to profile preset number
ON_COMPLETE="Nothing"          # Nothing | Delete | Replace
CONTENT="General"              # General | Sports | Movie | Show
FAVOR="quality"                # quality | space
NO_EXPORT_LIST=false           # true suppresses CSV export
EXPORT_ERROR="NONE"            # NONE | WARN | ERROR
DRY_RUN=false                  # --dry-run / --what-if

# =========================================================================
# HELP TEXT
# =========================================================================
show_help() {
    cat <<'EOF'

SYNOPSIS
    Re-encodes video files using FFmpeg with AV1 hardware acceleration.

USAGE
    mucus.sh --source <path> --target <path> [options]
    mucus.sh --help

PARAMETERS
    --source, -s  <path>   [Required]
        Full path to the directory containing source video files.
        Scanned recursively.

    --target, -t  <path>   [Required]
        Full path to the directory where re-encoded files will be written.
        Directory structure mirrors the source.

    --log-dir, -l  <path>  [Default: ./encode_logs]
        Full path to the directory where log files will be written.
        The master session log is written to the root of this directory.
        Per-file encode logs are written to subdirectories mirroring
        the source structure.

    --content  <string>    [Default: General]
        Content type profile controlling all FFmpeg quality/encode parameters.

          General   — Balanced for any content from SD to 8K.
          Sports    — Fast motion: aggressive AQ, moderate lookahead.
          Movie     — Feature film: resolution-aware quality, strong AQ,
                      high lookahead. Resolution tiers unlock slower
                      presets and stronger AQ (SD through 8K+).
          Show      — TV episodes: efficient compression, large libraries.

        Use --cq or --preset alongside --content to override individual
        profile values, or --adjust-cq / --adjust-preset to offset them.

    --cq  <int>            [Default: profile value]  Range: 0–63
        Constant Quality value for AV1 encoding.
        Lower = better quality / larger file.
        Overrides the selected Content profile's default CQ when supplied.

    --preset  <string>     [Default: profile value]  Values: p1–p7
        Encoding speed preset.
        p1 = fastest/lowest quality, p7 = slowest/best.
        Overrides the selected Content profile's default preset when supplied.

    --adjust-cq  <int>     [Default: none]
        Integer offset added to the content profile's CQ value for each file.
        Cannot be combined with --cq. Final value is clamped to 0–51.
        Positive = higher CQ (lower quality); negative = lower CQ (higher quality).
        Example: profile CQ 24, --adjust-cq 2  →  effective CQ 26.

    --adjust-preset  <int>  [Default: none]
        Integer offset added to the content profile's preset number for each file.
        Cannot be combined with --preset. Final value is clamped to p1–p7.
        Positive = slower/better preset; negative = faster preset.
        Example: profile p6, --adjust-preset -2  →  effective preset p4.

    --favor  <string>      [Default: quality]  Values: quality, space
        Selects the content profile table.
          quality  — Standard profiles; prioritize output quality.
          space    — Space profiles; CQ raised by 4, preset raised by 1 across all tiers.
                     Produces consistently smaller files at the cost of some quality.
        --cq, --adjust-cq, --preset, and --adjust-preset still override or adjust
        the selected profile's values when supplied.

    --on-complete  <string>  [Default: Nothing]
        Action to take on the SOURCE file after a successful encode:

          Nothing  — Leave source file untouched. (default)
          Delete   — Delete source file; remove directory if empty.
          Replace  — Move encoded output to source directory, delete original.

        Special behavior when source is already a valid AV1 MKV:
          Nothing  — Copy source to target location.
          Delete   — Move source to target location.
          Replace  — No action (file is already correct format and location).

    --dry-run, --what-if
        Simulate the run without encoding or modifying any files.
        All decisions are logged but no FFmpeg processes are started
        and no source files are touched.

    --no-export-list
        Suppress the per-session CSV export.
        By default a CSV named FileList_<timestamp>.csv is written to
        the log directory.
        Columns: File, Status, Src Action, Target Action, Src Size,
                 Tgt Size, Savings.

    --export-error  <string>  [Default: NONE]  Values: NONE, WARN, ERROR
        Controls whether a separate error log is written to the log directory.
        File name: ErrorLog_<timestamp>.log

          NONE   — No error log written. (default)
          WARN   — All WARN and ERROR entries written to the error log.
          ERROR  — Only ERROR entries written to the error log.

    --help, -h
        Display this help text and exit.

REQUIREMENTS
    bash 4+, ffmpeg 5.1+ with AV1 support, ffprobe, jq, flock.
    ffmpeg/ffprobe placed in the working directory override system PATH.
    Multi-threading is throttled automatically based on detected GPU VRAM.
    AMD AMF (av1_amf) is not supported on Linux/macOS — SVT-AV1 or
    libaom-AV1 software fallback is used instead when no other HW is found.

EXAMPLES
    # Basic re-encode with all defaults
    ./mucus.sh --source /media/GoPro/Baseball --target /archive/Baseball

    # Custom quality, preset, log path, delete sources on success
    ./mucus.sh --source /media/Shows --target /archive \
               --log-dir /var/log/mucus --cq 28 --preset p6 \
               --on-complete Replace

    # TV library using the Show profile, replace originals in-place
    ./mucus.sh --source /media/TV --target /archive/TV \
               --content Show --on-complete Replace

    # Dry run — see what would happen without touching any files
    ./mucus.sh --source /media/GoPro --target /archive --dry-run

EOF
}

# =========================================================================
# BANNER
# =========================================================================
show_banner() {
    printf "${C_CYAN}"
    cat <<'EOF'

  ##     ##   ##     ##    #######    ##     ##    #######
  ###   ###   ##     ##   ##     ##   ##     ##   ##     ##
  #### ####   ##     ##   ##          ##     ##   ##
  ## ### ##   ##     ##   ##          ##     ##    #######
  ##  #  ##   ##     ##   ##          ##     ##          ##
  ##     ##    ##   ##    ##     ##    ##   ##    ##     ##
  ##     ##     #####      #######      #####      #######

  Media Universal Compression Utility Script

EOF
    printf "${C_RESET}"
}

# =========================================================================
# ARGUMENT PARSING
# =========================================================================
# Supports both --flag value and --flag=value forms.
# Boolean switches take no argument.
# =========================================================================
parse_args() {
    local has_cq=false
    local has_preset=false

    while [[ $# -gt 0 ]]; do
        case "$1" in

            # ── Source directory ───────────────────────────────────────────
            --source|-s)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                SOURCE_DIR="$2"; shift 2 ;;
            --source=*)
                SOURCE_DIR="${1#*=}"; shift ;;

            # ── Target directory ───────────────────────────────────────────
            --target|-t)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                TARGET_DIR="$2"; shift 2 ;;
            --target=*)
                TARGET_DIR="${1#*=}"; shift ;;

            # ── Log directory ──────────────────────────────────────────────
            --log-dir|-l)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                LOG_DIR="$2"; shift 2 ;;
            --log-dir=*)
                LOG_DIR="${1#*=}"; shift ;;

            # ── Constant Quality ───────────────────────────────────────────
            --cq|-q)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                CQ="$2"; has_cq=true; shift 2 ;;
            --cq=*)
                CQ="${1#*=}"; has_cq=true; shift ;;

            # ── Encoding preset ────────────────────────────────────────────
            --preset|-p)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                PRESET="$2"; has_preset=true; shift 2 ;;
            --preset=*)
                PRESET="${1#*=}"; has_preset=true; shift ;;

            # ── CQ adjustment ──────────────────────────────────────────────
            --adjust-cq)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                ADJUST_CQ="$2"; shift 2 ;;
            --adjust-cq=*)
                ADJUST_CQ="${1#*=}"; shift ;;

            # ── Preset adjustment ──────────────────────────────────────────
            --adjust-preset)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                ADJUST_PRESET="$2"; shift 2 ;;
            --adjust-preset=*)
                ADJUST_PRESET="${1#*=}"; shift ;;

            # ── OnComplete action ──────────────────────────────────────────
            --on-complete|-o)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                ON_COMPLETE="$2"; shift 2 ;;
            --on-complete=*)
                ON_COMPLETE="${1#*=}"; shift ;;

            # ── Content type profile ───────────────────────────────────────
            --content|-c)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                CONTENT="$2"; shift 2 ;;
            --content=*)
                CONTENT="${1#*=}"; shift ;;

            # ── Favor (quality vs space profiles) ─────────────────────────
            --favor)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                FAVOR="$2"; shift 2 ;;
            --favor=*)
                FAVOR="${1#*=}"; shift ;;

            # ── Export error log ───────────────────────────────────────────
            --export-error)
                [[ $# -lt 2 ]] && { printf "${C_RED}[ERROR] '%s' requires a value.\n${C_RESET}" "$1" >&2; exit 1; }
                EXPORT_ERROR="$2"; shift 2 ;;
            --export-error=*)
                EXPORT_ERROR="${1#*=}"; shift ;;

            # ── Switches (no argument) ─────────────────────────────────────
            --no-export-list)
                NO_EXPORT_LIST=true; shift ;;

            --dry-run|--what-if)
                DRY_RUN=true; shift ;;

            # ── Help ───────────────────────────────────────────────────────
            --help|-h)
                show_help; exit 0 ;;

            # ── Positional fallback (source then target) ───────────────────
            -*)
                printf "${C_RED}[ERROR] Unknown option: %s\n${C_RESET}" "$1" >&2
                printf "        Run  %s --help  for usage information.\n" "$0" >&2
                exit 1 ;;
            *)
                if [[ -z "$SOURCE_DIR" ]]; then
                    SOURCE_DIR="$1"
                elif [[ -z "$TARGET_DIR" ]]; then
                    TARGET_DIR="$1"
                else
                    printf "${C_RED}[ERROR] Unexpected positional argument: %s\n${C_RESET}" "$1" >&2
                    exit 1
                fi
                shift ;;
        esac
    done

    # Expose override flags for later sections
    HAS_CQ_OVERRIDE=$has_cq
    HAS_PRESET_OVERRIDE=$has_preset
}

# =========================================================================
# PARAMETER VALIDATION
# =========================================================================
validate_params() {
    local errors=()

    # Required parameters
    if [[ -z "$SOURCE_DIR" ]]; then
        errors+=("--source  is required. Provide the full path to the source video directory.")
    elif [[ ! -d "$SOURCE_DIR" ]]; then
        errors+=("--source  '$SOURCE_DIR' does not exist or is not a directory.")
    fi

    if [[ -z "$TARGET_DIR" ]]; then
        errors+=("--target  is required. Provide the full path where re-encoded files will be written.")
    fi

    # CQ range
    if [[ -n "$CQ" ]]; then
        if ! [[ "$CQ" =~ ^[0-9]+$ ]] || (( CQ < 0 || CQ > 63 )); then
            errors+=("--cq  '$CQ' is invalid. Must be an integer in the range 0–63.")
        fi
    fi

    # adjust-cq must be an integer (may be negative)
    if [[ -n "$ADJUST_CQ" ]]; then
        if ! [[ "$ADJUST_CQ" =~ ^-?[0-9]+$ ]]; then
            errors+=("--adjust-cq  '$ADJUST_CQ' is invalid. Must be a positive or negative integer.")
        fi
    fi

    # adjust-preset must be an integer (may be negative)
    if [[ -n "$ADJUST_PRESET" ]]; then
        if ! [[ "$ADJUST_PRESET" =~ ^-?[0-9]+$ ]]; then
            errors+=("--adjust-preset  '$ADJUST_PRESET' is invalid. Must be a positive or negative integer.")
        fi
    fi

    # Conflict: --cq and --adjust-cq are mutually exclusive
    if [[ -n "$CQ" && -n "$ADJUST_CQ" ]]; then
        errors+=("--cq and --adjust-cq cannot be used together. Use one or the other.")
    fi

    # Conflict: --preset and --adjust-preset are mutually exclusive
    if [[ -n "$PRESET" && -n "$ADJUST_PRESET" ]]; then
        errors+=("--preset and --adjust-preset cannot be used together. Use one or the other.")
    fi

    # Preset values
    if [[ -n "$PRESET" ]]; then
        case "$PRESET" in
            p1|p2|p3|p4|p5|p6|p7) ;;
            *)
                errors+=("--preset  '$PRESET' is invalid. Valid values: p1 p2 p3 p4 p5 p6 p7.")
                ;;
        esac
    fi

    # OnComplete values
    case "$ON_COMPLETE" in
        Nothing|Delete|Replace) ;;
        *)
            errors+=("--on-complete  '$ON_COMPLETE' is invalid. Valid values: Nothing Delete Replace.")
            ;;
    esac

    # Content values
    case "$CONTENT" in
        General|Sports|Movie|Show) ;;
        *)
            errors+=("--content  '$CONTENT' is invalid. Valid values: General Sports Movie Show.")
            ;;
    esac

    # Favor values
    case "$FAVOR" in
        quality|space) ;;
        *)
            errors+=("--favor  '$FAVOR' is invalid. Valid values: quality space.")
            ;;
    esac

    # ExportError values
    case "$EXPORT_ERROR" in
        NONE|WARN|ERROR) ;;
        *)
            errors+=("--export-error  '$EXPORT_ERROR' is invalid. Valid values: NONE WARN ERROR.")
            ;;
    esac

    if (( ${#errors[@]} > 0 )); then
        printf "\n${C_RED}[ERROR] Cannot start — the following required parameters are missing or invalid:\n\n${C_RESET}" >&2
        for err in "${errors[@]}"; do
            printf "${C_YELLOW}    • %s\n${C_RESET}" "$err" >&2
        done
        printf "\n${C_YELLOW}    Both --source and --target must be supplied to run.\n${C_RESET}" >&2
        printf "${C_CYAN}    Run  %s --help  for full usage information and examples.\n\n${C_RESET}" "$0" >&2
        exit 1
    fi
}

# =========================================================================
# DESTRUCTIVE ACTION CONFIRMATION
# =========================================================================
confirm_destructive() {
    if [[ "$ON_COMPLETE" == "Nothing" || "$DRY_RUN" == true ]]; then
        return 0
    fi

    local action_desc
    case "$ON_COMPLETE" in
        Delete)
            action_desc="DELETE the original source video files after each successful encode." ;;
        Replace)
            action_desc="DELETE the original source video files and REPLACE them with the re-encoded versions." ;;
    esac

    printf "\n${C_RED}  ⚠  WARNING: DESTRUCTIVE ACTION\n\n${C_RESET}"
    printf "${C_YELLOW}  OnComplete is set to '%s'. This will permanently:\n" "$ON_COMPLETE"
    printf "    %s\n\n" "$action_desc"
    printf "  Source files that are deleted CANNOT be recovered from a Recycle Bin.\n"
    printf "  Source directory : %s\n\n${C_RESET}" "$SOURCE_DIR"

    local confirmation
    read -r -p "  Type Y to confirm and proceed, or any other key to abort: " confirmation
    if [[ "$confirmation" != "Y" ]]; then
        printf "\n${C_GREEN}  Aborted. No files were modified.\n\n${C_RESET}"
        exit 0
    fi
    printf "\n"
}

# =========================================================================
# PURE-BASH PATH RESOLVER
# Resolves an absolute, normalized path without requiring the path to exist.
# Equivalent to GNU realpath -m / Python os.path.normpath(os.path.abspath()).
# Handles relative paths, . and .. components.
# Usage: resolve_path <path>   (prints the resolved path; no trailing slash)
# =========================================================================
resolve_path() {
    local path="$1"

    # Make absolute — prepend cwd if not already rooted
    [[ "$path" != /* ]] && path="$(pwd)/$path"

    # Split on '/' into an array of segments
    local -a parts
    local old_ifs="$IFS"
    IFS='/' read -ra parts <<< "$path"
    IFS="$old_ifs"

    # Walk segments, maintaining a stack to resolve . and ..
    local -a stack=()
    local seg
    for seg in "${parts[@]}"; do
        case "$seg" in
            ""|.)
                # Empty segment (leading slash or double slash) or current-dir: skip
                ;;
            ..)
                # Parent-dir: pop the top of the stack (if non-empty)
                if (( ${#stack[@]} > 0 )); then
                    stack=("${stack[@]:0:$(( ${#stack[@]} - 1 ))}")
                fi
                ;;
            *)
                stack+=("$seg")
                ;;
        esac
    done

    # Reassemble: always rooted at /
    if (( ${#stack[@]} == 0 )); then
        printf "/"
    else
        local result=""
        for seg in "${stack[@]}"; do
            result+="/$seg"
        done
        printf "%s" "$result"
    fi
}

# =========================================================================
# GLOBAL LOG STATE
# LOG_LOCK_FILE  — path to the flock sentinel file; set inside mucus() once
#                  the log directory is known; exported so parallel subshells
#                  inherit it automatically.
# ERROR_LOG_PATH — path to the optional error log; empty string when disabled.
# =========================================================================
LOG_LOCK_FILE=""
ERROR_LOG_PATH=""

# =========================================================================
# log <message> <level> <log_file>
#
# Mutex-safe log write.  Mirrors Write-Log from mucus.ps1 (lines 300–330).
#
# <level>    : INFO | WARN | ERROR | SUCCESS  (default: INFO)
# <log_file> : absolute path to the master or per-file log
#
# Locking strategy:
#   flock -w 5 acquires an exclusive lock on LOG_LOCK_FILE within 5 seconds.
#   The lock is held only for the duration of the write, then released when
#   the subshell ( ... ) 200>"$LOG_LOCK_FILE" exits.
#   If the timeout fires the entry is dropped with a console warning, matching
#   the PS1 mutex-timeout behavior.
#
# Colour output goes to stdout (INFO/WARN/SUCCESS) or stderr (ERROR).
# =========================================================================
log() {
    local message="$1"
    local level="${2:-INFO}"
    local log_file="${3:-}"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local entry="[$timestamp] [$level] $message"

    # ── Write to log file under flock ─────────────────────────────────────
    if [[ -n "$log_file" && -n "$LOG_LOCK_FILE" ]]; then
        (
            if ! flock -w 5 200; then
                printf "${C_YELLOW}[$timestamp] [WARN] Log mutex timeout — entry may be lost: %s\n${C_RESET}" \
                    "$message" >&2
            else
                printf "%s\n" "$entry" >> "$log_file"

                # Mirror to error log when ExportError threshold is met
                if [[ -n "$ERROR_LOG_PATH" ]]; then
                    local write_err=false
                    if   [[ "$EXPORT_ERROR" == "WARN"  && ( "$level" == "WARN" || "$level" == "ERROR" ) ]]; then
                        write_err=true
                    elif [[ "$EXPORT_ERROR" == "ERROR" && "$level" == "ERROR" ]]; then
                        write_err=true
                    fi
                    [[ "$write_err" == true ]] && printf "%s\n" "$entry" >> "$ERROR_LOG_PATH"
                fi
            fi
        ) 200>"$LOG_LOCK_FILE"
    fi

    # ── Console output with color ────────────────────────────────────────
    case "$level" in
        INFO)    printf "${C_CYAN}%s\n${C_RESET}"   "$entry" ;;
        WARN)    printf "${C_YELLOW}%s\n${C_RESET}" "$entry" ;;
        ERROR)   printf "${C_RED}%s\n${C_RESET}"    "$entry" >&2 ;;
        SUCCESS) printf "${C_GREEN}%s\n${C_RESET}"  "$entry" ;;
        *)       printf "%s\n"                      "$entry" ;;
    esac
}

# =========================================================================
# format_bytes <bytes>
#
# Prints a human-readable size string.  Mirrors Format-Bytes (ps1 line 332).
# Uses awk for floating-point division; no bc dependency required.
# =========================================================================
format_bytes() {
    local bytes="${1:-0}"
    if   (( bytes >= 1073741824 )); then
        awk "BEGIN { printf \"%.2f GB\", $bytes / 1073741824 }"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN { printf \"%.2f MB\", $bytes / 1048576 }"
    elif (( bytes >= 1024 )); then
        awk "BEGIN { printf \"%.2f KB\", $bytes / 1024 }"
    else
        printf "%d B" "$bytes"
    fi
}

# =========================================================================
# pad <string> <width>
#
# Returns <string> left-padded with spaces to exactly <width> characters.
# Strings longer than <width> are truncated to (<width>-2) chars and
# suffixed with '..', matching the PS1 Pad helper (ps1 lines 1722–1725).
# =========================================================================
pad() {
    local s="$1"
    local width="$2"
    local len="${#s}"

    if (( len > width )); then
        # Truncate and add ellipsis marker
        printf "%s" "${s:0:$(( width - 2 ))}.."
    else
        # Left-align, pad with spaces to width
        printf "%-*s" "$width" "$s"
    fi
}

# =========================================================================
# _file_size <path>
#
# Prints the file size in bytes.  Abstracts the stat(1) interface difference
# between Linux (stat -c %s) and macOS (stat -f %z).
# Returns 0 on failure so callers get a safe integer to compare against.
# =========================================================================
_file_size() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        stat -f %z "$1" 2>/dev/null || echo 0
    else
        stat -c %s  "$1" 2>/dev/null || echo 0
    fi
}

# =========================================================================
# MAIN FUNCTION
# =========================================================================
mucus() {

    parse_args "$@"
    show_banner

    validate_params
    confirm_destructive

    # CQ / preset override flags — re-derived here as locals so that background
    # subshells (encode_one_file) fork a correct copy.  Also guards the edge
    # case where the user passes "--cq=" (empty value), which would leave the
    # global has_cq=true but $CQ empty; checking -n catches that correctly.
    local HAS_CQ_OVERRIDE=false;     [[ -n "$CQ"     ]] && HAS_CQ_OVERRIDE=true
    local HAS_PRESET_OVERRIDE=false; [[ -n "$PRESET" ]] && HAS_PRESET_OVERRIDE=true
    local HAS_CQ_ADJUST=false;     [[ -n "$ADJUST_CQ"     ]] && HAS_CQ_ADJUST=true
    local HAS_PRESET_ADJUST=false; [[ -n "$ADJUST_PRESET" ]] && HAS_PRESET_ADJUST=true

    # ── Resolve paths ──────────────────────────────────────────────────────
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
    TARGET_DIR="$(resolve_path "$TARGET_DIR")"  # may not exist yet; resolve_path handles this

    # Overlap check — source and target must not contain each other
    if [[ "$SOURCE_DIR" == "$TARGET_DIR" ]] ||
       [[ "$TARGET_DIR" == "$SOURCE_DIR"/* ]] ||
       [[ "$SOURCE_DIR" == "$TARGET_DIR"/* ]]; then
        printf "${C_RED}[ERROR] --source and --target must not overlap (one cannot be inside the other).\n${C_RESET}" >&2
        printf "${C_YELLOW}        Source : %s\n${C_RESET}" "$SOURCE_DIR" >&2
        printf "${C_YELLOW}        Target : %s\n${C_RESET}" "$TARGET_DIR" >&2
        exit 1
    fi

    # Stamp log directory so concurrent or repeated runs never share the same path
    SESSION_STAMP="$(date '+%Y%m%d_%H%M%S')"
    LOG_DIR="${LOG_DIR%/}_${SESSION_STAMP}"

    # =========================================================================
    # STEP 1: Resolve FFmpeg / FFprobe
    # Working-directory copies take priority over anything on PATH, matching
    # the PS1 behavior (ps1 lines 344–360).
    # =========================================================================
    local working_dir
    working_dir="$(pwd)"
    local ffmpeg_bin ffprobe_bin

    if   [[ -x "$working_dir/ffmpeg"  ]];     then ffmpeg_bin="$working_dir/ffmpeg"
    elif [[ -x "$working_dir/ffmpeg.exe" ]];  then ffmpeg_bin="$working_dir/ffmpeg.exe"
    else                                           ffmpeg_bin="ffmpeg"
    fi

    if   [[ -x "$working_dir/ffprobe"  ]];    then ffprobe_bin="$working_dir/ffprobe"
    elif [[ -x "$working_dir/ffprobe.exe" ]]; then ffprobe_bin="$working_dir/ffprobe.exe"
    else                                           ffprobe_bin="ffprobe"
    fi

    printf "${C_CYAN}[INFO] FFmpeg  : %s\n${C_RESET}" "$ffmpeg_bin"
    printf "${C_CYAN}[INFO] FFprobe : %s\n${C_RESET}" "$ffprobe_bin"

    local exe
    for exe in "$ffmpeg_bin" "$ffprobe_bin"; do
        if ! "$exe" -version > /dev/null 2>&1; then
            printf "${C_RED}[ERROR] Cannot execute '%s'.\n${C_RESET}" "$exe" >&2
            printf "${C_YELLOW}        Ensure FFmpeg is installed or place executables in the working directory.\n${C_RESET}" >&2
            printf "${C_YELLOW}        Linux  : https://ffmpeg.org/download.html\n${C_RESET}" >&2
            printf "${C_YELLOW}        macOS  : brew install ffmpeg\n${C_RESET}" >&2
            exit 1
        fi
    done

    if ! command -v jq > /dev/null 2>&1; then
        printf "${C_RED}[ERROR] 'jq' is required but was not found in PATH.\n${C_RESET}" >&2
        printf "${C_YELLOW}        Linux  : sudo apt install jq  (or equivalent)\n${C_RESET}" >&2
        printf "${C_YELLOW}        macOS  : brew install jq\n${C_RESET}" >&2
        exit 1
    fi

    # =========================================================================
    # STEP 2: Probe FFmpeg hardware acceleration capabilities
    # Builds two associative arrays:
    #   API_PRESENT[<api>] = true|false  — hwaccel APIs in this build
    #   ENC_PRESENT[<enc>] = true|false  — AV1 encoders in this build
    # Also detects GPU vendor via lspci (Linux) or system_profiler (macOS).
    # Mirrors ps1 lines 362–396.
    # =========================================================================
    printf "\n${C_CYAN}[INFO] Probing FFmpeg hardware acceleration capabilities...\n${C_RESET}"

    local ff_version ff_encoders ff_hwaccels
    ff_version="$( "$ffmpeg_bin" -version  2>&1 )"
    ff_encoders="$("$ffmpeg_bin" -encoders 2>&1 )"
    ff_hwaccels="$("$ffmpeg_bin" -hwaccels 2>&1 )"

    if ! printf "%s" "$ff_version" | grep -q 'version'; then
        printf "${C_RED}[ERROR] FFmpeg did not return version information. The executable may be corrupt.\n${C_RESET}" >&2
        exit 1
    fi

    # ── API presence (hwaccels + encoder list both searched) ─────────────
    local -A API_PRESENT
    local api
    for api in cuda cuvid nvenc d3d11va qsv vaapi amf vulkan opencl videotoolbox; do
        if printf "%s\n%s" "$ff_hwaccels" "$ff_encoders" | grep -q "$api"; then
            API_PRESENT[$api]=true
        else
            API_PRESENT[$api]=false
        fi
    done

    # ── AV1 encoder presence ──────────────────────────────────────────────
    local -A ENC_PRESENT
    local enc
    for enc in av1_nvenc av1_qsv av1_amf av1_videotoolbox libsvtav1 libaom-av1; do
        if printf "%s" "$ff_encoders" | grep -qF "$enc"; then
            ENC_PRESENT[$enc]=true
        else
            ENC_PRESENT[$enc]=false
        fi
    done

    # ── Build display strings ─────────────────────────────────────────────
    local api_list="" enc_list=""
    for api in cuda cuvid nvenc d3d11va qsv vaapi amf vulkan opencl videotoolbox; do
        [[ "${API_PRESENT[$api]}" == true ]] && api_list="${api_list:+$api_list, }${api^^}"
    done
    for enc in av1_nvenc av1_qsv av1_amf av1_videotoolbox libsvtav1 libaom-av1; do
        [[ "${ENC_PRESENT[$enc]}" == true ]] && enc_list="${enc_list:+$enc_list, }$enc"
    done

    printf "${C_CYAN}[INFO] HW APIs available  : %s\n${C_RESET}" \
        "${api_list:-none detected}"
    printf "${C_CYAN}[INFO] AV1 encoders found : %s\n${C_RESET}" \
        "${enc_list:-none — software fallback only}"

    # ── GPU vendor detection ──────────────────────────────────────────────
    # Replaces WMI (Windows-only) with lspci on Linux and system_profiler
    # on macOS.  Results are advisory — FFmpeg encoder/hwaccel presence is
    # the authoritative gating check used in STEP 3.
    local HAS_NVIDIA_GPU=false HAS_INTEL_GPU=false HAS_AMD_GPU=false
    local gpu_list=""

    case "$(uname -s)" in
        Darwin)
            # macOS: system_profiler is always present; no extra packages needed
            gpu_list="$(system_profiler SPDisplaysDataType 2>/dev/null \
                        | grep -i 'Chipset Model' || true)"
            ;;
        *)
            # Linux (and other POSIX): lspci from pciutils
            if command -v lspci > /dev/null 2>&1; then
                gpu_list="$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' || true)"
            else
                printf "${C_YELLOW}[WARN] 'lspci' not found — GPU vendor detection skipped.\n${C_RESET}"
                printf "${C_YELLOW}        Install pciutils to enable GPU detection:\n${C_RESET}"
                printf "${C_YELLOW}        Linux  : sudo apt install pciutils  (or equivalent)\n${C_RESET}"
                printf "${C_YELLOW}        macOS  : not applicable (system_profiler is used instead)\n${C_RESET}"
            fi
            ;;
    esac

    printf "%s" "$gpu_list" | grep -qi 'nvidia'         && HAS_NVIDIA_GPU=true || true
    printf "%s" "$gpu_list" | grep -qi 'intel'          && HAS_INTEL_GPU=true  || true
    printf "%s" "$gpu_list" | grep -qiE 'amd|radeon|ati' && HAS_AMD_GPU=true   || true

    local gpu_vendor_list=""
    [[ "$HAS_NVIDIA_GPU" == true ]] && gpu_vendor_list="${gpu_vendor_list:+$gpu_vendor_list, }NVIDIA"
    [[ "$HAS_INTEL_GPU"  == true ]] && gpu_vendor_list="${gpu_vendor_list:+$gpu_vendor_list, }Intel"
    [[ "$HAS_AMD_GPU"    == true ]] && gpu_vendor_list="${gpu_vendor_list:+$gpu_vendor_list, }AMD"
    printf "${C_CYAN}[INFO] GPU vendor(s) detected : %s\n${C_RESET}" \
        "${gpu_vendor_list:-none detected}"

    # =========================================================================
    # STEP 3: Select hardware stack and compute max_parallel
    # Priority: NVIDIA NVENC → Intel QSV → AMD AMF (Windows-only) →
    #           Apple VideoToolbox → SVT-AV1 → libaom-AV1 → CPU fallback
    # Mirrors ps1 lines 398–542.
    # =========================================================================
    printf "\n${C_CYAN}[INFO] Selecting hardware acceleration stack...\n${C_RESET}"

    local selected_stack=""
    local hw_vendor=""
    local vram_mb=0
    local max_parallel=1
    local cpu_fallback_enc=""
    local -a hw_decode_args=()

    # ── Helper: portable integer clamp ───────────────────────────────────
    # clamp <value> <min> <max>  →  prints result
    clamp() { local v=$1 lo=$2 hi=$3
               (( v < lo )) && v=$lo; (( v > hi )) && v=$hi; printf "%d" "$v"; }

    # ── OS detection (used to gate Windows-only encoders) ────────────────
    local os_type
    os_type="$(uname -s 2>/dev/null)"
    local is_macos=false is_windows_like=false
    [[ "$os_type" == Darwin ]]                    && is_macos=true
    [[ "$os_type" == MINGW* || "$os_type" == MSYS* || "$os_type" == CYGWIN* ]] \
                                                  && is_windows_like=true

    # ── CPU core count (for SW-* throttle) ───────────────────────────────
    local cpu_cores
    cpu_cores="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

    # ── Priority 1: NVIDIA NVENC + NVDEC (cuda) ───────────────────────────
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[av1_nvenc]}"  == true ]] &&
       [[ "${API_PRESENT[cuda]}"       == true ]]; then

        local smi_out=""
        if smi_out="$(nvidia-smi --query-gpu=memory.total \
                                 --format=csv,noheader,nounits 2>/dev/null \
                      | head -1)"; then
            smi_out="${smi_out// /}"   # strip spaces
            if [[ "$smi_out" =~ ^[0-9]+$ ]] && (( smi_out > 0 )); then
                selected_stack="NVIDIA-NVENC"
                hw_vendor="NVIDIA"
                vram_mb="$smi_out"
                hw_decode_args=(-hwaccel cuda -hwaccel_output_format cuda)
            else
                printf "${C_YELLOW}[WARN] nvidia-smi returned an invalid VRAM value ('%s') — NVIDIA stack skipped.\n${C_RESET}" \
                    "$smi_out"
            fi
        else
            printf "${C_YELLOW}[WARN] nvidia-smi query failed — NVIDIA stack skipped.\n${C_RESET}"
        fi
    fi

    # ── Priority 2: Intel Quick Sync Video (QSV) ──────────────────────────
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[av1_qsv]}" == true ]] &&
       [[ "${API_PRESENT[qsv]}"     == true ]]; then

        selected_stack="INTEL-QSV"
        hw_vendor="Intel"
        hw_decode_args=(-hwaccel qsv -hwaccel_output_format qsv)
        # VRAM not reliably queryable on Linux without privileged tools;
        # is_arc_gpu detection drives the parallel formula (see throttle block).
    fi

    # ── Priority 3: AMD AMF ────────────────────────────────────────────────
    # AMF AV1 requires the AMD Windows SDK — not supported on Linux/macOS.
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[av1_amf]}" == true ]] &&
       [[ "$is_windows_like"        == true ]]; then

        selected_stack="AMD-AMF"
        hw_vendor="AMD"
        # d3d11va is the Windows decode accelerator; vaapi on Linux (unreachable
        # here given the is_windows_like gate, but kept for symmetry)
        if [[ "${API_PRESENT[d3d11va]}" == true ]]; then
            hw_decode_args=(-hwaccel d3d11va -hwaccel_output_format d3d11)
        fi
        # VRAM query via rocm-smi (best-effort; not available on Windows)
        if command -v rocm-smi > /dev/null 2>&1; then
            local roc_out roc_bytes=""
            roc_out="$(rocm-smi --showmeminfo vram 2>/dev/null || true)"
            roc_bytes="$(printf "%s" "$roc_out" \
                         | grep -iE 'total.*memory|vram.*total' \
                         | grep -oE '[0-9]+' | tail -1 || true)"
            if [[ -n "$roc_bytes" ]] && (( roc_bytes > 0 )); then
                vram_mb=$(( roc_bytes / 1048576 ))
            fi
        fi
    fi

    # ── Priority 4: Apple VideoToolbox ────────────────────────────────────
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[av1_videotoolbox]}" == true ]] &&
       [[ "${API_PRESENT[videotoolbox]}"     == true ]] &&
       [[ "$is_macos"                        == true ]]; then

        selected_stack="APPLE-VTB"
        hw_vendor="Apple"
        hw_decode_args=(-hwaccel videotoolbox)
    fi

    # ── Priority 5: Software SVT-AV1 ──────────────────────────────────────
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[libsvtav1]}" == true ]]; then

        selected_stack="SW-SVTAV1"
        hw_vendor="Software (SVT-AV1)"
        printf "${C_YELLOW}[WARN] No hardware acceleration detected — falling back to CPU encoding (SVT-AV1).\n${C_RESET}"
        # Best available decode-only hwaccel for this platform
        if   [[ "${API_PRESENT[vaapi]}"        == true ]]; then hw_decode_args=(-hwaccel vaapi)
        elif [[ "${API_PRESENT[qsv]}"          == true ]]; then hw_decode_args=(-hwaccel qsv)
        elif [[ "${API_PRESENT[videotoolbox]}" == true ]]; then hw_decode_args=(-hwaccel videotoolbox)
        fi
    fi

    # ── Priority 6: Software libaom-AV1 ───────────────────────────────────
    if [[ -z "$selected_stack" ]] &&
       [[ "${ENC_PRESENT[libaom-av1]}" == true ]]; then

        selected_stack="SW-LIBAOM"
        hw_vendor="Software (libaom-AV1)"
        printf "${C_YELLOW}[WARN] No hardware acceleration detected — falling back to CPU encoding (libaom-AV1, very slow).\n${C_RESET}"
        if   [[ "${API_PRESENT[vaapi]}" == true ]]; then hw_decode_args=(-hwaccel vaapi)
        elif [[ "${API_PRESENT[qsv]}"   == true ]]; then hw_decode_args=(-hwaccel qsv)
        fi
    fi

    # ── Priority 7: Last-resort CPU scan ──────────────────────────────────
    # Scan ffmpeg -encoders for any line that looks like a video AV1 encoder.
    if [[ -z "$selected_stack" ]]; then
        local any_av1_line=""
        any_av1_line="$(printf "%s" "$ff_encoders" \
                        | grep -E '^\s+V.+av1' | head -1 || true)"
        if [[ -n "$any_av1_line" ]]; then
            cpu_fallback_enc="$(printf "%s" "$any_av1_line" | awk '{print $2}')"
            selected_stack="SW-CPU"
            hw_vendor="Software ($cpu_fallback_enc)"
            printf "${C_YELLOW}[WARN] No known AV1 encoder detected — attempting CPU fallback with '%s'.\n${C_RESET}" \
                "$cpu_fallback_enc"
        fi
    fi

    # ── Abort if no encoder found ─────────────────────────────────────────
    if [[ -z "$selected_stack" ]]; then
        printf "${C_RED}[ERROR] No AV1 encoder found in this FFmpeg build.\n${C_RESET}" >&2
        printf "${C_YELLOW}        Checked : av1_nvenc, av1_qsv, av1_amf, av1_videotoolbox, libsvtav1, libaom-av1\n${C_RESET}" >&2
        printf "${C_YELLOW}        Install a full FFmpeg build that includes SVT-AV1 (recommended).\n${C_RESET}" >&2
        printf "${C_YELLOW}        Linux  : https://ffmpeg.org/download.html\n${C_RESET}" >&2
        printf "${C_YELLOW}        macOS  : brew install ffmpeg\n${C_RESET}" >&2
        exit 1
    fi

    # ── Stack summary ─────────────────────────────────────────────────────
    local is_hw_stack=false
    [[ "$selected_stack" != SW-* ]] && is_hw_stack=true

    if [[ "$is_hw_stack" == true ]]; then
        printf "${C_GREEN}[SUCCESS] Hardware stack  : %s (%s)\n${C_RESET}" \
            "$selected_stack" "$hw_vendor"
    else
        printf "${C_YELLOW}[WARN]    CPU fallback    : %s (%s)\n${C_RESET}" \
            "$selected_stack" "$hw_vendor"
    fi

    local decode_label
    if (( ${#hw_decode_args[@]} > 0 )); then
        decode_label="${hw_decode_args[*]}"
    else
        decode_label="software (pure CPU)"
    fi
    printf "${C_CYAN}[INFO] Decode hwaccel   : %s\n${C_RESET}" "$decode_label"

    # ── Parallel throttle ─────────────────────────────────────────────────
    case "$selected_stack" in
        NVIDIA-NVENC)
            # Reserve ~2 GB for OS/display; each NVENC AV1 session ~2.5 GB; cap 4
            local usable=$(( vram_mb > 2048 ? vram_mb - 2048 : 0 ))
            max_parallel="$(clamp $(( usable / 2560 )) 1 4)"
            ;;
        INTEL-QSV)
            # Detect discrete Arc GPU via lspci for VRAM-based formula;
            # iGPU falls back to a conservative fixed limit of 2.
            local is_arc_gpu=false
            if command -v lspci > /dev/null 2>&1; then
                lspci 2>/dev/null | grep -qiE 'Intel.*(Arc|A[0-9]{3})' \
                    && is_arc_gpu=true || true
            fi
            if [[ "$is_arc_gpu" == true ]] && (( vram_mb > 0 )); then
                local usable=$(( vram_mb > 1024 ? vram_mb - 1024 : 0 ))
                max_parallel="$(clamp $(( usable / 1536 )) 1 4)"
            else
                max_parallel=2
            fi
            ;;
        AMD-AMF)
            # Each AMF AV1 session ~1.5 GB; reserve 1 GB for display; cap 4
            if (( vram_mb > 0 )); then
                local usable=$(( vram_mb > 1024 ? vram_mb - 1024 : 0 ))
                max_parallel="$(clamp $(( usable / 1536 )) 1 4)"
            else
                max_parallel=2
            fi
            ;;
        APPLE-VTB)
            max_parallel=2
            ;;
        SW-*)
            # CPU-bound: one job per 4 logical cores, capped at 4
            max_parallel="$(clamp $(( cpu_cores / 4 )) 1 4)"
            ;;
    esac

    if (( vram_mb > 0 )); then
        printf "${C_CYAN}[INFO] GPU VRAM         : %s  →  Max parallel encodes: %d\n${C_RESET}" \
            "$(format_bytes $(( vram_mb * 1048576 )))" "$max_parallel"
    else
        printf "${C_CYAN}[INFO] Max parallel     : %d\n${C_RESET}" "$max_parallel"
    fi

    # =========================================================================
    # STEP 4: Content × Resolution profile table
    # =========================================================================
    # Each profile is stored as a set of eight parallel associative arrays
    # keyed by "<ContentType>-<ResTier>".  Using one array per field avoids
    # nested-hashtable syntax (which bash doesn't support natively) and keeps
    # lookups simple: PROF_CQ[Movie-HD], PROF_PRESET[Movie-HD], etc.
    #
    # Resolution tier thresholds (total pixels = width × height):
    #   8K+  : > 8,847,360   (above DCI 4K, 4096×2160)
    #   4K   : > 3,686,400   (above QHD 2560×1440, up to DCI 4K)
    #   2K   : > 2,073,600   (above 1080p 1920×1080, up to QHD)
    #   HD   : >   921,600   (above 720p 1280×720, up to 1080p)
    #   SD   : ≤   921,600   (720p and below)
    #
    # Background subshells (parallel encode jobs in STEP 6) inherit these
    # arrays via bash's fork-copy semantics — no explicit serialization needed.
    # Mirrors ps1 lines 543–640.
    # =========================================================================

    # ── MOVIE — cinematic quality, resolution-aware presets ───────────────
    local -A PROF_CQ=(
        [Movie-SD]=26  [Movie-HD]=24  [Movie-2K]=23  [Movie-4K]=22  [Movie-8K+]=24
        [Show-SD]=30   [Show-HD]=32   [Show-2K]=31   [Show-4K]=28   [Show-8K+]=30
        [Sports-SD]=26 [Sports-HD]=28 [Sports-2K]=27 [Sports-4K]=26 [Sports-8K+]=28
        [General-SD]=28 [General-HD]=30 [General-2K]=29 [General-4K]=27 [General-8K+]=28
    )
    local -A PROF_PRESET=(
        [Movie-SD]=p5  [Movie-HD]=p6  [Movie-2K]=p6  [Movie-4K]=p7  [Movie-8K+]=p7
        [Show-SD]=p4   [Show-HD]=p5   [Show-2K]=p5   [Show-4K]=p6   [Show-8K+]=p6
        [Sports-SD]=p4 [Sports-HD]=p5 [Sports-2K]=p5 [Sports-4K]=p5 [Sports-8K+]=p5
        [General-SD]=p4 [General-HD]=p5 [General-2K]=p5 [General-4K]=p6 [General-8K+]=p6
    )
    local -A PROF_LOOKAHEAD=(
        [Movie-SD]=32  [Movie-HD]=48  [Movie-2K]=56  [Movie-4K]=64  [Movie-8K+]=64
        [Show-SD]=24   [Show-HD]=32   [Show-2K]=40   [Show-4K]=48   [Show-8K+]=48
        [Sports-SD]=20 [Sports-HD]=32 [Sports-2K]=32 [Sports-4K]=32 [Sports-8K+]=32
        [General-SD]=24 [General-HD]=40 [General-2K]=48 [General-4K]=56 [General-8K+]=56
    )
    local -A PROF_SPATIAL_AQ=(
        [Movie-SD]=1  [Movie-HD]=1  [Movie-2K]=1  [Movie-4K]=1  [Movie-8K+]=1
        [Show-SD]=1   [Show-HD]=1   [Show-2K]=1   [Show-4K]=1   [Show-8K+]=1
        [Sports-SD]=1 [Sports-HD]=1 [Sports-2K]=1 [Sports-4K]=1 [Sports-8K+]=1
        [General-SD]=1 [General-HD]=1 [General-2K]=1 [General-4K]=1 [General-8K+]=1
    )
    local -A PROF_TEMPORAL_AQ=(
        [Movie-SD]=1  [Movie-HD]=1  [Movie-2K]=1  [Movie-4K]=1  [Movie-8K+]=1
        [Show-SD]=1   [Show-HD]=1   [Show-2K]=1   [Show-4K]=1   [Show-8K+]=1
        [Sports-SD]=1 [Sports-HD]=1 [Sports-2K]=1 [Sports-4K]=1 [Sports-8K+]=1
        [General-SD]=1 [General-HD]=1 [General-2K]=1 [General-4K]=1 [General-8K+]=1
    )
    local -A PROF_AQ_STRENGTH=(
        [Movie-SD]=10  [Movie-HD]=13  [Movie-2K]=14  [Movie-4K]=15  [Movie-8K+]=15
        [Show-SD]=7    [Show-HD]=8    [Show-2K]=9    [Show-4K]=12   [Show-8K+]=12
        [Sports-SD]=9  [Sports-HD]=10 [Sports-2K]=11 [Sports-4K]=12 [Sports-8K+]=12
        [General-SD]=8 [General-HD]=10 [General-2K]=11 [General-4K]=13 [General-8K+]=13
    )
    local -A PROF_MULTIPASS=(
        [Movie-SD]=disabled  [Movie-HD]=qres  [Movie-2K]=qres  [Movie-4K]=qres  [Movie-8K+]=qres
        [Show-SD]=disabled   [Show-HD]=disabled [Show-2K]=disabled [Show-4K]=qres [Show-8K+]=qres
        [Sports-SD]=disabled [Sports-HD]=disabled [Sports-2K]=disabled [Sports-4K]=disabled [Sports-8K+]=disabled
        [General-SD]=disabled [General-HD]=disabled [General-2K]=disabled [General-4K]=qres [General-8K+]=qres
    )
    local -A PROF_DESC=(
        [Movie-SD]="Movie SD: older/archival film, balanced quality for low-res masters"
        [Movie-HD]="Movie HD: high-fidelity 1080p, strong AQ, fine grain and shadow detail"
        [Movie-2K]="Movie 2K: DCI 2K / QHD cinema, near-maximum quality"
        [Movie-4K]="Movie 4K: UHD/DCI 4K HDR feature film, maximum quality, slowest preset"
        [Movie-8K+]="Movie 8K+: beyond DCI 4K, max preset/lookahead, slight CQ relaxation"
        [Show-SD]="Show SD: older SD broadcast, fast encode, moderate quality"
        [Show-HD]="Show HD: standard 1080p broadcast, efficient compression"
        [Show-2K]="Show 2K: QHD streaming series, slightly higher fidelity than HD"
        [Show-4K]="Show 4K: premium UHD streaming (HDR series), strong quality"
        [Show-8K+]="Show 8K+: future-format streaming, balanced quality/file-size"
        [Sports-SD]="Sports SD: fast-motion SD footage, minimal lookahead for speed"
        [Sports-HD]="Sports HD: 1080p sports, aggressive AQ, moderate lookahead"
        [Sports-2K]="Sports 2K: QHD sports broadcast, slightly tighter quality than HD"
        [Sports-4K]="Sports 4K: UHD sports (fine crowd/grass detail), strong AQ"
        [Sports-8K+]="Sports 8K+: future-format sports, balanced quality at high resolution"
        [General-SD]="General SD: mixed unknown SD content, conservative quality"
        [General-HD]="General HD: versatile 1080p profile for mixed content"
        [General-2K]="General 2K: mixed QHD/1440p content, slightly increased quality"
        [General-4K]="General 4K: mixed UHD content, high quality, multipass"
        [General-8K+]="General 8K+: mixed 8K+ content, balanced quality at extreme resolution"
    )

    # ── Space-favor overrides (CQ +4, preset +1; all other params identical) ─
    local -A PROF_SPACE_CQ=(
        [Movie-SD]=30  [Movie-HD]=28  [Movie-2K]=27  [Movie-4K]=26  [Movie-8K+]=28
        [Show-SD]=34   [Show-HD]=36   [Show-2K]=35   [Show-4K]=32   [Show-8K+]=34
        [Sports-SD]=30 [Sports-HD]=32 [Sports-2K]=31 [Sports-4K]=30 [Sports-8K+]=32
        [General-SD]=32 [General-HD]=34 [General-2K]=33 [General-4K]=31 [General-8K+]=32
    )
    local -A PROF_SPACE_PRESET=(
        [Movie-SD]=p6  [Movie-HD]=p7  [Movie-2K]=p7  [Movie-4K]=p7  [Movie-8K+]=p7
        [Show-SD]=p5   [Show-HD]=p6   [Show-2K]=p6   [Show-4K]=p7   [Show-8K+]=p7
        [Sports-SD]=p5 [Sports-HD]=p6 [Sports-2K]=p6 [Sports-4K]=p6 [Sports-8K+]=p6
        [General-SD]=p5 [General-HD]=p6 [General-2K]=p6 [General-4K]=p7 [General-8K+]=p7
    )

    # ── Validate all 20 profiles have all 8 required field entries ────────
    # A missing entry produces a silent empty-string lookup in the encode
    # block, which is the same silent-failure risk as PS1's $null dereference.
    # Mirrors ps1 lines 631–640.
    local -a required_profile_keys=(
        Movie-SD Movie-HD Movie-2K Movie-4K "Movie-8K+"
        Show-SD  Show-HD  Show-2K  Show-4K  "Show-8K+"
        Sports-SD Sports-HD Sports-2K Sports-4K "Sports-8K+"
        General-SD General-HD General-2K General-4K "General-8K+"
    )
    local -a required_field_arrays=(
        PROF_CQ PROF_PRESET PROF_LOOKAHEAD PROF_SPATIAL_AQ
        PROF_TEMPORAL_AQ PROF_AQ_STRENGTH PROF_MULTIPASS PROF_DESC
        PROF_SPACE_CQ PROF_SPACE_PRESET
    )

    local profile_key field_array missing_fields=()
    for profile_key in "${required_profile_keys[@]}"; do
        for field_array in "${required_field_arrays[@]}"; do
            # Use nameref (bash 4.3+) for indirect array lookup
            local -n _arr_ref="$field_array"
            if [[ -z "${_arr_ref[$profile_key]+isset}" ]]; then
                missing_fields+=("$field_array[$profile_key]")
            fi
            unset -n _arr_ref
        done
    done

    if (( ${#missing_fields[@]} > 0 )); then
        printf "${C_RED}[ERROR] Content profile table is incomplete. Missing field(s):\n${C_RESET}" >&2
        local f; for f in "${missing_fields[@]}"; do
            printf "${C_YELLOW}    • %s\n${C_RESET}" "$f" >&2
        done
        exit 1
    fi

    # ── Log content/override settings (mirrors ps1 lines 648–650) ────────
    printf "\n${C_CYAN}[INFO] Content type     : %s (profile resolved per-file from source resolution)\n${C_RESET}" \
        "$CONTENT"
    printf "${C_CYAN}[INFO] Favor            : %s\n${C_RESET}" \
        "$( [[ "$FAVOR" == space ]] && printf "space (space profiles active — CQ +4, preset +1)" || printf "quality (quality profiles active)" )"
    printf "${C_CYAN}[INFO] CQ override      : %s\n${C_RESET}" \
        "$( if [[ "$HAS_CQ_OVERRIDE" == true ]]; then printf "%s" "$CQ"
            elif [[ "$HAS_CQ_ADJUST" == true ]]; then printf "adjust %+d (clamped 0–51)" "$ADJUST_CQ"
            else printf "none — using profile default"; fi )"
    printf "${C_CYAN}[INFO] Preset override  : %s\n${C_RESET}" \
        "$( if [[ "$HAS_PRESET_OVERRIDE" == true ]]; then printf "%s" "$PRESET"
            elif [[ "$HAS_PRESET_ADJUST" == true ]]; then printf "adjust %+d (clamped p1–p7)" "$ADJUST_PRESET"
            else printf "none — using profile default"; fi )"

    # =========================================================================
    # SESSION SETUP — directories, master log, lock file, results temp dir
    # Mirrors ps1 lines 664–706.
    # =========================================================================
    local dir
    for dir in "$TARGET_DIR" "$LOG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            if ! mkdir -p "$dir"; then
                printf "${C_RED}[ERROR] Could not create directory '%s'\n${C_RESET}" "$dir" >&2
                exit 1
            fi
        fi
    done

    local master_log="$LOG_DIR/encode_session_${SESSION_STAMP}.log"
    if ! touch "$master_log"; then
        printf "${C_RED}[ERROR] Could not create master log '%s'\n${C_RESET}" "$master_log" >&2
        exit 1
    fi

    # flock sentinel — set global so log() and background subshells find it
    LOG_LOCK_FILE="$LOG_DIR/.mucus_log.lock"
    touch "$LOG_LOCK_FILE"
    export LOG_LOCK_FILE

    # Optional error log
    if [[ "$EXPORT_ERROR" != "NONE" ]]; then
        ERROR_LOG_PATH="$LOG_DIR/ErrorLog_${SESSION_STAMP}.log"
        export ERROR_LOG_PATH
    fi
    export EXPORT_ERROR  # log() in background encode subprocesses reads this
    export FAVOR

    # Results temp directory — one tab-separated record file per processed file.
    # Resume results written here during pre-flight; encode results written here
    # by each background encode job.  Step 7 reads all records to build the summary.
    # Record field order (11 fields, tab-separated):
    #   rel_path, src_file, tgt_file, src_size, tgt_size,
    #   src_action, tgt_action, was_av1mkv, transcoded, status, savings_pct
    RESULTS_DIR="$(mktemp -d)"
    export RESULTS_DIR

    # Cleanup on any exit — mirrors PS1's finally { logMutex.Dispose() }
    trap 'rm -rf "${RESULTS_DIR:-}" 2>/dev/null; rm -f "${LOG_LOCK_FILE:-}" 2>/dev/null' EXIT

    # ── Session header ────────────────────────────────────────────────────
    local sep; printf -v sep '=%.0s' {1..60}
    log "$sep"                                                     INFO "$master_log"
    log "  Video Re-encode Session Started"                        INFO "$master_log"
    log "  Bash      : ${BASH_VERSION}"                            INFO "$master_log"
    log "  FFmpeg    : $ffmpeg_bin"                                INFO "$master_log"
    log "  FFprobe   : $ffprobe_bin"                               INFO "$master_log"
    log "  Source    : $SOURCE_DIR"                                INFO "$master_log"
    log "  Target    : $TARGET_DIR"                                INFO "$master_log"
    log "  Logs      : $LOG_DIR"                                   INFO "$master_log"
    log "  HW Stack  : $selected_stack ($hw_vendor)"               INFO "$master_log"
    log "  Decode    : $decode_label"                              INFO "$master_log"
    log "  HW APIs   : ${api_list:-none detected}"                 INFO "$master_log"
    log "  AV1 Encs  : ${enc_list:-none}"                          INFO "$master_log"
    log "  Content   : $CONTENT (profile resolved per-file)"       INFO "$master_log"
    log "  Favor     : $( [[ "$FAVOR" == space ]] && printf 'space (CQ +4, preset +1)' || printf 'quality' )" \
                                                                   INFO "$master_log"
    log "  CQ        : $( if [[ "$HAS_CQ_OVERRIDE" == true ]]; then printf '%s (CLI override)' "$CQ"
                          elif [[ "$HAS_CQ_ADJUST" == true ]]; then printf 'adjust %+d (clamped 0–51)' "$ADJUST_CQ"
                          else printf 'profile default (per-file)'; fi )" \
                                                                   INFO "$master_log"
    log "  Preset    : $( if [[ "$HAS_PRESET_OVERRIDE" == true ]]; then printf '%s (CLI override)' "$PRESET"
                          elif [[ "$HAS_PRESET_ADJUST" == true ]]; then printf 'adjust %+d (clamped p1–p7)' "$ADJUST_PRESET"
                          else printf 'profile default (per-file)'; fi )" \
                                                                   INFO "$master_log"
    log "  OnComplete: $ON_COMPLETE"                               INFO "$master_log"
    log "  Parallel  : $max_parallel"                              INFO "$master_log"
    log "$sep"                                                     INFO "$master_log"

    # =========================================================================
    # STEP 5: Discover all video files
    # Recursive scan by extension; NUL-delimited find output handles filenames
    # with spaces.  Mirrors ps1 lines 708–724.
    # =========================================================================
    local -a video_exts=(
        mp4 mov mkv avi wmv flv webm m4v mpg mpeg
        mts m2ts ts vob ogv 3gp 3g2 divx xvid f4v
        rmvb rm asf mxf dv gxf qt hevc h264 h265
    )

    # Build find -iname expression: ( -iname "*.ext1" -o -iname "*.ext2" ... )
    local -a find_expr=()
    local first_ext=true ext
    for ext in "${video_exts[@]}"; do
        if [[ "$first_ext" == true ]]; then
            find_expr+=(-iname "*.${ext}")
            first_ext=false
        else
            find_expr+=(-o -iname "*.${ext}")
        fi
    done

    local -a source_files=()
    while IFS= read -r -d $'\0' f; do
        source_files+=("$f")
    done < <(find "$SOURCE_DIR" -type f \( "${find_expr[@]}" \) -print0 | sort -z)

    local src_count="${#source_files[@]}"
    if (( src_count == 0 )); then
        log "No video files found in '$SOURCE_DIR'." WARN "$master_log"
        exit 0
    fi
    log "Found $src_count video file(s) in source directory." INFO "$master_log"

    # =========================================================================
    # STEP 5.5a: Base-name collision detection
    # Files sharing a case-insensitive (parent-dir, basename-without-ext) pair
    # would map to the same target .mkv — they receive disambiguated names.
    # Mirrors ps1 lines 727–757.
    # =========================================================================

    # Pass 1 — count files per collision key
    local -A _coll_count=()
    local src_file parent_lc base_lc coll_key
    for src_file in "${source_files[@]}"; do
        parent_lc="$(dirname  "$src_file" | tr '[:upper:]' '[:lower:]')"
        base_lc="$(  basename "$src_file" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]')"
        coll_key="${parent_lc}|||${base_lc}"
        _coll_count[$coll_key]=$(( ${_coll_count[$coll_key]:-0} + 1 ))
    done

    # Pass 2 — mark conflicted files and count groups
    local -A conflicted_files=()  # full_path → 1 for files in a collision group
    local -A _seen_groups=()
    local collision_groups=0
    for src_file in "${source_files[@]}"; do
        parent_lc="$(dirname  "$src_file" | tr '[:upper:]' '[:lower:]')"
        base_lc="$(  basename "$src_file" | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]')"
        coll_key="${parent_lc}|||${base_lc}"
        if (( ${_coll_count[$coll_key]} > 1 )); then
            conflicted_files[$src_file]=1
            if [[ -z "${_seen_groups[$coll_key]+x}" ]]; then
                collision_groups=$(( collision_groups + 1 ))
                _seen_groups[$coll_key]=1
            fi
        fi
    done
    unset _coll_count _seen_groups

    local conflict_file_count="${#conflicted_files[@]}"
    if (( collision_groups > 0 )); then
        printf "${C_YELLOW}[WARN] Base-name collisions: %d file(s) across %d group(s) — disambiguated target names will be used.\n${C_RESET}" \
            "$conflict_file_count" "$collision_groups"
        log "Base-name collisions: $conflict_file_count file(s) in $collision_groups group(s) — using disambiguated names (e.g. file1-(mp4).mkv)." \
            WARN "$master_log"
    fi

    # =========================================================================
    # STEP 5.5: Pre-flight resume check
    # Validates any existing target before treating it as a completed encode.
    # Mirrors ps1 lines 759–918.
    # =========================================================================

    local -a files_to_encode=()
    local -a resume_conflicts=()
    local resumed_count=0
    local result_seq=0
    local -a probe_flags=(-v quiet -print_format json -show_format -show_streams)

    log "Running pre-flight resume check on $src_count file(s)..." INFO "$master_log"

    for src_file in "${source_files[@]}"; do

        # ── Derive relative path and target path ──────────────────────────
        local rel_path="${src_file#"$SOURCE_DIR"/}"
        local rel_dir;  rel_dir="$(dirname "$rel_path")"
        local base_noext src_ext tgt_dir tgt_name tgt_file

        base_noext="$(basename "$src_file")"; base_noext="${base_noext%.*}"
        src_ext="${src_file##*.}"; src_ext="${src_ext,,}"

        if [[ "$rel_dir" == "." ]]; then tgt_dir="$TARGET_DIR"
        else                              tgt_dir="$TARGET_DIR/$rel_dir"
        fi

        if [[ -n "${conflicted_files[$src_file]+x}" ]]; then
            tgt_name="${base_noext}-(${src_ext}).mkv"
        else
            tgt_name="${base_noext}.mkv"
        fi
        tgt_file="$tgt_dir/$tgt_name"

        # ── No target yet — queue for encoding ───────────────────────────
        if [[ ! -f "$tgt_file" ]]; then
            files_to_encode+=("$src_file")
            continue
        fi

        # ── Target exists — probe both files ─────────────────────────────
        local src_size tgt_size
        src_size="$(_file_size "$src_file")"
        tgt_size="$(_file_size "$tgt_file")"

        local tgt_probe_json src_probe_json
        tgt_probe_json="$("$ffprobe_bin" "${probe_flags[@]}" "$tgt_file" 2>/dev/null || true)"
        src_probe_json="$("$ffprobe_bin" "${probe_flags[@]}" "$src_file" 2>/dev/null || true)"

        local tgt_codec=""
        tgt_codec="$(jq -r '([.streams[]|select(.codec_type=="video")]|first|.codec_name)//"" ' \
                     <<< "$tgt_probe_json" 2>/dev/null || true)"

        local src_audio_cnt=0 tgt_audio_cnt=0 src_sub_cnt=0 tgt_sub_cnt=0
        src_audio_cnt="$(jq '[.streams[]|select(.codec_type=="audio")]|length'    <<< "$src_probe_json" 2>/dev/null || echo 0)"
        tgt_audio_cnt="$(jq '[.streams[]|select(.codec_type=="audio")]|length'    <<< "$tgt_probe_json" 2>/dev/null || echo 0)"
        src_sub_cnt="$(  jq '[.streams[]|select(.codec_type=="subtitle")]|length' <<< "$src_probe_json" 2>/dev/null || echo 0)"
        tgt_sub_cnt="$(  jq '[.streams[]|select(.codec_type=="subtitle")]|length' <<< "$tgt_probe_json" 2>/dev/null || echo 0)"

        local src_dur tgt_dur
        src_dur="$(jq -r '.format.duration//"0"' <<< "$src_probe_json" 2>/dev/null || echo 0)"
        tgt_dur="$(jq -r '.format.duration//"0"' <<< "$tgt_probe_json" 2>/dev/null || echo 0)"
        src_dur="${src_dur:-0}"; tgt_dur="${tgt_dur:-0}"

        # ── Validation flags ──────────────────────────────────────────────
        local is_av1=false is_mkv=false dur_match=false size_ok=false probe_ok=false

        [[ "$tgt_codec" == "av1" ]] && is_av1=true
        [[ "$tgt_file"  == *.mkv ]] && is_mkv=true   # target paths are always *.mkv
        [[ -n "$tgt_codec"       ]] && probe_ok=true
        dur_match="$(awk "BEGIN { d=$src_dur - $tgt_dur; if(d<0)d=-d; print (d<=1.0)?\"true\":\"false\" }")"

        local min_size=$(( src_size / 100 ))
        (( min_size < 1 )) && min_size=1
        if (( tgt_size > min_size )); then size_ok=true; fi

        local is_valid=false
        [[ "$is_av1" == true && "$is_mkv" == true && "$dur_match" == true && \
           "$size_ok" == true && "$probe_ok" == true ]] && is_valid=true

        # ── Invalid target → record conflict, abort later ─────────────────
        if [[ "$is_valid" != true ]]; then
            local -a reasons=()
            [[ "$probe_ok"  != true ]] && reasons+=("target unreadable by FFprobe")
            [[ "$is_mkv"    != true ]] && reasons+=("target is not an MKV container")
            [[ "$is_av1"    != true ]] && reasons+=("target video codec is '${tgt_codec:-unknown}', not AV1")
            [[ "$dur_match" != true ]] && reasons+=("duration mismatch: source=${src_dur}s target=${tgt_dur}s")
            [[ "$size_ok"   != true ]] && reasons+=("target suspiciously small (${tgt_size} bytes vs source ${src_size} bytes)")
            local reason_str
            printf -v reason_str '%s; ' "${reasons[@]}"
            resume_conflicts+=("  [$rel_path] — ${reason_str%; }")
            continue
        fi

        # ── Stream count warnings (non-blocking) ─────────────────────────
        if (( src_audio_cnt != tgt_audio_cnt )); then
            log "RESUME WARN [$rel_path]: audio stream count differs (source=$src_audio_cnt target=$tgt_audio_cnt)" \
                WARN "$master_log"
        fi
        if (( src_sub_cnt != tgt_sub_cnt )); then
            log "RESUME WARN [$rel_path]: subtitle stream count differs (source=$src_sub_cnt target=$tgt_sub_cnt)" \
                WARN "$master_log"
        fi

        local savings_pct
        savings_pct="$(awk -v s="$src_size" -v t="$tgt_size" 'BEGIN { if(s>0) printf "%.1f",(1-t/s)*100; else print "0.0" }')"

        # ── OnComplete handling for already-encoded files ─────────────────
        local src_action="Unchanged" tgt_action="AlreadyEncoded"

        case "$ON_COMPLETE" in
            Delete)
                if [[ "$DRY_RUN" == true ]]; then
                    src_action="WhatIf-Delete"
                else
                    rm -f "$src_file"
                    src_action="Deleted"
                    log "RESUME: Source deleted (OnComplete=Delete): $rel_path" INFO "$master_log"
                    local src_parent; src_parent="$(dirname "$src_file")"
                    rmdir "$src_parent" 2>/dev/null || true
                fi
                ;;
            Replace)
                local replace_dest; replace_dest="$(dirname "$src_file")/$tgt_name"
                if [[ -e "$replace_dest" && "$replace_dest" != "$src_file" ]]; then
                    log "RESUME WARN [$rel_path]: Replace blocked — '$(basename "$replace_dest")' already exists as a different file. Source preserved." \
                        WARN "$master_log"
                    src_action="Preserved-NameConflict"
                elif [[ "$DRY_RUN" == true ]]; then
                    src_action="WhatIf-Replace"
                else
                    # Move target first, copy timestamps from source, then delete source
                    mv -f "$tgt_file" "$replace_dest"
                    touch -r "$src_file" "$replace_dest" 2>/dev/null || true
                    rm -f "$src_file"
                    tgt_file="$replace_dest"
                    tgt_action="MovedToSource"
                    src_action="Replaced"
                    log "RESUME: Encode moved to source dir, original deleted (OnComplete=Replace): $rel_path" \
                        INFO "$master_log"
                fi
                ;;
        esac

        log "RESUME: Already encoded — $rel_path (${savings_pct}% savings)" INFO "$master_log"

        # ── Write result record ───────────────────────────────────────────
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$rel_path" "$src_file" "$tgt_file" \
            "$src_size" "$tgt_size" \
            "$src_action" "$tgt_action" \
            "false" "false" "Resumed" "$savings_pct" \
            > "$RESULTS_DIR/result_$(printf '%08d' "$result_seq").rec"
        result_seq=$(( result_seq + 1 ))
        resumed_count=$(( resumed_count + 1 ))
    done

    # ── Abort if any existing targets failed validation ───────────────────
    if (( ${#resume_conflicts[@]} > 0 )); then
        log "ABORT: ${#resume_conflicts[@]} file(s) could not be verified as valid re-encodes:" \
            ERROR "$master_log"
        printf "\n${C_RED}[ERROR] Pre-flight check failed — unrecognized file(s) found in target directory:\n${C_RESET}" >&2
        local conflict
        for conflict in "${resume_conflicts[@]}"; do
            log "$conflict" ERROR "$master_log"
            printf "${C_YELLOW}%s\n${C_RESET}" "$conflict" >&2
        done
        printf "\n${C_YELLOW}    Resolve or remove the conflicting file(s) above, then re-run.\n\n${C_RESET}" >&2
        exit 1
    fi

    local files_to_encode_count="${#files_to_encode[@]}"
    log "Pre-flight complete: $resumed_count resumed, $files_to_encode_count queued for encoding." \
        INFO "$master_log"

    # =========================================================================
    # STEP 6: Parallel encode loop
    # =========================================================================
    # ── Counting semaphore (FIFO + file descriptor) ────────────────────────
    # Pre-load max_parallel "tokens"; each worker reads one token before
    # starting (blocks when all slots are in use) and writes one back on exit.
    local _sem_fifo
    _sem_fifo="$(mktemp -u)"
    mkfifo "$_sem_fifo"
    exec 9<>"$_sem_fifo"
    rm -f "$_sem_fifo"
    local _si
    for (( _si = 0; _si < max_parallel; _si++ )); do printf 'x' >&9; done
    unset _si

    # Extend cleanup trap to also close the semaphore fd on exit
    trap 'exec 9>&- 2>/dev/null || true
          rm -rf "${RESULTS_DIR:-}" 2>/dev/null
          rm -f  "${LOG_LOCK_FILE:-}" 2>/dev/null' EXIT

    # ── Per-file encode worker ─────────────────────────────────────────────
    # Runs in a background subshell forked from mucus(); inherits all local
    # variables (PROF_* arrays, conflicted_files, selected_stack, etc.) via
    # bash fork-copy semantics.  No serialization or export is needed.
    # Arguments:
    #   $1  absolute path to the source video file
    #   $2  path of the pre-created result .rec file to write on completion
    encode_one_file() {
        local _src_file="$1"
        local _rec_file="$2"
        local _ts_ref=""

        # Release semaphore token + clean up timestamp reference on any exit
        trap 'printf "x" >&9 2>/dev/null || true
              rm -f "${_ts_ref:-}" 2>/dev/null' EXIT

        # Save source timestamps before any file operations that might move/
        # delete the original — used later to propagate mtime to the output.
        if [[ -f "$_src_file" ]]; then
            _ts_ref="$(mktemp 2>/dev/null)" \
                && touch -r "$_src_file" "$_ts_ref" 2>/dev/null \
                || { rm -f "${_ts_ref:-}" 2>/dev/null; _ts_ref=""; }
        fi

        # ── Derive target and per-file log paths ────────────────────────────
        local _rel_path="${_src_file#"$SOURCE_DIR"/}"
        local _rel_dir;  _rel_dir="$(dirname "$_rel_path")"
        local _base_noext="${_src_file##*/}"; _base_noext="${_base_noext%.*}"
        local _src_ext="${_src_file##*.}";    _src_ext="${_src_ext,,}"

        local _tgt_dir _tgt_name _tgt_file
        if [[ "$_rel_dir" == "." ]]; then _tgt_dir="$TARGET_DIR"
        else                               _tgt_dir="$TARGET_DIR/$_rel_dir"
        fi

        if [[ -n "${conflicted_files[$_src_file]+x}" ]]; then
            _tgt_name="${_base_noext}-(${_src_ext}).mkv"
        else
            _tgt_name="${_base_noext}.mkv"
        fi
        _tgt_file="$_tgt_dir/$_tgt_name"

        local _log_rel_dir
        if [[ "$_rel_dir" == "." ]]; then _log_rel_dir="$_base_noext"
        else                               _log_rel_dir="$_rel_dir/$_base_noext"
        fi
        local _file_log_dir="$LOG_DIR/$_log_rel_dir"
        local _file_log="$_file_log_dir/${_base_noext}_encode_${SESSION_STAMP}.log"

        # ── Result record field defaults ─────────────────────────────────────
        local _r_src_size; _r_src_size="$(_file_size "$_src_file")"
        local _r_tgt_size=0
        local _r_src_action="Unchanged"
        local _r_tgt_action="Pending"
        local _r_was_av1mkv="false"
        local _r_transcoded="false"
        local _r_status="Pending"
        local _r_savings="0.0"

        # Inner helper — write tab-separated result record to pre-allocated file
        _write_rec() {
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_rel_path" "$_src_file" "$_tgt_file" \
                "$_r_src_size" "$_r_tgt_size" \
                "$_r_src_action" "$_r_tgt_action" \
                "$_r_was_av1mkv" "$_r_transcoded" \
                "$_r_status" "$_r_savings" \
                > "$_rec_file"
        }

        # ── Create required directories ──────────────────────────────────────
        local _mkd
        for _mkd in "$_tgt_dir" "$_file_log_dir"; do
            if [[ ! -d "$_mkd" ]] && ! mkdir -p "$_mkd" 2>/dev/null; then
                log "ERROR — Could not create directory '$_mkd'" ERROR "$master_log"
                _r_status="Exception"; _r_tgt_action="Failed"
                _write_rec; return 1
            fi
        done

        # ── FFprobe source file ──────────────────────────────────────────────
        local _probe_json
        _probe_json="$("$ffprobe_bin" -v quiet -print_format json \
                       -show_format -show_streams "$_src_file" 2>/dev/null || true)"
        if [[ -z "$_probe_json" ]]; then
            log "SKIPPED (FFprobe parse failed — invalid or empty output): $_rel_path" WARN "$master_log"
            _r_status="Skipped-ProbeError"; _r_tgt_action="None"
            _write_rec; return 0
        fi

        local _vid_codec
        _vid_codec="$(jq -r \
            '([.streams[]|select(.codec_type=="video")]|first|.codec_name)//"" ' \
            <<< "$_probe_json" 2>/dev/null || true)"
        if [[ -z "$_vid_codec" ]]; then
            log "SKIPPED (no video stream): $_rel_path" WARN "$master_log"
            _r_status="Skipped-NoVideo"; _r_tgt_action="None"
            _write_rec; return 0
        fi

        local _src_w _src_h _has_audio _has_sub _has_att
        _src_w="$(jq -r \
            '([.streams[]|select(.codec_type=="video")]|first|.width)//0' \
            <<< "$_probe_json" 2>/dev/null || echo 0)"
        _src_h="$(jq -r \
            '([.streams[]|select(.codec_type=="video")]|first|.height)//0' \
            <<< "$_probe_json" 2>/dev/null || echo 0)"
        _has_audio="$(jq \
            '([.streams[]|select(.codec_type=="audio")]|length)>0' \
            <<< "$_probe_json" 2>/dev/null || echo false)"
        _has_sub="$(jq \
            '([.streams[]|select(.codec_type=="subtitle")]|length)>0' \
            <<< "$_probe_json" 2>/dev/null || echo false)"
        _has_att="$(jq \
            '([.streams[]|select(.codec_type=="attachment")]|length)>0' \
            <<< "$_probe_json" 2>/dev/null || echo false)"

        # ── Resolution tier ──────────────────────────────────────────────────
        local _pixels=$(( _src_w * _src_h ))
        local _res_tier
        if   (( _pixels > 8847360 )); then _res_tier="8K+"
        elif (( _pixels > 3686400 )); then _res_tier="4K"
        elif (( _pixels > 2073600 )); then _res_tier="2K"
        elif (( _pixels >  921600 )); then _res_tier="HD"
        else                               _res_tier="SD"
        fi

        local _prof_key="${CONTENT}-${_res_tier}"
        if [[ -z "${PROF_CQ[$_prof_key]+x}" ]]; then
            _prof_key="General-HD"
            log "[$_rel_path] Profile '$CONTENT-$_res_tier' not found; falling back to General-HD." \
                WARN "$master_log"
        fi

        local _eff_cq _eff_preset
        local _base_cq
        if [[ "${FAVOR:-quality}" == space ]]; then
            _base_cq="${PROF_SPACE_CQ[$_prof_key]}"
        else
            _base_cq="${PROF_CQ[$_prof_key]}"
        fi

        if [[ "$HAS_CQ_OVERRIDE" == true ]]; then
            _eff_cq="${CQ}"
        elif [[ "$HAS_CQ_ADJUST" == true ]]; then
            local _adj_cq=$(( _base_cq + ADJUST_CQ ))
            (( _adj_cq < 0  )) && _adj_cq=0
            (( _adj_cq > 51 )) && _adj_cq=51
            _eff_cq="$_adj_cq"
        else
            _eff_cq="$_base_cq"
        fi
        local _base_preset
        if [[ "${FAVOR:-quality}" == space ]]; then
            _base_preset="${PROF_SPACE_PRESET[$_prof_key]}"
        else
            _base_preset="${PROF_PRESET[$_prof_key]}"
        fi

        if [[ "$HAS_PRESET_OVERRIDE" == true ]]; then
            _eff_preset="${PRESET}"
        elif [[ "$HAS_PRESET_ADJUST" == true ]]; then
            local _base_num="${_base_preset#p}"
            local _adj_preset=$(( _base_num + ADJUST_PRESET ))
            (( _adj_preset < 1 )) && _adj_preset=1
            (( _adj_preset > 7 )) && _adj_preset=7
            _eff_preset="p${_adj_preset}"
        else
            _eff_preset="$_base_preset"
        fi

        local _lookahead="${PROF_LOOKAHEAD[$_prof_key]}"
        local _spatial_aq="${PROF_SPATIAL_AQ[$_prof_key]}"
        local _temporal_aq="${PROF_TEMPORAL_AQ[$_prof_key]}"
        local _aq_strength="${PROF_AQ_STRENGTH[$_prof_key]}"
        local _multipass="${PROF_MULTIPASS[$_prof_key]}"

        # ── Build stack-specific encode arguments ────────────────────────────
        local -a _enc_args=()
        case "$selected_stack" in
            NVIDIA-NVENC)
                _enc_args=(
                    -c:v av1_nvenc
                    -cq          "$_eff_cq"
                    -preset      "$_eff_preset"
                    -b:v 0
                    -rc-lookahead "$_lookahead"
                    -spatial_aq  "$_spatial_aq"
                    -temporal_aq "$_temporal_aq"
                    -aq-strength "$_aq_strength"
                )
                [[ "$_multipass" != "disabled" ]] && _enc_args+=(-multipass "$_multipass")
                ;;
            INTEL-QSV)
                local _qsv_preset
                case "$_eff_preset" in
                    p1) _qsv_preset=veryfast ;; p2) _qsv_preset=faster   ;;
                    p3) _qsv_preset=fast     ;; p4) _qsv_preset=medium   ;;
                    p5) _qsv_preset=slow     ;; p6) _qsv_preset=slower   ;;
                    p7) _qsv_preset=veryslow ;; *)  _qsv_preset=medium   ;;
                esac
                _enc_args=(-c:v av1_qsv -global_quality "$_eff_cq" \
                           -preset "$_qsv_preset" -b:v 0)
                if (( _lookahead > 0 )); then
                    local _qla=$(( _lookahead < 100 ? _lookahead : 100 ))
                    _enc_args+=(-look_ahead 1 -look_ahead_depth "$_qla")
                fi
                ;;
            AMD-AMF)
                local _amf_quality
                case "$_eff_preset" in
                    p1|p2|p3) _amf_quality=speed    ;;
                    p4|p5)    _amf_quality=balanced ;;
                    *)        _amf_quality=quality  ;;
                esac
                local _amf_qp_p=$(( _eff_cq + 2 < 63 ? _eff_cq + 2 : 63 ))
                _enc_args=(-c:v av1_amf -quality "$_amf_quality" -rc cqp \
                           -qp_i "$_eff_cq" -qp_p "$_amf_qp_p")
                (( _lookahead > 0 )) && _enc_args+=(-preanalysis 1)
                ;;
            APPLE-VTB)
                _enc_args=(-c:v av1_videotoolbox -q:v "$_eff_cq")
                ;;
            SW-SVTAV1)
                local _svt_preset
                case "$_eff_preset" in
                    p1) _svt_preset=12 ;; p2) _svt_preset=10 ;;
                    p3) _svt_preset=8  ;; p4) _svt_preset=6  ;;
                    p5) _svt_preset=4  ;; p6) _svt_preset=2  ;;
                    p7) _svt_preset=0  ;; *)  _svt_preset=6  ;;
                esac
                local _svt_la=$(( _lookahead < 120 ? _lookahead : 120 ))
                (( _lookahead > 120 )) && \
                    log "[$_rel_path] RcLookahead $_lookahead clamped to 120 (SVT-AV1 max)." \
                        INFO "$master_log"
                _enc_args=(-c:v libsvtav1 -crf "$_eff_cq" -preset "$_svt_preset" \
                           -svtav1-params "lookahead=${_svt_la}")
                ;;
            SW-LIBAOM)
                local _cpu_used
                case "$_eff_preset" in
                    p1) _cpu_used=8 ;; p2) _cpu_used=7 ;;
                    p3) _cpu_used=6 ;; p4) _cpu_used=5 ;;
                    p5) _cpu_used=4 ;; p6) _cpu_used=2 ;;
                    p7) _cpu_used=0 ;; *)  _cpu_used=5 ;;
                esac
                _enc_args=(-c:v libaom-av1 -crf "$_eff_cq" \
                           -cpu-used "$_cpu_used" -row-mt 1)
                ;;
            SW-CPU)
                _enc_args=(-c:v "$cpu_fallback_enc" -crf "$_eff_cq" -b:v 0)
                ;;
        esac

        # ── AV1-in-MKV check ────────────────────────────────────────────────
        local _is_av1mkv=false
        [[ "$_vid_codec" =~ ^av1$ ]] && [[ "${_src_file,,}" == *.mkv ]] \
            && _is_av1mkv=true
        _r_was_av1mkv="$_is_av1mkv"

        log "Processing: $_rel_path | ${_src_w}x${_src_h} (${_res_tier}) | Profile: $_prof_key | Codec: $_vid_codec | AV1-MKV: $_is_av1mkv | OnComplete: $ON_COMPLETE" \
            INFO "$master_log"

        # ====================================================================
        # Branch A: Source is already AV1 inside an MKV container
        # ====================================================================
        if [[ "$_is_av1mkv" == true ]]; then
            case "$ON_COMPLETE" in
                Nothing)
                    if [[ ! -f "$_tgt_file" ]]; then
                        if [[ "$DRY_RUN" == true ]]; then
                            log "WhatIf: Would copy already-AV1 MKV to target: $_rel_path" \
                                INFO "$master_log"
                            _r_tgt_action="WhatIf-Copy"
                        else
                            cp -- "$_src_file" "$_tgt_file"
                            [[ -n "$_ts_ref" ]] && touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                            _r_tgt_action="Copied"
                            log "Already AV1 MKV — copied to target: $_rel_path" INFO "$master_log"
                        fi
                    else
                        _r_tgt_action="AlreadyExists"
                        log "Already AV1 MKV — target exists, skipped: $_rel_path" WARN "$master_log"
                    fi
                    _r_src_action="Unchanged"
                    ;;
                Delete)
                    if [[ ! -f "$_tgt_file" ]]; then
                        if [[ "$DRY_RUN" == true ]]; then
                            log "WhatIf: Would move already-AV1 MKV to target: $_rel_path" \
                                INFO "$master_log"
                            _r_tgt_action="WhatIf-Move"; _r_src_action="WhatIf-Delete"
                        else
                            mv -- "$_src_file" "$_tgt_file"
                            [[ -n "$_ts_ref" ]] && touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                            _r_tgt_action="Moved"; _r_src_action="Deleted"
                            log "Already AV1 MKV — moved to target: $_rel_path" INFO "$master_log"
                            rmdir "$(dirname "$_src_file")" 2>/dev/null || true
                        fi
                    else
                        _r_tgt_action="AlreadyExists"; _r_src_action="Unchanged"
                        log "Already AV1 MKV — target exists, source unchanged: $_rel_path" \
                            WARN "$master_log"
                    fi
                    ;;
                Replace)
                    _r_tgt_action="N/A"; _r_src_action="Unchanged"
                    log "Already AV1 MKV — Replace mode, no action needed: $_rel_path" \
                        INFO "$master_log"
                    ;;
            esac
            if [[ -f "$_tgt_file" ]]; then _r_tgt_size="$(_file_size "$_tgt_file")"
            else                            _r_tgt_size="$_r_src_size"
            fi
            _r_status="AlreadyAV1MKV"; _r_savings="0.0"
            _write_rec; return 0
        fi

        # ====================================================================
        # Branch B: Target already exists — skip (safe resume)
        # ====================================================================
        if [[ -f "$_tgt_file" ]]; then
            log "SKIPPED — target already exists: $_rel_path" WARN "$master_log"
            _r_status="Skipped-TargetExists"; _r_tgt_action="AlreadyExists"
            _r_tgt_size="$(_file_size "$_tgt_file")"
            _write_rec; return 0
        fi

        # ====================================================================
        # Branch C-pre: Pre-encode skip
        # Thresholds (bpp = bits_per_second / (width × height × fps)):
        #   • AV1       — always skip (already the target codec)
        #   • HEVC/VP9  — skip if bpp < 0.010
        #     (well-compressed modern HEVC/VP9; AV1 cannot reliably beat it)
        #   • H.264     — skip if bpp < 0.005
        #     (extremely compressed H.264; too little headroom for AV1 to gain)
        # All other codecs always proceed to transcode.
        # ====================================================================
        local _rfr
        _rfr="$(jq -r \
            '([.streams[]|select(.codec_type=="video")]|first|.r_frame_rate)//"30/1"' \
            <<< "$_probe_json" 2>/dev/null || echo "30/1")"
        local _fps
        _fps="$(awk -v r="$_rfr" 'BEGIN {
            n = split(r, a, "/")
            if (n == 2 && a[2]+0 > 0) printf "%.6f", a[1]/a[2]
            else printf "30.0"
        }')"

        # Prefer stream-level bit_rate; fall back to container-level
        local _bps
        _bps="$(jq -r '
            (([.streams[]|select(.codec_type=="video")]|first|.bit_rate)//null) //
            (.format.bit_rate//null) // "0"
        ' <<< "$_probe_json" 2>/dev/null || echo 0)"
        [[ "$_bps" == "null" || -z "$_bps" ]] && _bps=0

        if [[ "$_bps" == "0" ]]; then
            log "[$_rel_path] Bitrate unavailable from FFprobe; pre-encode skip check bypassed." \
                INFO "$master_log"
        fi

        local _bpp
        _bpp="$(awk -v w="$_src_w" -v h="$_src_h" -v fps="$_fps" -v bps="$_bps" 'BEGIN {
            if (w > 0 && h > 0 && fps > 0 && bps > 0)
                printf "%.9f", bps / (w * h * fps)
            else
                printf "0.0"
        }')"

        local _no_savings=false _no_savings_reason=""
        if [[ "$_vid_codec" =~ ^av1$ ]]; then
            _no_savings=true
            _no_savings_reason="source is already AV1 (codec: $_vid_codec)"
        elif [[ "$_vid_codec" =~ ^(hevc|vp9)$ ]]; then
            local _bpp_low
            _bpp_low="$(awk -v b="$_bpp" \
                'BEGIN { print (b+0 > 0 && b+0 < 0.010) ? "true" : "false" }')"
            if [[ "$_bpp_low" == true ]]; then
                _no_savings=true
                _no_savings_reason="source is $_vid_codec with bpp \
$(awk -v b="$_bpp" 'BEGIN{printf "%.6f",b+0}') — already efficiently encoded; unlikely to yield savings"
            fi
        elif [[ "$_vid_codec" =~ ^h264$ ]]; then
            local _bpp_h264_low
            _bpp_h264_low="$(awk -v b="$_bpp" \
                'BEGIN { print (b+0 > 0 && b+0 < 0.005) ? "true" : "false" }')"
            if [[ "$_bpp_h264_low" == true ]]; then
                _no_savings=true
                _no_savings_reason="source is $_vid_codec with bpp \
$(awk -v b="$_bpp" 'BEGIN{printf "%.6f",b+0}') — already heavily compressed; unlikely to yield savings"
            fi
        fi

        if [[ "$_no_savings" == true ]]; then
            printf 'PRE-ENCODE SKIP: %s\n' "$_no_savings_reason" > "$_file_log"
            log "SKIPPED (likely no savings) [$_rel_path] — $_no_savings_reason" \
                WARN "$master_log"
            _r_status="Skipped-LikelyNoSavings"

            case "$ON_COMPLETE" in
                Nothing)
                    if [[ "$DRY_RUN" == true ]]; then
                        log "WhatIf: Would copy source to target (no-savings/Nothing): $_rel_path" \
                            INFO "$master_log"
                        _r_tgt_action="WhatIf-Copy"; _r_src_action="Unchanged"
                    else
                        cp -- "$_src_file" "$_tgt_file"
                        [[ -n "$_ts_ref" ]] && touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                        _r_tgt_action="CopiedSource"; _r_src_action="Unchanged"
                        _r_tgt_size="$(_file_size "$_tgt_file")"
                        log "Source copied to target (no-savings/Nothing): $_rel_path" \
                            INFO "$master_log"
                    fi
                    ;;
                Delete)
                    if [[ "$DRY_RUN" == true ]]; then
                        log "WhatIf: Would move source to target (no-savings/Delete): $_rel_path" \
                            INFO "$master_log"
                        _r_tgt_action="WhatIf-Move"; _r_src_action="WhatIf-Delete"
                    else
                        mv -- "$_src_file" "$_tgt_file"
                        [[ -n "$_ts_ref" ]] && touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                        _r_tgt_action="MovedSource"; _r_src_action="Deleted"
                        _r_tgt_size="$(_file_size "$_tgt_file")"
                        log "Source moved to target (no-savings/Delete): $_rel_path" \
                            INFO "$master_log"
                        rmdir "$(dirname "$_src_file")" 2>/dev/null || true
                    fi
                    ;;
                Replace)
                    _r_tgt_action="N/A"; _r_src_action="Unchanged"; _r_tgt_size=0
                    log "No action taken (no-savings/Replace): $_rel_path" INFO "$master_log"
                    ;;
            esac
            _write_rec; return 0
        fi

        # ====================================================================
        # Branch C: Full transcode
        # ====================================================================

        # Write per-file log header
        {
            printf '========================================================\n'
            printf '  Per-File Encode Log\n'
            printf '  Session   : %s\n'       "$SESSION_STAMP"
            printf '  Source    : %s  (%s)\n' "$_src_file" \
                                               "$(format_bytes "$_r_src_size")"
            printf '  Target    : %s\n'       "$_tgt_file"
            printf '  Resolution: %sx%s (%s)\n' "$_src_w" "$_src_h" "$_res_tier"
            printf '  Profile   : %s\n'       "$_prof_key"
            printf '  Content   : %s\n'       "$CONTENT"
            printf '  Stack     : %s\n'       "$selected_stack"
            printf '  CQ        : %s  |  Preset : %s\n' "$_eff_cq" "$_eff_preset"
            printf '  Encode    : %s\n'       "${_enc_args[*]}"
            printf '  Streams   : audio=%s  subtitles=%s  attachments=%s\n' \
                "$_has_audio" "$_has_sub" "$_has_att"
            printf '  Started   : %s\n'       "$(date '+%Y-%m-%d %H:%M:%S')"
            printf '========================================================\n'
        } > "$_file_log"

        # Build full FFmpeg argument list
        local -a _ff_args=()
        (( ${#hw_decode_args[@]} > 0 )) && _ff_args+=("${hw_decode_args[@]}")
        _ff_args+=(-i "$_src_file" -map 0:v:0)
        [[ "$_has_audio" == true ]] && _ff_args+=(-map 0:a)
        [[ "$_has_sub"   == true ]] && _ff_args+=(-map 0:s)
        [[ "$_has_att"   == true ]] && _ff_args+=(-map 0:t)
        _ff_args+=("${_enc_args[@]}")
        [[ "$_has_audio" == true ]] && _ff_args+=(-c:a copy)
        [[ "$_has_sub"   == true ]] && _ff_args+=(-c:s copy)
        _ff_args+=(-map_metadata 0 -map_metadata:s:v 0:s:v -write_tmcd 0)
        [[ "$_has_audio" == true ]] && _ff_args+=(-map_metadata:s:a 0:s:a)
        [[ "$_has_sub"   == true ]] && _ff_args+=(-map_metadata:s:s 0:s:s)
        _ff_args+=("$_tgt_file")

        printf 'FFmpeg command:\n"%s" %s\n---\n' \
            "$ffmpeg_bin" "${_ff_args[*]}" >> "$_file_log"

        # WhatIf — report intent and return without executing
        if [[ "$DRY_RUN" == true ]]; then
            log "WhatIf: Would encode '$_rel_path' → '$_tgt_file'" INFO "$master_log"
            _r_status="WhatIf"; _r_tgt_action="WhatIf-Transcode"
            case "$ON_COMPLETE" in
                Replace)
                    local _repl_check; _repl_check="$(dirname "$_src_file")/$_tgt_name"
                    if [[ -f "$_repl_check" && "$_repl_check" != "$_src_file" ]]; then
                        log "WhatIf: WARN — Replace blocked for '$_rel_path': '$_tgt_name' already exists in source dir as a different file." \
                            WARN "$master_log"
                        _r_src_action="WhatIf-Replace-Blocked"
                    else
                        _r_src_action="WhatIf-Replace"
                    fi
                    ;;
                Delete)  _r_src_action="WhatIf-Delete" ;;
                *)       _r_src_action="Unchanged"      ;;
            esac
            _write_rec; return 0
        fi

        # Run FFmpeg — capture stdout+stderr for the per-file log and warning scan
        local _tmp_out _tmp_err
        _tmp_out="$(mktemp)" || {
            log "EXCEPTION [$_rel_path] — mktemp failed" ERROR "$master_log"
            _r_status="Exception"; _r_tgt_action="Failed"
            _write_rec; return 1
        }
        _tmp_err="$(mktemp)" || {
            rm -f "$_tmp_out"
            log "EXCEPTION [$_rel_path] — mktemp failed" ERROR "$master_log"
            _r_status="Exception"; _r_tgt_action="Failed"
            _write_rec; return 1
        }

        local _enc_start _enc_exit=0
        _enc_start="$(date +%s)"
        "$ffmpeg_bin" "${_ff_args[@]}" > "$_tmp_out" 2> "$_tmp_err" || _enc_exit=$?
        local _enc_end; _enc_end="$(date +%s)"
        local _enc_dur_s=$(( _enc_end - _enc_start ))
        local _enc_dur
        printf -v _enc_dur '%02d:%02d:%02d' \
            $(( _enc_dur_s / 3600 )) \
            $(( (_enc_dur_s % 3600) / 60 )) \
            $(( _enc_dur_s % 60 ))

        { cat "$_tmp_out"; cat "$_tmp_err"; } >> "$_file_log" 2>/dev/null
        printf -- '---\nExit code : %d\nDuration  : %s\n' \
            "$_enc_exit" "$_enc_dur" >> "$_file_log"

        local _ff_out
        _ff_out="$(cat "$_tmp_out" "$_tmp_err" 2>/dev/null || true)"
        rm -f "$_tmp_out" "$_tmp_err"

        # ------------------------------------------------------------------
        # Hwaccel decode retry: if the encode failed and output suggests a
        # mid-stream format change that broke the hardware decode filter
        # graph, retry without the hwaccel decode prefix.
        # ------------------------------------------------------------------
        if (( _enc_exit != 0 )) && (( ${#hw_decode_args[@]} > 0 )) &&
           { (( _enc_exit == -40 )) || [[ "$_ff_out" =~ (hwaccel\ changed|reinitializing\ filters|Error\ reinitializing) ]]; }; then

            log "WARN [$_rel_path] — FFmpeg exited $_enc_exit (hwaccel filter graph error); retrying without hardware decode" \
                WARN "$master_log"
            printf '\n--- Retry (software decode) ---\n' >> "$_file_log"

            # Remove any partial output left by the failed attempt
            rm -f "$_tgt_file"

            # Strip hw_decode_args from the front of _ff_args
            local -a _ff_args_sw=("${_ff_args[@]:${#hw_decode_args[@]}}")

            local _tmp_out2 _tmp_err2
            _tmp_out2="$(mktemp)"
            _tmp_err2="$(mktemp)"
            local _retry_start _retry_exit=0
            _retry_start="$(date +%s)"
            "$ffmpeg_bin" "${_ff_args_sw[@]}" > "$_tmp_out2" 2> "$_tmp_err2" || _retry_exit=$?
            local _retry_end; _retry_end="$(date +%s)"
            _enc_dur_s=$(( _retry_end - _retry_start ))
            printf -v _enc_dur '%02d:%02d:%02d' \
                $(( _enc_dur_s / 3600 )) \
                $(( (_enc_dur_s % 3600) / 60 )) \
                $(( _enc_dur_s % 60 ))

            { cat "$_tmp_out2"; cat "$_tmp_err2"; } >> "$_file_log" 2>/dev/null
            printf -- '---\nExit code : %d\nDuration  : %s\n' \
                "$_retry_exit" "$_enc_dur" >> "$_file_log"

            _ff_out="$(cat "$_tmp_out2" "$_tmp_err2" 2>/dev/null || true)"
            rm -f "$_tmp_out2" "$_tmp_err2"
            _enc_exit="$_retry_exit"
        fi

        if (( _enc_exit == 0 )) && [[ -f "$_tgt_file" ]]; then

            _r_tgt_size="$(_file_size "$_tgt_file")"
            _r_transcoded="true"
            _r_savings="$(awk -v s="$_r_src_size" -v t="$_r_tgt_size" \
                'BEGIN { if (s > 0) printf "%.1f", (1 - t/s)*100; else print "0.0" }')"

            printf 'Source    : %s\nTarget    : %s\nSavings   : %s%%\n' \
                "$(format_bytes "$_r_src_size")" \
                "$(format_bytes "$_r_tgt_size")" \
                "$_r_savings" >> "$_file_log"

            local _tgt_not_smaller
            _tgt_not_smaller="$(awk -v t="$_r_tgt_size" -v s="$_r_src_size" \
                'BEGIN { print (t+0 >= s+0) ? "true" : "false" }')"

            if [[ "$_tgt_not_smaller" == true ]]; then
                # ── Post-encode no-savings: revert to source file ─────────────
                printf 'Result    : SUCCESS (no savings — encoded file not smaller than source)\n' \
                    >> "$_file_log"
                log "SUCCESS-NO-SAVINGS [$_rel_path] $(format_bytes "$_r_src_size") → $(format_bytes "$_r_tgt_size") (${_r_savings}% saved) [$_enc_dur] — reverting to source" \
                    WARN "$master_log"
                _r_status="Success-NoSavings"
                rm -f "$_tgt_file"

                case "$ON_COMPLETE" in
                    Nothing)
                        if [[ -f "$_src_file" ]]; then
                            cp -- "$_src_file" "$_tgt_file"
                            [[ -n "$_ts_ref" ]] && \
                                touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                            _r_tgt_action="CopiedSource"; _r_src_action="Unchanged"
                            _r_tgt_size="$(_file_size "$_tgt_file")"
                            log "Source copied to target (no-savings/Nothing): $_rel_path" \
                                INFO "$master_log"
                        else
                            log "WARN [$_rel_path] — Source no longer exists; cannot copy." \
                                WARN "$master_log"
                            _r_src_action="Missing"
                        fi
                        ;;
                    Delete)
                        if [[ -f "$_src_file" ]]; then
                            mv -- "$_src_file" "$_tgt_file"
                            [[ -n "$_ts_ref" ]] && \
                                touch -r "$_ts_ref" "$_tgt_file" 2>/dev/null || true
                            _r_tgt_action="MovedSource"; _r_src_action="Deleted"
                            _r_tgt_size="$(_file_size "$_tgt_file")"
                            log "Source moved to target (no-savings/Delete): $_rel_path" \
                                INFO "$master_log"
                            rmdir "$(dirname "$_src_file")" 2>/dev/null || true
                        else
                            log "WARN [$_rel_path] — Source no longer exists; cannot move." \
                                WARN "$master_log"
                            _r_src_action="Missing"
                        fi
                        ;;
                    Replace)
                        _r_tgt_action="N/A"; _r_src_action="Unchanged"; _r_tgt_size=0
                        log "No action taken (no-savings/Replace): $_rel_path" \
                            INFO "$master_log"
                        ;;
                esac

            else
                # ── Normal success — encoded file is smaller than source ───────
                printf 'Result    : SUCCESS\n' >> "$_file_log"
                log "SUCCESS [$_rel_path] $(format_bytes "$_r_src_size") → $(format_bytes "$_r_tgt_size") (${_r_savings}% saved) [$_enc_dur]" \
                    SUCCESS "$master_log"
                _r_tgt_action="Transcoded"; _r_status="Success"
                local _final_out="$_tgt_file"

                # Scan FFmpeg output for quality-warning patterns.
                # Even a zero exit code can accompany data corruption or
                # concealment — block destructive OnComplete in those cases.
                local -a _enc_warns=()
                local _wl
                while IFS= read -r _wl; do
                    if printf '%s' "$_wl" | grep -qiE \
                        '(concealing[[:space:]]+[0-9]+[[:space:]]+(error|MBs)|bitstream[[:space:]]error|corrupt(ed)?[[:space:]]+(frame|packet|data|bitstream)|invalid[[:space:]]data[[:space:]]found|conversion[[:space:]]failed|error[[:space:]]while[[:space:]]+(decoding|encoding)|overread[[:space:]]+[0-9]+[[:space:]]bits|truncated[[:space:]]+(file|packet)|missing[[:space:]]mandatory[[:space:]]field|pts[[:space:]]has[[:space:]]no[[:space:]]value)'; then
                        _enc_warns+=("${_wl%$'\r'}")
                    fi
                done <<< "$_ff_out"

                if (( ${#_enc_warns[@]} > 0 )); then
                    {
                        printf 'OnComplete : BLOCKED — %d warning/error line(s) detected in FFmpeg output.\n' \
                            "${#_enc_warns[@]}"
                        local _w; for _w in "${_enc_warns[@]}"; do
                            printf '  ! %s\n' "$_w"
                        done
                        printf '  Source file preserved; please verify output before deleting original.\n'
                    } >> "$_file_log"
                    log "WARN [$_rel_path] — OnComplete '$ON_COMPLETE' blocked: ${#_enc_warns[@]} encode warning(s) detected. Source preserved." \
                        WARN "$master_log"
                    _r_src_action="Preserved-EncodeWarnings"
                else
                    # OnComplete post-processing
                    case "$ON_COMPLETE" in
                        Delete)
                            if [[ -f "$_src_file" ]]; then
                                rm -f "$_src_file"
                                _r_src_action="Deleted"
                                log "Source deleted (OnComplete=Delete): $_rel_path" \
                                    INFO "$master_log"
                                local _src_dir; _src_dir="$(dirname "$_src_file")"
                                if rmdir "$_src_dir" 2>/dev/null; then
                                    log "Removed empty source directory: $_src_dir" \
                                        INFO "$master_log"
                                fi
                            else
                                log "WARN [$_rel_path] — Source no longer exists; skipping delete." \
                                    WARN "$master_log"
                                _r_src_action="Missing"
                            fi
                            ;;
                        Replace)
                            local _repl_dir; _repl_dir="$(dirname "$_src_file")"
                            local _repl_dest="$_repl_dir/$_tgt_name"
                            if [[ -f "$_repl_dest" && "$_repl_dest" != "$_src_file" ]]; then
                                printf 'OnComplete : BLOCKED (Replace) — "%s" already exists in source dir as a different file. Source preserved.\n' \
                                    "$_tgt_name" >> "$_file_log"
                                log "WARN [$_rel_path] — Replace blocked: '$_tgt_name' already exists in source dir as different file. Both files preserved." \
                                    WARN "$master_log"
                                _r_src_action="Preserved-NameConflict"
                            else
                                if mv -- "$_tgt_file" "$_repl_dest" 2>/dev/null; then
                                    [[ -f "$_src_file" ]] && rm -f "$_src_file"
                                    _r_tgt_action="MovedToSource"; _r_src_action="Replaced"
                                    _final_out="$_repl_dest"
                                    log "Encode moved to source dir, original deleted (OnComplete=Replace): $_rel_path" \
                                        INFO "$master_log"
                                else
                                    log "WARN [$_rel_path] — Replace move failed. Both files preserved." \
                                        WARN "$master_log"
                                    _r_src_action="Preserved-MoveFailed"
                                fi
                            fi
                            ;;
                        *)
                            _r_src_action="Unchanged"
                            ;;
                    esac
                fi

                # Propagate source filesystem timestamps to final output location
                if [[ -f "$_final_out" ]] && [[ -n "$_ts_ref" ]]; then
                    touch -r "$_ts_ref" "$_final_out" 2>/dev/null || true
                    {
                        printf 'Metadata  : Filesystem timestamps copied from source.\n'
                        printf '            Modified : %s\n' \
                            "$(date -r "$_ts_ref" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
                    } >> "$_file_log"
                fi
            fi

        else
            # FFmpeg exited non-zero or target file is missing
            printf 'Result    : FAILED (exit %d)\n' "$_enc_exit" >> "$_file_log"
            [[ -f "$_tgt_file" ]] && rm -f "$_tgt_file"
            _r_status="Failed"; _r_tgt_action="Failed"
            log "FAILED [$_rel_path] — exit $_enc_exit. See: $_file_log" \
                ERROR "$master_log"
        fi

        _write_rec
    }  # end encode_one_file

    # ── Dispatch loop ──────────────────────────────────────────────────────
    # Iterate queued files; acquire one semaphore token per job (blocks when
    # max_parallel jobs are already running), then fork the worker.
    local -a _enc_pids=()
    local _enc_file _enc_rec
    for _enc_file in "${files_to_encode[@]}"; do
        # Block until a slot opens (reads one 'x' token from fd 9)
        read -r -n1 -u9 _tok 2>/dev/null || true
        # Pre-allocate a unique result record file for this job
        _enc_rec="$(mktemp "$RESULTS_DIR/result_XXXXXX.rec")"
        encode_one_file "$_enc_file" "$_enc_rec" &
        _enc_pids+=($!)
    done

    # Wait for all background encode jobs to finish
    if (( ${#_enc_pids[@]} > 0 )); then
        log "All $files_to_encode_count file(s) dispatched; waiting for encode jobs..." \
            INFO "$master_log"
        local _enc_pid
        for _enc_pid in "${_enc_pids[@]}"; do
            wait "$_enc_pid" 2>/dev/null || true
        done
        log "All encode jobs complete." INFO "$master_log"
    fi

    # =========================================================================
    # STEP 7: Build summary table and append to master log
    # Mirrors ps1 lines 1704–1838.
    # =========================================================================

    # ── Load all result records from $RESULTS_DIR ─────────────────────────
    # Both pre-flight resume records (sequential names) and encode job records
    # (mktemp names) live there.  Collect paths, then sort by relative path
    # (field 1) so the table output is deterministic.
    local _all_recs=""
    if [[ -d "$RESULTS_DIR" ]]; then
        local -a _rec_files=()
        local _rf
        while IFS= read -r -d '' _rf; do
            _rec_files+=("$_rf")
        done < <(find "$RESULTS_DIR" -maxdepth 1 -name '*.rec' -print0 2>/dev/null)
        if (( ${#_rec_files[@]} > 0 )); then
            _all_recs="$(sort -t$'\t' -k1,1 "${_rec_files[@]}" 2>/dev/null || true)"
        fi
    fi

    # ── First pass: compute max relative-path length for File column ──────
    local _cw_file=10
    local _fp_tmp _fp_len _fp_rest
    while IFS=$'\t' read -r _fp_tmp _fp_rest; do
        [[ -z "$_fp_tmp" ]] && continue
        _fp_len="${#_fp_tmp}"
        (( _fp_len > _cw_file )) && _cw_file="$_fp_len"
    done <<< "$_all_recs"
    (( _cw_file > 55 )) && _cw_file=55

    # Fixed column widths (mirrors PS1 $cw hashtable)
    local _cw_status=18 _cw_src_act=13 _cw_tgt_act=16
    local _cw_src_sz=12 _cw_tgt_sz=12 _cw_sav=9

    # ── Build separator line ──────────────────────────────────────────────
    local _seg _sep="" _col
    for _col in $(( _cw_file    + 2 )) \
                $(( _cw_status  + 2 )) \
                $(( _cw_src_act + 2 )) \
                $(( _cw_tgt_act + 2 )) \
                $(( _cw_src_sz  + 2 )) \
                $(( _cw_tgt_sz  + 2 )) \
                $(( _cw_sav     + 2 )); do
        printf -v _seg '%*s' "$_col" ''
        _sep="${_sep}+${_seg// /-}"
    done
    _sep="${_sep}+"

    # ── Header row ────────────────────────────────────────────────────────
    local _hdr
    printf -v _hdr '| %s | %s | %s | %s | %s | %s | %s |' \
        "$(pad 'File'          $_cw_file)" \
        "$(pad 'Status'        $_cw_status)" \
        "$(pad 'Src Action'    $_cw_src_act)" \
        "$(pad 'Target Action' $_cw_tgt_act)" \
        "$(pad 'Src Size'      $_cw_src_sz)" \
        "$(pad 'Tgt Size'      $_cw_tgt_sz)" \
        "$(pad 'Savings'       $_cw_sav)"

    # ── Second pass: build table rows and accumulate totals ───────────────
    local _total_files=0
    local _total_src_bytes=0 _total_tgt_bytes=0
    local _cnt_success=0 _cnt_no_savings=0 _cnt_resumed=0
    local _cnt_failed=0 _cnt_already_av1=0 _cnt_likely_no_save=0 _cnt_skipped=0
    local -a _table_rows=()
    local _r_rel _r_src _r_tgt _r_src_sz _r_tgt_sz
    local _r_src_act _r_tgt_act _r_av1mkv _r_transcoded _r_status _r_savings
    local _file_txt _src_str _tgt_str _sav_str _row

    while IFS=$'\t' read -r \
        _r_rel _r_src _r_tgt _r_src_sz _r_tgt_sz \
        _r_src_act _r_tgt_act _r_av1mkv _r_transcoded _r_status _r_savings; do

        [[ -z "$_r_rel" ]] && continue

        _total_files=$(( _total_files + 1 ))
        _total_src_bytes=$(( _total_src_bytes + ${_r_src_sz:-0} ))
        _total_tgt_bytes=$(( _total_tgt_bytes + ${_r_tgt_sz:-0} ))

        case "$_r_status" in
            Success)                 _cnt_success=$(( _cnt_success + 1 ))               ;;
            Success-NoSavings)       _cnt_no_savings=$(( _cnt_no_savings + 1 ))         ;;
            Resumed)                 _cnt_resumed=$(( _cnt_resumed + 1 ))               ;;
            Failed|Exception)        _cnt_failed=$(( _cnt_failed + 1 ))                 ;;
            AlreadyAV1MKV)           _cnt_already_av1=$(( _cnt_already_av1 + 1 ))       ;;
            Skipped-LikelyNoSavings) _cnt_likely_no_save=$(( _cnt_likely_no_save + 1 )) ;;
            *)                       _cnt_skipped=$(( _cnt_skipped + 1 ))               ;;
        esac

        # Format size / savings display strings
        _src_str="$(format_bytes "${_r_src_sz:-0}")"
        if (( ${_r_tgt_sz:-0} > 0 )); then
            _tgt_str="$(format_bytes "$_r_tgt_sz")"
        else
            _tgt_str="N/A"
        fi
        if [[ "$_r_transcoded" == true ]] || \
           [[ "$_r_status" == "Resumed" ]] || \
           [[ "$_r_status" == "Success-NoSavings" ]]; then
            _sav_str="${_r_savings}%"
        else
            _sav_str="N/A"
        fi

        # Right-truncate long paths: show tail with '..' prefix
        if (( ${#_r_rel} > _cw_file )); then
            _file_txt="..${_r_rel:$(( ${#_r_rel} - (_cw_file - 2) ))}"
        else
            _file_txt="$_r_rel"
        fi

        printf -v _row '| %s | %s | %s | %s | %s | %s | %s |' \
            "$(pad "$_file_txt"  $_cw_file)" \
            "$(pad "$_r_status"  $_cw_status)" \
            "$(pad "$_r_src_act" $_cw_src_act)" \
            "$(pad "$_r_tgt_act" $_cw_tgt_act)" \
            "$(pad "$_src_str"   $_cw_src_sz)" \
            "$(pad "$_tgt_str"   $_cw_tgt_sz)" \
            "$(pad "$_sav_str"   $_cw_sav)"
        _table_rows+=("$_row")

    done <<< "$_all_recs"

    # ── Totals row ────────────────────────────────────────────────────────
    local _total_savings_pct
    _total_savings_pct="$(awk -v s="$_total_src_bytes" -v t="$_total_tgt_bytes" \
        'BEGIN { if (s > 0) printf "%.1f", (1-t/s)*100; else print "0.0" }')"

    local _saved_bytes=$(( _total_src_bytes - _total_tgt_bytes ))
    local _saved_str
    _saved_str="$(awk -v b="$_saved_bytes" 'BEGIN {
        sign = (b < 0) ? "-" : ""
        if (b < 0) b = -b
        if      (b >= 1073741824) printf "%s%.2f GB", sign, b/1073741824
        else if (b >= 1048576)    printf "%s%.2f MB", sign, b/1048576
        else if (b >= 1024)       printf "%s%.2f KB", sign, b/1024
        else                      printf "%s%d B",    sign, b
    }')"

    local _total_label="TOTAL ($_total_files files)"
    local _tot_row
    printf -v _tot_row '| %s | %s | %s | %s | %s | %s | %s |' \
        "$(pad "$_total_label"                        $_cw_file)" \
        "$(pad ''                                     $_cw_status)" \
        "$(pad ''                                     $_cw_src_act)" \
        "$(pad ''                                     $_cw_tgt_act)" \
        "$(pad "$(format_bytes $_total_src_bytes)"    $_cw_src_sz)" \
        "$(pad "$(format_bytes $_total_tgt_bytes)"    $_cw_tgt_sz)" \
        "$(pad "${_total_savings_pct}%"               $_cw_sav)"

    # ── Assemble summary block ────────────────────────────────────────────
    local _eq80; _eq80="$(printf '%*s' 80 '' | tr ' ' '=')"
    local _hr;   _hr="$(printf '%*s' 37 '' | tr ' ' '-')"

    local _summary
    _summary="$(
        printf '\n%s\n' "$_eq80"
        printf '  FINAL SUMMARY — Session %s\n' "$SESSION_STAMP"
        printf '%s\n'   "$_eq80"
        printf '%s\n'   "$_sep"
        printf '%s\n'   "$_hdr"
        printf '%s\n'   "$_sep"
        (( ${#_table_rows[@]} > 0 )) && printf '%s\n' "${_table_rows[@]}"
        printf '%s\n'   "$_sep"
        printf '%s\n'   "$_tot_row"
        printf '%s\n\n' "$_sep"
        printf '  Content profile : %s\n'     "$CONTENT"
        printf '  Succeeded       : %d\n'     "$_cnt_success"
        printf '  No savings      : %d  (encoded but not smaller — source used instead)\n' \
                                              "$_cnt_no_savings"
        printf '  Likely no save  : %d  (skipped — source already efficient)\n' \
                                              "$_cnt_likely_no_save"
        printf '  Resumed         : %d\n'     "$_cnt_resumed"
        printf '  Already AV1     : %d\n'     "$_cnt_already_av1"
        printf '  Skipped         : %d\n'     "$_cnt_skipped"
        printf '  Failed          : %d\n'     "$_cnt_failed"
        printf '  %s\n'                       "$_hr"
        printf '  Total source    : %s\n'     "$(format_bytes "$_total_src_bytes")"
        printf '  Total output    : %s\n'     "$(format_bytes "$_total_tgt_bytes")"
        printf '  Space saved     : %s  (%s%%)\n' "$_saved_str" "$_total_savings_pct"
        printf '  %s\n'                       "$_hr"
        printf '  Master log      : %s\n'     "$master_log"
        printf '%s\n'                         "$_eq80"
    )"

    # Append to master log and echo to console
    printf '%s\n' "$_summary" >> "$master_log"
    printf "${C_GREEN}%s\n${C_RESET}" "$_summary"

    # =========================================================================
    # STEP 8: CSV export (mirrors ps1 lines 1839–1876)
    # Skipped when --no-export-list is passed.
    # Fields: File, Relative Path, Status, Src Action, Target Action,
    #         Src Size, Tgt Size, Savings
    # =========================================================================
    if [[ "$NO_EXPORT_LIST" != true ]]; then
        local _csv_path="$LOG_DIR/FileList_${SESSION_STAMP}.csv"
        local _cv_file _cv_dir _cv_src_sz _cv_tgt_sz _cv_sav

        {
            printf '"File","Relative Path","Status","Src Action","Target Action","Src Size","Tgt Size","Savings"\n'

            while IFS=$'\t' read -r \
                _r_rel _r_src _r_tgt _r_src_sz _r_tgt_sz \
                _r_src_act _r_tgt_act _r_av1mkv _r_transcoded _r_status _r_savings; do

                [[ -z "$_r_rel" ]] && continue

                _cv_file="$(basename "$_r_rel")"
                _cv_dir="$(dirname "$_r_rel")"
                [[ "$_cv_dir" == "." ]] && _cv_dir=""
                _cv_src_sz="$(format_bytes "${_r_src_sz:-0}")"
                if (( ${_r_tgt_sz:-0} > 0 )); then
                    _cv_tgt_sz="$(format_bytes "$_r_tgt_sz")"
                else
                    _cv_tgt_sz="N/A"
                fi
                if [[ "$_r_transcoded" == true ]] || \
                   [[ "$_r_status" == "Resumed" ]] || \
                   [[ "$_r_status" == "Success-NoSavings" ]]; then
                    _cv_sav="${_r_savings}%"
                else
                    _cv_sav="N/A"
                fi

                # Double internal double-quotes for RFC 4180 CSV compliance
                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "${_cv_file//\"/\"\"}" \
                    "${_cv_dir//\"/\"\"}" \
                    "${_r_status//\"/\"\"}" \
                    "${_r_src_act//\"/\"\"}" \
                    "${_r_tgt_act//\"/\"\"}" \
                    "$_cv_src_sz" "$_cv_tgt_sz" "$_cv_sav"

            done <<< "$_all_recs"

            # Totals row
            printf '"TOTAL (%d files)","","","","","%s","%s","%.1f%%"\n' \
                "$_total_files" \
                "$(format_bytes "$_total_src_bytes")" \
                "$(format_bytes "$_total_tgt_bytes")" \
                "$_total_savings_pct"

        } > "$_csv_path"

        log "Results exported to: $_csv_path" INFO "$master_log"
        printf "${C_CYAN}[INFO] Results exported to: %s\n${C_RESET}" "$_csv_path"
    fi
}

# =========================================================================
# ENTRY POINT
# Run directly: ./mucus.sh [args]
# Source into session: source mucus.sh  (loads mucus() without executing)
# =========================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    mucus "$@"
fi
