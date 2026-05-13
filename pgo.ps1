# PGO (Profile-Guided Optimization) build script for Node.js on Windows (clang-cl / LLVM)
#
# Phases (determined by which parameters are provided):
#   Phase 1 (no params)              : Build instrumented binary  (Step 1 only)
#   Phase 2 (-PgoGenNode <path>)     : Collect profiles + merge   (Steps 2-3 only)
#   Phase 3 (-PgoGenNode + -ProfdataFile) : Build optimised binary (Step 4 only)
#
# Use -Lto <ltcg|thin-lto|lto> to combine PGO with an LTO option.
# Use -PhaseOnly to run only the relevant phase and exit (without it, all steps run end-to-end).
#
# Phases (with -PhaseOnly):
#   Phase 1 (no params)                    : Build instrumented binary  (Step 1 only)
#   Phase 2 (-PgoGenNode <path>)           : Collect profiles + merge   (Steps 2-3 only)
#   Phase 3 (-PgoGenNode + -ProfdataFile)  : Build optimised binary     (Step 4 only)

param(
    [string]$PgoGenNode,
    [string]$ProfdataFile,
    [ValidateSet('', 'ltcg', 'thin-lto', 'lto')]
    [string]$Lto = '',
    [switch]$PhaseOnly,
    [int]$Duration = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Derived values
$skipPgoGenerate = $false
$providedInstrumented = $null
$destinationDir = Split-Path $PSScriptRoot -Parent
$ltoSuffix = if ($Lto) { "_$($Lto -replace '-','_')" } else { '' }

# If a path to an existing instrumented node binary is provided, prepare to skip build
if ($PgoGenNode) {
    if (Test-Path $PgoGenNode) {
        $providedInstrumented = (Resolve-Path $PgoGenNode).Path
        Write-Host "Using provided instrumented node: $providedInstrumented"
        $skipPgoGenerate = $true
    }
    else {
        Write-Warning "Provided PgoGenNode was not found: $PgoGenNode. Will build instrumented binary."
    }
}

# If a pre-merged .profdata file is provided, skip steps 2 and 3 entirely
$skipProfileCollection = $false
$profdata = Join-Path $PSScriptRoot "node.profdata"

if ($ProfdataFile) {
    if (Test-Path $ProfdataFile) {
        $resolvedProfdata = (Resolve-Path $ProfdataFile).Path
        Write-Host "Using provided profdata: $resolvedProfdata"
        $skipProfileCollection = $true
        # If we have profdata, we also don't need the instrumented build
        $skipPgoGenerate = $true
        # Copy it to node.profdata in the workspace root (where pgo-use expects it)
        if ($resolvedProfdata -ne $profdata) {
            Copy-Item -Path $resolvedProfdata -Destination $profdata -Force
            Write-Host "Copied provided profdata to: $profdata"
        } else {
            Write-Host "Provided profdata is already at the expected location: $profdata"
        }
    }
    else {
        Write-Warning "Provided ProfdataFile was not found: $ProfdataFile. Will run workloads and merge."
    }
}

# ---------------------------------------------------------------------------
# Helpers (same pattern as build.ps1)
# ---------------------------------------------------------------------------

function Measure-CommandTime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    Write-Host "Running: $Command"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Invoke-Expression $Command *> $null
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Error "Command failed: $_"
        $exitCode = 1
    }

    $stopwatch.Stop()
    $elapsed = $stopwatch.Elapsed
    Write-Host "Command completed in: $($elapsed.Hours) hours, $($elapsed.Minutes) minutes, $($elapsed.Seconds) seconds, $($elapsed.Milliseconds) milliseconds"

    return $exitCode
}

function Copy-NodeExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationFileName
    )

    $sourcePath = Join-Path $PSScriptRoot "Release\node.exe"
    $destinationDir = Split-Path $PSScriptRoot -Parent
    $destinationPath = Join-Path $destinationDir $DestinationFileName

    if (-not (Test-Path $sourcePath)) {
        Write-Error "Source file not found: $sourcePath"
        return 1
    }

    Write-Host "Copying '$sourcePath' -> '$destinationPath'"
    Copy-Item -Path $sourcePath -Destination $destinationPath -Force
    Write-Host "Successfully copied to: $destinationPath"
    return 0
}

# ---------------------------------------------------------------------------
# Locate llvm-profdata shipped with Visual Studio's LLVM toolset
# ---------------------------------------------------------------------------

function Find-LlvmProfdata {
    # vcbuild.bat uses %VCINSTALLDIR%\Tools\Llvm\x64\bin for clang.exe - same spot for profdata
    $vcInstallDir = $env:VCINSTALLDIR

    if ($vcInstallDir) {
        $candidate = Join-Path $vcInstallDir "Tools\Llvm\x64\bin\llvm-profdata.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    # Fallback: try VS 2022 / 2026 default install locations
    $vsPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Enterprise\VC\Tools\Llvm\x64\bin",
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Community\VC\Tools\Llvm\x64\bin",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\VC\Tools\Llvm\x64\bin",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin"
    )
    foreach ($dir in $vsPaths) {
        $candidate = Join-Path $dir "llvm-profdata.exe"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    # Last resort: PATH
    $fromPath = Get-Command llvm-profdata -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    return $null
}

# ---------------------------------------------------------------------------
# Directory that will receive .profraw files from the instrumented binary.
# Using %p (PID) and %m (module hash) keeps concurrent runs from colliding.
# ---------------------------------------------------------------------------
$profileDir = Join-Path $PSScriptRoot "pgo-profiles"

# ---------------------------------------------------------------------------
# STEP 1 – Clean & build the instrumented (pgo-generate) binary
# ---------------------------------------------------------------------------

Write-Host "`n=== STEP 1: Build instrumented binary (pgo-generate) ===" -ForegroundColor Cyan

if ($skipPgoGenerate) {
    Write-Host "Skipping instrumented build because a provided PGO-generation binary was found." -ForegroundColor Yellow
    $rc = 0
} else {
    git clean -fdx *> $null

    $vcbuildArgs = "pgo-generate"
    if ($Lto) { $vcbuildArgs += " $Lto" }
    $rc = Measure-CommandTime -Command ".\vcbuild.bat $vcbuildArgs"
    if ($rc -ne 0) {
        Write-Error "pgo-generate build failed (exit code $rc)"
        exit $rc
    }

    Copy-NodeExecutable -DestinationFileName "node${ltoSuffix}_pgo_gen.exe"
}

# Phase 1 complete – exit if -PhaseOnly and no PgoGenNode/ProfdataFile was provided
if ($PhaseOnly -and -not $PgoGenNode -and -not $ProfdataFile) {
    Write-Host "`n=== Phase 1 complete: Instrumented binary built ===" -ForegroundColor Green
    Write-Host "  Next: .\pgo.ps1 -PgoGenNode .\node${ltoSuffix}_pgo_gen.exe"
    exit 0
}

# ---------------------------------------------------------------------------
# STEP 2 – Run workloads with the instrumented binary to collect profiles
# ---------------------------------------------------------------------------

Write-Host "`n=== STEP 2: Collect PGO profiles ===" -ForegroundColor Cyan

if ($skipProfileCollection) {
    Write-Host "Skipping profile collection and merge because a provided profdata file was found." -ForegroundColor Yellow
} else {
    # Ensure a clean profile directory for this run
    if (Test-Path $profileDir) {
        Remove-Item -Recurse -Force $profileDir
    }
    New-Item -ItemType Directory -Path $profileDir | Out-Null

    # Point the LLVM runtime at our profile directory.
    # %p  = process ID  (ensures unique files for concurrent/fork'd processes)
    # %m  = module hash (distinguishes shared libraries if any)
    $env:LLVM_PROFILE_FILE = Join-Path $profileDir "node-%p-%m.profraw"

    $instrumentedNode = if ($skipPgoGenerate -and $providedInstrumented) { $providedInstrumented } else { Join-Path $PSScriptRoot "Release\node.exe" }

    Write-Host "Instrumented node : $instrumentedNode"
    Write-Host "Profile output    : $($env:LLVM_PROFILE_FILE)"
    Write-Host ""

    # Run the PGO training workloads via tools/pgo/pgo-run-all.js
    $pgoRunAll = Join-Path $PSScriptRoot "tools\pgo\pgo-run-all.js"
    if (-not (Test-Path $pgoRunAll)) {
        Write-Error "PGO training script not found: $pgoRunAll"
        exit 1
    }

    Write-Host "Running PGO training workloads: $pgoRunAll" -ForegroundColor Green
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process `
        -FilePath $instrumentedNode `
        -ArgumentList "`"$pgoRunAll`" --verbose --duration=$Duration" `
        -Wait -PassThru -NoNewWindow
    $sw.Stop()
    Write-Host ("PGO training completed in {0}m {1}s (exit code: {2})" -f `
        $sw.Elapsed.Minutes, $sw.Elapsed.Seconds, $proc.ExitCode)
    if ($proc.ExitCode -ne 0) {
        Write-Warning "PGO training exited with code $($proc.ExitCode) - continuing"
    }

    # -------------------------------------------------------------------------
    # STEP 3 – Merge .profraw files -> node.profdata
    # -------------------------------------------------------------------------

    Write-Host "`n=== STEP 3: Merge profile data ===" -ForegroundColor Cyan

    # Remove the env var so subsequent node builds are not instrumented
    Remove-Item Env:\LLVM_PROFILE_FILE -ErrorAction SilentlyContinue

    $llvmProfdata = Find-LlvmProfdata
    if (-not $llvmProfdata) {
        Write-Error "llvm-profdata not found. Install the LLVM toolset via Visual Studio Installer."
        exit 1
    }
    Write-Host "Using llvm-profdata: $llvmProfdata"

    $profrawFiles = Get-ChildItem -Path $profileDir -Filter "*.profraw" -ErrorAction SilentlyContinue
    if ($profrawFiles.Count -eq 0) {
        Write-Warning "No .profraw files found in '$profileDir'. Did the instrumented binary run any workloads?"
        Write-Warning "The pgo-use build will proceed but may not benefit from profile data."
    } else {
        Write-Host "Found $($profrawFiles.Count) .profraw file(s) to merge."
    }

    # Build the merge command. llvm-profdata accepts a list of inputs or a wildcard via response file.
    $scriptWeights = [ordered]@{}
    $groups = @{}

    foreach ($file in $profrawFiles) {
        $parts = $file.BaseName -split '-'
        $key = if ($parts.Count -ge 4) {
            $parts[1..($parts.Count - 3)] -join '-'
        } else {
            '__orchestrator__'
        }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [System.Collections.Generic.List[string]]::new()
        }
        $groups[$key].Add($file.FullName)
    }

    Write-Host "Profile groups (weighted merge):"

    foreach ($key in ($groups.Keys | Sort-Object)) {
        Write-Host ("  {0,-22} {1,4} file(s)   group weight {2}" -f $key, $groups[$key].Count, 1)     
    }

    $maxCount = ($groups.Values | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum

    $mergeArgs = [System.Collections.Generic.List[string]]@("merge", "--output=$profdata")

    foreach ($key in $groups.Keys) {
        $groupWeight = if ($scriptWeights.Contains($key)) { $maxCount } else { $maxCount }
        $perFileWeight = $groupWeight / $groups[$key].Count
        foreach ($file in $groups[$key]) {
            $mergeArgs.Add("--weighted-input=$perFileWeight,$file")
        }
    }

    Write-Host "Merging: $llvmProfdata $($mergeArgs -join ' ')"

    $mergeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    & $llvmProfdata @mergeArgs
    $mergeExitCode = $LASTEXITCODE
    $mergeStopwatch.Stop()

    Write-Host "Merge completed in: $($mergeStopwatch.Elapsed.TotalSeconds) s"

    if ($mergeExitCode -ne 0) {
        Write-Error "llvm-profdata merge failed (exit code $mergeExitCode)"
        exit $mergeExitCode
    }

    Write-Host "Profile data written to: $profdata"
}

# Phase 2 complete – exit if -PhaseOnly and no ProfdataFile was provided
if ($PhaseOnly -and -not $ProfdataFile) {
    Write-Host "`n=== Phase 2 complete: Profile data collected ===" -ForegroundColor Green
    Write-Host "  Next: .\pgo.ps1 -PgoGenNode x -ProfdataFile .\node.profdata"
    exit 0
}

# ---------------------------------------------------------------------------
# STEP 4 – Build the optimised (pgo-use) binary
# ---------------------------------------------------------------------------

Write-Host "`n=== STEP 4: Build optimised binary (pgo-use) ===" -ForegroundColor Cyan

# vcbuild / common.gypi expect node.profdata in the workspace root (same dir as node.gyp)
# – it's already there from the merge step above.
# Preserve node.profdata across git clean by staging it
git add node.profdata

git clean -fdx *> $null

# Unstage node.profdata (restores it to the working tree)
git reset -- node.profdata *> $null

$vcbuildArgs = "pgo-use"
if ($Lto) { $vcbuildArgs += " $Lto" }
$rc = Measure-CommandTime -Command ".\vcbuild.bat $vcbuildArgs"
if ($rc -ne 0) {
    Write-Error "pgo-use build failed (exit code $rc)"
    exit $rc
}

Copy-NodeExecutable -DestinationFileName "node${ltoSuffix}_pgo_use.exe"

Write-Host "`n=== Phase 3 complete: PGO-optimised binary built ===" -ForegroundColor Green
Write-Host "  node${ltoSuffix}_pgo_use.exe  - PGO-optimised binary"
