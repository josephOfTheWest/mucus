# MUCUS — Media Universal Compression Utility Script
<img src="https://github.com/josephOfTheWest/mucus/blob/main/scr/assets/MUCUS_logo.svg" alt="Image of a film reel squeezed by belt spewing mucus" height="250" width="205" />

MUCUS is a collection of scripts that batch re-encode video files to AV1 using FFmpeg, with automatic hardware acceleration detection, parallel encoding, smart resume, and detailed logging. Authored with the help of Claude Code.

Two implementations are provided, sharing identical encoding logic, content profiles, and behavior:

| Script | Platform | Shell |
|---|---|---|
| [`mucus.ps1`](#mucusps1) | Windows (primary), macOS | PowerShell 7+ |
| [`mucus.sh`](#mucussh) | Linux, macOS | Bash 4+ |

---

## What MUCUS Does

- **Scans recursively** for all common video formats (MP4, MKV, MOV, AVI, MTS, M2TS, HEVC, and more)
- **Probes hardware** at startup and selects the best available AV1 encoder (NVENC → QSV → AMF → VideoToolbox → SVT-AV1 → libaom-AV1)
- **Runs encodes in parallel**, throttled automatically based on detected GPU VRAM or CPU core count
- **Applies per-file content profiles** based on detected resolution (SD → HD → 2K → 4K → 8K+), with individual tuning for CQ, preset, lookahead, and AQ settings
- **Resumes interrupted runs** by validating existing targets against their sources before encoding begins
- **Detects base-name collisions** and disambiguates target names automatically
- **Skips files predicted to show no savings** (AV1 sources; HEVC/VP9 below a bits-per-pixel threshold)
- **Checks post-encode file size** and falls back to the original source when the encode is larger
- **Applies an OnComplete action** (Nothing / Delete / Replace) to source files after successful encodes
- **Preserves source timestamps** on all output files
- **Writes a master session log**, per-file FFmpeg logs, an optional filtered error log, and a CSV results export

---

## Hardware Acceleration

Both scripts probe FFmpeg and the local hardware at startup and select the best available AV1 encoding stack:

| Priority | Stack | Encoder | Notes |
|---|---|---|---|
| 1 | NVIDIA NVENC | `av1_nvenc` | Requires NVIDIA GPU + CUDA |
| 2 | Intel Quick Sync | `av1_qsv` | Requires Intel GPU (Arc recommended) |
| 3 | AMD AMF | `av1_amf` | Requires AMD GPU; Windows only (`mucus.ps1`) |
| 4 | Apple VideoToolbox | `av1_videotoolbox` | macOS only |
| 5 | SVT-AV1 (CPU) | `libsvtav1` | Software fallback, reasonable speed |
| 6 | libaom-AV1 (CPU) | `libaom-av1` | Software fallback, very slow |
| 7 | CPU (any AV1) | auto-detected | Last-resort fallback |

Hardware decode acceleration is also configured separately when available, so the decode path is accelerated even on software-encode stacks.

### Parallel Encoding

The number of simultaneous encodes is automatically calculated from available GPU VRAM or CPU core count, with a hard cap of 4 concurrent encodes:

| Stack | Calculation |
|---|---|
| NVIDIA | `floor((VRAM_MB - 2048) / 2560)` capped at 4 |
| Intel Arc | `floor((VRAM_MB - 1024) / 1536)` capped at 4; iGPU fixed at 2 |
| AMD | `floor((VRAM_MB - 1024) / 1536)` capped at 4; default 2 if VRAM undetected |
| Apple | Fixed at 2 |
| CPU | `floor(LogicalCores / 4)` capped at 4 |

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
| `SpatialAQ` | Spatial adaptive quantization (1 = enabled) |
| `TemporalAQ` | Temporal adaptive quantization (1 = enabled) |
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

## Encoding Behaviour

### Pre-encode Size Prediction

Before encoding each file, MUCUS checks two conservative criteria to predict whether re-encoding is likely to produce a smaller file:

1. **Source is already AV1** — always skipped (re-encoding AV1→AV1 at the same quality level will not reduce size).
2. **Source is HEVC or VP9 with a bits-per-pixel (bpp) value below `0.003`** — already efficiently encoded; AV1 rarely beats this threshold.

All other codecs (H.264, MPEG-2, etc.) always proceed to encode. Files matching either criterion are marked `Skipped-LikelyNoSavings` and the `OnComplete` action is applied directly to the source (copy, move, or no-op), consistent with the post-encode no-savings behavior.

### Post-encode Size Check

After each encode completes, MUCUS compares the output file size to the source. If the encoded file is **not smaller** than the source, it is treated as a no-savings result:

| OnComplete | No-savings action |
|---|---|
| `Nothing` | Copy original source to target directory |
| `Delete` | Move original source to target directory |
| `Replace` | Discard the larger encoded file; do nothing |

The file status is recorded as `Success-NoSavings` in the results.

### Resume

MUCUS includes a **pre-flight resume check** that runs before encoding begins. For each source file, it checks whether a valid re-encoded target already exists in the target directory. This allows safe resumption after interruptions (power loss, crash, manual abort) without re-encoding files that already completed successfully.

A target is accepted as a valid re-encode only when **all** of the following are true:

1. The file is an MKV container with an AV1 video stream
2. Duration matches the source within ±1 second
3. File size is greater than 1% of the source size
4. FFprobe can successfully parse the file

Any target that exists but **fails** these checks is treated as a conflict and the run is aborted — the ambiguous file must be resolved manually before re-running.

Audio and subtitle stream count differences emit a warning but do not block resume.

### Base-name Collision Detection

If two source files in the same directory share the same base name but have different extensions (e.g. `clip.mp4` and `clip.mov`), both would normally map to `clip.mkv` in the target, causing a silent overwrite. MUCUS detects these collisions before encoding and automatically disambiguates the target names:

```
clip.mp4  →  clip-(mp4).mkv
clip.mov  →  clip-(mov).mkv
```

Collision detection is case-insensitive. Files not involved in any collision continue to use the standard `<baseName>.mkv` naming convention.

---

## File Status Values

| Status | Description |
|---|---|
| `Success` | Encoded successfully and output is smaller than source |
| `Success-NoSavings` | Encoded successfully but output is not smaller; source used instead |
| `Resumed` | Target already existed and was validated as a complete re-encode |
| `AlreadyAV1MKV` | Source was already an AV1 MKV; copied/moved per `OnComplete` |
| `Skipped-LikelyNoSavings` | Pre-encode check predicted no savings; encoding skipped |
| `Skipped-ProbeError` | FFprobe could not read the source file |
| `Failed` | FFmpeg encode process failed |

---

## mucus.ps1

PowerShell 7 implementation. Primary target is Windows; macOS is supported via Apple VideoToolbox.

### Requirements

| Requirement | Details |
|---|---|
| PowerShell | 7.0 or higher |
| FFmpeg | 5.1+ with AV1 support ([gyan.dev full build](https://www.gyan.dev/ffmpeg/builds/)) |
| GPU | NVIDIA, Intel, AMD, or Apple Silicon (software fallback available) |
| OS | Windows (primary); macOS supported via VideoToolbox |

> **Tip:** Place `ffmpeg.exe` and `ffprobe.exe` in the same directory as the script to override any system PATH versions.

### Installation

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

### Usage

```
mucus -SourceDirectory <path> -TargetDirectory <path> [options]
mucus -help
```

Only `-SourceDirectory` and `-TargetDirectory` are required.

### Parameters

#### `-SourceDirectory` `<string>` — **Required**

Full path to the directory containing source video files. Scanned recursively.

---

#### `-TargetDirectory` `<string>` — **Required**

Full path to the directory where re-encoded files will be written. The source directory structure is mirrored in the target. All output files are written as `.mkv` with an AV1 video stream.

> **Note:** The path is fully normalized at startup (relative paths are resolved against the current working directory). Source and target directories must not overlap.

---

#### `-LogDirectory` `<string>` — Default: `.\encode_logs`

Full path to the directory where log files will be written. A timestamp suffix is automatically appended to the directory name so concurrent or repeated runs never share the same log directory.

---

#### `-Content` `<string>` — Default: `General`

Selects the content type profile. See [Content Profiles](#content-profiles).

| Value | Description |
|---|---|
| `General` | Balanced defaults for any mixed or unknown content, SD through 8K |
| `Sports` | Optimized for fast motion: aggressive adaptive quantization, short lookahead |
| `Movie` | Optimized for feature film: high lookahead, strong AQ, resolution-aware quality |
| `Show` | Optimized for TV episodes: efficient compression for large libraries |

Use `-CQ` or `-Preset` alongside `-Content` to override individual profile values.

---

#### `-CQ` `<int>` — Default: profile value — Range: `0`–`63`

Constant Quality value for AV1 encoding. Lower values produce higher quality and larger files. When supplied, overrides the selected content profile's default CQ for every file in the run.

Recommended ranges:
- General archiving: `27`–`32`
- High quality / film: `22`–`26`
- Sports / fast motion: `26`–`30`

---

#### `-Preset` `<string>` — Default: profile value — Values: `p1`–`p7`

Encoding speed preset. `p1` is the fastest (lowest quality/compression). `p7` is the slowest (best quality/compression ratio).

---

#### `-OnComplete` `<string>` — Default: `Nothing`

Action to take on the **source** file after each successful encode.

| Value | Effect |
|---|---|
| `Nothing` | Leave the source file untouched |
| `Delete` | Delete the source file; remove the source directory if it becomes empty |
| `Replace` | Move the encoded output to the source directory, then delete the original |

> **Warning:** `Delete` and `Replace` are destructive and **cannot be undone via the Recycle Bin**. An interactive confirmation prompt is shown before the run starts (bypassed with `-WhatIf`).

**Special behavior when the source is already a valid AV1 MKV** (no transcode performed):

| Value | Effect |
|---|---|
| `Nothing` | Copy source to target location |
| `Delete` | Move source to target location |
| `Replace` | No action — file is already in the correct format and location |

---

#### `-NoExportList` `[switch]`

When specified, suppresses the per-file CSV results export at the end of the session.

**File name:** `FileList_<timestamp>.csv`

**Columns:** File, Relative Path, Status, Src Action, Target Action, Src Size, Tgt Size, Savings

A **TOTAL** row is appended as the final entry with aggregate sizes and overall savings percentage.

---

#### `-ExportError` `<string>` — Default: `NONE` — Values: `NONE`, `WARN`, `ERROR`

Controls whether a separate filtered log file is written alongside the master log.

**File name:** `ErrorLog_<timestamp>.log`

| Value | Effect |
|---|---|
| `NONE` | No error log is written |
| `WARN` | All `WARN` and `ERROR` log entries are written to the error log |
| `ERROR` | Only `ERROR` log entries are written to the error log |

---

#### `-WhatIf` `[switch]`

Simulates the entire run without encoding any files or modifying the filesystem. All decisions are logged to the console and the master log file, but no FFmpeg processes are started and no source files are touched. Bypasses the destructive action confirmation prompt.

---

#### `-help` `[switch]`

Displays the built-in help text and exits.

---

### Filesystem Metadata

After each successful encode, `mucus.ps1` copies all three Windows filesystem timestamps from the source file to the target file:

- Creation time
- Last write time
- Last access time

### Output Files

All output files are written to a timestamped subdirectory of `-LogDirectory` (e.g. `encode_logs_20260314_120000\`).

| File | Created when |
|---|---|
| `encode_session_<timestamp>.log` | Always |
| `<path>\<file>_encode.log` | For every file that goes through FFmpeg |
| `FileList_<timestamp>.csv` | Always, unless `-NoExportList` is specified |
| `ErrorLog_<timestamp>.log` | `-ExportError WARN` or `-ExportError ERROR` |

### Examples

```powershell
# Basic re-encode with all defaults
mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive\Shows"

# Custom quality and preset, custom log directory, delete sources after encode
mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive" `
      -LogDirectory "C:\Logs" -CQ 28 -Preset p6 -OnComplete Delete

# 4K movie library using the Movie profile
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
mucus -SourceDirectory "D:\Videos" -TargetDirectory "E:\Archive" -NoExportList

# Show built-in help
mucus -help
```

---

## mucus.sh

Bash implementation. Targets Linux and macOS. Mirrors `mucus.ps1` behavior exactly, with platform-appropriate tooling.

> **Note on AMD AMF:** `av1_amf` is not supported on Linux or macOS. When no other hardware encoder is found, MUCUS falls back to SVT-AV1 or libaom-AV1 software encoding.

### Requirements

| Requirement | Details |
|---|---|
| Bash | 4.0 or higher (macOS ships Bash 3 — `brew install bash`) |
| FFmpeg | 5.1+ with AV1 support |
| jq | JSON parsing for FFprobe output (`apt install jq` / `brew install jq`) |
| flock | Mutex-safe parallel log writes (Linux built-in; macOS: `brew install util-linux`) |
| GPU | NVIDIA, Intel, or Apple Silicon (software fallback available) |
| OS | Linux (primary); macOS supported via VideoToolbox |

Optional:
- `nvidia-smi` — NVIDIA VRAM detection
- `rocm-smi` — AMD VRAM detection
- `lspci` — GPU vendor detection (`pciutils` package)

> **Tip:** Place `ffmpeg` and `ffprobe` in the same directory as the script to override any system PATH versions.

### Installation

```bash
# Make the script executable
chmod +x mucus.sh

# Run directly
./mucus.sh --source /media/Videos --target /archive/Videos
```

Or source it to call `mucus` as a function in the current shell:

```bash
source mucus.sh
mucus --source /media/Videos --target /archive/Videos
```

### Usage

```
mucus.sh --source <path> --target <path> [options]
mucus.sh --help
```

Only `--source` and `--target` are required. All flags support both `--flag value` and `--flag=value` forms.

### Parameters

#### `--source`, `-s` `<path>` — **Required**

Full path to the directory containing source video files. Scanned recursively.

---

#### `--target`, `-t` `<path>` — **Required**

Full path to the directory where re-encoded files will be written. The source directory structure is mirrored in the target. All output files are written as `.mkv` with an AV1 video stream.

> **Note:** Source and target directories must not overlap — the script will abort if one is a subdirectory of the other, or if they are the same path.

---

#### `--log-dir`, `-l` `<path>` — Default: `./encode_logs`

Full path to the directory where log files will be written. A timestamp suffix is automatically appended to the directory name so concurrent or repeated runs never share the same log directory.

---

#### `--content`, `-c` `<string>` — Default: `General`

Selects the content type profile. See [Content Profiles](#content-profiles).

| Value | Description |
|---|---|
| `General` | Balanced defaults for any mixed or unknown content, SD through 8K |
| `Sports` | Optimized for fast motion: aggressive adaptive quantization, short lookahead |
| `Movie` | Optimized for feature film: high lookahead, strong AQ, resolution-aware quality |
| `Show` | Optimized for TV episodes: efficient compression for large libraries |

Use `--cq` or `--preset` alongside `--content` to override individual profile values.

---

#### `--cq`, `-q` `<int>` — Default: profile value — Range: `0`–`63`

Constant Quality value for AV1 encoding. Lower values produce higher quality and larger files. When supplied, overrides the selected content profile's default CQ for every file in the run.

Recommended ranges:
- General archiving: `27`–`32`
- High quality / film: `22`–`26`
- Sports / fast motion: `26`–`30`

---

#### `--preset`, `-p` `<string>` — Default: profile value — Values: `p1`–`p7`

Encoding speed preset. `p1` is the fastest (lowest quality/compression). `p7` is the slowest (best quality/compression ratio).

---

#### `--on-complete`, `-o` `<string>` — Default: `Nothing`

Action to take on the **source** file after each successful encode.

| Value | Effect |
|---|---|
| `Nothing` | Leave the source file untouched |
| `Delete` | Delete the source file; remove the source directory if it becomes empty |
| `Replace` | Move the encoded output to the source directory, then delete the original |

> **Warning:** `Delete` and `Replace` are destructive and **cannot be undone**. An interactive confirmation prompt is shown before the run starts (bypassed with `--dry-run`).

**Special behavior when the source is already a valid AV1 MKV** (no transcode performed):

| Value | Effect |
|---|---|
| `Nothing` | Copy source to target location |
| `Delete` | Move source to target location |
| `Replace` | No action — file is already in the correct format and location |

---

#### `--no-export-list`

When specified, suppresses the per-file CSV results export at the end of the session.

**File name:** `FileList_<timestamp>.csv`

**Columns:** File, Relative Path, Status, Src Action, Target Action, Src Size, Tgt Size, Savings

A **TOTAL** row is appended as the final entry with aggregate sizes and overall savings percentage.

---

#### `--export-error` `<string>` — Default: `NONE` — Values: `NONE`, `WARN`, `ERROR`

Controls whether a separate filtered log file is written alongside the master log.

**File name:** `ErrorLog_<timestamp>.log`

| Value | Effect |
|---|---|
| `NONE` | No error log is written |
| `WARN` | All `WARN` and `ERROR` log entries are written to the error log |
| `ERROR` | Only `ERROR` log entries are written to the error log |

---

#### `--dry-run`, `--what-if`

Simulates the entire run without encoding any files or modifying the filesystem. All decisions are logged to the console and the master log file, but no FFmpeg processes are started and no source files are touched. Bypasses the destructive action confirmation prompt.

---

#### `--help`, `-h`

Displays the built-in help text and exits.

---

### Filesystem Metadata

After each successful encode, `mucus.sh` copies the source file's **modification time** and **access time** to the target file using `touch -r`. Creation time is not preserved — Linux filesystems do not expose file creation time for modification.

### Output Files

All output files are written to a timestamped subdirectory of `--log-dir` (e.g. `encode_logs_20260314_120000/`).

| File | Created when |
|---|---|
| `encode_session_<timestamp>.log` | Always |
| `<path>/<file>_encode.log` | For every file that goes through FFmpeg |
| `FileList_<timestamp>.csv` | Always, unless `--no-export-list` is specified |
| `ErrorLog_<timestamp>.log` | `--export-error WARN` or `--export-error ERROR` |

### Examples

```bash
# Basic re-encode with all defaults
./mucus.sh --source /media/Shows --target /archive/Shows

# Custom quality, preset, log path, delete sources on success
./mucus.sh --source /media/Shows --target /archive \
           --log-dir /var/log/mucus --cq 28 --preset p6 \
           --on-complete Delete

# 4K movie library using the Movie profile
./mucus.sh --source /media/Movies/4K --target /archive/4K \
           --content Movie --on-complete Nothing

# TV library — Show profile, replace originals in-place
./mucus.sh --source /media/TV --target /archive/TV \
           --content Show --on-complete Replace

# Sports footage — export a WARN/ERROR-only log for quick review
./mucus.sh --source /media/GoPro --target /archive/GoPro \
           --content Sports --export-error WARN

# Dry run — log all decisions without encoding or touching any files
./mucus.sh --source /media/GoPro --target /archive --dry-run

# Suppress the CSV export
./mucus.sh --source /media/Videos --target /archive --no-export-list

# Show built-in help
./mucus.sh --help
```

---

## Differences at a Glance

| Feature | `mucus.ps1` | `mucus.sh` |
|---|---|---|
| Platform | Windows, macOS | Linux, macOS |
| Shell | PowerShell 7+ | Bash 4+ |
| Extra dependencies | None beyond FFmpeg | `jq`, `flock` |
| AMD AMF support | Yes | No (falls back to SVT-AV1) |
| Parameter style | `-SourceDirectory`, `-TargetDirectory` | `--source`, `--target` |
| Dry-run flag | `-WhatIf` | `--dry-run` / `--what-if` |
| Suppress CSV flag | `-NoExportList` | `--no-export-list` |
| Timestamp preservation | Creation + write + access time | Modification + access time only |
| Confirmation prompt | Interactive PowerShell prompt | Bash `read` prompt |
