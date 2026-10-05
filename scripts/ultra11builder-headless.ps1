<#
.SYNOPSIS
    Headless script that builds the "ultra11" image: Nano pushed to the
    absolute minimum that still installs and boots.

.DESCRIPTION
    Ultra is a separate, fourth variant - Nano is left untouched for people who
    need a usable image. It starts from Nano's aggressive base (bloatware,
    fonts, driver classes, WinSxS, input methods, speech, WinRE, Defender and
    Windows Update binaries already stripped) and then goes further, with the
    headline being service minimisation:

      * Every one of the ~678 service keys in the image is classified, rather
        than working from a hand-maintained blocklist. Kernel/file-system
        drivers and Boot/System load-order entries are never touched; every
        Win32 service that is not on a keep list is set to Disabled.
      * Auto-start Win32 services go from 63 in stock Windows down to the 28
        in the dependency closure of what the SCM actually needs to reach a
        desktop, plus a 20-entry Manual tier for things that should still be
        startable on demand (winutil's MapsBroker/StorSvc convention, RDP,
        W32Time, the clipboard host, and so on).
      * Startup types are written as the 'Start' DWORD (2=Automatic,
        3=Manual, 4=Disabled) instead of Nano's outright key deletion, so the
        Service Control Manager still has a valid record behind them.
      * winutil's background-apps kill switch (GlobalUserDisabled) and its
        privacy/telemetry policy block are baked in, along with a first-logon
        recompute of SvcHostSplitThresholdInKB from the target machine's RAM
        so svchost processes get packed together.

    NOTHING ELSE IS GUARANTEED. The contract is: it installs, it reaches a
    desktop, and as little as possible is running. Individual apps and features
    will fail - there is no print spooler, no audio, no firewall, no Windows
    Search indexer, no SMB/UNC access and no in-guest clipboard unless you flip
    the corresponding entry in $keepManual/$keepAuto back to a working startup
    type. VM testing only; do not use this on hardware you care about.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 ISO (e.g., E), or the full path to a
    downloaded Windows 11 .iso file - a file path is mounted automatically.

.PARAMETER INDEX
    Windows image index to process (required, e.g., 1 for Home, 6 for Pro)

.PARAMETER SCRATCH
    Drive letter for scratch disk operations (optional, defaults to script root)

.PARAMETER BackupDrivers
    Export third-party drivers from the running Windows installation into
    host_drivers\ and inject them into the new image (install.wim + boot.wim)

.PARAMETER Defender
    Windows Defender handling: Keep (no changes), Disable (policies, services
    and scheduled tasks turned off, files left in place - reversible) or
    Remove (default: Defender platform + Windows Security app uninstalled
    and files deleted - this script's historical behavior).

.PARAMETER OutputDir
    Custom folder for the finished ISO. Defaults to the folder of the source
    .iso file (file-path -ISO), or the script folder (drive-letter -ISO).

.PARAMETER Compress
    Compression for the install.wim export: max (default), fast or recovery
    (smallest - single-threaded DISM, slowest). fast/max are exported with
    wimlib (multi-threaded, downloaded and SHA256-verified at build time);
    any wimlib failure falls back to DISM automatically. Core and ultra still
    recompress to a solid ESD at the end for minimum size.

.PARAMETER SkipCleanup
    Skip cleanup of temporary files after ISO creation (optional, for debugging)

.EXAMPLE
    .\ultra11builder-headless.ps1 -ISO E -INDEX 1
    .\ultra11builder-headless.ps1 -ISO E -INDEX 6 -SCRATCH D -SkipCleanup
    .\ultra11builder-headless.ps1 -ISO D:\ISOs\Win11_25H2_x64.iso -INDEX 1 -BackupDrivers
    .\ultra11builder-headless.ps1 -ISO E -INDEX 1 -Defender Keep
    .\ultra11builder-headless.ps1 -ISO E -INDEX 1

.NOTES
    Original Author: ntdevlabs
    Modified by: kelexine (https://github.com/kelexine)
    GitHub: https://github.com/kelexine/tiny11-automated
    Date: 2025-12-13

    License: MIT
    This is a headless automation-ready version designed for CI/CD pipelines.
#>

#---------[ Parameters ]---------#
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="Drive letter of a mounted Windows 11 ISO (e.g., E) or path to a .iso file")]
    [string]$ISO,

    [Parameter(Mandatory=$true, HelpMessage="Windows image index (1=Home, 6=Pro, etc.)")]
    [ValidateRange(1, 10)]
    [int]$INDEX,

    [Parameter(Mandatory=$false, HelpMessage="Scratch disk drive letter (defaults to script directory)")]
    [ValidatePattern('^[c-zC-Z]$')]
    [string]$SCRATCH,

    [Parameter(Mandatory=$false, HelpMessage="Skip cleanup of temporary files")]
    [switch]$SkipCleanup,

    [Parameter(Mandatory=$false, HelpMessage="Preserve winre.wim instead of deleting it. Use this if targeting real hardware, EFI-enabled VMs (VirtualBox/VMware/Hyper-V), or 24H2/25H2 setups. Without this flag, winre.wim is deleted entirely so Windows Setup skips WinRE config gracefully. DO NOT use an empty stub — it causes error 0x8007000B on EFI systems.")]
    [switch]$PreserveWinRE,

    [Parameter(Mandatory=$false, HelpMessage="Export drivers from this PC into host_drivers\ and inject them into the image")]
    [switch]$BackupDrivers,

    [Parameter(Mandatory=$false, HelpMessage="Windows Defender handling: Keep, Disable or Remove (default)")]
    [ValidateSet('Keep', 'Disable', 'Remove')]
    [string]$Defender = 'Remove',

    [Parameter(Mandatory=$false, HelpMessage="Custom folder for the finished ISO (default: next to the source .iso file, or the script folder for a drive letter)")]
    [string]$OutputDir = '',

    [Parameter(Mandatory=$false, HelpMessage="Compression for the install.wim export: max (default), fast or recovery (smallest - single-threaded DISM, slow)")]
    [ValidateSet('fast', 'max', 'recovery')]
    [string]$Compress = 'max'
)

#---------[ Error Handling ]---------#
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

#---------[ Configuration ]---------#
if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

$script:MountedIsoPath = $null
$script:DriverCount = 0
if ($ISO -match '^[a-zA-Z]:?$') {
    $DriveLetter = $ISO.TrimEnd(':').ToUpper() + ':'
} else {
    $DriveLetter = $null  # .iso file path - mounted by Initialize-IsoSource
}
$driverBackupDir = Join-Path $PSScriptRoot 'host_drivers'
$wimFilePath = "$ScratchDisk\ultra11\sources\install.wim"
$scratchDir = "$ScratchDisk\scratchdir"
$ultra11Dir = "$ScratchDisk\ultra11"
$outputISO = "$PSScriptRoot\ultra11.iso"
if ($OutputDir) {
    $od = $OutputDir.Trim().Trim('"')
    if (-not [System.IO.Path]::IsPathRooted($od)) { $od = Join-Path -Path (Get-Location).Path -ChildPath $od }
    $outputISO = Join-Path ([System.IO.Path]::GetFullPath($od)) (Split-Path -Leaf $outputISO)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputISO) | Out-Null
}
$logFile = "$PSScriptRoot\ultra11_$(Get-Date -Format yyyyMMdd_HHmmss).log"

# Initialize admin identifiers for permission operations
try {
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
} catch {
    Write-Warning "Failed to resolve Administrator group SID. Defaulting to 'Administrators'."
    $adminGroup = [PSCustomObject]@{ Value = "Administrators" }
}

#---------[ Helper Functions ]---------#
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Output $logMessage
    Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Initialize-IsoSource {
    # -ISO accepts either a mounted drive letter (E) or a path to a .iso file.
    if ($DriveLetter) {
        Write-Log "Using mounted ISO source at $DriveLetter"
        return
    }

    $isoPath = $ISO.Trim().Trim('"')
    if ($isoPath -notmatch '\.iso$') {
        throw "Invalid -ISO value '$ISO'. Use a drive letter of a mounted ISO (e.g., E) or the path to a .iso file (e.g., D:\ISOs\Win11.iso)."
    }
    if (-not [System.IO.Path]::IsPathRooted($isoPath)) {
        $isoPath = Join-Path -Path (Get-Location).Path -ChildPath $isoPath
    }
    $isoPath = [System.IO.Path]::GetFullPath($isoPath)
    if (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) {
        throw "ISO file not found: $isoPath"
    }

    # Deliver the finished ISO next to the source file (same folder as the original .iso)
    if ($OutputDir) {
        Write-Log "Output ISO will be written to the custom -OutputDir folder: $($script:outputISO)"
    } else {
        $script:outputISO = Join-Path (Split-Path -Parent $isoPath) (Split-Path -Leaf $script:outputISO)
        Write-Log "Output ISO will be written next to the source: $($script:outputISO)"
    }

    $image = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    $alreadyAttached = [bool]($image -and $image.Attached)
    if ($alreadyAttached) {
        Write-Log "ISO already mounted: $isoPath"
    } else {
        Write-Log "Mounting ISO: $isoPath"
        $image = Mount-DiskImage -ImagePath $isoPath -PassThru -StorageType ISO
    }

    $letter = $null
    foreach ($attempt in 1..30) {
        $volume = $image | Get-Volume -ErrorAction SilentlyContinue
        if ($volume -and $volume.DriveLetter) { $letter = [string]$volume.DriveLetter; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $letter) { throw "Could not determine the drive letter of the mounted ISO: $isoPath" }

    $script:DriveLetter = "${letter}:"
    if (-not $alreadyAttached) { $script:MountedIsoPath = $isoPath }
    Write-Log "ISO mounted at $($script:DriveLetter)"
}

function Dismount-SourceIso {
    if (-not $script:MountedIsoPath) { return }
    try {
        $image = Get-DiskImage -ImagePath $script:MountedIsoPath -ErrorAction SilentlyContinue
        if ($image -and $image.Attached) {
            Write-Log "Dismounting source ISO: $($script:MountedIsoPath)"
            $image | Dismount-DiskImage -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Log "Could not dismount source ISO: $_" "WARN"
    } finally {
        $script:MountedIsoPath = $null
    }
}

function Export-BackupDrivers {
    if (-not $BackupDrivers) { return }

    try {
        $productName = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName).ProductName
        if ($productName -match 'Windows 11') { Write-Log "Host operating system: $productName" }
        else { Write-Log "Host operating system is '$productName' - exported drivers may not match Windows 11." "WARN" }
    } catch {
        Write-Log "Could not determine the host operating system version" "WARN"
    }

    $existing = @(Get-ChildItem -Path $driverBackupDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $script:DriverCount = $existing.Count
        Write-Log "Reusing existing driver backup: $driverBackupDir ($($existing.Count) driver packages)"
        return
    }

    New-Item -ItemType Directory -Force -Path $driverBackupDir | Out-Null
    Write-Log "Exporting third-party drivers from this PC to $driverBackupDir..."
    $output = & dism /English /online /export-driver "/destination:$driverBackupDir" 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        $output | ForEach-Object { Write-Log "$_" "ERROR" }
        throw "Driver export failed (DISM exit code $LASTEXITCODE)"
    }

    $count = @(Get-ChildItem -Path $driverBackupDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
    $script:DriverCount = $count
    if ($count -eq 0) {
        Write-Log "No third-party drivers found on this PC - nothing to back up." "WARN"
    } else {
        Write-Log "Backed up $count driver packages to $driverBackupDir"
    }
}

function Add-BackupDrivers {
    param(
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [Parameter(Mandatory=$false)][string]$TargetName = 'image'
    )
    if (-not $BackupDrivers) { return }
    if ($script:DriverCount -le 0) {
        Write-Log "No exported drivers available - skipping driver injection into $TargetName." "WARN"
        return
    }

    Write-Log "Injecting $script:DriverCount driver packages into $TargetName..."
    $output = & dism /English /image:"$TargetPath" /add-driver "/driver:$driverBackupDir" /recurse 2>&1
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        $output | ForEach-Object { Write-Log "$_" "WARN" }
        Write-Log "Driver injection into $TargetName reported errors (exit code $LASTEXITCODE) - continuing." "WARN"
        return
    }
    $added = @($output | Where-Object { "$_" -match 'Installing driver package' }).Count
    if ($added -gt 0) { Write-Log "Staged $added driver package(s) into $TargetName" }
    else { Write-Log "No matching driver packages staged into $TargetName (all were skipped)." "WARN" }
}

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    try {
        if ($name) {
            & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
        } else {
            & 'reg' 'add' $path '/ve' '/t' $type '/d' $value '/f' | Out-Null
        }
        Write-Log "Set registry: $path\$name = $value"
    } catch {
        Write-Log "Error setting registry $path\$name : $_" "ERROR"
        throw
    }
}

function Remove-RegistryKey {
    param([string]$path)
    try {
        & 'reg' 'delete' $path '/f' 2>&1 | Out-Null
        Write-Log "Removed registry key: $path"
    } catch {
        Write-Log "Registry key not found or error: $path" "WARN"
    }
}

function Remove-RegistryValue {
    # Removes a single value from a registry key. $path is the full
    # "key\valueName" form (e.g. '...\Run\OneDriveSetup'), where everything
    # after the last backslash is the value name and the rest is the key.
    param([string]$path)
    $lastSlash = $path.LastIndexOf('\')
    if ($lastSlash -lt 0) {
        Write-Log "Invalid registry value path (missing key\value separator): $path" "WARN"
        return
    }
    $keyPath = $path.Substring(0, $lastSlash)
    $valueName = $path.Substring($lastSlash + 1)
    try {
        & 'reg' 'delete' $keyPath '/v' $valueName '/f' 2>&1 | Out-Null
        Write-Log "Removed registry value: $path"
    } catch {
        Write-Log "Registry value not found or error: $path" "WARN"
    }
}

#---------[ Core Functions ]---------#
function Test-Prerequisites {
    Write-Log "Checking prerequisites..."

    # Check admin rights
    $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

    if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
        Write-Log "Script must run as Administrator!" "ERROR"
        throw "Administrative privileges required"
    }

    # Check ISO mount
    if (-not (Test-Path "$DriveLetter\sources\boot.wim")) {
        Write-Log "boot.wim not found at $DriveLetter\sources\" "ERROR"
        throw "Invalid Windows 11 ISO mount point"
    }

    # Check for install.wim or install.esd
    if (-not (Test-Path "$DriveLetter\sources\install.wim") -and -not (Test-Path "$DriveLetter\sources\install.esd")) {
        Write-Log "No install.wim or install.esd found" "ERROR"
        throw "Windows installation files not found"
    }

    # Check disk space (minimum 30GB recommended for ultra build)
    $disk = Get-PSDrive -Name $ScratchDisk[0] -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [math]::Round($disk.Free / 1GB, 2)
        Write-Log "Available space on ${ScratchDisk}: ${freeGB}GB"
        if ($freeGB -lt 30) {
            Write-Log "Low disk space warning: ${freeGB}GB (30GB+ recommended for ultra build)" "WARN"
        }
    }

    Write-Log "Prerequisites check passed"
}

function Initialize-Directories {
    Write-Log "Initializing directories..."
    New-Item -ItemType Directory -Force -Path "$ultra11Dir\sources" | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    Write-Log "Directories created"
}

function Convert-ESDToWIM {
    Write-Log "Converting install.esd to install.wim..."

    $esdPath = "$DriveLetter\sources\install.esd"
    $tempWimPath = "$ultra11Dir\sources\install.wim"

    # Validate index exists in ESD
    $images = Get-WindowsImage -ImagePath $esdPath
    $validIndices = $images.ImageIndex

    if ($INDEX -notin $validIndices) {
        Write-Log "Invalid index $INDEX. Available: $($validIndices -join ', ')" "ERROR"
        throw "Image index $INDEX not found in install.esd"
    }

    $esdComp = if ($Compress -eq 'fast') { 'Fast' } else { 'Maximum' }
    Write-Log "Exporting image index $INDEX from ESD ($Compress compression)..."
    Export-WindowsImage -SourceImagePath $esdPath -SourceIndex $INDEX `
        -DestinationImagePath $tempWimPath -CompressionType $esdComp -CheckIntegrity

    Write-Log "ESD conversion complete"
}

function Copy-WindowsFiles {
    Write-Log "Copying Windows installation files from $DriveLetter..."
    Copy-Item -Path "$DriveLetter\*" -Destination $ultra11Dir -Recurse -Force -ErrorAction SilentlyContinue

    # Remove install.esd if present
    if (Test-Path "$ultra11Dir\sources\install.esd") {
        Remove-Item "$ultra11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
    }

    Write-Log "File copy complete"
}

function Resolve-ImageIndex {
    Write-Log "Resolving and validating image index $INDEX..."
    
    $sourceImagePath = ""
    if (Test-Path "$DriveLetter\sources\install.wim") {
        $sourceImagePath = "$DriveLetter\sources\install.wim"
    } elseif (Test-Path "$DriveLetter\sources\install.esd") {
        $sourceImagePath = "$DriveLetter\sources\install.esd"
    } else {
        throw "Windows installation files not found on ISO"
    }
    
    $images = Get-WindowsImage -ImagePath $sourceImagePath
    
    # Standard Microsoft index mapping for Consumer ISOs
    $expectedNames = @{
        1 = "Windows 11 Home"
        4 = "Windows 11 Education"
        6 = "Windows 11 Pro"
        7 = "Windows 11 Pro N"
    }
    
    $targetName = $expectedNames[$INDEX]
    
    if ($targetName) {
        $foundImage = $images | Where-Object { $_.ImageName -eq $targetName }
        if ($foundImage) {
            $actualIndex = $foundImage.ImageIndex
            if ($actualIndex -ne $INDEX) {
                Write-Log "Index shifted! Expected '$targetName' at $INDEX, but found at $actualIndex." "WARN"
                Write-Log "Automatically adjusting INDEX to $actualIndex."
                $script:INDEX = $actualIndex
            } else {
                Write-Log "Edition '$targetName' matched expected index $INDEX."
            }
        } else {
            Write-Log "Expected edition '$targetName' not found in ISO. Proceeding with literal index $INDEX." "WARN"
        }
    } else {
        Write-Log "No standard mapping for index $INDEX. Proceeding with literal index."
    }
    
    $validIndices = $images.ImageIndex
    
    if ($script:INDEX -notin $validIndices) {
        Write-Log "Invalid index $script:INDEX. Available indices:" "ERROR"
        $images | ForEach-Object { Write-Log "  Index $($_.ImageIndex): $($_.ImageName)" }
        throw "Image index $script:INDEX not found"
    }
    
    $selectedImage = $images | Where-Object { $_.ImageIndex -eq $script:INDEX }
    Write-Log "Selected: Index $script:INDEX - $($selectedImage.ImageName)"

    # kelexine: the list object from 'Get-WindowsImage -ImagePath' has no 'Version'
    # property - DISM only populates Version/SPBuild/Architecture on the detailed
    # per-index object returned by 'Get-WindowsImage -ImagePath ... -Index N'.
    # Re-query with -Index for build-number extraction. Wrapped in try/catch since
    # this must never hard-fail the build - CI has its own windows_build fallback.
    $script:DetectedImageName = $selectedImage.ImageName
    $script:DetectedFullVersion = ""
    try {
        $detailedImage = Get-WindowsImage -ImagePath $sourceImagePath -Index $script:INDEX
        if ($detailedImage -and ($detailedImage.PSObject.Properties.Match('Version').Count -gt 0)) {
            $script:DetectedFullVersion = $detailedImage.Version
        } else {
            Write-Log "Detailed image query for index $script:INDEX returned no 'Version' property." "WARN"
        }
    } catch {
        Write-Log "Failed to query detailed image info for build number detection: $_" "WARN"
    }

    if ($script:DetectedFullVersion -match '(\d+\.\d+)$') {
        $script:DetectedBuildNumber = $Matches[1]
        Write-Log "Detected Windows build number: $script:DetectedBuildNumber (full version: $script:DetectedFullVersion)"
    } else {
        $script:DetectedBuildNumber = ""
        Write-Log "Could not parse a build number from image version '$script:DetectedFullVersion'" "WARN"
    }
}

function Mount-WindowsImageFile {
    Write-Log "Mounting Windows image (Index: $INDEX)..."

    # Take ownership and set permissions
    & takeown /F $wimFilePath /A | Out-Null
    & icacls $wimFilePath /grant "$($adminGroup.Value):(F)" | Out-Null

    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    & dism /English "/mount-image" "/imagefile:$wimFilePath" "/index:$INDEX" "/mountdir:$scratchDir"
    Write-Log "Image mounted at $scratchDir"
}

function Take-OwnershipOfFolders {
    Write-Log "Taking ownership of critical folders..."
    
    $foldersToOwn = @(
        "$scratchDir\Windows\System32\DriverStore\FileRepository",
        "$scratchDir\Windows\Fonts",
        "$scratchDir\Windows\Web",
        "$scratchDir\Windows\Help",
        "$scratchDir\Windows\Cursors",
        "$scratchDir\Program Files (x86)\Microsoft",
        "$scratchDir\Program Files\WindowsApps",
        "$scratchDir\Windows\System32\Microsoft-Edge-Webview",
        "$scratchDir\Windows\System32\Recovery",
        "$scratchDir\Windows\WinSxS",
        "$scratchDir\Windows\assembly",
        "$scratchDir\ProgramData\Microsoft\Windows Defender",
        "$scratchDir\Windows\System32\InputMethod",
        "$scratchDir\Windows\Speech",
        "$scratchDir\Windows\Temp"
    )
    
    $filesToOwn = @(
        "$scratchDir\Windows\System32\OneDriveSetup.exe"
    )
    
    foreach ($folder in $foldersToOwn) {
        if (Test-Path $folder) {
            Write-Log "Taking ownership: $folder"
            & takeown.exe /F $folder /R /D Y 2>&1 | Out-Null
            & icacls.exe $folder /grant "$($adminGroup.Value):(F)" /T /C 2>&1 | Out-Null
        }
    }
    
    foreach ($file in $filesToOwn) {
        if (Test-Path $file) {
            Write-Log "Taking ownership: $file"
            # Remove /D Y as it requires /R and is not needed for single files
            & takeown.exe /F $file 2>&1 | Out-Null
            & icacls.exe $file /grant "$($adminGroup.Value):(F)" /C 2>&1 | Out-Null
        }
    }
    
    Write-Log "Ownership taken"
}

function Get-ImageMetadata {
    Write-Log "Extracting image metadata..."

    # Get language
    $imageIntl = & dism /English /Get-Intl "/Image:$scratchDir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

    if ($languageLine) {
        $script:languageCode = $Matches[1]
        Write-Log "Language: $script:languageCode"
    } else {
        Write-Log "Language code not found, using default" "WARN"
        $script:languageCode = "en-US"
    }

    # Get architecture
    $imageInfo = & dism /English /Get-WimInfo "/wimFile:$wimFilePath" "/index:$INDEX"
    $lines = $imageInfo -split '\r?\n'

    foreach ($line in $lines) {
        if ($line -like '*Architecture : *') {
            $script:architecture = $line -replace 'Architecture : ', ''
            if ($script:architecture -eq 'x64') {
                $script:architecture = 'amd64'
            }
            Write-Log "Architecture: $script:architecture"
            break
        }
    }

    if (-not $script:architecture) {
        Write-Log "Architecture not found, defaulting to amd64" "WARN"
        $script:architecture = 'amd64'
    }
}

#---------[ ultra11-Specific Removal Functions ]---------#
function Remove-BloatwareApps {
    Write-Log "Removing provisioned appx packages (extended ultra11 list)..."

    $packagesToRemove = Get-AppxProvisionedPackage -Path $scratchDir | Where-Object {
        $_.PackageName -like '*Zune*' -or
        $_.PackageName -like '*Bing*' -or
        $_.PackageName -like '*Clipchamp*' -or
        $_.PackageName -like '*Gaming*' -or
        $_.PackageName -like '*People*' -or
        $_.PackageName -like '*PowerAutomate*' -or
        $_.PackageName -like '*Teams*' -or
        $_.PackageName -like '*Todos*' -or
        $_.PackageName -like '*YourPhone*' -or
        $_.PackageName -like '*SoundRecorder*' -or
        $_.PackageName -like '*Solitaire*' -or
        $_.PackageName -like '*FeedbackHub*' -or
        $_.PackageName -like '*Maps*' -or
        $_.PackageName -like '*OfficeHub*' -or
        $_.PackageName -like '*Help*' -or
        $_.PackageName -like '*Family*' -or
        $_.PackageName -like '*Alarms*' -or
        $_.PackageName -like '*CommunicationsApps*' -or
        $_.PackageName -like '*Copilot*' -or
        $_.PackageName -like '*CompatibilityEnhancements*' -or
        $_.PackageName -like '*AV1VideoExtension*' -or
        $_.PackageName -like '*AVCEncoderVideoExtension*' -or
        $_.PackageName -like '*HEIFImageExtension*' -or
        $_.PackageName -like '*HEVCVideoExtension*' -or
        $_.PackageName -like '*MicrosoftStickyNotes*' -or
        $_.PackageName -like '*OutlookForWindows*' -or
        $_.PackageName -like '*RawImageExtension*' -or
        $_.PackageName -like '*VP9VideoExtensions*' -or
        $_.PackageName -like '*WebpImageExtension*' -or
        $_.PackageName -like '*DevHome*' -or
        $_.PackageName -like '*Photos*' -or
        $_.PackageName -like '*ScreenSketch*' -or
        $_.PackageName -like '*Camera*' -or
        $_.PackageName -like '*QuickAssist*' -or
        $_.PackageName -like '*CoreAI*' -or
        $_.PackageName -like '*PeopleExperienceHost*' -or
        $_.PackageName -like '*PinningConfirmationDialog*' -or
        $_.PackageName -like '*SecureAssessmentBrowser*' -or
        $_.PackageName -like '*Paint*' -or
        $_.PackageName -like '*Notepad*' -or
        $_.PackageName -like '*Recall*' -or
        $_.PackageName -like '*WebExperience*' -or
        $_.PackageName -like '*StorePurchaseApp*' -or
        $_.PackageName -like '*MPEG2VideoExtension*' -or
        $_.PackageName -like '*WebMediaExtensions*' -or
        $_.PackageName -like '*WindowsAI*' -or
        $_.PackageName -like '*AIFabric*' -or

        # --- ultra additions -------------------------------------------------
        # *Gaming* only catches XboxGamingOverlay; the rest of the Xbox AppX
        # family (identity provider, game callable UI, speech-to-text, GIP) is
        # matched separately.
        $_.PackageName -like '*Xbox*' -or
        $_.PackageName -like '*WindowsTerminal*' -or
        $_.PackageName -like '*Getstarted*' -or        # Tips
        $_.PackageName -like '*Cortana*' -or
        $_.PackageName -like '*549981C3F5F10*' -or      # Cortana's actual package id
        $_.PackageName -like '*WindowsReadingList*' -or
        # StorePurchaseApp was already in the list above, which leaves the Store
        # itself a half-state; remove the rest so there is no broken Store icon.
        # NOTE: *AppInstaller* is deliberately NOT added - that is
        # Microsoft.DesktopAppInstaller, i.e. winget, which must survive.
        $_.PackageName -like '*WindowsStore*' -or
        # Windows Security UI only makes sense alongside Defender
        (($_.PackageName -like '*SecHealthUI*') -and ($Defender -ne 'Keep'))
    }

    $removeCount = 0
    foreach ($package in $packagesToRemove) {
        Write-Log "Removing: $($package.DisplayName)"
        try {
            Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            $removeCount++
        } catch {
            Write-Log "Could not remove $($package.DisplayName): $($_.Exception.Message)" "WARN"
        }
    }

    # Clean up leftover WindowsApps folders
    Write-Log "Cleaning leftover WindowsApps folders..."
    foreach ($package in $packagesToRemove) {
        $folderPath = Join-Path "$scratchDir\Program Files\WindowsApps" $package.PackageName
        if (Test-Path $folderPath) {
            Remove-Item $folderPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Removed $removeCount appx packages"
}

function Remove-SystemPackages {
    Write-Log "Removing system packages (extended ultra11 list)..."

    $packagePatterns = @(
        # Legacy Components & Optional Apps
        "Microsoft-Windows-InternetExplorer-Optional-Package~",
        "Microsoft-Windows-MediaPlayer-Package~",
        "Microsoft-Windows-WordPad-FoD-Package~",
        "Microsoft-Windows-StepsRecorder-Package~",
        "Microsoft-Windows-MSPaint-FoD-Package~",
        "Microsoft-Windows-SnippingTool-FoD-Package~",
        "Microsoft-Windows-TabletPCMath-Package~",
        "Microsoft-Windows-Xps-Xps-Viewer-Opt-Package~",
        "Microsoft-Windows-PowerShell-ISE-FOD-Package~",
        "OpenSSH-Client-Package~",
        
        # Language & Input Features
        "Microsoft-Windows-LanguageFeatures-Handwriting-$($script:languageCode)-Package~",
        "Microsoft-Windows-LanguageFeatures-OCR-$($script:languageCode)-Package~",
        "Microsoft-Windows-LanguageFeatures-Speech-$($script:languageCode)-Package~",
        "Microsoft-Windows-LanguageFeatures-TextToSpeech-$($script:languageCode)-Package~",
        "*IME-ja-jp*",
        "*IME-ko-kr*",
        "*IME-zh-cn*",
        "*IME-zh-tw*",
        
        # Core OS Features
        "Microsoft-Windows-Search-Engine-Client-Package~",
        "Microsoft-Windows-Kernel-LA57-FoD-Package~",
        
        # Security & Identity
        "Microsoft-Windows-Hello-Face-Package~",
        "Microsoft-Windows-Hello-BioEnrollment-Package~",
        "Microsoft-Windows-BitLocker-DriveEncryption-FVE-Package~",
        "Microsoft-Windows-TPM-WMI-Provider-Package~",
        
        # Accessibility Tools
        "Microsoft-Windows-Narrator-App-Package~",
        "Microsoft-Windows-Magnifier-App-Package~",
        
        # Miscellaneous Features
        "Microsoft-Windows-Printing-PMCPPC-FoD-Package~",
        "Microsoft-Windows-WebcamExperience-Package~",
        "Microsoft-Media-MPEG2-Decoder-Package~",
        "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~",
        "UserExperience-Recall-Package~",
        "Microsoft-Windows-AppManagement-AppV-Package~",
        "Microsoft-Edge-WebView-FOD-Package~"
    )

    $allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
    $allPackages = $allPackages -split "`n" | Select-Object -Skip 1

    $removeCount = 0
    foreach ($packagePattern in $packagePatterns) {
        $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }
        foreach ($package in $packagesToRemove) {
            $packageIdentity = ($package -split "\s+")[0]
            if ($packageIdentity) {
                Write-Log "Removing package: $packageIdentity"
                & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity /Quiet /NoRestart 2>&1 | Out-Null
                $removeCount++
            }
        }
    }

    Write-Log "Removed $removeCount system packages"
}

function Remove-OptionalFeatures {
    # Optional features are a second axis from packages: `Remove-WindowsOptionalFeature
    # -Remove` also drops the payload from WinSxS, where Remove-SystemPackages
    # only strips the Features-on-Demand package itself. An allowlist (rather
    # than a denylist) is the safer shape here because Microsoft turns new
    # features on by default in every 25H2 servicing release and we would never
    # notice a denylist going stale.
    Write-Log "Removing optional features..."

    $keep = @(
        'NetFx4-AdvSrvs',              # .NET Framework 4.x - plenty of Win32 apps still need it
        'MediaPlayback',               # base media stack, i.e. video playback at all
        'WCF-Services45',              # default-on .NET WCF subset
        'WCF-TCP-PortSharing45',
        'VirtualMachinePlatform',      # nested virtualisation is a plausible use for a VM image
        'HypervisorPlatform',
        'Microsoft-Windows-Subsystem-Linux'
    )
    if ($Defender -eq 'Keep') { $keep += 'Windows-Defender-Default-Definitions' }

    $enabled = @()
    try {
        $enabled = @(Get-WindowsOptionalFeature -Path $scratchDir -ErrorAction Stop |
            Where-Object { ([string]$_.State) -eq 'Enabled' -and $_.FeatureName -notin $keep })
    } catch {
        Write-Log "Could not enumerate optional features: $($_.Exception.Message)" "WARN"
        return
    }

    Write-Log "Removing $($enabled.Count) enabled optional features (keeping $($keep.Count))..."
    $removed = 0
    foreach ($feature in $enabled) {
        Write-Log "Removing optional feature: $($feature.FeatureName)"
        try {
            Remove-WindowsOptionalFeature -Path $scratchDir -FeatureName $feature.FeatureName -Remove -NoRestart -ErrorAction Stop | Out-Null
            $removed++
        } catch {
            Write-Log "Could not remove feature $($feature.FeatureName): $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "Removed $removed optional features"
}

function Remove-NativeImages {
    Write-Log "Removing pre-compiled .NET assemblies (Native Images)..."
    $nativeImagesPath = "$scratchDir\Windows\assembly\NativeImages_*"
    Remove-Item -Path $nativeImagesPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log ".NET Native Images removed"
}

function Slim-DriverStore {
    Write-Log "Slimming the DriverStore (removing non-essential driver classes)..."
    
    $driverRepo = "$scratchDir\Windows\System32\DriverStore\FileRepository"
    $patternsToRemove = @(
        'prn*',      # Printer drivers
        'ntprint*',  # Print support driver repository (Nano's prn* glob misses this prefix)
        'scan*',     # Scanner drivers
        'mfd*',      # Multi-function device drivers
        'wscsmd.inf*', # Smartcard readers
        'tapdrv*',   # Tape drives
        # rdpbus.inf intentionally kept: virtual bus enumeration path used by VMware/Hyper-V during setup
        'tdibth.inf*', # Bluetooth Personal Area Network
        'helloface*',  # Windows Hello Face - ~96MB, and the Hello Face FoD package
                       # is already removed by Remove-SystemPackages so this driver
                       # would be an orphan anyway
        'bth*',        # Bluetooth stack - no radio in a VM, and the Bluetooth
                       # services are disabled by Tune-Services

        # Physical 802.11 drivers. A VM presents an emulated Ethernet adapter and
        # can never see an 802.11 radio (short of USB passthrough), and these are
        # ~200MB of Intel/Realtek/Atheros/Qualcomm Wi-Fi images. Wired ethernet,
        # virtio, VMXNET and the Hyper-V/VMware network adapters are matched by
        # completely different INF prefixes and are not touched here.
        'netwtw*',   # Intel Wi-Fi 6/6E/7
        'netwns*',   # Intel Wi-Fi 6
        'netwew*',   # Intel Wi-Fi 5
        'netwsw*',   # Intel Wi-Fi 6E
        'netwbw*',   # Intel Wi-Fi
        'netwbz*',
        'netwlv*',   # Intel Centrino (legacy)
        'netrtw*',   # Realtek RTL8xxx
        'rtwlan*',   # Realtek RTL8xxx
        'netath*',   # Atheros / Qualcomm
        'athw*',
        'athr*',
        'qcwlan*'    # Qualcomm
    )

    $removeCount = 0
    $freedMB = 0
    Get-ChildItem -Path $driverRepo -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $driverFolder = $_.Name
        foreach ($pattern in $patternsToRemove) {
            if ($driverFolder -like $pattern) {
                $size = (Get-ChildItem -Path $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                Write-Log "Removing driver: $driverFolder ($([math]::Round($size/1MB,1)) MB)"
                Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $removeCount++
                $freedMB += [math]::Round($size/1MB, 1)
                break
            }
        }
    }

    Write-Log "Removed $removeCount driver packages (~$freedMB MB)"
}

function Reduce-Fonts {
    Write-Log "Reducing fonts (keeping only essentials)..."
    
    $fontsPath = "$scratchDir\Windows\Fonts"
    if (Test-Path $fontsPath) {
        # Keep essential fonts, remove the rest
        Get-ChildItem -Path $fontsPath -Exclude "segoe*.*", "tahoma*.*", "marlett.ttf", "8541oem.fon", "segui*.*", "consol*.*", "lucon*.*", "calibri*.*", "arial*.*", "times*.*", "cou*.*", "8*.*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        
        # Remove CJK fonts explicitly
        Get-ChildItem -Path $fontsPath -Include "mingli*", "msjh*", "msyh*", "malgun*", "meiryo*", "yugoth*", "segoeuihistoric.ttf" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Fonts reduced"
}

function Clean-InputMethods {
    Write-Log "Cleaning input methods (removing CJK)..."
    
    $inputMethodPaths = @(
        "$scratchDir\Windows\System32\InputMethod\CHS",
        "$scratchDir\Windows\System32\InputMethod\CHT",
        "$scratchDir\Windows\System32\InputMethod\JPN",
        "$scratchDir\Windows\System32\InputMethod\KOR"
    )

    foreach ($path in $inputMethodPaths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Input methods cleaned"
}

function Remove-MiscellaneousFiles {
    Write-Log "Performing aggressive file deletions..."
    
    # Speech (Full removal for ultra)
    Remove-Item -Path "$scratchDir\Windows\Speech" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Windows Error Reporting (WER)
    Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows\WER" -Recurse -Force -ErrorAction SilentlyContinue

    # Defender definitions (skipped when -Defender Keep; Remove deletes the whole folder earlier)
    if ($Defender -ne 'Keep') {
        Remove-Item -Path "$scratchDir\ProgramData\Microsoft\Windows Defender\Definition Updates" -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Temp files
    Remove-Item -Path "$scratchDir\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Web, Help, Cursors
    Remove-Item -Path "$scratchDir\Windows\Web" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\Help" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\Cursors" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Windows Update binaries (NON-SERVICEABLE BUILD)
    Write-Log "Removing Windows Update binaries (this is a non-serviceable build)..."
    Remove-Item -Path "$scratchDir\Windows\System32\usoclient.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UsoApiAll.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UsoApi.dll" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$scratchDir\Windows\System32\UpdatePolicy.dll" -Force -ErrorAction SilentlyContinue
    # NOTE: umbus.sys (User-mode Bus Enumerator) is intentionally kept.
    # Removing it causes Windows Setup to fail at ~77% on VMware and other hypervisors
    # during the PnP device initialization phase. Users may remove it post-install
    # on bare-metal systems if desired.
    Remove-Item -Path "$scratchDir\Windows\SoftwareDistribution" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Miscellaneous files removed"
}

function Remove-UltraExtras {
    # Directories a stock 25H2 image ships that Nano leaves untouched. Each one
    # was measured off the source image and checked against what the rest of
    # this script has already removed, so nothing here is orphaned for a reason
    # we did not already account for. Paths that are absent are skipped.
    Write-Log "Removing ultra-specific leftovers (measured against a stock 25H2 image)..."

    $targets = [ordered]@{
        # --- Windows\SystemApps: Nano only removes SecHealthUI ---------------
        "$scratchDir\Windows\SystemApps\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe" = 'Edge DevTools - Edge itself is removed (10.6 MB)'
        "$scratchDir\Windows\SystemApps\MicrosoftWindows.Client.CoreAI_cw5n1h2txyewy"        = 'Recall/Copilot UI host - Recall and WindowsAI packages already removed (28.9 MB)'
        "$scratchDir\Windows\SystemApps\Microsoft.AIFabric.CBS.1.6_8wekyb3d8bbwe"           = 'Windows AI fabric - AIFabric/WindowsAI AppX already removed (8.2 MB)'

        # --- Windows\System32 + SysWOW64 leftovers ---------------------------
        "$scratchDir\Windows\System32\migwiz"         = 'Windows Easy Transfer (43.1 MB)'
        "$scratchDir\Windows\SysWOW64\migwiz"         = 'Windows Easy Transfer, 32-bit'
        "$scratchDir\Windows\System32\F12"            = 'Internet Explorer F12 developer tools - IE package already removed (17.4 MB)'
        "$scratchDir\Windows\SysWOW64\F12"            = 'Internet Explorer F12 developer tools, 32-bit'
        "$scratchDir\Windows\System32\braille-tables" = 'braille display tables (10.1 MB)'
        "$scratchDir\Windows\System32\Speech_OneCore" = 'OneCore speech runtime - Windows\Speech already removed (12.5 MB)'
    }

    $freedMB = 0
    foreach ($entry in $targets.GetEnumerator()) {
        $path = $entry.Key
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $size = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $mb = [math]::Round(($size / 1MB), 1)
        Write-Log "Removing $path ($mb MB) - $($entry.Value)"
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $freedMB += $mb
    }

    # Duplicate WindowsAppRuntime framework packages: the image carries 1.5, 1.6,
    # 1.7 and 1.8 (~268 MB). Deliberately NOT removed - they are framework
    # dependencies that other packages pin to a specific minor version, and
    # breaking them costs more than the ~168 MB would buy.
    if ($freedMB -gt 0) {
        Write-Log "Ultra leftovers removed (~$freedMB MB)"
    } else {
        Write-Log "No ultra leftovers found" "WARN"
    }
}

function Remove-EdgeAndOneDrive {
    Write-Log "Removing Microsoft Edge and OneDrive..."

    # Remove Edge paths
    Remove-Item -Path "$scratchDir\Program Files (x86)\Microsoft\Edge*" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Remove Edge WebView from WinSxS (covers amd64 and arm64)
    $winSxSPaths = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    foreach ($winSxSPath in $winSxSPaths) {
        if (Test-Path $winSxSPath) {
            Remove-Item -Path $winSxSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Remove-Item -Path "$scratchDir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue
    
    # Remove OneDrive
    Write-Log "Removing OneDrive..."
    $oneDrivePaths = @(
        "$scratchDir\Windows\System32\OneDriveSetup.exe",
        "$scratchDir\Windows\SysWOW64\OneDriveSetup.exe"
    )
    foreach ($path in $oneDrivePaths) {
        if (Test-Path $path) {
            Write-Log "Deleting OneDrive setup: $path"
            & takeown.exe /f $path /a | Out-Null
            & icacls.exe $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Edge and OneDrive removed"
    
    # Clean up other remnants
    Write-Log "Cleaning up other remnants (GameBar, Copilot)..."
    $otherRemnants = @(
        "$scratchDir\Windows\GameBarPresenceWriter",
        "$scratchDir\Windows\System32\SettingsHandlers_Copilot.dll"
    )
    foreach ($path in $otherRemnants) {
        if (Test-Path $path) {
            Write-Log "Deleting remnant: $path"
            & takeown.exe /f $path /a | Out-Null
            & icacls.exe $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-WinRE {
    # Author: kelexine (https://github.com/kelexine)
    #
    # WHY NO STUB: Replacing winre.wim with a 0-byte empty file causes Windows
    # Setup to hard-crash at ~75% with error 0x8007000B (ERROR_BAD_FORMAT) on
    # EFI-enabled systems (VirtualBox, VMware, Hyper-V, real hardware with EFI).
    #
    # At ~75% setup invokes reagentc/DISM to configure the recovery environment.
    # On EFI systems this step *actually parses the WIM header* — a 0-byte file
    # is not a valid WIM, so the parser throws and setup aborts.
    #
    # When the file is simply ABSENT, Windows Setup gracefully skips WinRE
    # configuration ("WinRE not found, skipping") and continues to 100%.
    # The offline registry key WinREEnabled=0 (applied in Apply-RegistryTweaks)
    # suppresses any post-boot attempt to re-configure or re-enable WinRE.
    Write-Log "Removing Windows Recovery Environment (winre.wim)..."

    $winRE = "$scratchDir\Windows\System32\Recovery\winre.wim"
    if (Test-Path $winRE) {
        Remove-Item -Path $winRE -Force -ErrorAction SilentlyContinue
        Write-Log "winre.wim deleted. Windows Setup will skip WinRE config gracefully."
    } else {
        Write-Log "winre.wim not found — already absent, nothing to do." "WARN"
    }

    Write-Log "WinRE removed"
}

function Patch-ReAgentXml {
    # Author: kelexine (https://github.com/kelexine)
    #
    # WHY THIS IS NEEDED
    # ------------------
    # ReAgent.xml (Windows\System32\Recovery\ReAgent.xml) is the offline config
    # file that reagentc and Windows Setup read to determine WinRE state.
    #
    # After Remove-WinRE deletes winre.wim the XML may still contain:
    #   <WinREStaged state="1"/>         -- tells Setup a staged WIM exists
    #   <ImageLocation path="..."/>      -- stale path pointing to deleted file
    #   <InstallState state="1"/>        -- marks WinRE as installed
    #
    # On EFI/UEFI systems Windows Setup reads this file during the Pre-Finalize
    # phase (~75%) via WinReInstallOnTargetOS. If it sees WinREStaged=1 but
    # can't find or mount the WIM it referenced, setup.exe aborts. If the file
    # is absent OR consistently says state=0 everywhere, Setup skips gracefully.
    #
    # STRATEGY: rewrite the file with all state attributes zeroed and paths
    # cleared. We preserve the XML schema/version so reagentc doesn't choke on
    # a malformed file on first boot.
    Write-Log "Patching ReAgent.xml to clear stale WinRE staging state..."

    $reagentXmlPath = "$scratchDir\Windows\System32\Recovery\ReAgent.xml"

    # Canonical zeroed-out ReAgent.xml — schema version matches Win11 23H2/24H2/25H2.
    # All state attributes are 0, all path/guid/id/offset attributes are empty/zero.
    # This is equivalent to what reagentc /disable writes on a live system.
    $cleanXml = @'
<?xml version='1.0' encoding='utf-8'?>
<WindowsRE version="2.0">
  <WinreBCD id="{00000000-0000-0000-0000-000000000000}"/>
  <WinreLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <ImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}"/>
  <PBRImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <PBRCustomImageLocation path="" id="0" offset="0" guid="{00000000-0000-0000-0000-000000000000}" index="0"/>
  <InstallState state="0"/>
  <OsInstallAvailable state="0"/>
  <CustomImageAvailable state="0"/>
  <IsAutoRepairOn state="0"/>
  <WinREStaged state="0"/>
  <OperationParam path=""/>
  <OemTool path=""/>
</WindowsRE>
'@

    try {
        # Ensure the Recovery directory exists (it should, but be defensive)
        $recoveryDir = "$scratchDir\Windows\System32\Recovery"
        if (-not (Test-Path $recoveryDir)) {
            New-Item -ItemType Directory -Force -Path $recoveryDir | Out-Null
            Write-Log "Created missing Recovery directory."
        }

        # Write as UTF-8 without BOM — reagentc expects plain UTF-8
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($reagentXmlPath, $cleanXml.TrimStart(), $utf8NoBom)

        Write-Log "ReAgent.xml patched: all WinRE state/staging fields zeroed."
    } catch {
        Write-Log "Failed to patch ReAgent.xml: $_" "WARN"
        Write-Log "Setup may still skip WinRE gracefully due to missing winre.wim, but patching is preferred." "WARN"
    }
}

function Optimize-WinSxS {
    Write-Log "Optimizing WinSxS folder..."

    $sourceDirectory = "$scratchDir\Windows\WinSxS"
    $destinationDirectory = "$scratchDir\Windows\WinSxS_edit"

    New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

    $dirsToCopy = @()

    if ($script:architecture -eq "amd64") {
        $dirsToCopy = @(
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
            "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "x86_microsoft-windows-servicingstack-inetsrv_*",
            "x86_microsoft-windows-servicingstack-onecore_*",
            "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
            "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
            "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
            "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
            "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs",
            "FileMaps",
            "Fusion",
            "InstallTemp",
            "Manifests",
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        )
    } elseif ($script:architecture -eq "arm64") {
        $dirsToCopy = @(
            "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
            "Catalogs",
            "FileMaps",
            "Fusion",
            "InstallTemp",
            "Manifests",
            "SettingsManifests",
            "Temp",
            "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
            "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
            "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
            "arm_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*",
            "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*"
        )
    }

    foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory -ErrorAction SilentlyContinue
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Log "Copying: $($sourceDir.Name)"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }

    # Safety Check: Ensure we actually copied something before wiping original WinSxS
    $matchedCount = (Get-ChildItem -Path $destinationDirectory).Count
    if ($matchedCount -lt 5) {
        Write-Log "WinSxS optimization failed: Whitelist matched too few items ($matchedCount)." "ERROR"
        throw "WinSxS optimization verification failed - Aborting to prevent broken image"
    }

    Write-Log "Replacing WinSxS with minimal version..."

    # Re-assert ownership to ensure deletion is possible
    Write-Log "Ensuring ownership of WinSxS before deletion..."
    & takeown.exe /F $sourceDirectory /R /D Y 2>&1 | Out-Null
    & icacls.exe $sourceDirectory /grant "$($adminGroup.Value):(F)" /T /C 2>&1 | Out-Null

    $emptyDir = "$ScratchDisk\empty_temp"
    New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
    & robocopy $emptyDir $sourceDirectory /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS | Out-Null
    Remove-Item -Path $emptyDir -Force
    Remove-Item -Path $sourceDirectory -Recurse -Force
    Rename-Item -Path $destinationDirectory -NewName "WinSxS"

    Write-Log "WinSxS optimization complete"
}

#---------[ Registry Functions ]---------#
function Load-RegistryHives {
    Write-Log "Loading registry hives..."

    reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" 2>&1 | Out-Null
    reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" 2>&1 | Out-Null
    reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" 2>&1 | Out-Null
    reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null

    Write-Log "Registry hives loaded"
}

function Unload-RegistryHives {
    Write-Log "Unloading registry hives..."

    # Force garbage collection to release PowerShell registry handles
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 3

    foreach ($hive in 'zCOMPONENTS','zDEFAULT','zNTUSER','zSOFTWARE','zSYSTEM') {
        if (-not (Test-Path "HKLM:\$hive")) { continue }
        $unloaded = $false
        foreach ($attempt in 1..3) {
            reg unload "HKLM\$hive" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $unloaded = $true; break }
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds 3
        }
        if (-not $unloaded) { throw "Failed to unload HKLM\$hive - registry handles still held by another process" }
    }

    Write-Log "Registry hives unloaded"
}

function Set-WindowsDefender {
    # Applies the -Defender mode to the offline image while registry hives are
    # loaded. Keep = no changes. Disable/Remove = policies, services and tasks
    # turned off (Remove also has packages/files handled by Remove-DefenderPackages).
    if ($Defender -eq 'Keep') {
        Write-Log "Windows Defender: Keep (no changes)"
        return
    }
    Write-Log "Windows Defender: $Defender"

    # Policy switches read by the Defender platform at boot
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender' 'DisableAntiVirus' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableRealtimeMonitoring' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableBehaviorMonitoring' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableOnAccessProtection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableScanOnRealtimeEnable' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' 'DisableIOAVProtection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'MAPSReporting' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'DisableBlockAtFirstSeen' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'REG_SZ' 'Off'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 'REG_DWORD' '0'

    # Services (Test-Path guard: never create keys for services that don't exist)
    Write-Log "Disabling Windows Defender services..."
    $servicePaths = @('WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'Sense', 'SecurityHealthService')
    foreach ($path in $servicePaths) {
        if (Test-Path "HKLM:\zSYSTEM\ControlSet001\Services\$path") {
            Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$path" 'Start' 'REG_DWORD' '4'
        }
    }

    # Defender scheduled tasks: offline task files + Task Scheduler cache
    $defenderTasks = "$scratchDir\Windows\System32\Tasks\Windows Defender"
    if (Test-Path $defenderTasks) {
        Remove-Item -Path $defenderTasks -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Removed Defender scheduled task files"
    }
    $taskCache = 'HKLM:\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks'
    if (Test-Path $taskCache) {
        Get-ChildItem $taskCache | ForEach-Object {
            $taskPath = (Get-ItemProperty -Path $_.PSPath -Name 'Path' -ErrorAction SilentlyContinue).Path
            if ($taskPath -and $taskPath.StartsWith('\Windows Defender')) {
                Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-RegistryKey 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Windows Defender'
    }

    # Hide the virus & protection Settings page (WU page stays hidden too)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:virus;windowsupdate'

    Write-Log "Windows Defender disabled in image"
}

function Remove-DefenderPackages {
    # -Defender Remove only: uninstall the Defender platform and the Windows
    # Security app from the offline image, then delete leftover files.
    # Runs while registry hives are NOT loaded so DISM can rewrite hive files.
    if ($Defender -ne 'Remove') { return }
    Write-Log "Removing Windows Defender packages and files..."

    # Defender platform FoD (contains MsMpEng, WdFilter, WdNisSvc)
    try {
        $allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
        $allPackages = $allPackages -split "`n" | Select-Object -Skip 1
        foreach ($package in $allPackages) {
            if (-not $package) { continue }
            $packageIdentity = ("$package" -split '\s+')[0]
            if ($packageIdentity -like 'Windows-Defender-Client-Package~*') {
                Write-Log "Removing package: $packageIdentity"
                & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity /Quiet /NoRestart 2>&1 | Out-Null
            }
        }
    } catch {
        Write-Log "Defender package removal issue: $_" "WARN"
    }

    # Windows Security app (SecHealthUI)
    try {
        $secHealth = @(Get-AppxProvisionedPackage -Path $scratchDir -ErrorAction SilentlyContinue |
            Where-Object { $_.PackageName -like '*SecHealthUI*' })
        foreach ($pkg in $secHealth) {
            Write-Log "Removing provisioned package: $($pkg.PackageName)"
            Remove-AppxProvisionedPackage -Path $scratchDir -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-Log "SecHealthUI provisioned removal blocked (expected on Win11 - folder deletion follows): $_" "WARN"
    }

    # Leftover files/folders - take ownership first, then delete
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    $targets = @(
        "$scratchDir\Program Files\Windows Defender",
        "$scratchDir\Program Files (x86)\Windows Defender",
        "$scratchDir\ProgramData\Microsoft\Windows Defender",
        "$scratchDir\Windows\System32\Tasks\Windows Defender",
        "$scratchDir\Windows\System32\MsMpEng.exe",
        "$scratchDir\Windows\System32\WdFilter.sys",
        "$scratchDir\Windows\System32\WdNisDrv.sys",
        "$scratchDir\Windows\System32\WdNisSvc.exe"
    )

    # Win11 22563+: SecHealthUI lives under WindowsApps and provisioned removal is
    # policy-blocked (0x80073CFA "Removal failed") - force-delete its package folder.
    foreach ($secDir in @(Get-ChildItem "$scratchDir\Program Files\WindowsApps\Microsoft.SecHealthUI*" -Directory -Force -ErrorAction SilentlyContinue)) {
        $targets += $secDir.FullName
    }
    $targets += "$scratchDir\Windows\SystemApps\Microsoft.Windows.SecHealthUI_cw5n1h2txyewy"
    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        Write-Log "Deleting: $target"
        & takeown.exe /F $target /R /D Y 2>&1 | Out-Null
        & icacls.exe $target /grant "$($adminGroup.Value):(F)" /T /C /Q 2>&1 | Out-Null
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Windows Defender removed from image"
}

function Apply-RegistryTweaks {
    Write-Log "Applying registry tweaks..."

    # Disable UAC permanently - image policy, read at every boot/logon.
    # Nothing on this image (no domain GPO/MDM) re-enables it; Windows Update
    # preserves HKLM policy keys. Revert = set EnableLUA back to 1.
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptOnSecureDesktop' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 'REG_DWORD' '0'
    Write-Log "UAC disabled (EnableLUA=0)"

    # Bypass system requirements
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

    # Disable sponsored apps
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'

    Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-RegistryKey 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'

    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

    # Enable local accounts on OOBE
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'

    # Copy autounattend-ultra.xml as autounattend.xml
    $ultraAutoUnattend = Join-Path (Split-Path $PSScriptRoot -Parent) "autounattend-ultra.xml"
    if (Test-Path $ultraAutoUnattend) {
        Copy-Item -Path $ultraAutoUnattend -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -Force
        Write-Log "Copied autounattend-ultra.xml to Sysprep"
    }

    # Disable reserved storage
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

    # Disable BitLocker
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    # Remove Edge registries
    Remove-RegistryKey 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge'
    Remove-RegistryKey 'HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'

    # Disable OneDrive folder backup
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'

    # Remove OneDrive from Run keys (prevent auto-install on first login)
    Remove-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"
    Remove-RegistryValue "HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup"

    # Disable telemetry
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

    # Prevent DevHome and Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryKey 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-RegistryKey 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

    # Disable Copilot
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

    # Disable AI features (Recall, AI Fabric, Windows AI)
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffWindowsAI' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'REG_DWORD' '1'
    
    # Enhanced telemetry removal
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' 'ShowedToastAtLevel' 'REG_DWORD' '1'
    
    # Gaming optimization: Increase VRAM allocation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\DirectDraw' 'EmulationOnly' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Direct3D' 'DisableVidMemVBs' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'DpiMapIommuContiguous' 'REG_DWORD' '1'

    # Prevent Teams installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

    # Prevent new Outlook installation
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

    # Disable Windows Update
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE1' 'REG_SZ' 'net stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE2' 'REG_SZ' 'sc stop wuauserv'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'StopWUPostOOBE3' 'REG_SZ' 'sc config wuauserv start= disabled'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisbaleWUPostOOBE1' 'REG_SZ' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'DisbaleWUPostOOBE2' 'REG_SZ' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'UpdateServiceUrlAlternate' 'REG_SZ' 'localhost'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' 'Start' 'REG_DWORD' '4'

    # Delete WaaS services
    Remove-RegistryKey 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC'
    Remove-RegistryKey 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc'

    # Disable WinRE — prevents reagentc from trying to reconfigure the recovery
    # environment on first boot after winre.wim has been removed. Without this,
    # Windows may attempt to recreate a WinRE partition and fail silently (or
    # trigger error dialogs). WinREEnabled=0 tells reagentc the feature is
    # intentionally absent. (Companion to the Remove-WinRE build-time deletion.)
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\WinRE' 'WinREEnabled' 'REG_DWORD' '0'

    # Hide settings pages (the virus page is added by Set-WindowsDefender when -Defender != Keep)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:windowsupdate'

    # Easter Egg / Branding
    Write-Log "Adding Easter Egg branding..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticecaption' 'REG_SZ' 'Tiny11 Automated'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'legalnoticetext' 'REG_SZ' 'This image was built using Tiny11 Automated by kelexine. Enjoy your lightweight Windows experience!'
    
    # Desktop Context Menu Link
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'MUIVerb' 'REG_SZ' 'Tiny11 Automated Info'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Icon' 'REG_SZ' 'shell32.dll,22'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info' 'Position' 'REG_SZ' 'Bottom'
    Set-RegistryValue 'HKLM\zSOFTWARE\Classes\DesktopBackground\Shell\Tiny11Info\command' '' 'REG_SZ' 'explorer.exe "https://github.com/kelexine/tiny11-automated"'

    Write-Log "Registry tweaks applied"
}

function Enable-UltimatePerformance {
    # Always-on: expose Microsoft's hidden Ultimate Performance power scheme and
    # activate it at first logon. Schemes can't be added to an offline image, so
    # this runs once via RunOnce (UAC is disabled in this image => full token).
    $powerScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$out = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-String
if ($out -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
    powercfg /setactive $Matches[1]
}
'@
    $stageDir = "$scratchDir\Windows\Tiny11"
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    Set-Content -LiteralPath "$stageDir\ultimate-power.ps1" -Value $powerScript -Encoding UTF8
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'Tiny11UltimatePerf' 'REG_SZ' 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Tiny11\ultimate-power.ps1'
    Write-Log "Ultimate Performance power plan will be activated at first logon"
}

function Apply-PerformanceTweaks {
    # Author: kelexine (https://github.com/kelexine)
    # Bakes performance optimizations into the offline image via registry.
    # Covers: Memory, CPU/Scheduler, Storage (NTFS), Network (TCP), Gaming, Boot time.
    # Profile: Aggressive — gaming and VM workloads; requires ≥4 GB RAM.
    Write-Log "Applying performance optimizations (gaming/VM profile)..."

    # ── Memory Management ──────────────────────────────────────────────────
    # Keep kernel-mode drivers in physical RAM — eliminates paging latency spikes during gaming
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'DisablePagingExecutive'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'LargeSystemCache'        'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 'REG_DWORD' '0'

    # ── CPU / Thread Scheduler ─────────────────────────────────────────────
    # 38 (0x26): foreground boost ON + variable short quanta — gaming sweet spot
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\PriorityControl' 'Win32PrioritySeparation' 'REG_DWORD' '38'

    # ── MMCSS (Multimedia Class Scheduler) ────────────────────────────────
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 'REG_DWORD' '0xffffffff'
    # 0 = dedicate maximum CPU to foreground/game; no background CPU reservation
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness'   'REG_DWORD' '0'
    # MMCSS Games class — maximum GPU and CPU priority for game threads
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority'        'REG_DWORD' '8'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'            'REG_DWORD' '6'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'REG_SZ'    'High'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority'       'REG_SZ'    'High'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Latency Sensitive'   'REG_SZ'    'True'

    # ── Storage / NTFS ────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisableLastAccessUpdate'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsMemoryUsage'              'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'DisableDeleteNotification'    'REG_DWORD' '0'

    # ── Network / TCP ─────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 'REG_DWORD' '30'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'MaxUserPort'       'REG_DWORD' '65534'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'Tcp1323Opts'       'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'DefaultTTL'        'REG_DWORD' '64'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'EnableWsd'         'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneNagle' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces | ForEach-Object { Set-ItemProperty $_.PSPath TCPNoDelay 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TcpAckFrequency 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TCPDelAckTicks 0 -Type DWord -ErrorAction SilentlyContinue }"'

    # ── Gaming ────────────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'HwSchMode'   'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDelay'    'REG_DWORD' '10'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDdiDelay' 'REG_DWORD' '10'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_Enabled'                        'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_FSEBehaviorMode'                'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode'       'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_EFSEBehaviorMode'               'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode'   'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 'REG_DWORD' '1'

    # ── Boot Time ─────────────────────────────────────────────────────────
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager' 'AutoChkTimeOut' 'REG_DWORD' '0'
    # Fast Startup OFF — HiberBoot conflicts with clean VM power cycles and snapshot restore
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power' 'HiberbootEnabled' 'REG_DWORD' '0'
    # Keep crash dump on BSOD — preserves minidump for analysis instead of silent restart
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\CrashControl' 'AutoReboot' 'REG_DWORD' '0'
    # BCD: short boot menu + disable dynamic tick for lower timer interrupt latency (gaming)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneBCD' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "& bcdedit /set timeout 5 2>&1 | Out-Null; & bcdedit /set disabledynamictick yes 2>&1 | Out-Null; & bcdedit /set useplatformtick yes 2>&1 | Out-Null"'

    # ── Service host packing ────────────────────────────────────────────────
    # winutil sets SvcHostSplitThresholdInKB to the machine's RAM so the SCM
    # packs service groups into fewer svchost.exe processes instead of one per
    # group. We cannot read the target VM's RAM from here (this is the build
    # host), so bake a generous floor now and let a RunOnce recompute the real
    # figure on first logon, when the hardware is known. Takes effect on reboot.
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control' 'SvcHostSplitThresholdInKB' 'REG_DWORD' '4194304'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneSvcHost' 'REG_SZ' `
        'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Set-ItemProperty -Path ''HKLM:\SYSTEM\CurrentControlSet\Control'' -Name SvcHostSplitThresholdInKB -Value ([int]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum/1KB)) -Type DWord"'

    Write-Log "Performance optimizations applied (gaming/VM profile)"

    # Always-on: Ultimate Performance power plan (activated at first logon)
    Enable-UltimatePerformance
}

function Remove-ScheduledTasks {
    Write-Log "Removing telemetry scheduled tasks..."

    $tasksPath = "$scratchDir\Windows\System32\Tasks"
    $tasksToRemove = @(
        "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program",
        "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "$tasksPath\Microsoft\Windows\Chkdsk\Proxy",
        "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"
    )

    foreach ($task in $tasksToRemove) {
        if (Test-Path $task) {
            Remove-Item -Path $task -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log "Scheduled tasks removed"
}

function Set-ServiceStartup {
    # Offline equivalent of `Set-Service -StartupType`:
    #   0 = Boot, 1 = System, 2 = Automatic, 3 = Manual, 4 = Disabled
    # Set-Service and sc.exe talk to the Service Control Manager of the RUNNING
    # OS; nothing here is running, so the 'Start' DWORD under
    # ControlSet001\Services\<name> is the only lever - and it is exactly what
    # Set-Service ends up writing on a live system. Never creates a key: a
    # service that does not exist in this image is silently skipped.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$StartValue
    )
    $regPath = "HKLM\zSYSTEM\ControlSet001\Services\$Name"
    if (-not (Test-Path "HKLM:\$regPath")) { return $false }

    & 'reg' 'add' $regPath '/v' 'Start' '/t' 'REG_DWORD' '/d' "$StartValue" '/f' 2>&1 | Out-Null
    if ($StartValue -ne 2) {
        # A leftover DelayedAutostart would silently turn Manual/Disabled into
        # a delayed-auto start.
        & 'reg' 'delete' $regPath '/v' 'DelayedAutostart' '/f' 2>&1 | Out-Null
    }
    return $true
}

function Tune-Services {
    # Run as few services as possible: classify EVERY service key in the image
    # instead of hand-maintaining a "disable these" list, so services Microsoft
    # adds in future 25H2 servicing updates get caught too.
    #
    # Skip rules (in order):
    #   * no Type / no Start value -> Winsock, COM and .NET registration
    #     containers that live under Services\ but are not services
    #   * Type & 3                 -> kernel / file-system driver. Untouched:
    #     boot and PnP safety matters more than the handful of extra drivers,
    #     and demand-start drivers only load when their device is present
    #   * Start <= 1               -> Boot/System load order, never touch
    #   * not (Type & 48)          -> not a Win32 service
    # Everything left over is set to Manual or Disabled unless it is on a keep
    # list. Note the contrast with Nano, which deletes the keys outright - that
    # leaves the SCM logging errors about missing services and breaks anything
    # that declares a dependency on them. Writing Start=4 is the same effect
    # with a working service record behind it.
    Write-Log "Tuning services (winutil-style: run as little as possible)..."

    # Load SYSTEM hive separately - service tuning is a standalone registry job
    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null
    if (-not (Test-Path 'HKLM:\zSYSTEM\ControlSet001\Services')) {
        Write-Log "Could not load the offline SYSTEM hive - service tuning skipped" "WARN"
        return
    }

    # --- Start=2: must be running for boot -> logon -> desktop -> network -----
    # Derived from the transitive DependOnService closure of the SCM's own hard
    # requirements (DCOM, RPC, event log, profile service, task scheduler, ...),
    # so nothing here has a hidden dependency on something we disable below.
    [string[]]$keepAuto = @(
        'AppXSvc',              # first logon registers the provisioned packages
        'BrokerInfrastructure', # background-task infra, the shell depends on it
        'CoreMessagingRegistrar',
        'CryptSvc',             # catalog/cert validation: setup + winget need it
        'DcomLaunch',
        'Dhcp',
        'Dnscache',
        'EventLog',
        'EventSystem',
        'gpsvc',                # Group Policy Client, required at logon
        'LSM',                  # Local Session Manager
        'NetSetupSvc',          # NIC bring-up
        'nsi',                  # Network Store Interface, AFD/Tcpip depend on it
        'Power',
        'ProfSvc',              # User Profile Service
        'RpcEptMapper',
        'RpcSs',
        'SamSs',                # Security Accounts Manager
        'Schedule',             # Task Scheduler - first-run tasks
        'SENS',
        'ShellHWDetection',     # drive letter / autorun enumeration
        'StateRepository',      # Start menu + AppX state
        'SystemEventsBroker',
        'Themes',
        'UserManager',
        'Wcmsvc',               # Windows Connection Manager
        'WinHttpAutoProxySvc',
        'Winmgmt'               # WMI - the autounattend scripts query it
    )

    # --- Start=3: startable on demand, but never resident --------------------
    # Winutil's own convention: MapsBroker and StorSvc go Automatic -> Manual
    # rather than Disabled, because things do still trigger them.
    #
    # The four dependency entries (BFE, iphlpsvc, LanmanWorkstation, Eaphost)
    # are here because something in this list needs them: NcaSvc declares
    # BFE + iphlpsvc, SessionEnv declares LanmanWorkstation, dot3svc declares
    # Eaphost. Leaving those Disabled would make the dependent service
    # unstartable the moment anything asked for it. Manual is free - the SCM
    # will start them only as a dependency, so none of them are resident at
    # boot, but the ones above them stay usable.
    [string[]]$keepManual = @(
        'W32Time',                     # clock sync (already Manual in stock)
        'cbdhsvc',                     # clipboard: spins up only when you copy
        'camsvc',                      # Content Access Manager
        'DispBrokerDesktopSvc',        # resolution / DPI changes in Settings
        'DoSvc',                       # Delivery Optimization, Store pulls on demand
        'dot3svc',                     # wired 802.1X
        'Eaphost',                     # ^ dependency of dot3svc (already stock-Manual)
        'KeyIso',                      # ^ dependency of Eaphost (CNG key isolation, stock-Manual)
        'FontCache',
        'LanmanWorkstation',           # ^ dependency of SessionEnv: keeps SMB/UNC and
                                       #   RDP re-enableable without running at boot
        'MapsBroker',                  # winutil: Automatic -> Manual
        'NcaSvc',                      # network connectivity indicator
        'iphlpsvc',                    # ^ dependency of NcaSvc (stock-Auto -> Manual)
        'BFE',                         # ^ dependency of NcaSvc (stock-Auto -> Manual)
        'NlaSvc',
        'netprofm',
        'ClipSVC',                     # Store app licensing
        'SessionEnv',                  # \
        'TermService',                 #  | RDP - stock-off, but leave it startable
        'UmRdpService',                # /
        'sppsvc',                      # Software Protection / activation
        'StorSvc',                     # winutil: Automatic -> Manual
        'TextInputManagementService',  # IME / text input
        'TrustedInstaller'             # Windows Modules Installer - servicing
    )

    $stats = @{ NonService = 0; Driver = 0; Auto = 0; Manual = 0; Disabled = 0 }
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($key in (Get-ChildItem -Path 'HKLM:\zSYSTEM\ControlSet001\Services' -ErrorAction SilentlyContinue)) {
        $props      = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        # StrictMode forbids touching properties that are not there, so probe
        # the property bag instead of reading $props.Type directly.
        $typeProp   = $props.PSObject.Properties['Type']
        $startProp  = $props.PSObject.Properties['Start']
        if (-not $typeProp -or -not $startProp) { $stats.NonService++; continue }

        $typeValue = [int]$typeProp.Value
        if (($typeValue -band 3) -ne 0)          { $stats.Driver++;     continue }  # kernel / fs driver
        if (($typeValue -band 48) -eq 0)         { $stats.NonService++; continue }  # not 16|32: not a Win32 service
        if ([int]$startProp.Value -le 1)         { $stats.Driver++;     continue }  # Boot / System load order

        $entries.Add([pscustomobject]@{ Name = $key.PSChildName; Start = [int]$startProp.Value })
    }

    $autoBefore = @($entries | Where-Object { $_.Start -eq 2 }).Count

    foreach ($entry in $entries) {
        $target = if     ($keepAuto   -contains $entry.Name) { 2 }
                  elseif ($keepManual -contains $entry.Name) { 3 }
                  else                                       { 4 }

        if (Set-ServiceStartup -Name $entry.Name -StartValue $target) {
            switch ($target) {
                2 { $stats.Auto++ }
                3 { $stats.Manual++ }
                4 { $stats.Disabled++ }
            }
        }
    }

    reg unload HKLM\zSYSTEM 2>&1 | Out-Null

    $autoAfter = $stats.Auto
    Write-Log ("Service tuning complete: auto-start {0} -> {1}, manual {2}, disabled {3} (skipped {4} drivers / {5} non-service keys)" -f `
        $autoBefore, $autoAfter, $stats.Manual, $stats.Disabled, $stats.Driver, $stats.NonService)
    if ($autoAfter -gt 40) {
        Write-Log "More than 40 auto-start services survived - check the keep lists" "WARN"
    }
}

function Disable-BackgroundApps {
    # Port of winutil's "Background Apps - Disable" plus its privacy/telemetry
    # policy block. winutil is a live system and uses Set-ItemProperty on HKCU;
    # here every HKCU value has to go into the Default user profile instead.
    #
    # Hive mapping matters: zNTUSER is Users\Default\ntuser.dat - the profile
    # EVERY account created during OOBE is copied from, so a value written here
    # reaches all users. zDEFAULT is the .DEFAULT service-account hive, which
    # nobody who logs on ever reads - writing it would silently do nothing.
    Write-Log "Disabling background apps and applying winutil privacy policies..."

    # --- the single kill switch for all Store app background activity --------
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 'REG_DWORD' '1'

    # --- HKCU half (-> zNTUSER) ---------------------------------------------
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 'REG_DWORD' '0'
    Remove-RegistryValue  'HKLM\zNTUSER\Software\Microsoft\Siuf\Rules\PeriodInNanoSeconds'

    # --- HKLM half (-> SOFTWARE / SYSTEM hives) ------------------------------
    # Activity history: winutil leaves EnableActivityFeed at 1 and only zeroes
    # Publish/Upload; we are after the smaller footprint, so turn it off too.
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'REG_SZ' 'Deny'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\Maps' 'AutoUpdateEnabled' 'REG_DWORD' '0'

    # Machine-wide: opt every PowerShell host out of telemetry
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Environment' 'POWERSHELL_TELEMETRY_OPTOUT' 'REG_SZ' '1'

    Write-Log "Background apps disabled, privacy policies applied"
}

#---------[ Finalization Functions ]---------#
function Optimize-WindowsImage {
    Write-Log "Cleaning up Windows image (this may take 10-15 minutes)..."
    & dism.exe /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null
    Write-Log "Image cleanup complete"
}

function Get-WimlibExe {
    # Multi-threaded WIM writer used for fast/max exports. Downloads the small
    # portable zip (SHA256-pinned) like oscdimg, returns $null on any failure
    # so callers fall back to DISM.
    $dest = "$PSScriptRoot\wimlib"
    $exe  = "$dest\wimlib-imagex.exe"
    if (Test-Path -LiteralPath $exe) { return $exe }
    try {
        $url = 'https://wimlib.net/downloads/wimlib-1.14.5-windows-x86_64-bin.zip'
        $sha = '2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265'
        $zip = Join-Path $env:TEMP 'wimlib.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180
        if ((Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower() -ne $sha) {
            throw 'wimlib download failed SHA256 verification'
        }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $exe)) { throw 'wimlib-imagex.exe missing after extraction' }
        return $exe
    } catch {
        Write-Log "wimlib unavailable ($($_.Exception.Message)) - falling back to DISM (single-threaded)" "WARN"
        return $null
    }
}

function Dismount-AndExport {
    Write-Log "Dismounting install.wim..."
    & dism /English /unmount-image "/mountdir:$scratchDir" /commit

    $tempWim = "$ultra11Dir\sources\install2.wim"
    $exported = $false
    if ($Compress -ne 'recovery') {
        $wimlib = Get-WimlibExe
        if ($wimlib) {
            $threads = [Environment]::ProcessorCount
            Write-Log "Exporting image ($Compress compression, wimlib x$threads threads)..."
            & $wimlib export $wimFilePath $INDEX $tempWim "--compress=$Compress" "--threads=$threads" | Out-Null
            if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tempWim)) {
                $exported = $true
            } else {
                Write-Log "wimlib export failed (exit code $LASTEXITCODE) - falling back to DISM" "WARN"
                Remove-Item -LiteralPath $tempWim -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if (-not $exported) {
        Write-Log "Exporting image ($Compress compression, DISM)..."
        & Dism.exe /English /Export-Image /SourceImageFile:$wimFilePath /SourceIndex:$INDEX /DestinationImageFile:$tempWim /Compress:$Compress
        if (-not (Test-Path -LiteralPath $tempWim)) { throw "Export failed: no image produced at $tempWim" }
    }

    Remove-Item -Path $wimFilePath -Force
    Rename-Item -Path $tempWim -NewName "install.wim"

    Write-Log "Install.wim export complete"
}

function Process-BootImage {
    Write-Log "Processing boot.wim (ultra11 shrinking)..."

    $bootWimPath = "$ultra11Dir\sources\boot.wim"

    # Take ownership
    & takeown /F $bootWimPath /A 2>&1 | Out-Null
    & icacls $bootWimPath /grant "$($adminGroup.Value):(F)" 2>&1 | Out-Null
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

    # Export only index 2 (setup image)
    Write-Log "Exporting boot.wim index 2..."
    $newBootWimPath = "$ultra11Dir\sources\boot_new.wim"
    & dism /English /Export-Image /SourceImageFile:$bootWimPath /SourceIndex:2 /DestinationImageFile:$newBootWimPath

    # Mount the new boot image
    Write-Log "Mounting boot image for modifications..."
    & dism /English /mount-image "/imagefile:$newBootWimPath" /index:1 "/mountdir:$scratchDir"

    # Load registry and apply bypasses
    reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" 2>&1 | Out-Null
    reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" 2>&1 | Out-Null
    reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" 2>&1 | Out-Null
    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" 2>&1 | Out-Null

    Write-Log "Applying system requirement bypasses and WinRE suppression to boot image..."
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'DisableRecovery' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'SkipInstallingWinRE' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\WinRE' 'WinREEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Setup\Recovery' 'DisableRecovery' 'REG_DWORD' '1'

    # If winre.wim was removed from the OS image, patch ReAgent.xml in boot.wim as well
    # so SetupHost does not attempt to stage SafeOS from Install.esd during WinPE setup (bypasses error 0x80070003 at 11%)
    if (-not $PreserveWinRE) {
        Write-Log "Patching ReAgent.xml in boot.wim to suppress WinRE SafeOS extraction..."
        Patch-ReAgentXml
    }

    # Unload registry
    reg unload HKLM\zNTUSER 2>&1 | Out-Null
    reg unload HKLM\zDEFAULT 2>&1 | Out-Null
    reg unload HKLM\zSOFTWARE 2>&1 | Out-Null
    reg unload HKLM\zSYSTEM 2>&1 | Out-Null

    Start-Sleep -Seconds 5

    Add-BackupDrivers -TargetPath $scratchDir -TargetName 'boot.wim'

    # Dismount boot image
    Write-Log "Dismounting boot image..."
    & dism /English /unmount-image "/mountdir:$scratchDir" /commit

    # Replace original boot.wim with shrunk version
    Remove-Item -Path $bootWimPath -Force
    $finalBootWimPath = "$ultra11Dir\sources\boot_final.wim"
    & dism /English /Export-Image /SourceImageFile:$newBootWimPath /SourceIndex:1 /DestinationImageFile:$finalBootWimPath /Compress:max
    Remove-Item -Path $newBootWimPath -Force
    Rename-Item -Path $finalBootWimPath -NewName "boot.wim"

    Write-Log "Boot image processing complete"
}

function Convert-ToESD {
    Write-Log "Converting to ESD format for maximum compression..."
    $esdPath = "$ultra11Dir\sources\install.esd"
    & dism /Export-Image /SourceImageFile:$wimFilePath /SourceIndex:1 /DestinationImageFile:$esdPath /Compress:recovery
    Remove-Item $wimFilePath -Force -ErrorAction SilentlyContinue
    Write-Log "ESD conversion complete"
}

function Slim-BootMedia {
    # Both BCD stores on this media are `locale = en-US` and neither carries a
    # font element, so bootmgr and the WinPE setup phase only ever resolve
    # Latin glyphs. The CJK boot faces are ~15 MB of the built ISO across
    # boot\fonts and efi\microsoft\boot\fonts. Latin faces are kept so there is
    # always a fallback: wgl4 is bootmgr's base face, segoe* the ClearType
    # fallback, segmono the monospace fallback.
    Write-Log "Slimming boot media (removing non-Latin boot fonts)..."

    $latinFaces = @('wgl4_boot.ttf', 'segoe_slboot.ttf', 'segoen_slboot.ttf', 'segmono_boot.ttf')

    foreach ($fontDir in "$ultra11Dir\boot\fonts", "$ultra11Dir\efi\microsoft\boot\fonts") {
        if (-not (Test-Path -LiteralPath $fontDir)) { continue }

        $freed = [long]0
        Get-ChildItem -LiteralPath $fontDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $latinFaces } |
            ForEach-Object {
                $freed += $_.Length
                Write-Log "Removing boot font: $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }

        Write-Log "$fontDir -> $([math]::Round($freed/1MB,1)) MB reclaimed"
    }
}

function Clean-IsoRoot {
    Write-Log "Cleaning ISO root (keeping only essentials)..."
    
    $keepList = @("boot", "efi", "sources", "bootmgr", "bootmgr.efi", "setup.exe", "autounattend.xml")
    Get-ChildItem -Path $ultra11Dir | Where-Object { $_.Name -notin $keepList } | ForEach-Object {
        Write-Log "Removing from ISO root: $($_.Name)"
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "ISO root cleaned"
}

function Create-UltraISO {
    Write-Log "Creating ISO image..."

    # Copy autounattend-ultra.xml as autounattend.xml to ISO root
    $ultraAutoUnattend = Join-Path (Split-Path $PSScriptRoot -Parent) "autounattend-ultra.xml"
    if (Test-Path $ultraAutoUnattend) {
        Copy-Item -Path $ultraAutoUnattend -Destination "$ultra11Dir\autounattend.xml" -Force
        Write-Log "Copied autounattend-ultra.xml to ISO root as autounattend.xml"
    }

    # Verify boot files
    $bootFiles = @(
        "$ultra11Dir\boot\etfsboot.com",
        "$ultra11Dir\efi\microsoft\boot\efisys.bin"
    )
    foreach ($bootFile in $bootFiles) {
        if (-not (Test-Path $bootFile)) {
            throw "Required boot file not found: $bootFile"
        }
    }

    # Determine oscdimg.exe location
    $hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

    if (Test-Path "$ADKDepTools\oscdimg.exe") {
        Write-Log "Using oscdimg.exe from Windows ADK"
        $OSCDIMG = "$ADKDepTools\oscdimg.exe"
    } else {
        Write-Log "ADK not found, downloading oscdimg.exe..."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
        if (-not (Test-Path $localOSCDIMGPath)) {
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath -UseBasicParsing
        }
        $OSCDIMG = $localOSCDIMGPath
    }

    # Move any existing output ISO aside so a failed rebuild cannot lose it
    $backISO = $null
    if (Test-Path -LiteralPath $outputISO) {
        $backISO = "$outputISO.bak"
        Remove-Item -LiteralPath $backISO -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $outputISO -Destination $backISO -Force
        Write-Log "Existing output ISO moved aside: $backISO"
    }
    Write-Log "Building bootable ISO..."
    try {
        & $OSCDIMG '-m' '-o' '-u2' '-udfver102' `
            "-bootdata:2#p0,e,b$ultra11Dir\boot\etfsboot.com#pEF,e,b$ultra11Dir\efi\microsoft\boot\efisys.bin" `
            $ultra11Dir $outputISO
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE" }
    } catch {
        if ($backISO -and (Test-Path -LiteralPath $backISO)) {
            Move-Item -LiteralPath $backISO -Destination $outputISO -Force
            Write-Log "Restored the previous ISO after failure: $outputISO" -Level WARN
        }
        throw
    }

    if (Test-Path $outputISO) {
        $isoSize = [math]::Round((Get-Item $outputISO).Length / 1GB, 2)
        Write-Log "ISO created successfully: $outputISO (${isoSize}GB)"
        if ($backISO) { Remove-Item -LiteralPath $backISO -Force -ErrorAction SilentlyContinue }
    } else {
        if ($backISO -and (Test-Path -LiteralPath $backISO)) {
            Move-Item -LiteralPath $backISO -Destination $outputISO -Force
            Write-Log "Restored the previous ISO after failure: $outputISO" -Level WARN
        }
        throw "ISO creation failed"
    }
}

function Write-BuildInfo {
    # kelexine: emits build metadata JSON so CI can read the real Windows build number
    param(
        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )
    try {
        $buildInfo = @{
            windows_build = $script:DetectedBuildNumber
            full_version  = $script:DetectedFullVersion
            image_name    = $script:DetectedImageName
            image_index   = $INDEX
            generated_at  = (Get-Date -Format 'o')
        }
        $buildInfo | ConvertTo-Json | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
        Write-Log "Build info written to $OutputPath"
    } catch {
        Write-Log "Failed to write build info to $OutputPath : $_" "WARN"
    }
}

function Invoke-Cleanup {
    if ($SkipCleanup) {
        Write-Log "Skipping cleanup (SkipCleanup flag set)" "WARN"
        return
    }

    Write-Log "Performing cleanup..."

    # Ensure image is unmounted
    & dism /English /unmount-image "/mountdir:$scratchDir" /discard 2>&1 | Out-Null

    Remove-Item -Path $ultra11Dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$PSScriptRoot\wimlib" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log "Cleanup complete"
}

#---------[ Main Execution ]---------#
try {
    Write-Log "=== Ultra11 Headless Builder Started ===" "INFO"
    Write-Log "Author: kelexine (https://github.com/kelexine)"
    Write-Log "Parameters: ISO=$ISO, INDEX=$INDEX, SCRATCH=$ScratchDisk, DEFENDER=$Defender"
    Write-Log "WARNING: absolute-minimum build - installs and boots, nothing else is guaranteed. VM TESTING ONLY!"

    Initialize-IsoSource
    Test-Prerequisites
    Export-BackupDrivers
    Initialize-Directories

    Resolve-ImageIndex

    # Handle install.esd conversion if needed
    if (Test-Path "$DriveLetter\sources\install.esd") {
        Write-Log "Found install.esd, conversion required"
        Convert-ESDToWIM
        Copy-WindowsFiles
        Write-Log "Resetting INDEX to 1 since ESD was exported to a new WIM"
        $script:INDEX = 1
    } else {
        Write-Log "Found install.wim, no conversion needed"
        Copy-WindowsFiles
    }

    Mount-WindowsImageFile
    Take-OwnershipOfFolders
    Get-ImageMetadata

    # Customization phase
    Remove-BloatwareApps
    Remove-SystemPackages
    Remove-DefenderPackages
    Remove-OptionalFeatures
    Remove-NativeImages
    Slim-DriverStore
    Reduce-Fonts
    Clean-InputMethods
    Remove-MiscellaneousFiles
    Remove-UltraExtras
    Remove-EdgeAndOneDrive
    if ($PreserveWinRE) {
        Write-Log "Skipping WinRE removal (PreserveWinRE flag set)" "INFO"
        Write-Log "ReAgent.xml will NOT be patched — original WinRE state preserved." "INFO"
    } else {
        Remove-WinRE
        Patch-ReAgentXml
    }

    # Registry phase
    Load-RegistryHives
    Apply-RegistryTweaks
    Set-WindowsDefender
    Apply-PerformanceTweaks
    Disable-BackgroundApps
    Remove-ScheduledTasks
    Unload-RegistryHives

    # Service tuning (separate registry operation - loads SYSTEM itself)
    Tune-Services

    # WinSxS optimization
    Optimize-WinSxS

    # Finalization phase
    Add-BackupDrivers -TargetPath $scratchDir -TargetName 'install.wim'
    Dismount-AndExport
    Process-BootImage
    Convert-ToESD
    Slim-BootMedia
    Clean-IsoRoot
    Create-UltraISO
    Write-BuildInfo -OutputPath "$PSScriptRoot\ultra11-buildinfo.json"

    # Cleanup
    Invoke-Cleanup
    Dismount-SourceIso

    Write-Log "=== ultra11 Build Completed Successfully ===" "INFO"
    Write-Log "Output: $outputISO"
    Write-Log "WARNING: This is AN EXTREMELY MINIMAL build - NOT for daily use!"

    exit 0

} catch {
    Write-Log "FATAL ERROR: $_" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"

    # Emergency cleanup
    try {
        Dismount-SourceIso

        Get-WindowsImage -Mounted | ForEach-Object {
            Write-Log "Emergency dismount: $($_.Path)" "WARN"
            Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue
        }

        @("zCOMPONENTS", "zDEFAULT", "zNTUSER", "zSOFTWARE", "zSYSTEM") | ForEach-Object {
            reg unload "HKLM\$_" 2>$null
        }
    } catch {
        Write-Log "Emergency cleanup failed: $_" "ERROR"
    }

    exit 1
}
