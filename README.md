# MUCUS — Media Universal Compression Utility Script
<img src="https://github.com/josephOfTheWest/mucus/blob/main/MUCUS_logo.svg" alt="Image of a film reel squeezed by belt spewing mucus" height="250" width="205" />

MUCUS - Media Universal Compression Utility Script - a versatile collection of scripts to automate FFMPEG conversion of media for compression and archival authored with the help of Cluade Code.

MUCUS can batch re-encodes video files to AV1 using FFmpeg, with automatic hardware acceleration detection, parallel encoding, smart resume, and detailed logging.

---

## Requirements

| Requirement | Details |
|---|---|
| PowerShell | 7.0 or higher |
| FFmpeg | 5.1+ with AV1 support ([gyan.dev full build](https://www.gyan.dev/ffmpeg/builds/)) |
| GPU | NVIDIA, Intel, AMD, or Apple Silicon (software fallback available) |
| OS | Windows (primary); macOS supported via VideoToolbox |

> **Tip:** Place `ffmpeg.exe` and `ffprobe.exe` in the same directory as the script to override any system PATH versions.

---

## Installation

```powershell
# Dot-source the script to load the function into your current session
. .\mucus.ps1

# Then call the function
mucus -SourceDirectory "D:\Videos" -TargetDirectory "E:\Archive"
```

Alternatively, run the script directly — it will forward all arguments automatically:

```powershell
.\mucus.ps1 -SourceDirectory "D:\Videos" -TargetDirectory "E:\Archive"
```

---

## Usage

```
mucus -SourceDirectory <path> -TargetDirectory <path> [options]
mucus -help
```

Only `-SourceDirectory` and `-TargetDirectory` are required. All other parameters have defaults.

---

## Parameters

### `-SourceDirectory` `<string>` — **Required**

Full path to the directory containing source video files. Scanned recursively. Supports all common video formats including MP4, MKV, MOV, AVI, MTS, M2TS, HEVC, and more.

---

### `-TargetDirectory` `<string>` — **Required**

Full path to the directory where re-encoded files will be written. The source directory structure is mirrored in the target. All output files are written as `.mkv` with an AV1 video stream.

---

### `-LogDirectory` `<string>` — Default: `.\encode_logs`

Full path to the directory where log files will be written. A timestamp suffix is automatically appended to the directory name so concurrent or repeated runs never share the same log directory.

**Log files created:**
- `encode_session_<timestamp>.log` — Master session log with all events and a final summary table
- `<relative_path>\<filename>_encode.log` — Per-file FFmpeg output log (mirrors source structure)
- `ErrorLog_<timestamp>.log` — Error/warn log (only when `-ExportError` is set; see below)
- `FileList_<timestamp>.csv` — Results spreadsheet (only when `-ExportList` is `$true`; see below)

---

### `-Content` `<string>` — Default: `General`

Selects the content type profile that controls all FFmpeg encoding parameters. The profile is resolved **per file** based on the source resolution, so a single run across a mixed library automatically applies the right settings for each file.

| Value | Description |
|---|---|
| `General` | Balanced defaults for any mixed or unknown content, SD through 8K |
| `Sports` | Optimised for fast motion: aggressive adaptive quantisation, short lookahead |
| `Movie` | Optimised for feature film: high lookahead, strong AQ, resolution-aware quality |
| `Show` | Optimised for TV episodes: efficient compression for large libraries |

Each profile × resolution tier combination has individually tuned values for CQ, preset, lookahead, spatial AQ, temporal AQ, AQ strength, and multipass mode. See [Content Profiles](#content-profiles) for the full table.

Use `-CQ` or `-Preset` alongside `-Content` to override individual profile values.

---

### `-CQ` `<int>` — Default: profile value — Range: `0`–`63`

Constant Quality value for AV1 encoding. Lower values produce higher quality and larger files. When supplied, overrides the selected content profile's default CQ for every file in the run.

Recommended ranges:
- General archiving: `27`–`32`
- High quality / film: `22`–`26`
- Sports / fast motion: `26`–`30`

---

### `-Preset` `<string>` — Default: profile value — Values: `p1`–`p7`

Encoding speed preset. `p1` is the fastest (lowest quality/compression). `p7` is the slowest (best quality/compression ratio). When supplied, overrides the selected content profile's default preset for every file in the run.

---

### `-OnComplete` `<string>` — Default: `Nothing`

Action to take on the **source** file after each successful encode.

| Value | Effect |
|---|---|
| `Nothing` | Leave the source file untouched |
| `Delete` | Delete the source file; remove the source directory if it becomes empty |
| `Replace` | Move the encoded output to the source directory, then delete the original |

> **Warning:** `Delete` and `Replace` are destructive and **cannot be undone via the Recycle Bin**. An interactive confirmation prompt is shown before the run starts (bypassed with `-WhatIf`).

**Special behaviour when the source is already a valid AV1 MKV** (no transcode performed):

| Value | Effect |
|---|---|
| `Nothing` | Copy source to target location |
| `Delete` | Move source to target location |
| `Replace` | No action — file is already in the correct format and location |

**Special behaviour when the encode produces no file size savings** (post-encode check):

| Value | Effect |
|---|---|
| `Nothing` | Copy the original source to the target directory |
| `Delete` | Move the original source to the target directory |
| `Replace` | Do nothing — the larger encoded file is discarded |

---

### `-ExportList` `<bool>` — Default: `$true`

When `$true`, exports a per-file results spreadsheet to the log directory at the end of the session.

**File name:** `FileList_<timestamp>.csv`

**Columns:**

| Column | Description |
|---|---|
| File | Filename only |
| Relative Path | Parent directory path relative to the source root |
| Status | Outcome for this file (see [File Status Values](#file-status-values)) |
| Src Action | What happened to the source file |
| Target Action | What happened to the target file |
| Src Size | Human-readable source file size |
| Tgt Size | Human-readable target/output file size |
| Savings | Percentage size reduction (`N/A` for skipped/failed files) |

A **TOTAL** row is appended as the final entry with aggregate sizes and overall savings percentage.

Pass `-ExportList $false` to suppress the export.

---

### `-ExportError` `<string>` — Default: `NONE` — Values: `NONE`, `WARN`, `ERROR`

Controls whether a separate filtered log file is written alongside the master log.

**File name:** `ErrorLog_<timestamp>.log`

| Value | Effect |
|---|---|
| `NONE` | No error log is written |
| `WARN` | All `WARN` and `ERROR` log entries are written to the error log |
| `ERROR` | Only `ERROR` log entries are written to the error log |

This is useful for quickly identifying problems in large batch runs without scanning the full master log.

---

### `-WhatIf` `[switch]`

Simulates the entire run without encoding any files or modifying the filesystem. All decisions (skip, encode, resume, collision detection) are logged to the console and the master log file, but no FFmpeg processes are started and no source files are touched. Bypasses the destructive action confirmation prompt.

---

### `-help` `[switch]`

Displays the built-in help text and exits.

---

## Content Profiles

Each combination of content type and resolution tier has individually tuned encoding parameters. The resolution tier for each source file is determined automatically by FFprobe before encoding begins.

**Resolution tier thresholds** (total pixel count = width × height):

| Tier | Threshold |
|---|---|
| SD | ≤ 921,600 (720p and below) |
| HD | > 921,600 and ≤ 1,920 × 1,080 |
| 2K | > 1,920 × 1,080 and ≤ 2,560 × 1,440 |
| 4K | > 2,560 × 1,440 and ≤ 4,096 × 2,160 |
| 8K+ | > 4,096 × 2,160 |

**Profile parameters:**

| Parameter | Description |
|---|---|
| `DefaultCQ` | Base constant quality value (0–63, lower = better quality) |
| `DefaultPreset` | Base encoding speed preset (p1–p7) |
| `RcLookahead` | Frames the encoder looks ahead for rate control |
| `SpatialAQ` | Spatial adaptive quantisation (1 = enabled) |
| `TemporalAQ` | Temporal adaptive quantisation (1 = enabled) |
| `AQStrength` | AQ aggressiveness (1–15; higher = more bits to complex regions) |
| `Multipass` | Internal resolution quality pass (`disabled` / `qres`) |

**Full profile table:**

| Profile | CQ | Preset | Lookahead | AQ Strength | Multipass |
|---|---|---|---|---|---|
| General-SD | 28 | p4 | 24 | 8 | disabled |
| General-HD | 30 | p5 | 40 | 10 | disabled |
| General-2K | 29 | p5 | 48 | 11 | disabled |
| General-4K | 27 | p6 | 56 | 13 | qres |
| General-8K+ | 28 | p6 | 56 | 13 | qres |
| Sports-SD | 26 | p4 | 20 | 9 | disabled |
| Sports-HD | 28 | p5 | 32 | 10 | disabled |
| Sports-2K | 27 | p5 | 32 | 11 | disabled |
| Sports-4K | 26 | p5 | 32 | 12 | disabled |
| Sports-8K+ | 28 | p5 | 32 | 12 | disabled |
| Movie-SD | 26 | p5 | 32 | 10 | disabled |
| Movie-HD | 24 | p6 | 48 | 13 | qres |
| Movie-2K | 23 | p6 | 56 | 14 | qres |
| Movie-4K | 22 | p7 | 64 | 15 | qres |
| Movie-8K+ | 24 | p7 | 64 | 15 | qres |
| Show-SD | 30 | p4 | 24 | 7 | disabled |
| Show-HD | 32 | p5 | 32 | 8 | disabled |
| Show-2K | 31 | p5 | 40 | 9 | disabled |
| Show-4K | 28 | p6 | 48 | 12 | qres |
| Show-8K+ | 30 | p6 | 48 | 12 | qres |

---

## Hardware Acceleration

On startup, MUCUS probes FFmpeg and the local hardware to select the best available encoding stack. The selection priority is:

| Priority | Stack | Encoder | Notes |
|---|---|---|---|
| 1 | NVIDIA NVENC | `av1_nvenc` | Requires NVIDIA GPU + CUDA |
| 2 | Intel Quick Sync | `av1_qsv` | Requires Intel GPU (Arc recommended) |
| 3 | AMD AMF | `av1_amf` | Requires AMD GPU |
| 4 | Apple VideoToolbox | `av1_videotoolbox` | macOS only |
| 5 | SVT-AV1 (CPU) | `libsvtav1` | Software fallback, reasonable speed |
| 6 | libaom-AV1 (CPU) | `libaom-av1` | Software fallback, very slow |
| 7 | CPU (any AV1) | auto-detected | Last-resort fallback |

Hardware decode acceleration is also configured separately when available, so the decode path is accelerated even on software-encode stacks where possible.

### Parallel Encoding

The number of simultaneous encodes is automatically calculated from available GPU VRAM (or CPU core count for software stacks), with a hard cap of 4 concurrent encodes:

| Stack | Calculation |
|---|---|
| NVIDIA | `floor((VRAM_MB - 2048) / 2560)` capped at 4 |
| Intel Arc | `floor((VRAM_MB - 1024) / 1536)` capped at 4; iGPU fixed at 2 |
| AMD | `floor((VRAM_MB - 1024) / 1536)` capped at 4; default 2 if VRAM undetected |
| Apple | Fixed at 2 |
| CPU | `floor(LogicalCores / 4)` capped at 4 |

---

## Pre-encode Size Prediction

Before encoding each file, MUCUS uses a **bits-per-pixel (bpp)** metric to predict whether the encode is likely to produce a smaller file. Sources that are already efficiently encoded (low bpp) are marked as `Likely-NoSavings` and skipped, saving time on files where AV1 re-encoding would not reduce size.

The bpp threshold used is based on the content type profile's target quality level.

---

## Post-encode Size Check

After each encode completes, MUCUS compares the output file size to the source. If the encoded file is **not smaller** than the source, it is treated as a no-savings result and the `OnComplete` setting determines what happens:

| OnComplete | No-savings action |
|---|---|
| `Nothing` | Copy original source to target directory |
| `Delete` | Move original source to target directory |
| `Replace` | Discard the larger encoded file; do nothing |

The file status is recorded as `Success-NoSavings` in the results.

---

## Resume

MUCUS includes a **pre-flight resume check** that runs before encoding begins. For each source file, it checks whether a valid re-encoded target already exists in the target directory. This allows safe resumption after interruptions (power loss, crash, manual abort) without re-encoding files that already completed successfully.

A target is accepted as a valid re-encode only when **all** of the following are true:

1. The file is an MKV container with an AV1 video stream
2. Duration matches the source within ±1 second
3. File size is greater than 1% of the source size
4. FFprobe can successfully parse the file

Any target that exists but **fails** these checks is treated as a conflict and the run is aborted — the ambiguous file must be resolved manually before re-running.

Audio and subtitle stream count differences emit a warning but do not block resume.

---

## Base-name Collision Detection

If two source files in the same directory share the same base name but have different extensions (e.g. `clip.mp4` and `clip.mov`), both would normally map to `clip.mkv` in the target, causing a silent overwrite. MUCUS detects these collisions before encoding and automatically disambiguates the target names:

```
clip.mp4  →  clip-(mp4).mkv
clip.mov  →  clip-(mov).mkv
```

Collision detection is case-insensitive. Files not involved in any collision continue to use the standard `<baseName>.mkv` naming convention.

---

## Filesystem Metadata

After each successful encode, MUCUS copies the Windows filesystem timestamps from the source file to the target file:

- Creation time
- Last write time
- Last access time

This preserves the original media dates in the re-encoded archive.

---

## File Status Values

| Status | Description |
|---|---|
| `Success` | Encoded successfully and output is smaller than source |
| `Success-NoSavings` | Encoded successfully but output is not smaller; source used instead |
| `Resumed` | Target already existed and was validated as a complete re-encode |
| `AlreadyAV1` | Source was already an AV1 MKV; copied/moved per `OnComplete` |
| `Likely-NoSavings` | Pre-encode bpp check predicted no savings; encoding skipped |
| `Skipped-ProbeError` | FFprobe could not read the source file |
| `Failed` | FFmpeg encode process failed |

---

## Examples

```powershell
# Basic re-encode with all defaults
mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive\Shows"

# Custom quality and preset, custom log directory, delete sources after encode
mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive" `
      -LogDirectory "C:\Logs" -CQ 28 -Preset p6 -OnComplete Delete

# 4K movie library using the Movie profile, high quality
mucus -SourceDirectory "D:\Movies\4K" -TargetDirectory "E:\Archive\4K" `
      -Content Movie -OnComplete Nothing

# TV library — Show profile, replace originals in-place
mucus -SourceDirectory "D:\TV" -TargetDirectory "E:\Archive\TV" `
      -Content Show -OnComplete Replace

# Sports footage — export a WARN/ERROR-only log for quick review
mucus -SourceDirectory "D:\GoPro" -TargetDirectory "E:\Archive\GoPro" `
      -Content Sports -ExportError WARN

# Dry run — log all decisions without encoding or touching any files
mucus -SourceDirectory "D:\GoPro" -TargetDirectory "E:\Archive" -WhatIf

# Suppress the CSV export
mucus -SourceDirectory "D:\Videos" -TargetDirectory "E:\Archive" `
      -ExportList $false

# Show built-in help
mucus -help
```

---

## Output Files

All output files are written to a timestamped subdirectory of `-LogDirectory` (e.g. `encode_logs_20260314_120000\`).

| File | Created when |
|---|---|
| `encode_session_<timestamp>.log` | Always |
| `<path>\<file>_encode.log` | For every file that goes through FFmpeg |
| `FileList_<timestamp>.csv` | `-ExportList $true` (default) |
| `ErrorLog_<timestamp>.log` | `-ExportError WARN` or `-ExportError ERROR` |

The master log contains a final summary table with per-file status, source/target sizes, savings percentages, and aggregate totals.
