<#
.SYNOPSIS
    One-line bootstrap that builds a Tiny11 ISO locally on your Windows PC.

.DESCRIPTION
    Run this from any PowerShell window (Administrator rights are requested
    automatically through UAC):

        irm https://raw.githubusercontent.com/thanhdtr/tiny11-automated/main/run.ps1 | iex

    The bootstrap script will:
      * download this repository to %LOCALAPPDATA%\tiny11-automated\repo
      * ask for the Windows 11 source (path to an .iso file, or the drive
        letter of an ISO you already mounted - files are mounted for you)
      * run the selected headless builder (Standard / Core / Nano)
      * move the finished ISO to %LOCALAPPDATA%\tiny11-automated\output

    Requirements: Windows 10/11, 25GB+ free disk space, internet access
    (repository + optional oscdimg.exe download), a Windows 11 ISO and a
    valid Windows license.

.PARAMETER Variant
    Build variant: Standard, Core or Nano. Prompted when omitted.

.PARAMETER ISO
    Windows 11 source: path to an .iso file, or a single drive letter of an
    already mounted ISO. Prompted when omitted.

.PARAMETER Index
    Windows image index (1=Home, 4=Education, 6=Pro, 7=Pro N). Prompted when omitted.

.PARAMETER Scratch
    Drive letter (e.g. D) used for temporary files. Defaults to the repository
    drive when omitted.

.PARAMETER PreserveWinRE
    Keep winre.wim intact (Core/Nano only). Recommended for real hardware and
    24H2/25H2 builds to avoid error 0x8007000B.

.PARAMETER EnableDotnet35
    Enable .NET Framework 3.5 support (Core only).

.PARAMETER SkipCleanup
    Keep temporary build files for debugging.

.PARAMETER NonInteractive
    Never prompt; fail instead when a required value is missing.

.EXAMPLE
    irm https://raw.githubusercontent.com/thanhdtr/tiny11-automated/main/run.ps1 | iex

.EXAMPLE
    irm https://raw.githubusercontent.com/thanhdtr/tiny11-automated/main/run.ps1 -OutFile run.ps1
    .\run.ps1 -Variant Core -ISO D:\Win11_25H2_English_x64.iso -Index 6 -NonInteractive

.NOTES
    MIT License - based on tiny11builder (ntdevlabs) / tiny11-automated (kelexine)
#>

[CmdletBinding()]
param(
    [ValidateSet('Standard', 'Core', 'Nano')]
    [string]$Variant,

    [string]$ISO,

    [int]$Index,

    [string]$Scratch,

    [switch]$PreserveWinRE,

    [switch]$EnableDotnet35,

    [switch]$SkipCleanup,

    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$Repo   = 'thanhdtr/tiny11-automated'
$RawUrl = "https://raw.githubusercontent.com/$Repo/main/run.ps1"

# Windows PowerShell 5.1 defaults to TLS 1.0, which GitHub rejects.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Options are forwarded to the elevated process through environment variables
# (an elevated process inherits the parent environment).
if (-not $Variant -and $env:TINY11_VARIANT) { $Variant = $env:TINY11_VARIANT }
if (-not $ISO -and $env:TINY11_ISO) { $ISO = $env:TINY11_ISO }
if (-not $Index -and $env:TINY11_INDEX) { try { $Index = [int]$env:TINY11_INDEX } catch { } }
if (-not $Scratch -and $env:TINY11_SCRATCH) { $Scratch = $env:TINY11_SCRATCH }
if ($env:TINY11_PRESERVEWINRE -eq '1') { $PreserveWinRE = $true }
if ($env:TINY11_DOTNET35 -eq '1') { $EnableDotnet35 = $true }
if ($env:TINY11_SKIPCLEANUP -eq '1') { $SkipCleanup = $true }
if ($env:TINY11_NONINTERACTIVE -eq '1') { $NonInteractive = $true }

function Read-Default {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

function Set-ChildEnv {
    param([string]$Name, [string]$Value)
    if ($Value) { Set-Item -Path "Env:$Name" -Value $Value }
}

#---------[ Administrator check ]---------#
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Administrator rights are required - requesting elevation...' -ForegroundColor Yellow
    try {
        Set-ChildEnv 'TINY11_VARIANT' $Variant
        Set-ChildEnv 'TINY11_ISO' $ISO
        if ($Index) { Set-ChildEnv 'TINY11_INDEX' "$Index" }
        Set-ChildEnv 'TINY11_SCRATCH' $Scratch
        if ($PreserveWinRE) { Set-ChildEnv 'TINY11_PRESERVEWINRE' '1' }
        if ($EnableDotnet35) { Set-ChildEnv 'TINY11_DOTNET35' '1' }
        if ($SkipCleanup) { Set-ChildEnv 'TINY11_SKIPCLEANUP' '1' }
        if ($NonInteractive) { Set-ChildEnv 'TINY11_NONINTERACTIVE' '1' }

        $command = "irm '$RawUrl' | iex"
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Command "' + $command + '"') -ErrorAction Stop
        Write-Host 'Continue in the new elevated PowerShell window.' -ForegroundColor Cyan
    } catch {
        Write-Host 'Elevation was cancelled.' -ForegroundColor Red
        Write-Host "Re-run this in a PowerShell window opened as Administrator, or save run.ps1 and execute it there." -ForegroundColor Yellow
    } finally {
        foreach ($name in @('TINY11_VARIANT', 'TINY11_ISO', 'TINY11_INDEX', 'TINY11_SCRATCH', 'TINY11_PRESERVEWINRE', 'TINY11_DOTNET35', 'TINY11_SKIPCLEANUP', 'TINY11_NONINTERACTIVE')) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    return
}

#---------[ Prepare workspace ]---------#
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch { }

$workRoot   = Join-Path $env:LOCALAPPDATA 'tiny11-automated'
$repoDir    = Join-Path $workRoot 'repo'
$scriptsDir = Join-Path $repoDir 'scripts'
$outputDir  = Join-Path $workRoot 'output'
New-Item -ItemType Directory -Force -Path $workRoot, $outputDir | Out-Null

Write-Host "Downloading $Repo from GitHub..." -ForegroundColor Cyan
$zipUrl  = "https://github.com/$Repo/archive/refs/heads/main.zip"
$zipPath = Join-Path $env:TEMP 'tiny11-src.zip'
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

$stage = Join-Path $env:TEMP ('tiny11-stage-' + [Guid]::NewGuid().ToString('N'))
Expand-Archive -Path $zipPath -DestinationPath $stage -Force
$staged = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
if (-not $staged -or -not (Test-Path (Join-Path $staged.FullName 'scripts\tiny11maker-headless.ps1'))) {
    throw 'Downloaded repository does not contain the expected builder scripts.'
}

# Preserve ISOs/logs produced by an earlier run before replacing the checkout.
if (Test-Path $scriptsDir) {
    foreach ($pattern in @('*.iso', '*.log', '*buildinfo*.json')) {
        Get-ChildItem -Path (Join-Path $scriptsDir $pattern) -ErrorAction SilentlyContinue | ForEach-Object {
            $destination = Join-Path $outputDir $_.Name
            if (Test-Path $destination) {
                $destination = Join-Path $outputDir ($_.BaseName + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $_.Extension)
            }
            Move-Item -LiteralPath $_.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
        }
    }
}
if (Test-Path $repoDir) { Remove-Item -LiteralPath $repoDir -Recurse -Force }
Move-Item -LiteralPath $staged.FullName -Destination $repoDir
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

#---------[ Collect options ]---------#
if (-not $Variant) {
    if ($NonInteractive) { throw 'Missing -Variant (Standard, Core or Nano).' }
    Write-Host ''
    Write-Host 'Select build variant:' -ForegroundColor Cyan
    Write-Host '  1) Standard - daily use, Defender and WinRE intact (default)'
    Write-Host '  2) Core     - ultra-minimal, VMs and testing'
    Write-Host '  3) Nano     - extreme minimal, VM testing only'
    $choice = Read-Default 'Choice' '1'
    $Variant = switch ($choice) { '2' { 'Core' } '3' { 'Nano' } default { 'Standard' } }
}

while (-not $ISO) {
    if ($NonInteractive) { throw 'Missing -ISO (path to a Windows 11 .iso file, or drive letter of a mounted ISO).' }
    $candidate = (Read-Host 'Windows 11 source: path to .iso file, or drive letter of an already mounted ISO').Trim().Trim('"')
    if (-not $candidate) { continue }
    if ($candidate -match '^[a-zA-Z]$') {
        if (Test-Path -LiteralPath ($candidate.Substring(0, 1) + ':\')) { $ISO = $candidate; break }
        Write-Host "Drive ${candidate}: does not exist." -ForegroundColor Yellow
        continue
    }
    if (Test-Path -LiteralPath $candidate) { $ISO = $candidate; break }
    Write-Host "File not found: $candidate" -ForegroundColor Yellow
}
$ISO = $ISO.Trim().Trim('"')

if (-not $Index) {
    if ($NonInteractive) { $Index = 1 }
    else {
        Write-Host ''
        Write-Host 'Image index: 1=Home, 4=Education, 6=Pro, 7=Pro N' -ForegroundColor Cyan
        $parsed = 0
        while (-not $parsed) {
            $raw = Read-Default 'Image index' '1'
            if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 10) { break }
            Write-Host 'Please enter a number between 1 and 10.' -ForegroundColor Yellow
            $parsed = 0
        }
        $Index = $parsed
    }
}
if ($Index -lt 1 -or $Index -gt 10) { throw "Invalid image index: $Index" }

if (-not $Scratch -and -not $NonInteractive) {
    while (-not $Scratch) {
        $raw = Read-Default 'Scratch drive letter for temporary files (Enter = same drive as the repository)' ''
        if ([string]::IsNullOrWhiteSpace($raw)) { break }
        if ($raw -notmatch '^[a-zA-Z]$') {
            Write-Host 'Please enter a single drive letter, or press Enter to keep the default.' -ForegroundColor Yellow
            continue
        }
        if (-not (Test-Path -LiteralPath ($raw.Substring(0, 1) + ':\'))) {
            Write-Host "Drive ${raw}: does not exist." -ForegroundColor Yellow
            continue
        }
        $Scratch = $raw.Substring(0, 1).ToUpper()
    }
}
if ($Scratch -and $Scratch -notmatch '^[a-zA-Z]$') { throw "-Scratch must be a single drive letter, got '$Scratch'." }

if (($Variant -eq 'Core' -or $Variant -eq 'Nano') -and -not $PreserveWinRE -and -not $NonInteractive) {
    $raw = Read-Default 'Preserve winre.wim (recommended for real hardware / 24H2+ builds)? [Y/n]' 'Y'
    if ($raw -notmatch '^[nN]') { $PreserveWinRE = $true }
}
if ($Variant -eq 'Core' -and -not $EnableDotnet35 -and -not $NonInteractive) {
    $raw = Read-Default 'Enable .NET Framework 3.5 (Core only)? [y/N]' 'N'
    if ($raw -match '^[yY]') { $EnableDotnet35 = $true }
}

#---------[ Resolve the Windows 11 source ]---------#
$mountedByUs = $false
$isoDrive    = $null
$isoFile     = $null

if ($ISO -match '^[a-zA-Z]$') {
    $isoDrive = $ISO.ToUpper()
} else {
    if (-not (Test-Path -LiteralPath $ISO)) { throw "ISO file not found: $ISO" }
    $isoFile = (Resolve-Path -LiteralPath $ISO).Path

    $image = Get-DiskImage -ImagePath $isoFile -ErrorAction SilentlyContinue
    if (-not $image -or -not $image.Attached) {
        Write-Host "Mounting $isoFile ..." -ForegroundColor Cyan
        $image = Mount-DiskImage -ImagePath $isoFile -PassThru
        $mountedByUs = $true
    }
    for ($i = 0; $i -lt 30 -and -not $isoDrive; $i++) {
        Start-Sleep -Milliseconds 500
        $volume = $image | Get-Volume -ErrorAction SilentlyContinue
        if ($volume -and $volume.DriveLetter) { $isoDrive = [string]$volume.DriveLetter }
    }
}

if (-not $isoDrive) { throw 'Could not determine the drive letter of the mounted ISO.' }
$isoDrive = $isoDrive.ToUpper()
if (-not ((Test-Path "${isoDrive}:\sources\install.wim") -or (Test-Path "${isoDrive}:\sources\install.esd"))) {
    if ($mountedByUs) { Get-DiskImage -ImagePath $isoFile -ErrorAction SilentlyContinue | Dismount-DiskImage -ErrorAction SilentlyContinue }
    throw "Drive ${isoDrive}: does not contain Windows installation media (sources\install.wim / install.esd)."
}

#---------[ Disk space check ]---------#
$targetDrive = if ($Scratch) { $Scratch } else { $repoDir.Substring(0, 1) }
$freeGB = [math]::Round(([System.IO.DriveInfo]::new($targetDrive)).AvailableFreeSpace / 1GB, 1)
if ($freeGB -lt 25) {
    if ($NonInteractive) {
        throw "Only ${freeGB}GB free on ${targetDrive}: - at least 25GB required."
    }
    $raw = Read-Default "Only ${freeGB}GB free on ${targetDrive}: (25GB+ recommended). Continue anyway?" 'N'
    if ($raw -notmatch '^[yY]') { throw 'Aborted: not enough free disk space.' }
}

#---------[ Confirm ]---------#
$scratchLabel = if ($Scratch) { "${Scratch}:" } else { "${targetDrive}: (repository drive)" }
$winreLabel   = if ($PreserveWinRE) { 'preserved' } else { 'removed' }

Write-Host ''
Write-Host 'Build summary' -ForegroundColor Cyan
Write-Host "  Variant : $Variant"
Write-Host "  Source  : $ISO (drive ${isoDrive}:)"
Write-Host "  Index   : $Index"
Write-Host "  Scratch : $scratchLabel"
Write-Host "  Free    : ${freeGB}GB on ${targetDrive}:"
if ($Variant -ne 'Standard') { Write-Host "  WinRE   : $winreLabel" }
Write-Host "  Output  : $outputDir"
Write-Host ''
if (-not $NonInteractive) {
    $raw = Read-Default 'Start the build (30-80 minutes)?' 'Y'
    if ($raw -notmatch '^[yY]') {
        if ($mountedByUs) { Get-DiskImage -ImagePath $isoFile -ErrorAction SilentlyContinue | Dismount-DiskImage -ErrorAction SilentlyContinue }
        return
    }
}

#---------[ Run the builder ]---------#
$autounattend = Join-Path $repoDir 'autounattend.xml'
if (Test-Path $autounattend) {
    Copy-Item -Path $autounattend -Destination (Join-Path $scriptsDir 'autounattend.xml') -Force
}

$builderName = switch ($Variant) {
    'Core'   { 'tiny11coremaker-headless.ps1' }
    'Nano'   { 'nano11builder-headless.ps1' }
    default  { 'tiny11maker-headless.ps1' }
}
$builderPath = Join-Path $scriptsDir $builderName

$builderParams = @{ ISO = $isoDrive; INDEX = $Index }
if ($Scratch) { $builderParams.SCRATCH = $Scratch }
if ($SkipCleanup) { $builderParams.SkipCleanup = $true }
if ($PreserveWinRE -and $Variant -ne 'Standard') { $builderParams.PreserveWinRE = $true }
if ($EnableDotnet35 -and $Variant -eq 'Core') { $builderParams.ENABLE_DOTNET35 = $true }

Write-Host ''
Write-Host "Starting $Variant build - this takes 30-80 minutes, do not close the window..." -ForegroundColor Green
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$LASTEXITCODE = 0

try {
    & $builderPath @builderParams
    $exitCode = $LASTEXITCODE
} finally {
    if ($mountedByUs -and $isoFile) {
        Get-DiskImage -ImagePath $isoFile -ErrorAction SilentlyContinue | Dismount-DiskImage -ErrorAction SilentlyContinue
    }
}
$timer.Stop()

#---------[ Collect the result ]---------#
$producedIso = switch ($Variant) {
    'Core'  { 'tiny11-core.iso' }
    'Nano'  { 'nano11.iso' }
    default { 'tiny11.iso' }
}
$producedPath = Join-Path $scriptsDir $producedIso

if ($exitCode -ne 0 -or -not (Test-Path $producedPath)) {
    $log = Get-ChildItem -Path (Join-Path $scriptsDir '*.log') -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host ''
    Write-Host "Build FAILED after $([math]::Round($timer.Elapsed.TotalMinutes, 1)) minutes." -ForegroundColor Red
    if ($log) { Write-Host "Log: $($log.FullName)" -ForegroundColor Yellow }
    return
}

$suffix = switch ($Variant) { 'Core' { 'core' } 'Nano' { 'nano' } default { 'standard' } }
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$finalName = "tiny11-$suffix-$stamp.iso"
$finalPath = Join-Path $outputDir $finalName
Move-Item -LiteralPath $producedPath -Destination $finalPath -Force

Get-ChildItem -Path (Join-Path $scriptsDir '*') -Include '*.log', '*buildinfo*.json' -ErrorAction SilentlyContinue |
    ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $outputDir -Force -ErrorAction SilentlyContinue }

$sizeGB = [math]::Round((Get-Item $finalPath).Length / 1GB, 2)
$sha256 = (Get-FileHash -Path $finalPath -Algorithm SHA256).Hash
"$sha256  $finalName" | Out-File -FilePath ($finalPath + '.sha256') -Encoding ASCII

Write-Host ''
Write-Host '=== Build completed ===' -ForegroundColor Green
Write-Host "  ISO    : $finalPath"
Write-Host "  Size   : ${sizeGB}GB"
Write-Host "  SHA256 : $sha256"
Write-Host "  Time   : $([math]::Round($timer.Elapsed.TotalMinutes, 1)) minutes"
Write-Host ''
Write-Host 'Reminder: you need a valid Windows license. Modified images are unsupported by Microsoft.' -ForegroundColor Yellow
