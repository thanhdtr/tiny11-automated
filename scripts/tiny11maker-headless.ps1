<#
.SYNOPSIS
    Headless script to build a trimmed-down Windows 11 image for CI/CD automation.

.DESCRIPTION
    Automated build of a streamlined Windows 11 image (tiny11) without user interaction.
    Designed for GitHub Actions workflows and other CI/CD pipelines.
    Uses only Microsoft utilities like DISM, with oscdimg.exe from Windows ADK.

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
    Windows Defender handling: Keep (default, no changes), Disable (policies,
    services and scheduled tasks turned off, files left in place - reversible)
    or Remove (Defender platform + Windows Security app uninstalled and files
    deleted).

.PARAMETER Apps
    Comma-separated winutil app keys to install silently on first logon
    (e.g. '7zip,chrome,vlc'), or the literal value 'winutil' to only bundle
    the winutil tool (Desktop shortcut) without auto-installing anything.

.PARAMETER OutputDir
    Custom folder for the finished ISO. Defaults to the folder of the source
    .iso file (file-path -ISO), or the script folder (drive-letter -ISO).

.PARAMETER Compress
    Compression for the install.wim exports: fast (default - quickest build,
    slightly larger ISO), max or recovery (slowest - smallest ISO). Core and
    Nano still recompress to a solid ESD at the end for minimum size.

.PARAMETER SkipCleanup
    Skip cleanup of temporary files after ISO creation (optional, for debugging)

.EXAMPLE
    .\tiny11maker-headless.ps1 -ISO E -INDEX 1
    .\tiny11maker-headless.ps1 -ISO E -INDEX 6 -SCRATCH D
    .\tiny11maker-headless.ps1 -ISO D:\ISOs\Win11_25H2_x64.iso -INDEX 6 -BackupDrivers
    .\tiny11maker-headless.ps1 -ISO E -INDEX 6 -Defender Remove
    .\tiny11maker-headless.ps1 -ISO E -INDEX 6 -Apps '7zip,chrome,vlc'

.NOTES
    Original Author: ntdevlabs
    Modified by: kelexine (https://github.com/kelexine)
    GitHub: https://github.com/kelexine/tiny11-automated
    Date: 2025-12-08
    
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

    [Parameter(Mandatory=$false, HelpMessage="Export drivers from this PC into host_drivers\ and inject them into the image")]
    [switch]$BackupDrivers,

    [Parameter(Mandatory=$false, HelpMessage="Windows Defender handling: Keep (no changes), Disable (policies/services/tasks off, reversible) or Remove (packages + files deleted)")]
    [ValidateSet('Keep', 'Disable', 'Remove')]
    [string]$Defender = 'Keep',

    [Parameter(Mandatory=$false, HelpMessage="Comma-separated winutil app keys to install on first logon (e.g. '7zip,chrome,vlc'), or 'winutil' to only bundle the tool")]
    [string]$Apps = '',

    [Parameter(Mandatory=$false, HelpMessage="Custom folder for the finished ISO (default: next to the source .iso file, or the script folder for a drive letter)")]
    [string]$OutputDir = '',

    [Parameter(Mandatory=$false, HelpMessage="Compression for the install.wim exports: fast (default, quickest, slightly larger ISO), max or recovery (slowest, smallest)")]
    [ValidateSet('fast', 'max', 'recovery')]
    [string]$Compress = 'fast'
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
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
$scratchDir = "$ScratchDisk\scratchdir"
$tiny11Dir = "$ScratchDisk\tiny11"
$outputISO = "$PSScriptRoot\tiny11.iso"
if ($OutputDir) {
    $od = $OutputDir.Trim().Trim('"')
    if (-not [System.IO.Path]::IsPathRooted($od)) { $od = Join-Path -Path (Get-Location).Path -ChildPath $od }
    $outputISO = Join-Path ([System.IO.Path]::GetFullPath($od)) (Split-Path -Leaf $outputISO)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputISO) | Out-Null
}
$logFile = "$PSScriptRoot\tiny11_$(Get-Date -Format yyyyMMdd_HHmmss).log"
# Third-party app sources (-Apps) - only contacted when -Apps is used
$appsCatalogUrl = 'https://raw.githubusercontent.com/Christitustech/winutil/main/config/applications.json'
$winutilUrl = 'https://christitus.com/win'

#---------[ Functions ]---------#
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

function Test-AppsSelection {
    # Validates -Apps keys against winutil's live catalog before any heavy work.
    # Runs before the admin check so bad keys fail fast. 'winutil' is always valid.
    if ([string]::IsNullOrWhiteSpace($Apps)) { return }
    $keys = @($Apps -split '[,;]' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($keys.Count -eq 0) { return }
    $toCheck = @($keys | Where-Object { $_ -ne 'winutil' })
    if ($toCheck.Count -eq 0) {
        Write-Log "Apps selection: winutil tool only"
        return
    }
    $json = $null
    try {
        $json = (Invoke-WebRequest -Uri $appsCatalogUrl -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
    } catch {
        Write-Log "Could not fetch winutil app catalog for validation ($_); continuing without key validation" "WARN"
        return
    }
    $known = @($json.PSObject.Properties.Name)
    $bad = @($toCheck | Where-Object { $known -notcontains $_ })
    if ($bad.Count -gt 0) {
        Write-Log "Unknown -Apps key(s): $($bad -join ', ')" "ERROR"
        throw "Unknown -Apps key(s): $($bad -join ', '). Keys must come from winutil's applications.json (e.g. 7zip, chrome, vlc) or the literal value 'winutil'."
    }
    Write-Log "App selection validated: $($keys -join ', ')"
}

function Stage-ThirdPartyApps {
    # Downloads winutil into the image and wires a silent first-logon install.
    # Requires registry hives to be loaded (writes RunOnce) and the image mounted.
    if ([string]::IsNullOrWhiteSpace($Apps)) { return }
    $keys = @($Apps -split '[,;]' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($keys.Count -eq 0) { return }
    $installKeys = @($keys | Where-Object { $_ -ne 'winutil' })

    $stageDir = "$scratchDir\Windows\Tiny11"
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    try {
        Invoke-WebRequest -Uri $winutilUrl -OutFile "$stageDir\winutil.ps1" -UseBasicParsing -TimeoutSec 180
    } catch {
        throw "Failed to download winutil from $winutilUrl : $_"
    }
    Write-Log "Bundled winutil.ps1 into image ($stageDir)"

    # Desktop launcher - also the recovery path if the auto-install fails
    $desktopDir = "$scratchDir\Users\Public\Desktop"
    if (Test-Path $desktopDir) {
        Set-Content -LiteralPath "$desktopDir\winutil.cmd" -Encoding ASCII -Value `
            "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%SystemRoot%\Tiny11\winutil.ps1`"`r`npause"
        Write-Log "Added winutil.cmd launcher to Public Desktop"
    }

    if ($installKeys.Count -eq 0) {
        Write-Log "Apps: winutil tool bundled (no auto-install requested)"
        return
    }

    ConvertTo-Json -InputObject @($installKeys) -Depth 3 | Set-Content -LiteralPath "$stageDir\install-apps.json" -Encoding UTF8
    Write-Log "App config staged: $($installKeys -join ', ')"

    # First-logon runner (single-quoted here-string: no expansion at build time)
    $runner = @'
$logPath = 'C:\ProgramData\tiny11\apps.log'
function Write-AppLog([string]$Message) {
    try { Add-Content -Path $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" } catch { }
}
function Test-InternetConnection {
    foreach ($probe in @('http://www.msftconnecttest.com/connecttest.txt', 'http://connectivitycheck.gstatic.com/generate_204')) {
        try {
            $r = Invoke-WebRequest -Uri $probe -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) { return $true }
        } catch { }
    }
    return $false
}
try {
    New-Item -ItemType Directory -Force -Path 'C:\ProgramData\tiny11' | Out-Null
    Write-AppLog 'Third-party app install starting'
    if (-not (Test-InternetConnection)) {
        Write-AppLog 'No internet connection at logon - skipping third-party app install'
        return
    }
    $dir = Join-Path $env:SystemRoot 'Tiny11'
    $scriptPath = Join-Path $dir 'winutil.ps1'
    $configPath = Join-Path $dir 'install-apps.json'
    if (-not (Test-Path $scriptPath)) { throw "winutil.ps1 not found at $scriptPath" }
    if (-not (Test-Path $configPath)) { throw "install-apps.json not found at $configPath" }
    $source = Get-Content -LiteralPath $scriptPath -Raw
    try {
        & ([ScriptBlock]::Create($source)) -Config $configPath -Run -Noui
    } catch {
        Write-AppLog "winutil -Noui invocation failed ($($_.Exception.Message)); retrying without -Noui"
        & ([ScriptBlock]::Create($source)) -Config $configPath -Run
    }
    Write-AppLog 'Third-party app install finished'
} catch {
    Write-AppLog "FAILED: $($_.Exception.Message)"
}
'@
    Set-Content -LiteralPath "$stageDir\install-apps.ps1" -Value $runner -Encoding UTF8

    # Runs silently at first logon (UAC is disabled in this image)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'Tiny11Apps' 'REG_SZ' 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Windows\Tiny11\install-apps.ps1'
    Write-Log "First-logon app install registered (RunOnce -> C:\Windows\Tiny11\install-apps.ps1)"
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

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check admin rights
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
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
    
    # Check disk space (minimum 15GB recommended)
    $disk = Get-PSDrive -Name $ScratchDisk[0] -ErrorAction SilentlyContinue
    if ($disk) {
        $freeGB = [math]::Round($disk.Free / 1GB, 2)
        Write-Log "Available space on ${ScratchDisk}: ${freeGB}GB"
        if ($freeGB -lt 15) {
            Write-Log "Low disk space warning: ${freeGB}GB (15GB+ recommended)" "WARN"
        }
    }
    
    Write-Log "Prerequisites check passed"
}

function Initialize-Directories {
    Write-Log "Initializing directories..."
    New-Item -ItemType Directory -Force -Path "$tiny11Dir\sources" | Out-Null
    New-Item -ItemType Directory -Force -Path $scratchDir | Out-Null
    Write-Log "Directories created"
}

function Convert-ESDToWIM {
    Write-Log "Converting install.esd to install.wim..."
    
    $esdPath = "$DriveLetter\sources\install.esd"
    $tempWimPath = "$tiny11Dir\sources\install.wim"
    
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
    Copy-Item -Path "$DriveLetter\*" -Destination $tiny11Dir -Recurse -Force -ErrorAction SilentlyContinue
    
    # Remove read-only attribute and delete install.esd if present
    if (Test-Path "$tiny11Dir\sources\install.esd") {
        Set-ItemProperty -Path "$tiny11Dir\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Remove-Item "$tiny11Dir\sources\install.esd" -Force -ErrorAction SilentlyContinue
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
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    & icacls $wimFilePath /grant "$($adminGroup.Value):(F)" | Out-Null
    
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    
    Mount-WindowsImage -ImagePath $wimFilePath -Index $INDEX -Path $scratchDir
    Write-Log "Image mounted at $scratchDir"
}

function Get-ImageMetadata {
    Write-Log "Extracting image metadata..."
    
    # Get language
    $imageIntl = & dism /English /Get-Intl "/Image:$scratchDir"
    $languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }
    
    if ($languageLine) {
        $languageCode = $Matches[1]
        Write-Log "Language: $languageCode"
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
}

function Remove-BloatwareApps {
    Write-Log "Removing provisioned appx packages..."
    
    $packages = & dism /English "/image:$scratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object {
            if ($_ -match 'PackageName : (.*)') {
                $matches[1]
            }
        }
    
    $packagePrefixes = @(
        'AppUp.IntelManagementandSecurityStatus',
        'Clipchamp.Clipchamp',
        'DolbyLaboratories.DolbyAccess',
        'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.Windows.CrossDevice',
        'Microsoft.GamingApp',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.MixedReality.Portal',
        'Microsoft.MSPaint',
        'Microsoft.Office.OneNote',
        'Microsoft.OfficePushNotificationUtility',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Wallet',
        'Microsoft.Windows.DevHome',
        'Microsoft.Windows.Copilot',
        'Microsoft.Windows.Teams',
        'Microsoft.Windows.Photos',
        'Microsoft.ScreenSketch',
        'Microsoft.StorePurchaseApp',
        'Microsoft.MPEG2VideoExtension',
        'Microsoft.WebMediaExtensions',
        'MicrosoftWindows.Client.WebExperience',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'microsoft.windowscommunicationsapps',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.WindowsTerminal',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams',
        'MicrosoftTeams',
        'Microsoft.549981C3F5F10',
        'Microsoft.Windows.AI',
        'Microsoft.Windows.AIFabric',
        'Microsoft.Windows.Recall',
        'Microsoft.Windows.CoreAI',
        'Microsoft.Recall'
    )
    
    $packagesToRemove = $packages | Where-Object {
        $packageName = $_
        $packagePrefixes | Where-Object { $packageName -like "*$_*" }
    }
    
    $removeCount = 0
    foreach ($package in $packagesToRemove) {
        Write-Log "Removing: $package"
        & dism /English "/image:$scratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$package" | Out-Null
        $removeCount++
    }
    
    Write-Log "Removed $removeCount appx packages"
}

function Remove-EdgeAndOneDrive {
    Write-Log "Removing Microsoft Edge and Edge WebView..."
    
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    
    $edgePaths = @(
        "$scratchDir\Program Files (x86)\Microsoft\Edge",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeUpdate",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeCore",
        "$scratchDir\Program Files (x86)\Microsoft\EdgeWebView",
        "$scratchDir\Windows\System32\Microsoft-Edge-Webview"
    )
    
    foreach ($path in $edgePaths) {
        if (Test-Path $path) {
            Write-Log "Deleting Edge component: $path"
            & takeown /f $path /r /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Remove Edge WebView directories inside WinSxS (covers amd64 and arm64)
    Write-Log "Removing Edge WebView assemblies from WinSxS..."
    $winSxSPaths = Get-ChildItem -Path "$scratchDir\Windows\WinSxS" -Filter "*microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    foreach ($winSxSPath in $winSxSPaths) {
        if (Test-Path $winSxSPath) {
            Write-Log "Taking ownership and removing WinSxS WebView folder: $winSxSPath"
            & takeown /f $winSxSPath /r /a | Out-Null
            & icacls $winSxSPath /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $winSxSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "Removing OneDrive..."
    $oneDrivePaths = @(
        "$scratchDir\Windows\System32\OneDriveSetup.exe",
        "$scratchDir\Windows\SysWOW64\OneDriveSetup.exe"
    )
    foreach ($path in $oneDrivePaths) {
        if (Test-Path $path) {
            Write-Log "Deleting OneDrive setup: $path"
            & takeown /f $path /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "Edge, Edge WebView, and OneDrive removal complete"
    
    # Clean up other remnants
    Write-Log "Cleaning up other remnants (GameBar, Copilot)..."
    $otherRemnants = @(
        "$scratchDir\Windows\GameBarPresenceWriter",
        "$scratchDir\Windows\System32\SettingsHandlers_Copilot.dll"
    )
    foreach ($path in $otherRemnants) {
        if (Test-Path $path) {
            Write-Log "Deleting remnant: $path"
            & takeown /f $path /a | Out-Null
            & icacls $path /grant "$($adminGroup.Value):(F)" /T /C | Out-Null
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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

    # Hide the virus & protection Settings page (no Defender UI to configure)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:virus'

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
    Write-Log "Loading registry hives..."
    
    reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
    reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
    reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
    reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    
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
    
    # Copy autounattend.xml if exists
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$scratchDir\Windows\System32\Sysprep\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml"
    }
    
    # Disable reserved storage
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    
    # Disable BitLocker
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    
    # Disable Chat icon
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
    
    # Remove Edge registries
    Remove-RegistryKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryKey "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
    
    # Disable OneDrive folder backup
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
    
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
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
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
            Write-Log "Removed task: $task"
        }
    }
    
    Write-Log "Scheduled tasks removed"
}

function Remove-NonEssentialServices {
    Write-Log "Disabling non-essential services (minimal for standard build)..."
    
    # Standard build: Only disable diagnostic and telemetry services
    # This preserves maximum compatibility while removing privacy/performance drains
    $servicesToDisable = @(
        'DiagTrack',           # Connected User Experiences and Telemetry
        'WerSvc',              # Windows Error Reporting
        'PcaSvc',              # Program Compatibility Assistant
        'SysMain'              # Superfetch (not needed on SSDs)
    )
    
    foreach ($service in $servicesToDisable) {
        Write-Log "Disabling service: $service"
        try {
            Set-RegistryValue "HKLM\zSYSTEM\ControlSet001\Services\$service" 'Start' 'REG_DWORD' '4'
        } catch {
            Write-Log "Could not disable service $service : $_" "WARN"
        }
    }
    
    Write-Log "Non-essential services disabled"
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
    # Profile: Conservative — safe for desktop and dev workstation use.
    Write-Log "Applying performance optimizations (desktop/dev profile)..."

    # ── Memory Management ──────────────────────────────────────────────────
    # Keep default paging for kernel drivers — safe for variable-RAM desktop systems
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'DisablePagingExecutive'  'REG_DWORD' '0'
    # Workstation memory model (0 = workstation, not server)
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'LargeSystemCache'        'REG_DWORD' '0'
    # Skip zeroing page file on shutdown — saves 30-60 s per reboot cycle
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management' 'ClearPageFileAtShutdown' 'REG_DWORD' '0'
    # SysMain is disabled — match prefetcher state to prevent orphaned background I/O
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 'REG_DWORD' '0'

    # ── CPU / Thread Scheduler ─────────────────────────────────────────────
    # 38 (0x26): foreground boost ON + variable short quanta — gaming and desktop sweet spot
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\PriorityControl' 'Win32PrioritySeparation' 'REG_DWORD' '38'

    # ── MMCSS (Multimedia Class Scheduler) ────────────────────────────────
    # Disable network throttling during multimedia/game workloads
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 'REG_DWORD' '0xffffffff'
    # 20 = default; reserves 20% CPU headroom for background tasks (safe for desktop)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness'   'REG_DWORD' '20'
    # MMCSS Games class — moderate GPU/CPU priority balanced for gaming alongside other workloads
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority'        'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority'            'REG_DWORD' '6'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'REG_SZ'    'Medium'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority'       'REG_SZ'    'High'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Latency Sensitive'   'REG_SZ'    'True'

    # ── Storage / NTFS ────────────────────────────────────────────────────
    # Disable 8.3 short filename generation — pure legacy overhead on modern systems
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 'REG_DWORD' '1'
    # Disable last-access timestamp update on every file read — eliminates per-read metadata writes
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsDisableLastAccessUpdate'  'REG_DWORD' '1'
    # Allow NTFS more memory for its internal metadata cache
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'NtfsMemoryUsage'              'REG_DWORD' '2'
    # Ensure SSD TRIM delete notifications are not suppressed
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\FileSystem' 'DisableDeleteNotification'    'REG_DWORD' '0'

    # ── Network / TCP ─────────────────────────────────────────────────────
    # Shrink TIME_WAIT from 240 s → 30 s (recycles ports faster after connection close)
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 'REG_DWORD' '30'
    # Expand ephemeral port range to near-maximum
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'MaxUserPort'       'REG_DWORD' '65534'
    # RFC 1323: TCP window scaling + timestamps (better throughput on high-bandwidth links)
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'Tcp1323Opts'       'REG_DWORD' '1'
    # TTL 64 (Linux/BSD default): consistent cross-platform behaviour
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'DefaultTTL'        'REG_DWORD' '64'
    # Disable WSD (Web Services on Devices) network probe overhead
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Tcpip\Parameters' 'EnableWsd'         'REG_DWORD' '0'
    # Per-interface Nagle + delayed-ACK disable — deferred to first boot (adapter GUIDs unknown offline)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneNagle' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces | ForEach-Object { Set-ItemProperty $_.PSPath TCPNoDelay 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TcpAckFrequency 1 -Type DWord -ErrorAction SilentlyContinue; Set-ItemProperty $_.PSPath TCPDelAckTicks 0 -Type DWord -ErrorAction SilentlyContinue }"'

    # ── Gaming ────────────────────────────────────────────────────────────
    # Hardware Accelerated GPU Scheduling (HAGS) — reduces CPU↔GPU submission latency
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'HwSchMode'   'REG_DWORD' '2'
    # Raise GPU TDR timeout: default 2 s causes false "GPU hung" errors under sustained load
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDelay'    'REG_DWORD' '10'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\GraphicsDrivers' 'TdrDdiDelay' 'REG_DWORD' '10'
    # Disable Xbox Game DVR / Game Bar capture overlay
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_Enabled'                        'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_FSEBehaviorMode'                'REG_DWORD' '2'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode'       'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible'  'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SYSTEM\GameConfigStore' 'GameDVR_EFSEBehaviorMode'               'REG_DWORD' '0'
    # Enable Game Mode — Windows auto-prioritizes detected game processes
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode'   'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 'REG_DWORD' '1'

    # ── Boot Time ─────────────────────────────────────────────────────────
    # Remove Explorer shell extension load stagger (default 5 s; now immediate)
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'REG_DWORD' '0'
    # Remove chkdsk countdown at boot — runs immediately if volume is flagged, skips otherwise
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager' 'AutoChkTimeOut' 'REG_DWORD' '0'
    # Fast Startup (HiberBoot) OFF - always: no hybrid boot, clean full shutdowns
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\Session Manager\Power' 'HiberbootEnabled' 'REG_DWORD' '0'
    # BCD tweaks — cannot modify BCD store offline; deferred to first boot via RunOnce
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'PerfTuneBCD' 'REG_SZ' `
        'powershell -WindowStyle Hidden -ExecutionPolicy Bypass -Command "& bcdedit /set timeout 10 2>&1 | Out-Null"'

    Write-Log "Performance optimizations applied (desktop/dev profile)"

    # Always-on: Ultimate Performance power plan (activated at first logon)
    Enable-UltimatePerformance
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

function Optimize-WindowsImage {
    Write-Log "Cleaning up Windows image (this may take 10-15 minutes)..."
    & dism.exe /Image:$scratchDir /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
    Write-Log "Image cleanup complete"
}

function Dismount-AndExport {
    Write-Log "Dismounting install.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save
    
    Write-Log "Exporting image ($Compress compression)..."
    $tempWim = "$tiny11Dir\sources\install2.wim"
    & Dism.exe /Export-Image /SourceImageFile:$wimFilePath /SourceIndex:$INDEX `
        /DestinationImageFile:$tempWim /Compress:$Compress | Out-Null
    
    Remove-Item -Path $wimFilePath -Force
    Rename-Item -Path $tempWim -NewName "install.wim"
    
    Write-Log "Install.wim export complete"
}

function Process-BootImage {
    Write-Log "Processing boot.wim..."
    
    $bootWimPath = "$tiny11Dir\sources\boot.wim"
    
    # Take ownership
    $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
    & takeown /F $bootWimPath /A | Out-Null
    & icacls $bootWimPath /grant "$($adminGroup.Value):(F)" | Out-Null
    Set-ItemProperty -Path $bootWimPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    
    Write-Log "Mounting boot.wim (Index 2)..."
    Mount-WindowsImage -ImagePath $bootWimPath -Index 2 -Path $scratchDir
    
    Write-Log "Loading boot image registry..."
    reg load HKLM\zCOMPONENTS "$scratchDir\Windows\System32\config\COMPONENTS" | Out-Null
    reg load HKLM\zDEFAULT "$scratchDir\Windows\System32\config\default" | Out-Null
    reg load HKLM\zNTUSER "$scratchDir\Users\Default\ntuser.dat" | Out-Null
    reg load HKLM\zSOFTWARE "$scratchDir\Windows\System32\config\SOFTWARE" | Out-Null
    reg load HKLM\zSYSTEM "$scratchDir\Windows\System32\config\SYSTEM" | Out-Null
    
    Write-Log "Applying system requirement bypasses to boot image..."
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
    
    Unload-RegistryHives
    
    Add-BackupDrivers -TargetPath $scratchDir -TargetName 'boot.wim'
    
    Write-Log "Dismounting boot.wim..."
    Dismount-WindowsImage -Path $scratchDir -Save
    
    Write-Log "Boot image processing complete"
}

function Create-TinyISO {
    Write-Log "Creating ISO image..."
    
    # Copy autounattend.xml to ISO root for OOBE bypass
    if (Test-Path "$PSScriptRoot\autounattend.xml") {
        Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$tiny11Dir\autounattend.xml" -Force
        Write-Log "Copied autounattend.xml to ISO root"
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
            Write-Log "Downloaded oscdimg.exe"
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
    Write-Log "Building bootable ISO (this may take 5-10 minutes)..."
    try {
        & $OSCDIMG '-m' '-o' '-u2' '-udfver102' `
            "-bootdata:2#p0,e,b$tiny11Dir\boot\etfsboot.com#pEF,e,b$tiny11Dir\efi\microsoft\boot\efisys.bin" `
            $tiny11Dir $outputISO | Out-Null
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
    
    # Remove temporary directories
    Remove-Item -Path $tiny11Dir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    
    # Remove downloaded files
    Remove-Item -Path "$PSScriptRoot\oscdimg.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$PSScriptRoot\autounattend.xml" -Force -ErrorAction SilentlyContinue
    
    # Verify cleanup
    $remainingItems = @()
    if (Test-Path $tiny11Dir) { $remainingItems += "tiny11 folder" }
    if (Test-Path $scratchDir) { $remainingItems += "scratchdir folder" }
    
    if ($remainingItems.Count -gt 0) {
        Write-Log "Cleanup incomplete: $($remainingItems -join ', ') still exist" "WARN"
    } else {
        Write-Log "Cleanup complete"
    }
}

#---------[ Main Execution ]---------#
try {
    Write-Log "=== Tiny11 Headless Builder Started ===" "INFO"
    Write-Log "Author: kelexine (https://github.com/kelexine)"
    Write-Log "Parameters: ISO=$ISO, INDEX=$INDEX, SCRATCH=$ScratchDisk, DEFENDER=$Defender, APPS=$Apps"
    
    Initialize-IsoSource
    Test-AppsSelection
    Test-Prerequisites
    Export-BackupDrivers
    
    Resolve-ImageIndex
    
    # Handle install.esd conversion if needed
    if (Test-Path "$DriveLetter\sources\install.esd") {
        Write-Log "Found install.esd, conversion required"
        Initialize-Directories
        Convert-ESDToWIM
        Copy-WindowsFiles
        Write-Log "Resetting INDEX to 1 since ESD was exported to a new WIM"
        $script:INDEX = 1
    } else {
        Write-Log "Found install.wim, no conversion needed"
        Initialize-Directories
        Copy-WindowsFiles
    }
    
    Mount-WindowsImageFile
    Get-ImageMetadata
    
    # Customization phase
    Remove-BloatwareApps
    Remove-EdgeAndOneDrive
    Remove-DefenderPackages
    Apply-RegistryTweaks
    Set-WindowsDefender
    Stage-ThirdPartyApps
    Apply-PerformanceTweaks
    Remove-ScheduledTasks
    Remove-NonEssentialServices
    Unload-RegistryHives
    
    # Finalization phase
    Optimize-WindowsImage
    Add-BackupDrivers -TargetPath $scratchDir -TargetName 'install.wim'
    Dismount-AndExport
    Process-BootImage
    Create-TinyISO
    Write-BuildInfo -OutputPath "$PSScriptRoot\tiny11-buildinfo.json"
    
    # Cleanup
    Invoke-Cleanup
    Dismount-SourceIso
    
    Write-Log "=== Tiny11 Build Completed Successfully ===" "INFO"
    Write-Log "Output: $outputISO"
    
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

        Unload-RegistryHives -ErrorAction SilentlyContinue
    } catch {
        Write-Log "Emergency cleanup failed: $_" "ERROR"
    }
    
    exit 1
}
