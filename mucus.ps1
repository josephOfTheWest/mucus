#Requires -Version 7.0
<#
.SYNOPSIS
    Re-encodes video files using FFmpeg with AV1 hardware acceleration.

.DESCRIPTION
    Recursively scans a source directory for video files and re-encodes them using
    FFmpeg's av1 encoder with hardware acceleration. Mirrors the source
    directory structure in the target directory. Supports multi-threaded encoding
    throttled by available GPU VRAM. Generates a master process log and individual
    per-file encode logs. Produces a final summary table in the master log.

.PARAMETER SourceDirectory
    Full path to the directory containing source video files. Scanned recursively.

.PARAMETER TargetDirectory
    Full path to the directory where re-encoded files will be written. Directory
    structure mirrors the source.

.PARAMETER LogDirectory
    Full path to the directory where log files will be written. Defaults to the
    current working directory. Log structure mirrors the source directory structure
    for per-file logs.

.PARAMETER CQ
    Constant Quality value for AV1 encoding (0-63, lower = better quality).
    Defaults to 30. Recommended range for sports archiving: 28-32.

.PARAMETER Preset
    Encoding preset (p1=fastest/worst .. p7=slowest/best).
    Defaults to p5.

.PARAMETER OnComplete
    Action to take on the SOURCE file after a successful encode:
      Nothing  (default) - Leave source file untouched.
      Delete             - Delete source file (and its directory if empty afterwards).
      Replace            - Move encoded output to source directory, delete original source.

    Special handling when source is already a valid AV1 MKV (no transcode performed):
      Nothing  - Copy source to target location.
      Delete   - Move source to target location.
      Replace  - Do nothing (file is already correct format and location).

.PARAMETER Content
    Content type profile that controls all FFmpeg quality/encode parameters:
      General   (default) - Balanced profile suitable for any content from SD to 8K.
      Sports              - Optimised for fast motion: high-framerate action, low latency
                            lookahead, aggressive AQ to handle rapid scene changes.
      Movie               - Optimised for feature film: cinematic quality, strong AQ,
                            high lookahead, good detail retention in dark scenes.
                            Resolution-aware: higher tiers unlock slower presets and
                            stronger AQ (SD through 8K+).
      Show                - Optimised for recorded TV episodes: efficient compression at
                            broadcast quality, balanced AQ, fast enough for large libraries.

    When -CQ is also supplied it overrides the profile's default CQ value.
    When -Preset is also supplied it overrides the profile's default preset.

.EXAMPLE
    . .\mucus.ps1
    mucus -SourceDirectory "D:\GoPro\Baseball" -TargetDirectory "E:\Archive\Baseball"

.EXAMPLE
    mucus -SourceDirectory "D:\GoPro" -TargetDirectory "E:\Archive" `
                         -LogDirectory "C:\Logs" -CQ 28 -Preset p6 -OnComplete Replace

.EXAMPLE
    mucus -SourceDirectory "D:\Movies\4K" -TargetDirectory "E:\Archive\4K" `
                         -Content 'Movie' -OnComplete Delete

.EXAMPLE
    mucus -SourceDirectory "D:\TV" -TargetDirectory "E:\Archive\TV" `
                         -Content Show -OnComplete Replace

.NOTES
    Requires PowerShell 7.0+, FFmpeg with AV1 support, and a GPU that supports hardware acceleration.
    FFmpeg/FFprobe placed in the working directory override system PATH versions.
    Multi-threading is throttled automatically based on detected GPU VRAM.
    Supports -WhatIf: destructive source-file operations are simulated without executing.
#>

function mucus {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$TargetDirectory,

        [Parameter(Mandatory = $false, Position = 2)]
        [string]$LogDirectory = (Join-Path (Get-Location).Path 'encode_logs'),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 63)]
        [int]$CQ,

        [Parameter(Mandatory = $false)]
        [ValidateSet('p1','p2','p3','p4','p5','p6','p7')]
        [string]$Preset,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Nothing','Delete','Replace')]
        [string]$OnComplete = 'Nothing',

        [Parameter(Mandatory = $false)]
        [ValidateSet('General','Sports','Movie','Show')]
        [string]$Content = 'General',

        [Parameter(Mandatory = $false)]
        [bool]$ExportList = $true,

        [Parameter(Mandatory = $false)]
        [ValidateSet('NONE','WARN','ERROR')]
        [string]$ExportError = 'NONE',

        [Parameter(Mandatory = $false)]
        [switch]$help
    )

    # =========================================================================
    # HELP
    # =========================================================================
    if ($help) {
        Write-Host @"

SYNOPSIS
    Re-encodes video files using FFmpeg with AV1 hardware acceleration.

USAGE
    mucus -SourceDirectory <path> -TargetDirectory <path> [options]
    mucus -help

PARAMETERS
    -SourceDirectory  <string>  [Required]
        Full path to the directory containing source video files. Scanned recursively.

    -TargetDirectory  <string>  [Required]
        Full path to the directory where re-encoded files will be written.
        Directory structure mirrors the source.

    -LogDirectory     <string>  [Default: .\encode_logs]
        Full path to the directory where log files will be written.
        The master session log is written to the root of this directory.
        Per-file encode logs are written to subdirectories mirroring the source structure.

    -Content          <string>  [Default: General]
        Content type profile controlling all FFmpeg quality and encode parameters.
        Profiles and their optimised defaults (resolved per-file from source resolution):

          General   — Balanced for any content from SD to 8K.
          Sports    — Fast motion: aggressive AQ, moderate lookahead.
          Movie     — Feature film: resolution-aware quality, strong AQ, high lookahead.
          Show      — TV episodes: efficient compression, large libraries.

        Use -CQ or -Preset alongside -Content to override individual profile values.

    -CQ               <int>     [Default: profile value]  Range: 0–63
        Constant Quality value for AV1 encoding. Lower = better quality / larger file.
        Overrides the selected Content profile's default CQ when supplied.

    -Preset           <string>  [Default: profile value]  Values: p1–p7
        Encoding speed preset. p1 = fastest/lowest quality, p7 = slowest/best.
        Overrides the selected Content profile's default preset when supplied.

    -OnComplete       <string>  [Default: Nothing]
        Action to take on the SOURCE file after a successful encode:

          Nothing  — Leave source file untouched. (default)
          Delete   — Delete source file; remove directory if it becomes empty.
          Replace  — Move encoded output to source directory, delete original.

        Special behaviour when source is already a valid AV1 MKV (no transcode):
          Nothing  — Copy source to target location.
          Delete   — Move source to target location.
          Replace  — No action; file stays in source directory (already correct
                     format and location — no file is created in the target).

    -WhatIf           [switch]
        Simulate the run without encoding or modifying any files. All decisions are
        logged but no FFmpeg processes are started and no source files are touched.

    -ExportList       <bool>    [Default: True]
        When True (default), exports the per-file results to a CSV file in the
        LogDirectory at the end of the session.  The file is named:
            FileList_<yyyyMMdd_HHmmss>.csv
        Columns: File, Status, Src Action, Target Action, Src Size, Tgt Size, Savings.
        A Total row is appended as the final entry.
        Pass -ExportList $false to suppress the export.

    -ExportError      <string>  [Default: NONE]  Values: NONE, WARN, ERROR
        Controls whether a separate error log file is written to the LogDirectory.
        The file is named:  ErrorLog_<yyyyMMdd_HHmmss>.log

          NONE   — No error log is written. (default)
          WARN   — All WARN and ERROR log entries are written to the error log.
          ERROR  — Only ERROR log entries are written to the error log.

    -help             [switch]
        Display this help text and exit.

REQUIREMENTS
    - PowerShell 7.0 or higher
    - FFmpeg 5.1+ with AV1 hardware acceleration support  (https://www.gyan.dev/ffmpeg/builds/)
    - GPU that supports hardware acceleration
    - Appropriate GPU driver
    Placing ffmpeg.exe / ffprobe.exe in the working directory overrides system PATH versions.

EXAMPLES
    # Basic re-encode with all defaults
    mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive\Shows"

    # Custom quality and preset, custom log path, delete sources on success
    mucus -SourceDirectory "D:\Shows" -TargetDirectory "E:\Archive" ``
                         -LogDirectory "C:\Logs" -CQ 28 -Preset p6 -OnComplete Replace

    # TV library using the Show profile, replace originals in-place
    mucus -SourceDirectory "D:\TV" -TargetDirectory "E:\Archive\TV" ``
                         -Content Show -OnComplete Replace

    # Dry run — see what would happen without touching any files
    mucus -SourceDirectory "D:\GoPro" -TargetDirectory "E:\Archive" -WhatIf

"@ -ForegroundColor Cyan
        return
    }

    # =========================================================================
    # BANNER
    # =========================================================================
    Write-Host @"

  ##     ##   ##     ##    #######    ##     ##    #######
  ###   ###   ##     ##   ##     ##   ##     ##   ##     ##
  #### ####   ##     ##   ##          ##     ##   ##
  ## ### ##   ##     ##   ##          ##     ##    #######
  ##  #  ##   ##     ##   ##          ##     ##          ##
  ##     ##    ##   ##    ##     ##    ##   ##    ##     ##
  ##     ##     #####      #######      #####      #######

  Media Universal Compression Utility Script

"@ -ForegroundColor Cyan

    # =========================================================================
    # PARAMETER VALIDATION
    # =========================================================================
    $paramErrors = [System.Collections.Generic.List[string]]::new()

    if (-not $PSBoundParameters.ContainsKey('SourceDirectory')) {
        $paramErrors.Add('-SourceDirectory  is required. Provide the full path to the directory containing source video files.')
    } elseif (-not (Test-Path $SourceDirectory -PathType Container)) {
        $paramErrors.Add("-SourceDirectory  '$SourceDirectory' does not exist or is not a directory.")
    }

    if (-not $PSBoundParameters.ContainsKey('TargetDirectory')) {
        $paramErrors.Add('-TargetDirectory  is required. Provide the full path where re-encoded files will be written.')
    }

    if ($paramErrors.Count -gt 0) {
        Write-Host "`n[ERROR] Cannot start — the following required parameters are missing or invalid:`n" -ForegroundColor Red
        foreach ($err in $paramErrors) {
            Write-Host "    • $err" -ForegroundColor Yellow
        }
        Write-Host "`n    Both -SourceDirectory and -TargetDirectory must be supplied to run."  -ForegroundColor Yellow
        Write-Host "    Run  .\mucus.ps1 -help  for full usage information and examples.`n"    -ForegroundColor Cyan
        return
    }

    # =========================================================================
    # DESTRUCTIVE ACTION CONFIRMATION
    # =========================================================================
    if ($OnComplete -in @('Delete', 'Replace') -and -not $WhatIfPreference) {
        $actionDesc = switch ($OnComplete) {
            'Delete'  { 'DELETE the original source video files after each successful encode.' }
            'Replace' { 'DELETE the original source video files and REPLACE them with the re-encoded versions.' }
        }
        Write-Host ''
        Write-Host '  ⚠  WARNING: DESTRUCTIVE ACTION' -ForegroundColor Red
        Write-Host ''
        Write-Host "  OnComplete is set to '$OnComplete'. This will permanently:" -ForegroundColor Yellow
        Write-Host "    $actionDesc" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Source files that are deleted CANNOT be recovered from the Recycle Bin.' -ForegroundColor Yellow
        Write-Host "  Source directory : $SourceDirectory" -ForegroundColor Cyan
        Write-Host ''
        $confirmation = Read-Host '  Type Y to confirm and proceed, or any other key to abort'
        if ($confirmation -ne 'Y') {
            Write-Host "`n  Aborted. No files were modified.`n" -ForegroundColor Green
            return
        }
        Write-Host ''
    }

    # =========================================================================
    # HELPERS
    # =========================================================================
    $logMutex = $null
    $logMutex = [System.Threading.Mutex]::new($false, 'VideoEncodeLogMutex')

    function Write-Log {
        param(
            [string]$Message,
            [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
            [string]$Level = 'INFO',
            [string]$LogFile
        )
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $entry     = "[$timestamp] [$Level] $Message"
        $acquired  = $logMutex.WaitOne(5000)
        if (-not $acquired) {
            Write-Host "[$timestamp] [WARN] Log mutex timeout — entry may be lost: $Message" -ForegroundColor Yellow
        }
        try {
            if ($acquired) {
                Add-Content -Path $LogFile -Value $entry -Encoding UTF8
                if ($null -ne $errorLogPath) {
                    $shouldWriteErr = ($ExportError -eq 'WARN' -and $Level -in @('WARN','ERROR')) -or
                                      ($ExportError -eq 'ERROR' -and $Level -eq 'ERROR')
                    if ($shouldWriteErr) { Add-Content -Path $errorLogPath -Value $entry -Encoding UTF8 }
                }
            }
        }
        finally { if ($acquired) { $logMutex.ReleaseMutex() } }
        switch ($Level) {
            'INFO'    { Write-Host $entry -ForegroundColor Cyan    }
            'WARN'    { Write-Host $entry -ForegroundColor Yellow  }
            'ERROR'   { Write-Host $entry -ForegroundColor Red     }
            'SUCCESS' { Write-Host $entry -ForegroundColor Green   }
        }
    }

    function Format-Bytes([long]$Bytes) {
        if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GB" }
        if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 2)) MB" }
        if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 2)) KB" }
        return "$Bytes B"
    }

    try {

    # =========================================================================
    # STEP 1: Resolve FFmpeg / FFprobe (working directory takes priority)
    # =========================================================================
    $workingDir   = (Get-Location).Path
    $ffmpegLocal  = Join-Path $workingDir 'ffmpeg.exe'
    $ffprobeLocal = Join-Path $workingDir 'ffprobe.exe'
    $ffmpeg  = if (Test-Path $ffmpegLocal)  { $ffmpegLocal }  else { 'ffmpeg'  }
    $ffprobe = if (Test-Path $ffprobeLocal) { $ffprobeLocal } else { 'ffprobe' }

    Write-Host "[INFO] FFmpeg  : $ffmpeg"  -ForegroundColor Cyan
    Write-Host "[INFO] FFprobe : $ffprobe" -ForegroundColor Cyan

    foreach ($exe in @($ffmpeg, $ffprobe)) {
        try   { $null = & $exe -version 2>&1 }
        catch {
            Write-Host "[ERROR] Cannot execute '$exe'. Ensure FFmpeg is installed or place executables in the working directory." -ForegroundColor Red
            Write-Host "        Download from: https://www.gyan.dev/ffmpeg/builds/" -ForegroundColor Yellow
            return
        }
    }

    # =========================================================================
    # STEP 2: Probe FFmpeg hardware acceleration capabilities
    # =========================================================================
    Write-Host "`n[INFO] Probing FFmpeg hardware acceleration capabilities..." -ForegroundColor Cyan

    $ffmpegVer  = (& $ffmpeg -version  2>&1) -join "`n"
    $ffEncoders = (& $ffmpeg -encoders 2>&1) -join "`n"
    $ffHwaccels = (& $ffmpeg -hwaccels 2>&1) -join "`n"

    if ($ffmpegVer -notmatch 'version') {
        Write-Host "[ERROR] FFmpeg did not return version information. The executable may be corrupt." -ForegroundColor Red
        return
    }

    # Map which APIs and AV1 encoders are present in this FFmpeg build
    $apiPresent = @{}
    foreach ($api in @('cuda','cuvid','nvenc','d3d11va','qsv','vaapi','amf','vulkan','opencl','videotoolbox')) {
        $apiPresent[$api] = ($ffHwaccels + "`n" + $ffEncoders) -match $api
    }
    $encPresent = @{}
    foreach ($enc in @('av1_nvenc','av1_qsv','av1_amf','av1_videotoolbox','libsvtav1','libaom-av1')) {
        $encPresent[$enc] = $ffEncoders -match [regex]::Escape($enc)
    }

    $apiList = ($apiPresent.GetEnumerator() | Where-Object Value | ForEach-Object { $_.Key.ToUpper() }) -join ', '
    $encList = ($encPresent.GetEnumerator() | Where-Object Value | ForEach-Object { $_.Key }) -join ', '
    Write-Host "[INFO] HW APIs available  : $(if ($apiList) { $apiList } else { 'none detected' })" -ForegroundColor Cyan
    Write-Host "[INFO] AV1 encoders found : $(if ($encList) { $encList } else { 'none — software fallback only' })" -ForegroundColor Cyan

    # Detect installed GPU hardware via WMI (vendor presence used alongside FFmpeg checks)
    $gpuControllers = @()
    try { $gpuControllers = Get-CimInstance Win32_VideoController -ErrorAction Stop } catch { }
    $hasNvidiaGpu = ($gpuControllers | Where-Object { $_.Name -match 'NVIDIA'         }).Count -gt 0
    $hasIntelGpu  = ($gpuControllers | Where-Object { $_.Name -match 'Intel'          }).Count -gt 0
    $hasAmdGpu    = ($gpuControllers | Where-Object { $_.Name -match 'AMD|Radeon|ATI' }).Count -gt 0

    # =========================================================================
    # STEP 3: Select optimal hardware stack (encode + decode) and detect VRAM
    # =========================================================================
    # Priority: NVIDIA → Intel → AMD → Apple → Software (SVT-AV1) → Software (libaom)
    Write-Host "`n[INFO] Selecting hardware acceleration stack..." -ForegroundColor Cyan

    $selectedStack  = $null
    $hwVendor       = $null
    $vramMB         = 0
    $maxParallel    = 1
    $cpuFallbackEnc = $null
    $hwDecodeArgs  = [System.Collections.Generic.List[string]]::new()

    # Priority 1 — NVIDIA NVENC + NVDEC (cuda) --------------------------------
    if (-not $selectedStack -and $encPresent['av1_nvenc'] -and $apiPresent['cuda'] -and $hasNvidiaGpu) {
        try {
            $smiOut = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>&1 |
                      Select-Object -First 1
            $parsed = [int]($smiOut.Trim())
            if ($parsed -gt 0) {
                $selectedStack = 'NVIDIA-NVENC'
                $hwVendor      = 'NVIDIA'
                $vramMB        = $parsed
                $hwDecodeArgs.AddRange([string[]]@('-hwaccel','cuda','-hwaccel_output_format','cuda'))
            } else {
                Write-Host "[WARN] nvidia-smi returned an invalid VRAM value ('$smiOut') — NVIDIA stack skipped." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "[WARN] nvidia-smi query failed: $($_.Exception.Message) — NVIDIA stack skipped." -ForegroundColor Yellow
        }
    }

    # Priority 2 — Intel Quick Sync Video (QSV) --------------------------------
    if (-not $selectedStack -and $encPresent['av1_qsv'] -and $apiPresent['qsv'] -and $hasIntelGpu) {
        $selectedStack = 'INTEL-QSV'
        $hwVendor      = 'Intel'
        $hwDecodeArgs.AddRange([string[]]@('-hwaccel','qsv','-hwaccel_output_format','qsv'))
        $intelGpu = $gpuControllers | Where-Object { $_.Name -match 'Intel' } | Select-Object -First 1
        if ($intelGpu) {
            $wmiMB = [math]::Round($intelGpu.AdapterRAM / 1MB)
            if ($wmiMB -gt 0 -and $wmiMB -ne 4096 -and $wmiMB -le 131072) { $vramMB = $wmiMB }
        }
    }

    # Priority 3 — AMD AMF -----------------------------------------------------
    if (-not $selectedStack -and $encPresent['av1_amf'] -and $hasAmdGpu) {
        $selectedStack = 'AMD-AMF'
        $hwVendor      = 'AMD'
        if ($apiPresent['d3d11va']) {
            $hwDecodeArgs.AddRange([string[]]@('-hwaccel','d3d11va','-hwaccel_output_format','d3d11'))
        }
        $amdGpu = $gpuControllers | Where-Object { $_.Name -match 'AMD|Radeon|ATI' } | Select-Object -First 1
        if ($amdGpu) {
            $wmiMB = [math]::Round($amdGpu.AdapterRAM / 1MB)
            if ($wmiMB -gt 0 -and $wmiMB -ne 4096 -and $wmiMB -le 131072) { $vramMB = $wmiMB }
        }
    }

    # Priority 4 — Apple VideoToolbox ------------------------------------------
    if (-not $selectedStack -and $encPresent['av1_videotoolbox'] -and $apiPresent['videotoolbox'] -and $IsMacOS) {
        $selectedStack = 'APPLE-VTB'
        $hwVendor      = 'Apple'
        $hwDecodeArgs.AddRange([string[]]@('-hwaccel','videotoolbox'))
    }

    # Priority 5 — Software SVT-AV1 (fast software encoder) -------------------
    if (-not $selectedStack -and $encPresent['libsvtav1']) {
        $selectedStack = 'SW-SVTAV1'
        $hwVendor      = 'Software (SVT-AV1)'
        Write-Host "[WARN] No hardware acceleration detected — falling back to CPU encoding (SVT-AV1)." -ForegroundColor Yellow
        # Use the best available decode-only hwaccel for this platform
        if      ($apiPresent['d3d11va'])      { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','d3d11va'))      }
        elseif  ($apiPresent['qsv'])          { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','qsv'))          }
        elseif  ($apiPresent['videotoolbox']) { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','videotoolbox')) }
        elseif  ($apiPresent['vaapi'])        { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','vaapi'))        }
    }

    # Priority 6 — Software libaom-AV1 (reference encoder, very slow) ----------
    if (-not $selectedStack -and $encPresent['libaom-av1']) {
        $selectedStack = 'SW-LIBAOM'
        $hwVendor      = 'Software (libaom-AV1)'
        Write-Host "[WARN] No hardware acceleration detected — falling back to CPU encoding (libaom-AV1, very slow)." -ForegroundColor Yellow
        if      ($apiPresent['d3d11va']) { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','d3d11va')) }
        elseif  ($apiPresent['vaapi'])   { $hwDecodeArgs.AddRange([string[]]@('-hwaccel','vaapi'))  }
    }

    # Priority 7 — Last-resort CPU: scan for any AV1 encoder in this FFmpeg build
    if (-not $selectedStack) {
        $anyAV1Line = ($ffEncoders -split "`n") | Where-Object { $_ -match '^\s+V.+av1' } | Select-Object -First 1
        if ($anyAV1Line -and ($anyAV1Line -match '^\s+V\S*\s+(\S+)')) {
            $cpuFallbackEnc = $Matches[1]
            $selectedStack  = 'SW-CPU'
            $hwVendor       = "Software ($cpuFallbackEnc)"
            Write-Host "[WARN] No known AV1 encoder detected — attempting CPU fallback with '$cpuFallbackEnc'." -ForegroundColor Yellow
        }
    }

    if (-not $selectedStack) {
        Write-Host "[ERROR] No AV1 encoder found in this FFmpeg build." -ForegroundColor Red
        Write-Host "        Checked: av1_nvenc, av1_qsv, av1_amf, av1_videotoolbox, libsvtav1, libaom-av1" -ForegroundColor Yellow
        Write-Host "        Install a full FFmpeg build that includes SVT-AV1 (recommended) or libaom." -ForegroundColor Yellow
        Write-Host "        Windows: https://www.gyan.dev/ffmpeg/builds/  (use the 'full' variant)" -ForegroundColor Yellow
        return
    }

    $isHardwareStack = $selectedStack -notlike 'SW-*'
    $stackLabel      = if ($isHardwareStack) { 'Hardware stack' } else { 'CPU fallback   ' }
    Write-Host "[$( if ($isHardwareStack) { 'SUCCESS' } else { 'WARN' })] $stackLabel : $selectedStack ($hwVendor)" `
               -ForegroundColor $(if ($isHardwareStack) { 'Green' } else { 'Yellow' })
    $decodeLabel = if ($hwDecodeArgs.Count -gt 0) { $hwDecodeArgs -join ' ' } else { 'software (pure CPU)' }
    Write-Host "[INFO] Decode hwaccel   : $decodeLabel" -ForegroundColor Cyan

    # Parallel throttle — each stack has its own resource model
    switch -Wildcard ($selectedStack) {
        'NVIDIA-NVENC' {
            # Reserve ~2 GB for OS/display; each NVENC AV1 session uses ~2.5 GB; hard cap at 4
            $usableVRAM  = [math]::Max(0, $vramMB - 2048)
            $maxParallel = [math]::Min([math]::Max(1, [math]::Floor($usableVRAM / 2560)), 4)
        }
        'INTEL-QSV' {
            # Discrete Arc GPU: VRAM-based at ~1.5 GB/session. iGPU: conservative fixed limit.
            $isArc = ($gpuControllers | Where-Object { $_.Name -match 'Arc|A\d{3}' }).Count -gt 0
            $maxParallel = if ($isArc -and $vramMB -gt 0) {
                [math]::Min([math]::Max(1, [math]::Floor(($vramMB - 1024) / 1536)), 4)
            } else { 2 }
        }
        'AMD-AMF' {
            # Each AMF AV1 session uses ~1.5 GB; reserve 1 GB for display; hard cap at 4
            if ($vramMB -gt 0) {
                $usableVRAM  = [math]::Max(0, $vramMB - 1024)
                $maxParallel = [math]::Min([math]::Max(1, [math]::Floor($usableVRAM / 1536)), 4)
            } else { $maxParallel = 2 }
        }
        'APPLE-VTB' { $maxParallel = 2 }
        'SW-*' {
            # CPU-bound: one encode thread per 4 logical cores, capped at 4
            $maxParallel = [math]::Min([math]::Max(1, [math]::Floor([Environment]::ProcessorCount / 4)), 4)
        }
    }

    if ($vramMB -gt 0) {
        Write-Host "[INFO] GPU VRAM         : $(Format-Bytes ($vramMB * 1MB))  →  Max parallel encodes: $maxParallel" -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] Max parallel     : $maxParallel" -ForegroundColor Cyan
    }

    # =========================================================================
    # STEP 4: Content × Resolution profile table
    # =========================================================================
    # Profile key format: "<ContentType>-<ResTier>"
    # Resolution tiers are assigned per-file in the parallel block after FFprobe
    # extracts source dimensions.  CLI -CQ and -Preset overrides are applied
    # inside the parallel block after the profile is selected.
    #
    # Tier pixel-count thresholds (total pixels = width × height):
    #   8K+  : > 8,847,360  (above DCI 4K, 4096×2160)
    #   4K   : > 3,686,400  (above QHD 2560×1440, up to and including DCI 4K)
    #   2K   : > 2,073,600  (above 1080p 1920×1080, up to and including QHD)
    #   HD   : > 921,600    (above 720p 1280×720, up to and including 1080p)
    #   SD   : ≤ 921,600    (720p and below)
    #
    # Profile parameters:
    #   DefaultCQ     — lower = higher quality / larger file (AV1 CQ / CRF scale)
    #   DefaultPreset — p1 (fastest) → p7 (slowest / best compression)
    #   RcLookahead   — frames the encoder looks ahead for rate control
    #   SpatialAQ     — spatial adaptive quantisation (0/1)
    #   TemporalAQ    — temporal adaptive quantisation (0/1)
    #   AQStrength    — 1–15; higher = more bits redirected to complex regions
    #   Multipass     — Internal quality-resolution pass ('disabled'/'qres')
    # =========================================================================

    $contentProfiles = @{

        # ── MOVIE ──────────────────────────────────────────────────────────────
        # Cinematic content: slow motion, fine grain, HDR.  Prioritise quality
        # over encode speed.  Higher resolution = more headroom for compression.

        'Movie-SD'  = @{ DefaultCQ=26; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=10; Multipass='disabled'
                         Description='Movie SD: older/archival film, balanced quality for low-res masters' }
        'Movie-HD'  = @{ DefaultCQ=24; DefaultPreset='p6'; RcLookahead=48; SpatialAQ=1; TemporalAQ=1; AQStrength=13; Multipass='qres'
                         Description='Movie HD: high-fidelity 1080p, strong AQ, fine grain and shadow detail' }
        'Movie-2K'  = @{ DefaultCQ=23; DefaultPreset='p6'; RcLookahead=56; SpatialAQ=1; TemporalAQ=1; AQStrength=14; Multipass='qres'
                         Description='Movie 2K: DCI 2K / QHD cinema, near-maximum quality' }
        'Movie-4K'  = @{ DefaultCQ=22; DefaultPreset='p7'; RcLookahead=64; SpatialAQ=1; TemporalAQ=1; AQStrength=15; Multipass='qres'
                         Description='Movie 4K: UHD/DCI 4K HDR feature film, maximum quality, slowest preset' }
        'Movie-8K+' = @{ DefaultCQ=24; DefaultPreset='p7'; RcLookahead=64; SpatialAQ=1; TemporalAQ=1; AQStrength=15; Multipass='qres'
                         Description='Movie 8K+: beyond DCI 4K, max preset/lookahead, slight CQ relaxation' }

        # ── SHOW ───────────────────────────────────────────────────────────────
        # TV episodes: large libraries, broadcast-compressed masters.  Efficiency
        # over perfection; diminishing returns chasing lossless transparency.

        'Show-SD'   = @{ DefaultCQ=30; DefaultPreset='p4'; RcLookahead=24; SpatialAQ=1; TemporalAQ=1; AQStrength=7;  Multipass='disabled'
                         Description='Show SD: older SD broadcast, fast encode, moderate quality' }
        'Show-HD'   = @{ DefaultCQ=32; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=8;  Multipass='disabled'
                         Description='Show HD: standard 1080p broadcast, efficient compression' }
        'Show-2K'   = @{ DefaultCQ=31; DefaultPreset='p5'; RcLookahead=40; SpatialAQ=1; TemporalAQ=1; AQStrength=9;  Multipass='disabled'
                         Description='Show 2K: QHD streaming series, slightly higher fidelity than HD' }
        'Show-4K'   = @{ DefaultCQ=28; DefaultPreset='p6'; RcLookahead=48; SpatialAQ=1; TemporalAQ=1; AQStrength=12; Multipass='qres'
                         Description='Show 4K: premium UHD streaming (HDR series), strong quality' }
        'Show-8K+'  = @{ DefaultCQ=30; DefaultPreset='p6'; RcLookahead=48; SpatialAQ=1; TemporalAQ=1; AQStrength=12; Multipass='qres'
                         Description='Show 8K+: future-format streaming, balanced quality/file-size' }

        # ── SPORTS ─────────────────────────────────────────────────────────────
        # Fast motion: aggressive AQ to avoid block artifacts on moving subjects.
        # Short lookahead prevents encoder stall on action bursts.

        'Sports-SD'  = @{ DefaultCQ=26; DefaultPreset='p4'; RcLookahead=20; SpatialAQ=1; TemporalAQ=1; AQStrength=9;  Multipass='disabled'
                          Description='Sports SD: fast-motion SD footage, minimal lookahead for speed' }
        'Sports-HD'  = @{ DefaultCQ=28; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=10; Multipass='disabled'
                          Description='Sports HD: 1080p sports, aggressive AQ, moderate lookahead' }
        'Sports-2K'  = @{ DefaultCQ=27; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=11; Multipass='disabled'
                          Description='Sports 2K: QHD sports broadcast, slightly tighter quality than HD' }
        'Sports-4K'  = @{ DefaultCQ=26; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=12; Multipass='disabled'
                          Description='Sports 4K: UHD sports (fine crowd/grass detail), strong AQ' }
        'Sports-8K+' = @{ DefaultCQ=28; DefaultPreset='p5'; RcLookahead=32; SpatialAQ=1; TemporalAQ=1; AQStrength=12; Multipass='disabled'
                          Description='Sports 8K+: future-format sports, balanced quality at high resolution' }

        # ── GENERAL ────────────────────────────────────────────────────────────
        # Mixed or unknown content.  Balanced defaults across all resolution tiers.

        'General-SD'  = @{ DefaultCQ=28; DefaultPreset='p4'; RcLookahead=24; SpatialAQ=1; TemporalAQ=1; AQStrength=8;  Multipass='disabled'
                           Description='General SD: mixed unknown SD content, conservative quality' }
        'General-HD'  = @{ DefaultCQ=30; DefaultPreset='p5'; RcLookahead=40; SpatialAQ=1; TemporalAQ=1; AQStrength=10; Multipass='disabled'
                           Description='General HD: versatile 1080p profile for mixed content' }
        'General-2K'  = @{ DefaultCQ=29; DefaultPreset='p5'; RcLookahead=48; SpatialAQ=1; TemporalAQ=1; AQStrength=11; Multipass='disabled'
                           Description='General 2K: mixed QHD/1440p content, slightly increased quality' }
        'General-4K'  = @{ DefaultCQ=27; DefaultPreset='p6'; RcLookahead=56; SpatialAQ=1; TemporalAQ=1; AQStrength=13; Multipass='qres'
                           Description='General 4K: mixed UHD content, high quality, multipass' }
        'General-8K+' = @{ DefaultCQ=28; DefaultPreset='p6'; RcLookahead=56; SpatialAQ=1; TemporalAQ=1; AQStrength=13; Multipass='qres'
                           Description='General 8K+: mixed 8K+ content, balanced quality at extreme resolution' }
    }

    # Validate that every profile entry contains all required keys.
    # A missing key causes a silent $null dereference deep inside the parallel block.
    $requiredProfileKeys = @('DefaultCQ','DefaultPreset','RcLookahead','SpatialAQ','TemporalAQ','AQStrength','Multipass','Description')
    foreach ($profileKey in $contentProfiles.Keys) {
        $missingKeys = $requiredProfileKeys | Where-Object { -not $contentProfiles[$profileKey].ContainsKey($_) }
        if ($missingKeys) {
            Write-Host "[ERROR] Content profile '$profileKey' is missing required key(s): $($missingKeys -join ', ')" -ForegroundColor Red
            return
        }
    }

    # Profile selection and encode-arg building happen per-file inside the
    # parallel block (after FFprobe reveals each file's resolution).
    # Capture override flags here so the parallel block can apply them.
    $hasCQOverride     = $PSBoundParameters.ContainsKey('CQ')
    $hasPresetOverride = $PSBoundParameters.ContainsKey('Preset')

    Write-Host "`n[INFO] Content type     : $Content (profile resolved per-file from source resolution)" -ForegroundColor Cyan
    Write-Host "[INFO] CQ override      : $(if ($hasCQOverride) { $CQ } else { 'none — using profile default' })" -ForegroundColor Cyan
    Write-Host "[INFO] Preset override  : $(if ($hasPresetOverride) { $Preset } else { 'none — using profile default' })" -ForegroundColor Cyan

    $SourceDirectory = (Resolve-Path $SourceDirectory).Path.TrimEnd('\')
    $TargetDirectory = $TargetDirectory.TrimEnd('\')

    # Stamp the log root so concurrent or repeated runs never share the same directory
    $sessionStamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $LogDirectory  = "$($LogDirectory.TrimEnd('\'))_$sessionStamp"

    foreach ($dir in @($TargetDirectory, $LogDirectory)) {
        if (-not (Test-Path $dir)) {
            try {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Host "[ERROR] Could not create directory '$dir': $($_.Exception.Message)" -ForegroundColor Red
                return
            }
        }
    }

    $masterLogPath = Join-Path $LogDirectory "encode_session_$sessionStamp.log"
    try {
        New-Item -ItemType File -Path $masterLogPath -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "[ERROR] Could not create master log '$masterLogPath': $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $errorLogPath = if ($ExportError -ne 'NONE') { Join-Path $LogDirectory "ErrorLog_$sessionStamp.log" } else { $null }

    Write-Log ('=' * 60)                                                   -Level INFO -LogFile $masterLogPath
    Write-Log '  Video Re-encode Session Started'                          -Level INFO -LogFile $masterLogPath
    Write-Log "  PowerShell : $($PSVersionTable.PSVersion)"                -Level INFO -LogFile $masterLogPath
    Write-Log "  FFmpeg     : $ffmpeg"                                     -Level INFO -LogFile $masterLogPath
    Write-Log "  FFprobe    : $ffprobe"                                    -Level INFO -LogFile $masterLogPath
    Write-Log "  Source     : $SourceDirectory"                            -Level INFO -LogFile $masterLogPath
    Write-Log "  Target     : $TargetDirectory"                            -Level INFO -LogFile $masterLogPath
    Write-Log "  Logs       : $LogDirectory"                               -Level INFO -LogFile $masterLogPath
    Write-Log "  HW Stack   : $selectedStack ($hwVendor)"                   -Level INFO -LogFile $masterLogPath
    Write-Log "  Decode     : $decodeLabel"                                -Level INFO -LogFile $masterLogPath
    Write-Log "  Content    : $Content (profile resolved per-file from source resolution)" -Level INFO -LogFile $masterLogPath
    Write-Log "  CQ         : $(if ($hasCQOverride) { "$CQ (CLI override)" } else { 'profile default (per-file)' })" -Level INFO -LogFile $masterLogPath
    Write-Log "  Preset     : $(if ($hasPresetOverride) { "$Preset (CLI override)" } else { 'profile default (per-file)' })" -Level INFO -LogFile $masterLogPath
    Write-Log "  OnComplete : $OnComplete"                                 -Level INFO -LogFile $masterLogPath
    Write-Log "  Parallel   : $maxParallel"                                -Level INFO -LogFile $masterLogPath
    Write-Log ('=' * 60)                                                   -Level INFO -LogFile $masterLogPath

    # =========================================================================
    # STEP 5: Discover all video files (any format, confirmed by extension)
    # =========================================================================
    $videoExtensions = @(
        'mp4','mov','mkv','avi','wmv','flv','webm','m4v','mpg','mpeg',
        'mts','m2ts','ts','vob','ogv','3gp','3g2','divx','xvid','f4v',
        'rmvb','rm','asf','mxf','dv','gxf','qt','hevc','h264','h265'
    )
    $extFilter   = $videoExtensions | ForEach-Object { ".$_" }
    $sourceFiles = Get-ChildItem -Path $SourceDirectory -Recurse -File |
                   Where-Object { $extFilter -contains $_.Extension.ToLower() }

    if ($sourceFiles.Count -eq 0) {
        Write-Log "No video files found in '$SourceDirectory'." -Level WARN -LogFile $masterLogPath
        return
    }
    Write-Log "Found $($sourceFiles.Count) video file(s) in source directory." -Level INFO -LogFile $masterLogPath

    # =========================================================================
    # STEP 5.5a: Base-name collision detection
    # =========================================================================
    # Within any single source directory (or subdirectory), multiple files may
    # share the same base name but differ only by extension (e.g. file1.mp4 and
    # file1.mov). Both would otherwise map to file1.mkv in the target, causing a
    # silent overwrite. Files in a collision group receive disambiguated names:
    #   file1.mp4  →  file1-(mp4).mkv
    #   file1.mov  →  file1-(mov).mkv
    # Disambiguation only applies to files that are actually in conflict; all
    # other files continue to use the plain <baseName>.mkv convention.
    # =========================================================================
    # Group key is lowercased (parent + base) to detect case-insensitive collisions
    # (e.g. "File.mp4" and "file.mov" in the same directory both map to "file.mkv").
    # The resulting HashSet uses OrdinalIgnoreCase so .Contains() lookups later are
    # also case-insensitive, keeping the two strategies consistent.
    $baseNameGroups = $sourceFiles | Group-Object {
        $parent = (Split-Path $_.FullName -Parent).ToLower()
        $base   = [System.IO.Path]::GetFileNameWithoutExtension($_.Name).ToLower()
        "${parent}|||${base}"
    }
    $conflictedFiles = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $collisionGroups = 0
    foreach ($grp in ($baseNameGroups | Where-Object { $_.Count -gt 1 })) {
        $collisionGroups++
        foreach ($f in $grp.Group) { $conflictedFiles.Add($f.FullName) | Out-Null }
    }
    if ($collisionGroups -gt 0) {
        Write-Host "[WARN] Base-name collisions detected: $($conflictedFiles.Count) file(s) across $collisionGroups group(s) will use disambiguated target names." -ForegroundColor Yellow
        Write-Log "Base-name collisions: $($conflictedFiles.Count) file(s) in $collisionGroups group(s) will use disambiguated target names (e.g. file1-(mp4).mkv)." -Level WARN -LogFile $masterLogPath
    }

    # =========================================================================
    # STEP 5.5: Pre-flight resume check
    # =========================================================================
    # For each source file, checks whether a valid re-encoded target already
    # exists. This enables safe resumption after a failure (power loss, crash,
    # manual abort) without re-encoding files that completed successfully.
    #
    # A target is accepted as a valid re-encode when ALL of the following hold:
    #   1. File is an MKV container with an AV1 video stream
    #   2. Duration matches the source within ±1 second (an interrupted encode
    #      is typically minutes short; container rounding causes < 1s variance)
    #   3. Target file size exceeds 1% of the source size (rules out near-empty
    #      or stub files that FFprobe might partially parse)
    #   4. FFprobe successfully parses the target (rules out corrupt files)
    #
    # Audio and subtitle stream counts are also compared; mismatches emit a
    # warning but do not block resume (subtitle handling varies by container).
    #
    # Any target that exists but fails validation is treated as a conflict and
    # the run is aborted — the user must resolve it before re-running.
    # =========================================================================

    $resumedResults  = [System.Collections.Generic.List[object]]::new()
    $filesToEncode   = [System.Collections.Generic.List[object]]::new()
    $resumeConflicts = [System.Collections.Generic.List[string]]::new()

    Write-Log "Running pre-flight resume check on $($sourceFiles.Count) file(s)..." -Level INFO -LogFile $masterLogPath

    foreach ($srcFile in $sourceFiles) {
        $relPath  = $srcFile.FullName.Substring($SourceDirectory.Length).TrimStart('\')
        $relDir   = Split-Path $relPath -Parent
        $base     = [System.IO.Path]::GetFileNameWithoutExtension($srcFile.Name)
        $tgtDir   = if ($relDir) { Join-Path $TargetDirectory $relDir } else { $TargetDirectory }
        $srcExt0  = $srcFile.Extension.TrimStart('.').ToLower()
        $tgtName0 = if ($conflictedFiles.Contains($srcFile.FullName)) { "$base-($srcExt0).mkv" } else { "$base.mkv" }
        $tgtFile  = Join-Path $tgtDir $tgtName0

        if (-not (Test-Path $tgtFile)) {
            $filesToEncode.Add($srcFile)
            continue
        }

        $tgtItem    = Get-Item $tgtFile
        $probeFlags = @('-v','quiet','-print_format','json','-show_format','-show_streams')
        $tgtProbe   = (& $ffprobe @probeFlags $tgtFile          2>&1 | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue
        $srcProbe   = (& $ffprobe @probeFlags $srcFile.FullName 2>&1 | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue

        $tgtVideo    = $tgtProbe.streams | Where-Object { $_.codec_type -eq 'video'    } | Select-Object -First 1
        $srcAudioCnt = ($srcProbe.streams | Where-Object { $_.codec_type -eq 'audio'    }).Count
        $tgtAudioCnt = ($tgtProbe.streams | Where-Object { $_.codec_type -eq 'audio'    }).Count
        $srcSubCnt   = ($srcProbe.streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count
        $tgtSubCnt   = ($tgtProbe.streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count

        $isAV1      = $tgtVideo.codec_name -match '^av1$'
        $isMKV      = $tgtItem.Extension.ToLower() -eq '.mkv'
        $srcDur     = [double]($srcProbe.format.duration)
        $tgtDur     = [double]($tgtProbe.format.duration)
        $durMatch   = [math]::Abs($srcDur - $tgtDur) -le 1.0
        $sizeOk     = $tgtItem.Length -gt [math]::Max(1, [long]($srcFile.Length * 0.01))
        $probeOk    = $null -ne $tgtVideo
        $isValid    = $isAV1 -and $isMKV -and $durMatch -and $sizeOk -and $probeOk

        if (-not $isValid) {
            $reasons = [System.Collections.Generic.List[string]]::new()
            if (-not $probeOk)  { $reasons.Add('target unreadable by FFprobe') }
            if (-not $isMKV)    { $reasons.Add('target is not an MKV container') }
            if (-not $isAV1)    { $reasons.Add("target video codec is '$($tgtVideo.codec_name)', not AV1") }
            if (-not $durMatch) { $reasons.Add("duration mismatch: source=$([math]::Round($srcDur,2))s target=$([math]::Round($tgtDur,2))s") }
            if (-not $sizeOk)   { $reasons.Add("target suspiciously small ($($tgtItem.Length) bytes vs source $($srcFile.Length) bytes)") }
            $resumeConflicts.Add("  [$relPath] — $($reasons -join '; ')")
            continue
        }

        # Warn on stream count differences but don't block resume
        if ($srcAudioCnt -ne $tgtAudioCnt) {
            Write-Log "RESUME WARN [$relPath]: audio stream count differs (source=$srcAudioCnt target=$tgtAudioCnt)" -Level WARN -LogFile $masterLogPath
        }
        if ($srcSubCnt -ne $tgtSubCnt) {
            Write-Log "RESUME WARN [$relPath]: subtitle stream count differs (source=$srcSubCnt target=$tgtSubCnt)" -Level WARN -LogFile $masterLogPath
        }

        $savings = if ($srcFile.Length -gt 0) {
            [math]::Round((1 - $tgtItem.Length / $srcFile.Length) * 100, 1)
        } else { 0 }

        $resumeResult = [ordered]@{
            RelativePath = $relPath
            SourceFile   = $srcFile.FullName
            TargetFile   = $tgtFile
            SourceSize   = $srcFile.Length
            TargetSize   = $tgtItem.Length
            SourceAction = 'Unchanged'
            TargetAction = 'AlreadyEncoded'
            WasAV1MKV    = $false
            Transcoded   = $false
            Status       = 'Resumed'
            SavingsPct   = $savings
        }

        switch ($OnComplete) {
            'Delete' {
                if ($WhatIfPreference) {
                    $resumeResult.SourceAction = 'WhatIf-Delete'
                } else {
                    Remove-Item -Path $srcFile.FullName -Force
                    $resumeResult.SourceAction = 'Deleted'
                    Write-Log "RESUME: Source deleted (OnComplete=Delete): $relPath" -Level INFO -LogFile $masterLogPath
                    $srcParent = Split-Path $srcFile.FullName -Parent
                    if ((Get-ChildItem $srcParent -Force | Measure-Object).Count -eq 0) {
                        Remove-Item $srcParent -Force
                    }
                }
            }
            'Replace' {
                $replaceDir  = Split-Path $srcFile.FullName -Parent
                $replaceDest = Join-Path $replaceDir $tgtName0
                if ((Test-Path $replaceDest) -and ($replaceDest -ne $srcFile.FullName)) {
                    Write-Log "RESUME WARN [$relPath]: Replace blocked — '$([System.IO.Path]::GetFileName($replaceDest))' already exists as a different file. Source preserved." -Level WARN -LogFile $masterLogPath
                    $resumeResult.SourceAction = 'Preserved-NameConflict'
                } elseif ($WhatIfPreference) {
                    $resumeResult.SourceAction = 'WhatIf-Replace'
                } else {
                    Move-Item -Path $tgtFile -Destination $replaceDest -Force
                    Remove-Item -Path $srcFile.FullName -Force
                    $resumeResult.TargetFile   = $replaceDest
                    $resumeResult.TargetAction = 'MovedToSource'
                    $resumeResult.SourceAction = 'Replaced'
                    Write-Log "RESUME: Encode moved to source dir, original deleted (OnComplete=Replace): $relPath" -Level INFO -LogFile $masterLogPath
                    try {
                        $movedItem                = Get-Item $replaceDest
                        $movedItem.CreationTime   = $srcFile.CreationTime
                        $movedItem.LastWriteTime  = $srcFile.LastWriteTime
                        $movedItem.LastAccessTime = $srcFile.LastAccessTime
                    } catch { }
                }
            }
            default {
                $resumeResult.SourceAction = 'Unchanged'
            }
        }

        Write-Log "RESUME: Already encoded — $relPath ($savings% savings)" -Level INFO -LogFile $masterLogPath
        $resumedResults.Add($resumeResult)
    }

    # Abort if any target files exist but cannot be verified as valid re-encodes
    if ($resumeConflicts.Count -gt 0) {
        Write-Log "ABORT: $($resumeConflicts.Count) file(s) in the target directory could not be verified as valid re-encodes of their source:" -Level ERROR -LogFile $masterLogPath
        Write-Host "`n[ERROR] Pre-flight check failed — unrecognised file(s) found in target directory:" -ForegroundColor Red
        foreach ($conflict in $resumeConflicts) {
            Write-Log $conflict -Level ERROR -LogFile $masterLogPath
            Write-Host $conflict -ForegroundColor Yellow
        }
        Write-Host "`n    Resolve or remove the conflicting file(s) above, then re-run.`n" -ForegroundColor Yellow
        return
    }

    $sourceFiles = $filesToEncode
    Write-Log "Pre-flight complete: $($resumedResults.Count) resumed, $($sourceFiles.Count) queued for encoding." -Level INFO -LogFile $masterLogPath

    # =========================================================================
    # STEP 6: Parallel processing via PS7 ForEach-Object -Parallel
    # =========================================================================

    # Freeze all variables needed inside the parallel scope
    $p_ffmpeg      = $ffmpeg
    $p_ffprobe     = $ffprobe
    $p_srcRoot     = $SourceDirectory
    $p_tgtRoot     = $TargetDirectory
    $p_logRoot     = $LogDirectory
    $p_session     = $sessionStamp
    $p_onComplete  = $OnComplete
    $p_masterLog   = $masterLogPath
    $p_whatIf      = $WhatIfPreference
    $p_decodeArgs      = [string[]]$hwDecodeArgs
    $p_conflictedFiles = [string[]]$conflictedFiles   # passed as array; rebuilt as HashSet inside parallel
    $p_stackName       = $selectedStack
    $p_contentName     = $Content
    $p_profiles        = $contentProfiles
    $p_hasCQOverride   = $hasCQOverride
    $p_cqOverride      = $CQ
    $p_hasPresetOvr    = $hasPresetOverride
    $p_presetOverride  = $Preset
    $p_cpuFallbackEnc  = $cpuFallbackEnc
    $p_exportError     = $ExportError
    $p_errorLog        = $errorLogPath

    # Seed $results with any files resolved during the pre-flight resume check.
    # The parallel block appends to this list when there are files to encode.
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $resumedResults) { $results.Add($r) }

    if ($sourceFiles.Count -gt 0) {
    $encodingResults = $sourceFiles | ForEach-Object -ThrottleLimit $maxParallel -Parallel {

        # Bring outer variables into parallel scope
        $sourceFile      = $_
        $ffmpegPath      = $using:p_ffmpeg
        $ffprobePath     = $using:p_ffprobe
        $srcRoot         = $using:p_srcRoot
        $tgtRoot         = $using:p_tgtRoot
        $logRoot         = $using:p_logRoot
        $sessionId       = $using:p_session
        $onCompleteValue = $using:p_onComplete
        $masterLog       = $using:p_masterLog
        $whatIf          = $using:p_whatIf
        # Hardware stack and per-file profile data
        $decodeArgs        = $using:p_decodeArgs
        $conflictedSet     = [System.Collections.Generic.HashSet[string]]::new(
                                 [string[]]$using:p_conflictedFiles,
                                 [System.StringComparer]::OrdinalIgnoreCase)
        $stackName         = $using:p_stackName
        $contentName       = $using:p_contentName
        $profiles          = $using:p_profiles
        $hasCQOverride     = $using:p_hasCQOverride
        $cqOverride        = $using:p_cqOverride
        $hasPresetOverride = $using:p_hasPresetOvr
        $presetOverride    = $using:p_presetOverride
        $cpuFallbackEnc    = $using:p_cpuFallbackEnc
        $exportErrorValue  = $using:p_exportError
        $errLogPath        = $using:p_errorLog

        # ----------------------------------------------------------------------
        # Parallel-scope helpers
        # ----------------------------------------------------------------------
        function pLog([string]$Msg, [string]$Level = 'INFO', [string]$LogFile) {
            $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $entry = "[$ts] [$Level] $Msg"
            $mx = $null
            try { $mx = [System.Threading.Mutex]::OpenExisting('VideoEncodeLogMutex') } catch { }
            if ($null -ne $mx) {
                $acquired = $mx.WaitOne(5000)
                if (-not $acquired) {
                    Write-Host "[$ts] [WARN] Log mutex timeout — entry may be lost: $Msg" -ForegroundColor Yellow
                }
                try {
                    if ($acquired) {
                        Add-Content -Path $LogFile -Value $entry -Encoding UTF8
                        if ($null -ne $errLogPath) {
                            $shouldWriteErr = ($exportErrorValue -eq 'WARN' -and $Level -in @('WARN','ERROR')) -or
                                              ($exportErrorValue -eq 'ERROR' -and $Level -eq 'ERROR')
                            if ($shouldWriteErr) { Add-Content -Path $errLogPath -Value $entry -Encoding UTF8 }
                        }
                    }
                }
                finally { if ($acquired) { $mx.ReleaseMutex() } }
            }
            switch ($Level) {
                'INFO'    { Write-Host $entry -ForegroundColor Cyan    }
                'WARN'    { Write-Host $entry -ForegroundColor Yellow  }
                'ERROR'   { Write-Host $entry -ForegroundColor Red     }
                'SUCCESS' { Write-Host $entry -ForegroundColor Green   }
            }
        }
        function fBytes([long]$b) {
            if ($b -ge 1GB) { return "$([math]::Round($b/1GB,2)) GB" }
            if ($b -ge 1MB) { return "$([math]::Round($b/1MB,2)) MB" }
            if ($b -ge 1KB) { return "$([math]::Round($b/1KB,2)) KB" }
            return "$b B"
        }

        # ----------------------------------------------------------------------
        # Derive paths
        # ----------------------------------------------------------------------
        $relativePath = $sourceFile.FullName.Substring($srcRoot.Length).TrimStart('\')
        $relativeDir  = Split-Path $relativePath -Parent
        $baseName     = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name)

        $targetDir   = if ($relativeDir) { Join-Path $tgtRoot $relativeDir } else { $tgtRoot }
        $srcExtP     = $sourceFile.Extension.TrimStart('.').ToLower()
        $targetName  = if ($conflictedSet.Contains($sourceFile.FullName)) { "$baseName-($srcExtP).mkv" } else { "$baseName.mkv" }
        $targetFile  = Join-Path $targetDir $targetName
        $relativeLogDir = if ($relativeDir) { Join-Path $relativeDir $baseName } else { $baseName }
        $fileLogDir     = Join-Path $logRoot $relativeLogDir
        $fileLogPath    = Join-Path $fileLogDir "${baseName}_encode_$sessionId.log"

        foreach ($d in @($targetDir, $fileLogDir)) {
            if (-not (Test-Path $d)) {
                try {
                    New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
                } catch {
                    pLog "ERROR — Could not create directory '$d': $($_.Exception.Message)" -Level ERROR -LogFile $masterLog
                    $result.Status       = 'Exception'
                    $result.TargetAction = 'Failed'
                    return $result
                }
            }
        }

        # Result record
        $result = [ordered]@{
            RelativePath = $relativePath
            SourceFile   = $sourceFile.FullName
            TargetFile   = $targetFile
            SourceSize   = $sourceFile.Length
            TargetSize   = 0L
            SourceAction = 'Unchanged'
            TargetAction = 'Pending'
            WasAV1MKV    = $false
            Transcoded   = $false
            Status       = 'Pending'
            SavingsPct   = 0.0
        }

        # ----------------------------------------------------------------------
        # Probe source with FFprobe
        # ----------------------------------------------------------------------
        $probeArgs = @('-v','quiet','-print_format','json','-show_format','-show_streams',
                       $sourceFile.FullName)
        $probeJson = & $ffprobePath @probeArgs 2>&1 | Out-String
        $probeData = $null
        try { $probeData = $probeJson | ConvertFrom-Json -ErrorAction Stop } catch { }

        if ($null -eq $probeData) {
            pLog "SKIPPED (FFprobe parse failed — invalid or empty output): $relativePath" -Level WARN -LogFile $masterLog
            $result.Status       = 'Skipped-ProbeError'
            $result.TargetAction = 'None'
            return $result
        }

        $videoStream    = $probeData.streams | Where-Object { $_.codec_type -eq 'video'    } | Select-Object -First 1
        $hasAudio       = ($probeData.streams | Where-Object { $_.codec_type -eq 'audio'    }).Count -gt 0
        $hasSubtitle    = ($probeData.streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count -gt 0
        $hasAttachments = ($probeData.streams | Where-Object { $_.codec_type -eq 'attachment' }).Count -gt 0

        if (-not $videoStream) {
            pLog "SKIPPED (no video stream): $relativePath" -Level WARN -LogFile $masterLog
            $result.Status       = 'Skipped-NoVideo'
            $result.TargetAction = 'None'
            return $result
        }

        # ── Resolution-based profile selection ───────────────────────────────
        # Determine the resolution tier from source pixel count, then combine
        # with the content type to select the optimal encoding profile.
        # Falls back to HD tier if dimensions are unavailable from FFprobe.
        $srcWidth   = [int]($videoStream.width)
        $srcHeight  = [int]($videoStream.height)
        $pixelCount = $srcWidth * $srcHeight

        $resTier = if      ($pixelCount -gt 8847360) { '8K+' }   # > DCI 4K
                   elseif  ($pixelCount -gt 3686400) { '4K'  }   # > QHD
                   elseif  ($pixelCount -gt 2073600) { '2K'  }   # > 1080p
                   elseif  ($pixelCount -gt 921600)  { 'HD'  }   # > 720p
                   else                               { 'SD'  }

        $profileKey  = "$contentName-$resTier"
        $fileProfile = $profiles[$profileKey]

        # Guard: if the key somehow isn't in the table (e.g. a new content type
        # added without a matching profile) fall back to General-HD.
        if (-not $fileProfile) {
            $fileProfile = $profiles['General-HD']
            $profileKey  = 'General-HD (fallback)'
        }

        $effectiveCQ     = if ($hasCQOverride)     { $cqOverride     } else { $fileProfile.DefaultCQ     }
        $effectivePreset = if ($hasPresetOverride)  { $presetOverride } else { $fileProfile.DefaultPreset }

        # ── Build stack-specific encode args for this file ────────────────────
        $encodeArgs = [System.Collections.Generic.List[string]]::new()
        switch ($stackName) {
            'NVIDIA-NVENC' {
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','av1_nvenc',
                    '-cq',           $effectiveCQ.ToString(),
                    '-preset',       $effectivePreset,
                    '-b:v','0',
                    '-rc-lookahead', $fileProfile.RcLookahead.ToString(),
                    '-spatial_aq',   $fileProfile.SpatialAQ.ToString(),
                    '-temporal_aq',  $fileProfile.TemporalAQ.ToString(),
                    '-aq-strength',  $fileProfile.AQStrength.ToString()
                ))
                if ($fileProfile.Multipass -ne 'disabled') {
                    $encodeArgs.AddRange([string[]]@('-multipass', $fileProfile.Multipass))
                }
            }
            'INTEL-QSV' {
                $qsvPreset = @{ p1='veryfast'; p2='faster'; p3='fast'; p4='medium'
                                p5='slow'; p6='slower'; p7='veryslow' }[$effectivePreset]
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','av1_qsv',
                    '-global_quality', $effectiveCQ.ToString(),
                    '-preset',         $qsvPreset,
                    '-b:v','0'
                ))
                if ($fileProfile.RcLookahead -gt 0) {
                    $encodeArgs.AddRange([string[]]@(
                        '-look_ahead','1',
                        '-look_ahead_depth', [math]::Min($fileProfile.RcLookahead, 100).ToString()
                    ))
                }
            }
            'AMD-AMF' {
                $amfQuality = if     ($effectivePreset -in @('p1','p2','p3')) { 'speed'    }
                              elseif ($effectivePreset -in @('p4','p5'))      { 'balanced' }
                              else                                             { 'quality'  }
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','av1_amf',
                    '-quality', $amfQuality,
                    '-rc','cqp',
                    '-qp_i', $effectiveCQ.ToString(),
                    '-qp_p', [math]::Min($effectiveCQ + 2, 63).ToString()
                ))
                if ($fileProfile.RcLookahead -gt 0) { $encodeArgs.AddRange([string[]]@('-preanalysis','1')) }
            }
            'APPLE-VTB' {
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','av1_videotoolbox',
                    '-q:v', $effectiveCQ.ToString()
                ))
            }
            'SW-SVTAV1' {
                $svtPreset = @{ p1=12; p2=10; p3=8; p4=6; p5=4; p6=2; p7=0 }[$effectivePreset]
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','libsvtav1',
                    '-crf',    $effectiveCQ.ToString(),
                    '-preset', $svtPreset.ToString(),
                    '-svtav1-params', "lookahead=$([math]::Min($fileProfile.RcLookahead, 120))"
                if ($fileProfile.RcLookahead -gt 120) {
                    pLog "INFO [$relativePath] — RcLookahead $($fileProfile.RcLookahead) clamped to 120 (SVT-AV1 maximum)." -Level INFO -LogFile $masterLog
                }
                ))
            }
            'SW-LIBAOM' {
                $cpuUsed = @{ p1=8; p2=7; p3=6; p4=5; p5=4; p6=2; p7=0 }[$effectivePreset]
                $encodeArgs.AddRange([string[]]@(
                    '-c:v','libaom-av1',
                    '-crf',      $effectiveCQ.ToString(),
                    '-cpu-used', $cpuUsed.ToString(),
                    '-row-mt','1'
                ))
            }
            'SW-CPU' {
                $encodeArgs.AddRange([string[]]@(
                    '-c:v', $cpuFallbackEnc,
                    '-crf', $effectiveCQ.ToString(),
                    '-b:v', '0'
                ))
            }
        }

        # Is it already AV1 inside an MKV container?
        $isAV1    = $videoStream.codec_name -match '^av1$'
        $isMKV    = $sourceFile.Extension.ToLower() -eq '.mkv'
        $isAV1MKV = $isAV1 -and $isMKV
        $result.WasAV1MKV = $isAV1MKV

        pLog "Processing: $relativePath | ${srcWidth}x${srcHeight} ($resTier) | Profile: $profileKey | Codec: $($videoStream.codec_name) | AV1-MKV: $isAV1MKV | OnComplete: $onCompleteValue" -Level INFO -LogFile $masterLog

        # ----------------------------------------------------------------------
        # Branch A: Source is already a valid AV1 MKV — no transcode needed
        # ----------------------------------------------------------------------
        if ($isAV1MKV) {
            switch ($onCompleteValue) {
                'Nothing' {
                    if (-not (Test-Path $targetFile)) {
                        if ($whatIf) {
                            pLog "WhatIf: Would copy already-AV1 MKV to target: $relativePath" -Level INFO -LogFile $masterLog
                            $result.TargetAction = 'WhatIf-Copy'
                        } else {
                            Copy-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                            $result.TargetAction = 'Copied'
                            pLog "Already AV1 MKV — copied to target: $relativePath" -Level INFO -LogFile $masterLog
                        }
                    } else {
                        $result.TargetAction = 'AlreadyExists'
                        pLog "Already AV1 MKV — target exists, skipped: $relativePath" -Level WARN -LogFile $masterLog
                    }
                    $result.SourceAction = 'Unchanged'
                }
                'Delete' {
                    if (-not (Test-Path $targetFile)) {
                        if ($whatIf) {
                            pLog "WhatIf: Would move already-AV1 MKV to target: $relativePath" -Level INFO -LogFile $masterLog
                            $result.TargetAction = 'WhatIf-Move'
                            $result.SourceAction = 'WhatIf-Delete'
                        } else {
                            Move-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                            $result.TargetAction = 'Moved'
                            $result.SourceAction = 'Deleted'
                            pLog "Already AV1 MKV — moved to target: $relativePath" -Level INFO -LogFile $masterLog
                            $srcDir = Split-Path $sourceFile.FullName -Parent
                            if ((Get-ChildItem $srcDir -Force | Measure-Object).Count -eq 0) {
                                Remove-Item $srcDir -Force
                            }
                        }
                    } else {
                        $result.TargetAction = 'AlreadyExists'
                        $result.SourceAction = 'Unchanged'
                        pLog "Already AV1 MKV — target exists, source unchanged: $relativePath" -Level WARN -LogFile $masterLog
                    }
                }
                'Replace' {
                    $result.TargetAction = 'N/A'
                    $result.SourceAction = 'Unchanged'
                    pLog "Already AV1 MKV — Replace mode, no action needed: $relativePath" -Level INFO -LogFile $masterLog
                }
            }
            $result.TargetSize  = if (Test-Path $targetFile) { (Get-Item $targetFile).Length } else { $sourceFile.Length }
            $result.Status      = 'AlreadyAV1MKV'
            $result.SavingsPct  = 0.0
            return $result
        }

        # ----------------------------------------------------------------------
        # Branch B: Target already exists — skip (safe resume)
        # ----------------------------------------------------------------------
        if (Test-Path $targetFile) {
            pLog "SKIPPED — target already exists: $relativePath" -Level WARN -LogFile $masterLog
            $result.Status       = 'Skipped-TargetExists'
            $result.TargetAction = 'AlreadyExists'
            $result.TargetSize   = (Get-Item $targetFile).Length
            return $result
        }

        # ----------------------------------------------------------------------
        # Branch C-pre: Pre-encode size prediction
        # Skip files that are very unlikely to yield a smaller output.
        # Conservative criteria — only flag when highly confident:
        #   • Source codec is AV1 (already the target codec)
        #   • Source codec is HEVC or VP9 AND bits-per-pixel < 0.003
        #     (already efficiently encoded; AV1 rarely beats this)
        # H.264 and older codecs always proceed to encode.
        # ----------------------------------------------------------------------
        $sourceCodec = $videoStream.codec_name

        # Parse r_frame_rate fraction (e.g. "24000/1001" or "30/1")
        $srcFramerate = 30.0
        if ($videoStream.r_frame_rate -match '^(\d+)/(\d+)$') {
            $rfrDen = [double]$Matches[2]
            if ($rfrDen -gt 0) { $srcFramerate = [double]$Matches[1] / $rfrDen }
        }

        # Prefer stream-level bit_rate; fall back to container-level
        $srcBitsPerSec = 0.0
        if ($videoStream.bit_rate -and [double]::TryParse([string]$videoStream.bit_rate, [ref]$null)) {
            $srcBitsPerSec = [double]$videoStream.bit_rate
        } elseif ($probeData.format.bit_rate -and [double]::TryParse([string]$probeData.format.bit_rate, [ref]$null)) {
            $srcBitsPerSec = [double]$probeData.format.bit_rate
        }

        # bpp = bits_per_second / (width × height × fps)
        $srcBpp = 0.0
        if ($srcWidth -gt 0 -and $srcHeight -gt 0 -and $srcFramerate -gt 0 -and $srcBitsPerSec -gt 0) {
            $srcBpp = $srcBitsPerSec / ($srcWidth * $srcHeight * $srcFramerate)
        } elseif ($srcBitsPerSec -eq 0) {
            pLog "INFO [$relativePath] — Bitrate unavailable from FFprobe; pre-encode skip check bypassed." -Level INFO -LogFile $masterLog
        }

        $likelyNoSavings = $false
        $noSavingsReason  = ''
        if ($sourceCodec -match '^av1$') {
            $likelyNoSavings = $true
            $noSavingsReason  = "source is already AV1 (codec: $sourceCodec)"
        } elseif ($sourceCodec -match '^(hevc|vp9)$' -and $srcBpp -gt 0 -and $srcBpp -lt 0.003) {
            $likelyNoSavings = $true
            $noSavingsReason  = "source is $sourceCodec with bpp $([math]::Round($srcBpp,6)) — unlikely to yield savings"
        }

        if ($likelyNoSavings) {
            Set-Content -Path $fileLogPath -Value "PRE-ENCODE SKIP: $noSavingsReason" -Encoding UTF8
            pLog "SKIPPED (likely no savings) [$relativePath] — $noSavingsReason" -Level WARN -LogFile $masterLog
            $result.Status     = 'Skipped-LikelyNoSavings'
            $result.SourceSize = $sourceFile.Length

            try {
                New-Item -ItemType Directory -Path (Split-Path $targetFile -Parent) -Force -ErrorAction Stop | Out-Null
            } catch {
                pLog "ERROR — Could not create target directory: $($_.Exception.Message)" -Level ERROR -LogFile $masterLog
                $result.Status       = 'Exception'
                $result.TargetAction = 'Failed'
                return $result
            }

            switch ($onCompleteValue) {
                'Nothing' {
                    Copy-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                    $result.TargetAction = 'CopiedSource'
                    $result.SourceAction = 'Unchanged'
                    $result.TargetSize   = $sourceFile.Length
                    pLog "Source copied to target (no-savings / Nothing): $relativePath" -Level INFO -LogFile $masterLog
                }
                'Delete' {
                    Move-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                    $result.TargetAction = 'MovedSource'
                    $result.SourceAction = 'Deleted'
                    $result.TargetSize   = $sourceFile.Length
                    pLog "Source moved to target (no-savings / Delete): $relativePath" -Level INFO -LogFile $masterLog
                    $srcDir = Split-Path $sourceFile.FullName -Parent
                    if ((Get-ChildItem $srcDir -Force | Measure-Object).Count -eq 0) {
                        Remove-Item $srcDir -Force
                    }
                }
                'Replace' {
                    $result.TargetAction = 'N/A'
                    $result.SourceAction = 'Unchanged'
                    $result.TargetSize   = 0
                    pLog "No action taken (no-savings / Replace): $relativePath" -Level INFO -LogFile $masterLog
                }
            }

            # Propagate filesystem timestamps to copy/move destination
            if ($result.TargetAction -in @('CopiedSource','MovedSource') -and (Test-Path $targetFile)) {
                try {
                    $outItem                = Get-Item $targetFile
                    $outItem.CreationTime   = $sourceFile.CreationTime
                    $outItem.LastWriteTime  = $sourceFile.LastWriteTime
                    $outItem.LastAccessTime = $sourceFile.LastAccessTime
                } catch { <# non-fatal #> }
            }

            return $result
        }

        # ----------------------------------------------------------------------
        # Branch C: Transcode
        # ----------------------------------------------------------------------

        # Write per-file log header
        $fileLogHeader = @"
========================================================
  Per-File Encode Log
  Session  : $sessionId
  Source   : $($sourceFile.FullName)  ($(fBytes $sourceFile.Length))
  Target   : $targetFile
  Resolution: ${srcWidth}x${srcHeight} ($resTier)
  Profile  : $profileKey
  Content  : $contentName
  Stack    : $stackName
  CQ       : $effectiveCQ  |  Preset : $effectivePreset
  Encode   : $($encodeArgs -join ' ')
  Streams  : audio=$hasAudio  subtitles=$hasSubtitle  attachments=$hasAttachments
  Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
========================================================
"@
        Set-Content -Path $fileLogPath -Value $fileLogHeader -Encoding UTF8

        # Build FFmpeg argument list from content profile
        $ffArgs = [System.Collections.Generic.List[string]]::new()
        if ($decodeArgs.Count -gt 0) { $ffArgs.AddRange([string[]]$decodeArgs) }
        $ffArgs.AddRange([string[]]@('-i', "`"$($sourceFile.FullName)`""))

        # Map all streams: video, all audio tracks, all subtitle tracks, attachments
        $ffArgs.AddRange([string[]]@('-map','0:v:0'))
        if ($hasAudio)       { $ffArgs.AddRange([string[]]@('-map','0:a'))  }
        if ($hasSubtitle)    { $ffArgs.AddRange([string[]]@('-map','0:s'))  }
        if ($hasAttachments) { $ffArgs.AddRange([string[]]@('-map','0:t'))  }

        # Stack-specific encode parameters (built in outer scope STEP 4.5)
        $ffArgs.AddRange([string[]]$encodeArgs)

        if ($hasAudio)    { $ffArgs.AddRange([string[]]@('-c:a','copy')) }
        if ($hasSubtitle) { $ffArgs.AddRange([string[]]@('-c:s','copy')) }

        # Metadata: global + per-stream for video, audio, and subtitles
        $ffArgs.AddRange([string[]]@(
            '-map_metadata',     '0',
            '-map_metadata:s:v', '0:s:v',
            '-write_tmcd',       '0'
        ))
        if ($hasAudio)    { $ffArgs.AddRange([string[]]@('-map_metadata:s:a','0:s:a')) }
        if ($hasSubtitle) { $ffArgs.AddRange([string[]]@('-map_metadata:s:s','0:s:s')) }

        $ffArgs.Add("`"$targetFile`"")

        Add-Content -Path $fileLogPath -Value "FFmpeg command:`n`"$ffmpegPath`" $($ffArgs -join ' ')`n---" -Encoding UTF8

        if ($whatIf) {
            pLog "WhatIf: Would encode '$relativePath' → '$targetFile'" -Level INFO -LogFile $masterLog
            $result.Status       = 'WhatIf'
            $result.TargetAction = 'WhatIf-Transcode'
            if ($onCompleteValue -eq 'Replace') {
                $replaceDestCheck = Join-Path (Split-Path $sourceFile.FullName -Parent) $targetName
                if ((Test-Path $replaceDestCheck) -and ($replaceDestCheck -ne $sourceFile.FullName)) {
                    pLog "WhatIf: WARN — Replace would be blocked for '$relativePath': '$([System.IO.Path]::GetFileName($replaceDestCheck))' already exists in source directory as a different file." -Level WARN -LogFile $masterLog
                    $result.SourceAction = 'WhatIf-Replace-Blocked'
                } else {
                    $result.SourceAction = 'WhatIf-Replace'
                }
            } else {
                $result.SourceAction = switch ($onCompleteValue) {
                    'Delete' { 'WhatIf-Delete' }
                    default  { 'Unchanged'      }
                }
            }
            return $result
        }

        $encodeStart = Get-Date

        try {
            # Redirect both stdout and stderr to temp files so the log header written
            # above is preserved, then merge both into the per-file log after exit.
            # FFmpeg writes progress to stderr and some info/warnings to stdout.
            $tmpStdout = [System.IO.Path]::GetTempFileName()
            $tmpStderr = [System.IO.Path]::GetTempFileName()
            try {
                $proc = Start-Process -FilePath $ffmpegPath `
                                      -ArgumentList $ffArgs `
                                      -RedirectStandardOutput $tmpStdout `
                                      -RedirectStandardError  $tmpStderr `
                                      -NoNewWindow -Wait -PassThru

                $ffmpegStdout = $null
                $ffmpegStderr = $null
                try { $ffmpegStdout = Get-Content $tmpStdout -Raw -ErrorAction Stop } catch {
                    pLog "WARN [$relativePath] — Could not read FFmpeg stdout temp file: $($_.Exception.Message)" -Level WARN -LogFile $masterLog
                }
                try { $ffmpegStderr = Get-Content $tmpStderr -Raw -ErrorAction Stop } catch {
                    pLog "WARN [$relativePath] — Could not read FFmpeg stderr temp file: $($_.Exception.Message)" -Level WARN -LogFile $masterLog
                }
                # Combine both streams; stderr carries the bulk of FFmpeg diagnostics
                $ffmpegOutput = (@($ffmpegStdout, $ffmpegStderr) | Where-Object { $_ }) -join "`n"
                if ($ffmpegOutput) {
                    Add-Content -Path $fileLogPath -Value $ffmpegOutput -Encoding UTF8
                }
            } finally {
                if (Test-Path $tmpStdout) { Remove-Item $tmpStdout -Force }
                if (Test-Path $tmpStderr) { Remove-Item $tmpStderr -Force }
            }

            $encodeDuration = (Get-Date) - $encodeStart

            Add-Content -Path $fileLogPath -Value "---`nExit code : $($proc.ExitCode)`nDuration  : $($encodeDuration.ToString('hh\:mm\:ss'))" -Encoding UTF8

            if ($proc.ExitCode -eq 0 -and (Test-Path $targetFile)) {

                $targetSize        = (Get-Item $targetFile).Length
                $result.TargetSize = $targetSize
                $result.Transcoded = $true
                $savings           = if ($result.SourceSize -gt 0) {
                    [math]::Round((1 - $targetSize / $result.SourceSize) * 100, 1)
                } else { 0 }
                $result.SavingsPct = $savings

                Add-Content -Path $fileLogPath -Value "Source    : $(fBytes $result.SourceSize)`nTarget    : $(fBytes $targetSize)`nSavings   : $savings%" -Encoding UTF8

                if ($targetSize -ge $result.SourceSize) {
                    # ----------------------------------------------------------
                    # Post-encode: output is not smaller than source.
                    # Remove the oversized encode and apply the no-savings
                    # OnComplete behaviour (mirrors the pre-encode skip logic).
                    # ----------------------------------------------------------
                    Add-Content -Path $fileLogPath -Value "Result    : SUCCESS (no savings — encoded file is not smaller than source)" -Encoding UTF8
                    pLog "SUCCESS-NO-SAVINGS [$relativePath] $(fBytes $result.SourceSize) → $(fBytes $targetSize) ($savings% saved) [$($encodeDuration.ToString('hh\:mm\:ss'))] — reverting to source" -Level WARN -LogFile $masterLog

                    $result.Status = 'Success-NoSavings'
                    Remove-Item -Path $targetFile -Force

                    switch ($onCompleteValue) {
                        'Nothing' {
                            if (Test-Path $sourceFile.FullName) {
                                Copy-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                                $result.TargetAction = 'CopiedSource'
                                $result.SourceAction = 'Unchanged'
                                $result.TargetSize   = $sourceFile.Length
                                pLog "Source copied to target (no-savings / Nothing): $relativePath" -Level INFO -LogFile $masterLog
                            } else {
                                pLog "WARN [$relativePath] — Source no longer exists; cannot copy." -Level WARN -LogFile $masterLog
                                $result.SourceAction = 'Missing'
                            }
                        }
                        'Delete' {
                            if (Test-Path $sourceFile.FullName) {
                                Move-Item -Path $sourceFile.FullName -Destination $targetFile -Force
                                $result.TargetAction = 'MovedSource'
                                $result.SourceAction = 'Deleted'
                                $result.TargetSize   = $sourceFile.Length
                                pLog "Source moved to target (no-savings / Delete): $relativePath" -Level INFO -LogFile $masterLog
                                $srcDir = Split-Path $sourceFile.FullName -Parent
                                try {
                                    if ((Get-ChildItem $srcDir -Force | Measure-Object).Count -eq 0) {
                                        Remove-Item $srcDir -Force -ErrorAction Stop
                                    }
                                } catch { <# directory not empty or already gone — non-fatal #> }
                            } else {
                                pLog "WARN [$relativePath] — Source no longer exists; cannot move." -Level WARN -LogFile $masterLog
                                $result.SourceAction = 'Missing'
                            }
                        }
                        'Replace' {
                            $result.TargetAction = 'N/A'
                            $result.SourceAction = 'Unchanged'
                            $result.TargetSize   = 0
                            pLog "No action taken (no-savings / Replace): $relativePath" -Level INFO -LogFile $masterLog
                        }
                    }

                    # Propagate timestamps to copy/move destination
                    if ($result.TargetAction -in @('CopiedSource','MovedSource') -and (Test-Path $targetFile)) {
                        try {
                            $outItem                = Get-Item $targetFile
                            $outItem.CreationTime   = $sourceFile.CreationTime
                            $outItem.LastWriteTime  = $sourceFile.LastWriteTime
                            $outItem.LastAccessTime = $sourceFile.LastAccessTime
                        } catch { <# non-fatal #> }
                    }

                } else {
                    # ----------------------------------------------------------
                    # Normal success path — encoded file is smaller than source.
                    # ----------------------------------------------------------
                    Add-Content -Path $fileLogPath -Value "Result    : SUCCESS" -Encoding UTF8
                    pLog "SUCCESS [$relativePath] $(fBytes $result.SourceSize) → $(fBytes $targetSize) ($savings% saved) [$($encodeDuration.ToString('hh\:mm\:ss'))]" -Level SUCCESS -LogFile $masterLog

                    $result.TargetAction = 'Transcoded'
                    $result.Status       = 'Success'

                    # Tracks the final resting path of the output file after OnComplete
                    # may move it (Replace).  Metadata is applied to this path.
                    $finalOutputPath = $targetFile

                    # Scan FFmpeg output for patterns that indicate encode quality issues.
                    # Even a zero exit code can accompany concealment, corruption, or data errors.
                    # If any are found, destructive OnComplete actions are suppressed to protect
                    # the original source file.
                    $encodeWarnings = [System.Collections.Generic.List[string]]::new()
                    if ($ffmpegOutput) {
                        foreach ($outputLine in ($ffmpegOutput -split "`n")) {
                            if ($outputLine -match '(?i)(concealing\s+\d+\s+(error|MBs)|bitstream\s+error|corrupt(ed)?\s+(frame|packet|data|bitstream)|invalid\s+data\s+found|conversion\s+failed|error\s+while\s+(decoding|encoding)|overread\s+\d+\s+bits|truncated\s+(file|packet)|missing\s+mandatory\s+field|pts\s+has\s+no\s+value)') {
                                $encodeWarnings.Add($outputLine.Trim())
                            }
                        }
                    }

                    # OnComplete post-processing
                    if ($encodeWarnings.Count -gt 0) {
                        # Log every suspicious line so the user can review what triggered the block
                        $warningBlock = ($encodeWarnings | ForEach-Object { "  ! $_" }) -join "`n"
                        Add-Content -Path $fileLogPath `
                            -Value "OnComplete : BLOCKED — $($encodeWarnings.Count) warning/error line(s) detected in FFmpeg output.`n$warningBlock`n  Source file preserved; please verify the output before deleting the original." `
                            -Encoding UTF8
                        pLog "WARN [$relativePath] — OnComplete '$onCompleteValue' blocked: $($encodeWarnings.Count) encode warning(s) detected. Source preserved." -Level WARN -LogFile $masterLog
                        $result.SourceAction = 'Preserved-EncodeWarnings'
                    } else {
                        switch ($onCompleteValue) {
                            'Delete' {
                                if (Test-Path $sourceFile.FullName) {
                                    Remove-Item -Path $sourceFile.FullName -Force
                                    $result.SourceAction = 'Deleted'
                                    pLog "Source deleted (OnComplete=Delete): $relativePath" -Level INFO -LogFile $masterLog
                                    $srcDir = Split-Path $sourceFile.FullName -Parent
                                    try {
                                        if ((Get-ChildItem $srcDir -Force | Measure-Object).Count -eq 0) {
                                            Remove-Item $srcDir -Force -ErrorAction Stop
                                            pLog "Removed empty source directory: $srcDir" -Level INFO -LogFile $masterLog
                                        }
                                    } catch { <# directory not empty or already gone — non-fatal #> }
                                } else {
                                    pLog "WARN [$relativePath] — Source no longer exists; skipping delete." -Level WARN -LogFile $masterLog
                                    $result.SourceAction = 'Missing'
                                }
                            }
                            'Replace' {
                                $replaceDir  = Split-Path $sourceFile.FullName -Parent
                                $replaceDest = Join-Path $replaceDir $targetName
                                # Guard: a pre-existing MKV with the same base name but sourced from a
                                # *different* file (e.g. file1.mkv alongside file1.mp4) must not be
                                # overwritten — the encode target and that file are unrelated.
                                if ((Test-Path $replaceDest) -and ($replaceDest -ne $sourceFile.FullName)) {
                                    Add-Content -Path $fileLogPath `
                                        -Value "OnComplete : BLOCKED (Replace) — '$([System.IO.Path]::GetFileName($replaceDest))' already exists in the source directory as a different file. Source preserved." `
                                        -Encoding UTF8
                                    pLog "WARN [$relativePath] — Replace blocked: '$([System.IO.Path]::GetFileName($replaceDest))' already exists in source directory as a different file. Source and encode output both preserved." -Level WARN -LogFile $masterLog
                                    $result.SourceAction = 'Preserved-NameConflict'
                                } else {
                                    try {
                                        Move-Item -Path $targetFile -Destination $replaceDest -Force -ErrorAction Stop
                                        if (Test-Path $sourceFile.FullName) { Remove-Item -Path $sourceFile.FullName -Force }
                                        $result.TargetAction = 'MovedToSource'
                                        $result.SourceAction = 'Replaced'
                                        $finalOutputPath     = $replaceDest
                                        pLog "Encode moved to source dir, original deleted (OnComplete=Replace): $relativePath" -Level INFO -LogFile $masterLog
                                    } catch {
                                        pLog "WARN [$relativePath] — Replace move failed: $($_.Exception.Message). Source and encode output both preserved." -Level WARN -LogFile $masterLog
                                        $result.SourceAction = 'Preserved-MoveFailed'
                                    }
                                }
                            }
                            default {
                                $result.SourceAction = 'Unchanged'
                            }
                        }
                    }

                    # --------------------------------------------------------------
                    # Metadata propagation — applied to the file's final location
                    # after OnComplete so a Replace move doesn't undo the changes.
                    # --------------------------------------------------------------
                    if (Test-Path $finalOutputPath) {
                        try {
                            $outItem                = Get-Item $finalOutputPath
                            $outItem.CreationTime   = $sourceFile.CreationTime
                            $outItem.LastWriteTime  = $sourceFile.LastWriteTime
                            $outItem.LastAccessTime = $sourceFile.LastAccessTime
                            Add-Content -Path $fileLogPath `
                                -Value "Metadata  : Filesystem timestamps copied from source.`n            Created  : $($sourceFile.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))`n            Modified : $($sourceFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" `
                                -Encoding UTF8
                        } catch {
                            pLog "WARN [$relativePath] — Could not copy filesystem timestamps: $($_.Exception.Message)" -Level WARN -LogFile $masterLog
                            Add-Content -Path $fileLogPath -Value "Metadata  : Filesystem timestamp copy FAILED — $($_.Exception.ToString())" -Encoding UTF8
                        }
                    }
                }

            } else {
                Add-Content -Path $fileLogPath -Value "Result    : FAILED (exit $($proc.ExitCode))" -Encoding UTF8
                if (Test-Path $targetFile) { Remove-Item $targetFile -Force }
                $result.Status       = 'Failed'
                $result.TargetAction = 'Failed'
                pLog "FAILED [$relativePath] — exit $($proc.ExitCode). See: $fileLogPath" -Level ERROR -LogFile $masterLog
            }

        } catch {
            if (Test-Path $targetFile) { Remove-Item $targetFile -Force }
            $result.Status       = 'Exception'
            $result.TargetAction = 'Failed'
            Add-Content -Path $fileLogPath -Value "EXCEPTION : $($_.Exception.ToString())" -Encoding UTF8
            pLog "EXCEPTION [$relativePath] — $($_.Exception.Message)" -Level ERROR -LogFile $masterLog
        }

        return $result
    }

    foreach ($r in $encodingResults) { $results.Add($r) }
    } # end if ($sourceFiles.Count -gt 0)

    # =========================================================================
    # STEP 7: Build summary table and append to master log
    # =========================================================================

    # Column widths
    $maxFileLen = ($results | ForEach-Object { $_.RelativePath.Length } | Measure-Object -Maximum).Maximum ?? 10
    $maxFileLen = [math]::Max(10, [math]::Min($maxFileLen, 55))

    $cw = @{
        File    = $maxFileLen
        Status  = 18
        SrcAct  = 13
        TgtAct  = 16
        SrcSize = 12
        TgtSize = 12
        Savings = 9
    }

    function Pad([string]$s, [int]$w) {
        if ($s.Length -gt $w) { return $s.Substring(0, $w - 2) + '..' }
        return $s.PadRight($w)
    }

    $sep = '+' + ('-' * ($cw.File + 2)) + '+' + ('-' * ($cw.Status + 2)) + '+' +
           ('-' * ($cw.SrcAct + 2)) + '+' + ('-' * ($cw.TgtAct + 2)) + '+' +
           ('-' * ($cw.SrcSize + 2)) + '+' + ('-' * ($cw.TgtSize + 2)) + '+' +
           ('-' * ($cw.Savings + 2)) + '+'

    $hdr = '| ' + (Pad 'File'          $cw.File)    + ' | ' +
                  (Pad 'Status'         $cw.Status)  + ' | ' +
                  (Pad 'Src Action'     $cw.SrcAct)  + ' | ' +
                  (Pad 'Target Action'  $cw.TgtAct)  + ' | ' +
                  (Pad 'Src Size'       $cw.SrcSize) + ' | ' +
                  (Pad 'Tgt Size'       $cw.TgtSize) + ' | ' +
                  (Pad 'Savings'        $cw.Savings) + ' |'

    $tableLines = [System.Collections.Generic.List[string]]::new()
    $tableLines.Add($sep)
    $tableLines.Add($hdr)
    $tableLines.Add($sep)

    $totals = @{
        Files          = 0
        SourceBytes    = 0L
        TargetBytes    = 0L
        Success        = 0
        NoSavings      = 0
        Resumed        = 0
        Failed         = 0
        Skipped        = 0
        LikelyNoSavings= 0
        AlreadyAV1     = 0
    }

    foreach ($r in ($results | Sort-Object { $_.RelativePath })) {
        $totals.Files++
        $totals.SourceBytes += $r.SourceSize
        $totals.TargetBytes += $r.TargetSize

        switch -Wildcard ($r.Status) {
            'Success'                { $totals.Success++         }
            'Success-NoSavings'      { $totals.NoSavings++       }
            'Resumed'                { $totals.Resumed++         }
            'Failed'                 { $totals.Failed++          }
            'Exception'              { $totals.Failed++          }
            'AlreadyAV1*'            { $totals.AlreadyAV1++      }
            'Skipped-LikelyNoSavings'{ $totals.LikelyNoSavings++ }
            default                  { $totals.Skipped++         }
        }

        $srcStr  = Format-Bytes $r.SourceSize
        $tgtStr  = if ($r.TargetSize -gt 0) { Format-Bytes $r.TargetSize } else { 'N/A' }
        $savStr  = if ($r.Transcoded -or $r.Status -in @('Resumed','Success-NoSavings')) { "$($r.SavingsPct)%" } else { 'N/A' }
        $fileTxt = if ($r.RelativePath.Length -gt $cw.File) {
            $offset = [math]::Max(0, $r.RelativePath.Length - ($cw.File - 2))
            '..' + $r.RelativePath.Substring($offset)
        } else { $r.RelativePath }

        $row = '| ' + (Pad $fileTxt           $cw.File)    + ' | ' +
                      (Pad $r.Status           $cw.Status)  + ' | ' +
                      (Pad $r.SourceAction     $cw.SrcAct)  + ' | ' +
                      (Pad $r.TargetAction     $cw.TgtAct)  + ' | ' +
                      (Pad $srcStr             $cw.SrcSize) + ' | ' +
                      (Pad $tgtStr             $cw.TgtSize) + ' | ' +
                      (Pad $savStr             $cw.Savings) + ' |'
        $tableLines.Add($row)
    }

    $tableLines.Add($sep)

    # Totals row
    $totalSavingsPct = if ($totals.SourceBytes -gt 0) {
        [math]::Round((1 - $totals.TargetBytes / $totals.SourceBytes) * 100, 1)
    } else { 0 }

    $totalLabel = "TOTAL ($($totals.Files) files)"
    $totalSaved = Format-Bytes ($totals.SourceBytes - $totals.TargetBytes)

    $totRow = '| ' + (Pad $totalLabel                        $cw.File)    + ' | ' +
                     (Pad ''                                  $cw.Status)  + ' | ' +
                     (Pad ''                                  $cw.SrcAct)  + ' | ' +
                     (Pad ''                                  $cw.TgtAct)  + ' | ' +
                     (Pad (Format-Bytes $totals.SourceBytes)  $cw.SrcSize) + ' | ' +
                     (Pad (Format-Bytes $totals.TargetBytes)  $cw.TgtSize) + ' | ' +
                     (Pad "$totalSavingsPct%"                 $cw.Savings) + ' |'
    $tableLines.Add($totRow)
    $tableLines.Add($sep)

    $summaryBlock = @"

$('=' * 80)
  FINAL SUMMARY — Session $sessionStamp
$('=' * 80)
$($tableLines -join "`n")

  Content profile : $Content
  Succeeded       : $($totals.Success)
  No savings      : $($totals.NoSavings)  (encoded but not smaller — source used instead)
  Likely no save  : $($totals.LikelyNoSavings)  (skipped — source already efficient)
  Resumed         : $($totals.Resumed)
  Already AV1     : $($totals.AlreadyAV1)
  Skipped         : $($totals.Skipped)
  Failed          : $($totals.Failed)
  ─────────────────────────────────────
  Total source    : $(Format-Bytes $totals.SourceBytes)
  Total output    : $(Format-Bytes $totals.TargetBytes)
  Space saved     : $totalSaved  ($totalSavingsPct%)
  ─────────────────────────────────────
  Master log      : $masterLogPath
$('=' * 80)
"@

    Add-Content -Path $masterLogPath -Value $summaryBlock -Encoding UTF8

    # Echo to console
    Write-Host "`n$summaryBlock" -ForegroundColor Green

    # =========================================================================
    # STEP 8: Export results to CSV (if ExportList = $true)
    # =========================================================================
    if ($ExportList) {
        $csvPath = Join-Path $LogDirectory "FileList_$sessionStamp.csv"
        $csvRows = [System.Collections.Generic.List[object]]::new()

        foreach ($r in ($results | Sort-Object { $_.RelativePath })) {
            $csvRows.Add([PSCustomObject]@{
                File            = Split-Path $r.RelativePath -Leaf
                'Relative Path' = Split-Path $r.RelativePath -Parent
                Status          = $r.Status
                'Src Action'    = $r.SourceAction
                'Target Action' = $r.TargetAction
                'Src Size'      = if ($r.SourceSize -gt 0) { Format-Bytes $r.SourceSize } else { 'N/A' }
                'Tgt Size'      = if ($r.TargetSize -gt 0) { Format-Bytes $r.TargetSize } else { 'N/A' }
                Savings         = if ($r.Transcoded -or $r.Status -in @('Resumed','Success-NoSavings')) { "$($r.SavingsPct)%" } else { 'N/A' }
            })
        }

        # Total row
        $csvRows.Add([PSCustomObject]@{
            File            = "TOTAL ($($totals.Files) files)"
            'Relative Path' = ''
            Status          = ''
            'Src Action'    = ''
            'Target Action' = ''
            'Src Size'      = Format-Bytes $totals.SourceBytes
            'Tgt Size'      = Format-Bytes $totals.TargetBytes
            Savings         = "$totalSavingsPct%"
        })

        $csvRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "[INFO] Results exported to: $csvPath" -ForegroundColor Cyan
    }

    } finally {
        if ($null -ne $logMutex) { $logMutex.Dispose() }
    }
}

# When run directly (not dot-sourced), forward all arguments to the function.
# Dot-source the script (. .\mucus.ps1) to load the function
# into your session without executing it.
if ($MyInvocation.InvocationName -ne '.') {
    mucus @args
}
