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

    $sourcePath = Join-Path -Path $PSScriptRoot -ChildPath "Release\node.exe"
    $destinationDir = Split-Path -Path $PSScriptRoot -Parent
    $destinationPath = Join-Path -Path $destinationDir -ChildPath $DestinationFileName

    if (-not (Test-Path -Path $sourcePath)) {
        Write-Error "Source file not found: $sourcePath"
        return 1
    }

    Write-Host "Copying '$sourcePath' to '$destinationPath'"
    Copy-Item -Path $sourcePath -Destination $destinationPath -Force

    if ($LASTEXITCODE -eq 0 -or $?) {
        Write-Host "Successfully copied to: $destinationPath"
        return 0
    }
    else {
        Write-Error "Failed to copy file"
        return 1
    }
}

function Build-WithLto {
    param(
        [ValidateSet('', 'release', 'ltcg', 'thin-lto', 'lto')]
        [string]$Lto = '',
        [string]$Arch = '',
        [Parameter(Mandatory = $true)]
        [string]$OutputName
    )

    git clean -fdx *> $null

    $vcbuildArgs = @()
    if ($Lto)  { $vcbuildArgs += $Lto }
    if ($Arch) { $vcbuildArgs += $Arch }
    $cmd = ".\vcbuild.bat $($vcbuildArgs -join ' ')"

    Measure-CommandTime -Command $cmd
    Copy-NodeExecutable -DestinationFileName $OutputName
}

function Build-WithPgo {
    param(
        [ValidateSet('', 'release', 'ltcg', 'thin-lto', 'lto')]
        [string]$Lto = '',
        [string]$Arch = '',
        [Parameter(Mandatory = $true)]
        [string]$OutputName,
        [int]$Duration = 15
    )

    # Step 1: Build instrumented binary
    git clean -fdx *> $null

    $vcbuildArgs = @('pgo-generate')
    if ($Lto)  { $vcbuildArgs += $Lto }
    if ($Arch) { $vcbuildArgs += $Arch }
    $cmd = ".\vcbuild.bat $($vcbuildArgs -join ' ')"

    Measure-CommandTime -Command $cmd
    $genName = $OutputName -replace '\.exe$', '_gen.exe'
    Copy-NodeExecutable -DestinationFileName $genName

    # Step 2: Collect profiles + merge
    .\pgo.ps1 -PgoGenNode .\Release\node.exe -PhaseOnly -Duration $Duration
    $profdataName = $OutputName -replace '\.exe$', '.profdata'
    $destinationDir = Split-Path -Path $PSScriptRoot -Parent
    Copy-Item -Path (Join-Path $PSScriptRoot 'node.profdata') -Destination (Join-Path $destinationDir $profdataName) -Force

    # Step 3: Build optimised binary
    git add node.profdata
    git clean -fdx *> $null
    git reset -- node.profdata *> $null

    $vcbuildArgs[0] = 'pgo-use'
    $cmd = ".\vcbuild.bat $($vcbuildArgs -join ' ')"

    Measure-CommandTime -Command $cmd
    $useName = $OutputName -replace '\.exe$', '_use.exe'
    Copy-NodeExecutable -DestinationFileName $useName
}

# Run this when in main
# Default and LTCG builds
Build-WithLto -OutputName "node_main.exe"
Build-WithLto -Lto release -OutputName "node_main_ltcg.exe"
Build-WithLto -Lto release -Arch arm64 -OutputName "node_main_ltcg_arm64.exe"

# Run this when in mefi-win-pgo
# Default and LTO builds
Build-WithLto -OutputName "node_branch.exe"
Build-WithLto -Lto ltcg -OutputName "node_branch_ltcg.exe"
Build-WithLto -Lto thin-lto -OutputName "node_thin_lto.exe"
Build-WithLto -Lto lto -OutputName "node_lto.exe"
Build-WithLto -Lto ltcg -Arch arm64 -OutputName "node_branch_ltcg_arm64.exe"
Build-WithLto -Lto thin-lto -Arch arm64 -OutputName "node_thin_lto_arm64.exe"
Build-WithLto -Lto lto -Arch arm64 -OutputName "node_lto_arm64.exe"
# PGO builds
Build-WithPgo -OutputName "node_pgo.exe"
Build-WithPgo -Lto ltcg -OutputName "node_ltcg_pgo.exe"
Build-WithPgo -Lto thin-lto -OutputName "node_thin_lto_pgo.exe"
Build-WithPgo -Lto lto -OutputName "node_lto_pgo.exe"
Build-WithPgo -Lto ltcg -Arch arm64 -OutputName "node_ltcg_pgo_arm64.exe"
Build-WithPgo -Lto thin-lto -Arch arm64 -OutputName "node_thin_lto_pgo_arm64.exe"
Build-WithPgo -Lto lto -Arch arm64 -OutputName "node_lto_pgo_arm64.exe"