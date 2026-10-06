# Tiny11 Automated Builder


**Windows 11 25H2 Optimizations:**
- ✨ **AI/Recall Removal**: Complete removal of Copilot, Recall, and AI Fabric (~220 MB saved)
- 🛡️ **Enhanced Telemetry Blocking**: Stronger privacy protection with additional registry tweaks
- 🎮 **VRAM Gaming Optimization**: Improved graphics performance through DirectX registry optimizations
- ⚡ **Build-Specific Service Removal**: 4 services (Standard), 13 services (Core), 14 keys deleted (Nano), **every service classified - 34 of 260 Win32 services disabled, 195 startable on demand (Ultra)**
- 🚫 **Windows Update Binary Removal**: Core/Nano builds now remove WU binaries (~300 MB saved)
- 🏁 **Ultra Variant**: absolute-minimum build - every service classified, `Start=2` cut from 61 to 31 (stock-Manual and per-user templates kept startable, stock-Auto debloat targets disabled), winutil-style background-app and privacy policies baked in

**Total Additional Savings:**
- Standard: ~120 MB
- Core: ~320 MB
- Nano: ~320 MB
- Ultra: ~750 MB beyond Nano (estimate - the build log reports the actual
  reclaimed MB per step)

---

## 🔒 Privacy & Data Handling

This fork sends **nothing** to third parties:

- ❌ No Discord / Slack / email notifications
- ❌ No SourceForge uploads, download stats or API calls
- ❌ No release-detection services, scrapers or telemetry
- ❌ No analytics, tracking or any form of data collection

The only network traffic the build performs:

1. Downloading the Windows 11 ISO from the URL **you** provide (Microsoft)
2. Downloading this repository's scripts (GitHub)
3. Downloading `oscdimg.exe` from Microsoft - only if the Windows ADK is not installed
4. Storing results in **your own** repository (Actions artifacts / Releases)

---

## 🚀 Quick Start

### Option 1: Automated Build (GitHub Actions) - Recommended

Perfect for beginners and automated deployments:

1. **Fork** this repository
2. Go to **Actions** tab
3. Choose your workflow:
   - `Build Tiny11` → Standard trimmed Windows 11
   - `Build Tiny11 Core` → Ultra-minimal variant
   - `Build Nano11` → EXTREME minimal (VM only)

   ⚫ **Ultra has no CI workflow yet** - build it locally with Option 2 below
   (`run.ps1` picks it as variant 4, or invoke
   `scripts\ultra11builder-headless.ps1` directly).
4. Click **"Run workflow"** and configure:
   - Windows ISO URL
   - Edition (Home/Pro/Education)
   - Optional parameters
5. **Download** the ISO from the workflow **Artifacts** (or GitHub Releases)

**Build time**: 30-80 minutes depending on variant

### Option 2: Manual Build (PowerShell)

For advanced users and local builds:

```powershell
# Fastest: one-liner bootstrap (downloads this repo, asks for your ISO and the
# Windows Defender choice, then builds)
irm https://raw.githubusercontent.com/thanhdtr/tiny11-automated/main/run.ps1 | iex

# Or run the builders yourself:
# 1. Download the Windows 11 ISO (or mount one and note its drive letter, e.g. E:)
# 2. Run PowerShell as Administrator
# 3. Set execution policy
Set-ExecutionPolicy Bypass -Scope Process

# 4. Choose your variant - -ISO accepts a file path or a folder containing one (mounted automatically), or a drive letter:

# Standard Tiny11 (Recommended for daily use)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1

# From a downloaded .iso file
.\scripts\tiny11maker-headless.ps1 -ISO D:\ISOs\Win11_25H2_x64.iso -INDEX 1

# Tiny11 Core (Ultra-minimal, VM/testing only)
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6

# Nano11 (EXTREME minimal, VM testing ONLY)
.\scripts\nano11builder-headless.ps1 -ISO E -INDEX 1

# Ultra11 (absolute minimum - fewest services running, VM ONLY)
.\scripts\ultra11builder-headless.ps1 -ISO E -INDEX 1

# With .NET 3.5 (Core variant only)
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 1 -ENABLE_DOTNET35

# Back up this PC's drivers into the ISO (auto-installed on the new Windows)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -BackupDrivers

# Windows Defender: fully remove it - or -Defender Disable / -Defender Keep
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -Defender Remove
```

**Output location**: `run.ps1` asks where to save the finished ISO: the **same folder as your
source `.iso`** (the default) or a **custom location** you pick (created if it does not exist).
Direct builder runs default to the source file's folder when `-ISO` is a file path (or the script
folder for a mounted drive letter) and accept `-OutputDir <folder>` to override; `run.ps1` names
its ISO `tiny11-<variant>-<timestamp>.iso`.

**System Requirements**: Windows 10/11, PowerShell 5.1+, 30GB+ free space, Admin rights

---

## ⚠️ Choose Your Variant

<table>
<thead>
  <tr>
    <th>Feature</th>
    <th>🟢 Standard</th>
    <th>🟡 Core</th>
    <th>🔴 Nano</th>
    <th>⚫ Ultra</th>
  </tr>
</thead>
<tbody>
  <tr>
    <td><strong>Use Case</strong></td>
    <td>Daily use (with caution)</td>
    <td>Testing, disposable VMs</td>
    <td>VM testing ONLY</td>
    <td>Absolute minimum, fewest services running. VM ONLY</td>
  </tr>
  <tr>
    <td><strong>ISO Size</strong></td>
    <td>~3.5-5.5GB</td>
    <td>~3-3.5GB</td>
    <td>~2.5GB</td>
    <td>~2-2.5GB (target)</td>
  </tr>
  <tr>
    <td><strong>Bloatware Removal</strong></td>
    <td>✅ 40+ apps</td>
    <td>✅ 40+ apps</td>
    <td>✅ 50+ apps</td>
    <td>✅ 50+ apps, Store, Terminal</td>
  </tr>
  <tr>
    <td><strong>Services Running At Boot</strong></td>
    <td>stock &minus; 4</td>
    <td>stock &minus; 13</td>
    <td>14 service keys deleted</td>
    <td><strong>61 &rarr; 31 auto-start</strong><br>34 of 260 Win32 services disabled, 195 startable on demand (stock-Manual + per-user templates kept)</td>
  </tr>
  <tr>
    <td><strong>Background Apps &amp; Privacy</strong></td>
    <td>✅ Telemetry registry tweaks</td>
    <td>✅ Telemetry registry tweaks</td>
    <td>✅ Telemetry registry tweaks</td>
    <td>✅ <code>GlobalUserDisabled</code> + full winutil policy block</td>
  </tr>
  <tr>
    <td><strong>Optional Features</strong></td>
    <td>❌ Untouched</td>
    <td>❌ Untouched</td>
    <td>❌ Untouched</td>
    <td>✅ All enabled features removed (payload dropped from WinSxS)</td>
  </tr>
  <tr>
    <td><strong>Telemetry Disabled</strong></td>
    <td>✅ Complete</td>
    <td>✅ Complete</td>
    <td>✅ Complete</td>
    <td>✅ Complete</td>
  </tr>
  <tr>
    <td><strong>WinSxS Component Store</strong></td>
    <td>✅ Full</td>
    <td>❌ Minimized</td>
    <td>❌ Minimized</td>
    <td>❌ Minimized</td>
  </tr>
  <tr>
    <td><strong>Windows Recovery</strong></td>
    <td>✅ Intact</td>
    <td>⚙️ Removed by default - install fails ~15% without <code>-PreserveWinRE</code></td>
    <td>⚙️ Removed by default - install fails ~15% without <code>-PreserveWinRE</code></td>
    <td>⚙️ Removed by default - install fails ~15% without <code>-PreserveWinRE</code></td>
  </tr>
  <tr>
    <td><strong>Windows Defender</strong></td>
    <td>⚙️ Keep by default (<code>-Defender</code> Keep / Disable / Remove)</td>
    <td>⚙️ Remove by default (<code>-Defender</code> Keep / Disable / Remove)</td>
    <td>⚙️ Remove by default (<code>-Defender</code> Keep / Disable / Remove)</td>
    <td>⚙️ Remove by default (<code>-Defender</code> Keep / Disable / Remove)</td>
  </tr>
  <tr>
    <td><strong>Serviceability</strong></td>
    <td>✅ Can add features/updates</td>
    <td>❌ Cannot service</td>
    <td>❌ Cannot service</td>
    <td>❌ Cannot service</td>
  </tr>
  <tr>
    <td><strong>Printing Support</strong></td>
    <td>✅ Yes</td>
    <td>✅ Yes</td>
    <td>❌ No</td>
    <td>❌ No (spooler, print stack and print drivers all gone)</td>
  </tr>
  <tr>
    <td><strong>Audio</strong></td>
    <td>✅ Yes</td>
    <td>✅ Yes</td>
    <td>✅ Yes</td>
    <td>❌ No (Audiosrv / AudioEndpointBuilder disabled)</td>
  </tr>
  <tr>
    <td><strong>Firewall</strong></td>
    <td>✅ Yes</td>
    <td>✅ Yes</td>
    <td>✅ Yes</td>
    <td>❌ Off (mpssvc + BFE disabled)</td>
  </tr>
  <tr>
    <td><strong>Basic Apps (Notepad, Paint)</strong></td>
    <td>✅ Included</td>
    <td>✅ Included</td>
    <td>❌ Removed</td>
    <td>❌ Removed</td>
  </tr>
  <tr>
    <td><strong>Build Time</strong></td>
    <td>45-80 min</td>
    <td>30-45 min</td>
    <td>&lt;40 min</td>
    <td>&lt;40 min</td>
  </tr>
</tbody>
</table>

### 💡 Which Should You Choose?

- **🟢 Standard**: Best for most users. Balanced bloat removal with system stability
- **🟡 Core**: Perfect for development VMs, testing environments, disposable systems
- **🔴 Nano**: Absolute minimal testing only. Expect broken features. VM use ONLY.
- **⚫ Ultra**: You asked for the lightest possible image and nothing else. It installs
  and reaches a desktop; assume everything else you forgot about is gone. See
  [⚫ What Makes Ultra Different](#-what-makes-ultra-different) before building it.

---

## ⚫ What Makes Ultra Different

Ultra is a **fourth, separate builder** - `nano11builder-headless.ps1` is untouched, so
anyone relying on Nano gets exactly what they had before. Ultra starts from Nano's base
and adds three things.

### 1. Every service in the image is classified

Nano works from a blocklist: it deletes 14 service keys outright, which leaves the
Service Control Manager logging errors about records that no longer exist and breaks
anything that declared a dependency on them.

Ultra instead **walks every service key in the image** (697 keys on the stock source)
and decides each one from its own `Type` and `Start` values:

| Rule | Action |
|------|--------|
| No `Type` / no `Start` value | skipped - these are Winsock, COM and `.NET` registration containers that live under `Services\` but are not services |
| `Type & 3` (kernel / file-system driver) | **untouched** - boot and PnP safety beats a handful of spare drivers, and demand-start drivers only load when their device is present |
| `Start <= 1` (Boot / System) | **untouched** - load-order critical |
| Not (`Type & 48`) | skipped - not a Win32 service |
| On the `keepAuto` list | `Start = 2` (Automatic) |
| On the `keepManual` list | `Start = 3` (Manual) |
| Already `Start = 4` in the image | **left off** - stock-disabled services, plus everything an earlier pass in this build disabled on purpose (Defender, `wuauserv`, `dmwappushservice`); those writers run *before* service tuning, so the value read here is already 4 and must not be resurrected |
| `Type & 0x40` (per-user service template) | **kept at its stock `Start`** - the 24 templates (`UnistoreSvc`, `ConsentUxUserSvc`, `CredentialEnrollmentManagerUserSvc`, `CDPUserSvc`, `WpnUserService`, ...) are never run in session 0; the SCM clones one instance per logon. Disabling them strips the OOBE user's instances and is what made the region/keyboard XAML pages report "Something went wrong" |
| Stock `Start = 3` (stock-Manual) | `Start = 3` (Manual) - demand-start costs nothing at boot, but lets setup *start* them on demand (`TokenBroker`, `wlidsvc`, `WlanSvc`, `Appinfo`, `NgcSvc`, `DsmSvc`, `fdPHost`, `SharedAccess`, ...). Disabling these is what hung setup after the region and keyboard pages were skipped: SCM refuses with error 1058 and the page waits forever |
| Everything else (stock-Auto, not on `keepAuto`) | `Start = 4` (Disabled) - the debloat win: `DiagTrack`, `WSearch`, `SysMain`, `Spooler`, `mpssvc`, `Audiosrv`, `WpnService`, `CDPSvc`, `wscsvc`, `edgeupdate`, ... |

Startup types are written as the `Start` `REG_DWORD` under `ControlSet001\Services\<name>` -
which is exactly what `Set-Service -StartupType` writes on a live system. `Set-Service` and
`sc.exe` cannot be used here because they talk to the Service Control Manager of the
**running** OS, and nothing in a mounted image is running.

**Measured against a stock 25H2 image** (the same source ISO this repo builds from):

| | Before | After |
|---|---:|---:|
| Win32 services classified | 262 | 260 |
| Auto-start (`Start=2`) | **61** | **31** |
| Manual, startable on demand (`Start=3`) | 185 | **195** |
| Disabled (`Start=4`) | 16 (only 10 in the raw stock image - the rest are the explicit Defender/WU writes) | **34** |
| Never touched (drivers, containers) | 433 | 432 |

*(Measured by the builder's own log on build #4: `auto-start 61 -> 31, manual 195,
disabled 34 (24 per-user templates kept at stock Start)`, and spot-checked against the
shipped ISO's hive. "Before" is the stock source image minus the two keys
`Apply-RegistryTweaks` deletes outright (`UsoSvc`, `WaaSMedicSvc`; raw stock has 264
qualifying services) with this build's explicit Defender/WU/dmwappush disables already
applied - not the raw stock image, which ships only 10 disabled Win32 services. The
262 -> 260 delta is two service keys component removal takes with it before tuning
runs: `ssh-agent` (stock-disabled) and `workfolderssvc` (the Work Folders feature);
component removal also drops the driver key `smbdirect`, which is why the "never
touched" row goes 433 -> 432.)*

The 31 that still auto-start are the **transitive `DependOnService` closure** of what the
SCM actually needs to get from power-on to a desktop: DCOM, RPC, the event log, the
profile service, the task scheduler, the cryptographic services, the network stack up to
`Wcmsvc`/`Dhcp`/`Dnscache`, and `Winmgmt` because the autounattend scripts query WMI -
plus the three per-user service templates stock ships as Automatic (`CDPUserSvc`,
`webthreatdefusersvc`, `WpnUserService`; the fourth, `cbdhsvc`, is moved to Manual by
`keepManual` so the clipboard only spins up when you copy).

The 195 in the Manual tier are almost all of Windows' stock-Manual services, kept at
their stock value: `TokenBroker`, `wlidsvc` (Microsoft account sign-in), `WlanSvc`,
`Appinfo`, `NgcSvc` (Windows Hello), `lfsvc`, `DsmSvc`, `DeviceAssociationService`,
`fdPHost`, `RasMan`, `lmhosts`, `SharedAccess`, `cloudidsvc`, `wisvc`, ... plus the
curated `keepManual` extras (`W32Time`, `cbdhsvc` clipboard, `TrustedInstaller`,
RDP's `TermService`/`SessionEnv`/`UmRdpService`, `StorSvc`/`MapsBroker` from winutil's
own `Automatic → Manual` convention, and the dependency links `BFE`/`iphlpsvc` for
`NcaSvc`, `LanmanWorkstation` for `SessionEnv`, `Eaphost`/`KeyIso` for `dot3svc`).
Manual costs nothing at boot - the SCM starts them only when something asks - but it is
the difference between a setup page that can request a service on demand and one that
hangs forever on error 1058.

The 34 disabled are the debloat win and are all stock-**Auto** services this build
deliberately does not run - `DiagTrack`, `WSearch`, `SysMain`, `Spooler`, `mpssvc`,
`Audiosrv`, `WpnService`, `CDPSvc`, `wscsvc`, `edgeupdate`, `DPS`, `LanmanServer` -
plus the explicit Defender/WU/dmwappush disables. All 24 per-user service templates
(`UnistoreSvc`, `ConsentUxUserSvc`, `CredentialEnrollmentManagerUserSvc`, `CDPUserSvc`,
`WpnUserService`, ...) keep their stock `Start` value: they never run in session 0, the
SCM clones one instance per logon, and disabling them is what broke the OOBE XAML pages.

> **The keep set is verified dependency-closed.** Every dependency of a kept service that
> is itself a Win32 service is also kept, transitively. This is checked mechanically
> before the lists are considered final - it is what caught `SessionEnv → LanmanWorkstation`
> and `NcaSvc → BFE` in the first place.

### 2. winutil's background-app and privacy policies, ported offline

`winutil` is a live system and uses `Set-ItemProperty` against `HKCU`. Here every HKCU
value has to land in the **Default user profile** instead - `HKLM\zNTUSER` is
`Users\Default\ntuser.dat`, the profile that every account created at OOBE is copied from.
Writing `HKLM\zDEFAULT` would be wrong: that is the `.DEFAULT` service-account hive, which
nobody who logs on ever reads.

- `BackgroundAccessApplications\GlobalUserDisabled = 1` - winutil's single kill switch for
  all Store app background activity
- The privacy/telemetry policy block: activity history publish/upload off, telemetry = 0,
  `DisableWindowsConsumerFeatures`, `DODownloadMode = 0`, `LetAppsRunInBackground = 2`,
  location denied, advertising ID off, online speech off, ink/text harvesting off
- **`SvcHostSplitThresholdInKB`** - winutil sets this to the machine's RAM so the SCM packs
  service groups into fewer `svchost.exe` processes. We cannot read the target VM's RAM
  from the build host, so a generous floor is baked in and a `RunOnce` recomputes the real
  figure on first logon, when the hardware is known. Takes effect on reboot.

### 3. Size cuts Nano does not make

| Target | Est. saving | Why it is safe |
|---|---:|---|
| `helloface.inf` driver | **96 MB** | Windows Hello Face FoD package is already removed, so the driver would be an orphan |
| Physical 802.11 drivers (Intel/Realtek/Atheros/Qualcomm) | **~197 MB** | A VM presents an emulated Ethernet adapter and cannot see an 802.11 radio. Wired, virtio, VMXNET and Hyper-V/VMware NIC drivers use different INF prefixes and are untouched |
| `ntprint*` print support repository | **30 MB** | Nano's `prn*` glob misses this prefix; the print stack is removed anyway |
| All enabled optional features | varies | Payload dropped from WinSxS too, not just the FoD. Allowlisted: `NetFx4-AdvSrvs`, `MediaPlayback`, `WCF-*`, `VirtualMachinePlatform`, `HypervisorPlatform`, `Microsoft-Windows-Subsystem-Linux` |
| `SystemApps` leftovers (Edge DevTools, Recall/Copilot UI, AI fabric) | **48 MB** | Those packages are already removed by `Remove-SystemPackages` / `Remove-BloatwareApps` |
| `migwiz`, IE `F12`, braille tables, `Speech_OneCore` | **83 MB** | `Windows\Speech` and the IE package are already removed |
| Non-Latin boot fonts, both `boot\fonts` copies | **~30 MB** | Both BCD stores on the media are `locale = en-US` and carry **no font element**, so only Latin glyphs are ever resolved. `wgl4`/`segoe*`/`segmono` are kept as fallback |
| Windows Store, Terminal, Xbox family, Tips, Cortana | ~250 MB | `StorePurchaseApp` was already removed, which left the Store a half-state anyway |

**Deliberately not removed** even though they were measured: duplicate
`Microsoft.WindowsAppRuntime.1.5/1.6/1.7` packages (~168 MB) are framework dependencies
other packages pin to a specific minor version, and `.NET Framework` / `SysWOW64` are
needed by PowerShell 5.1 itself.

### ⚠️ What will NOT work

The contract is: **it installs, it reaches a desktop, and as little as possible is
running.** Nothing beyond that is guaranteed. Specifically:

- ❌ **No firewall** - `mpssvc` and `BFE` are disabled. Fine for a NAT/host-only VM; do not
  bridge this to a network you care about
- ❌ **No audio** - `Audiosrv` / `AudioEndpointBuilder` disabled
- ❌ **No printing** - spooler, print stack and print driver repository all removed
- ❌ **No Windows Search indexer** - `WSearch` disabled (the taskbar search box is hidden
  by the autounattend anyway)
- ❌ **No SMB / UNC access** - `LanmanServer` disabled, `LanmanWorkstation` left Manual
- ❌ **Clipboard does not work out of the box** - `cbdhsvc` is Manual, so no per-session
  host is created until something starts it
- ❌ **The network tray icon may show "no internet"** - `NcaSvc`/`BFE`/`iphlpsvc` are all
  Manual rather than running
- ❌ **No Windows Update, no Defender, no Notepad/Paint/Photos/Camera, no CJK input**
- ❌ **Cannot service** the image afterwards - no component store to add features to

**To restore any of these**, the switch is one registry value under
`HKLM\SYSTEM\CurrentControlSet\Services\<name>`: set `Start` to `2` (Automatic) or `3`
(Manual), then reboot. Nothing is deleted - unlike Nano, every service record still
exists, which is the whole reason for writing `Start=4` instead of removing the key.

The `keepAuto` and `keepManual` arrays at the top of `Tune-Services` in
`scripts\ultra11builder-headless.ps1` are plain string lists - edit them and rebuild if
you want a different floor.

---

## 📁 Repository Structure

```
tiny11-automated/
├── .github/
│   ├── workflows/              # GitHub Actions CI/CD
│   │   ├── build-tiny11.yml
│   │   ├── build-tiny11-core.yml
│   │   └── build-nano11.yml
│   ├── ISSUE_TEMPLATE/         # Issue templates
│   └── PULL_REQUEST_TEMPLATE.md
├── scripts/
│   ├── tiny11maker-headless.ps1          # ✨ Automated Standard
│   ├── tiny11coremaker-headless.ps1      # ✨ Automated Core
│   ├── nano11builder-headless.ps1        # ✨ Automated Nano
│   └── ultra11builder-headless.ps1       # ✨ Automated Ultra (service minimiser)
├── run.ps1                     # One-line bootstrap + interactive variant picker
├── autounattend.xml            # OOBE bypass (Standard/Core)
├── autounattend-nano.xml       # OOBE bypass (Nano)
├── autounattend-ultra.xml      # OOBE bypass (Ultra)
├── CONTRIBUTING.md             # Contributor guidelines
├── CODE_OF_CONDUCT.md          # Community standards
├── SECURITY.md                 # Security policy
├── ROADMAP.md                  # Project roadmap
├── README.md                   # This file
└── LICENSE                     # MIT License
```

---

## 🔧 Script Parameters

### Standard & Core Variants

```powershell
.\tiny11maker-headless.ps1
    -ISO <string>              # Drive letter of mounted ISO (e.g., "E"), a .iso file, or a folder containing one
    -INDEX <int>               # Image index (1=Home, 4=Education, 6=Pro, 7=Pro N)
    [-SCRATCH <string>]        # Optional: Scratch disk (default: script directory)
    [-BackupDrivers]           # Optional: Back up this PC's drivers into host_drivers\ and add them to the image
    [-Defender <string>]       # Optional: Keep (Standard default), Disable or Remove (Core/Nano default)
    [-OutputDir <string>]      # Optional: Custom folder for the finished ISO (default: next to the source .iso)
    [-Compress <string>]       # Optional: max (default, fast multi-threaded) | fast | recovery (smallest - slow single-threaded)
    [-SkipCleanup]             # Optional: Keep temp files for debugging
```

### Core-Only Parameter

```powershell
.\tiny11coremaker-headless.ps1
    [-ENABLE_DOTNET35]         # Enable .NET Framework 3.5 support
    [-PreserveWinRE]           # Keep winre.wim intact (REQUIRED for any install - without it setup dies ~15% with 0x8007000B, issue #95)
```

### Nano Variant

```powershell
.\nano11builder-headless.ps1
    -ISO <string>              # Drive letter of mounted ISO, a .iso file, or a folder containing one
    -INDEX <int>               # Image index
    [-SCRATCH <string>]        # Optional: Scratch disk
    [-BackupDrivers]           # Optional: Back up this PC's drivers into host_drivers\ and add them to the image
    [-Defender <string>]       # Optional: Keep, Disable or Remove (default: Remove)
    [-OutputDir <string>]      # Optional: Custom folder for the finished ISO (default: next to the source .iso)
    [-Compress <string>]       # Optional: max (default, fast multi-threaded) | fast | recovery (smallest - slow single-threaded)
    [-SkipCleanup]             # Optional: Keep temp files
    [-PreserveWinRE]           # Keep winre.wim intact (REQUIRED for any install - without it setup dies ~15% with 0x8007000B, issue #95)
```

### Ultra Variant

Same parameters as Nano (no `-ENABLE_DOTNET35`). See
[⚫ What Makes Ultra Different](#-what-makes-ultra-different) first.

```powershell
.\ultra11builder-headless.ps1
    -ISO <string>              # Drive letter of mounted ISO, a .iso file, or a folder containing one
    -INDEX <int>               # Image index
    [-SCRATCH <string>]        # Optional: Scratch disk
    [-BackupDrivers]           # Optional: Back up this PC's drivers into host_drivers\ and add them to the image
    [-Defender <string>]       # Optional: Keep, Disable or Remove (default: Remove)
    [-OutputDir <string>]      # Optional: Custom folder for the finished ISO (default: next to the source .iso)
    [-Compress <string>]       # Optional: max (default, fast multi-threaded) | fast | recovery (smallest - slow single-threaded)
    [-SkipCleanup]             # Optional: Keep temp files
    [-PreserveWinRE]           # Keep winre.wim intact (REQUIRED for any install - without it setup dies ~15% with 0x8007000B, issue #95)
```

### Examples

```powershell
# Basic build - Windows 11 Home Standard
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1

# Professional Edition Core with .NET 3.5
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -ENABLE_DOTNET35

# Core build (preserves WinRE - required, otherwise setup dies ~15% with 0x8007000B)
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -PreserveWinRE

# Nano build with WinRE preserved (same 15% install failure without it)
.\scripts\nano11builder-headless.ps1 -ISO E -INDEX 1 -PreserveWinRE

# Ultra build - absolute minimum, fewest services running (VM ONLY)
# -PreserveWinRE is required: without it setup dies ~15% into the install
.\scripts\ultra11builder-headless.ps1 -ISO E -INDEX 1 -PreserveWinRE

# Custom scratch drive (useful for limited C:\ space)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -SCRATCH D

# Build straight from a downloaded .iso file (mounted automatically)
.\scripts\tiny11maker-headless.ps1 -ISO D:\ISOs\Win11_25H2_x64.iso -INDEX 6

# Save the finished ISO to a custom folder (default: next to the source .iso)
.\scripts\tiny11maker-headless.ps1 -ISO D:\ISOs\Win11_25H2_x64.iso -INDEX 6 -OutputDir D:\Tiny11Out

# Compression: max (default, fast multi-threaded via wimlib) or recovery (smallest, slow single-threaded DISM)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 6 -Compress recovery

# Back up this PC's drivers into host_drivers\ and add them to the image -
# they auto-install on the freshly installed Windows (no driver downloads)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -BackupDrivers

# Windows Defender options: Remove (packages + files), Disable (reversible),
# Keep (no changes). Core/Nano default to Remove, Standard defaults to Keep.
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -Defender Remove
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -Defender Keep

# Debug mode (keeps temporary files)
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 1 -SkipCleanup
```

---

## 🛡️ Windows Defender Options (`-Defender`)

All four builders accept `-Defender Keep|Disable|Remove`. `run.ps1` prompts with a
numbered choice (Standard defaults to **Keep**, Core/Nano/Ultra to **Remove**):

| Mode | What happens |
|------|--------------|
| **Keep** | No Defender changes at all |
| **Disable** | Registry policies off (`DisableAntiSpyware`, real-time protection set, Spynet), services disabled (WinDefend, WdNisSvc, WdNisDrv, WdFilter, Sense, SecurityHealthService), Defender scheduled tasks removed, SmartScreen off, virus Settings page hidden. Files stay on disk → reversible |
| **Remove** | Everything in **Disable** *plus* `Windows-Defender-Client-Package` and the Windows Security app (SecHealthUI) uninstalled via DISM, then leftovers force-deleted (`Program Files\Windows Defender`, `ProgramData\Microsoft\Windows Defender`, `WdFilter.sys`, ...) |

After **Remove**, install a third-party AV before browsing. Getting Defender back means
reinstalling the *Windows Defender Platform* optional feature or resetting Windows.

---

## ⚡ Always-On Image Defaults

Applied unconditionally by every builder (no flag needed):

- **UAC disabled** - `EnableLUA=0` (+ `ConsentPromptBehaviorAdmin=0`, secure-desktop
  values off) written to the image policy key at every boot. Nothing on this image
  re-enables it: there is no domain GPO/MDM, and Windows Update preserves HKLM policy
  keys. Revert with `reg add .../Policies\System /v EnableLUA /t REG_DWORD /d 1`.
  Caveats: some Store apps/security notices warn with UAC off; "Reset this PC" restores defaults.
- **Ultimate Performance power plan** - Microsoft's hidden scheme is duplicated and
  activated at first logon (`powercfg` via RunOnce)
- **Fast Startup disabled** - `HiberbootEnabled=0`: clean full shutdowns, no hybrid boot

---

## 📦 What Gets Removed?

### 🗑️ Bloatware Apps (40-50+ removed)

<details>
<summary><strong>Click to expand full list</strong></summary>

**Productivity & Entertainment:**
- Microsoft Teams
- OneDrive
- Microsoft Edge
- Xbox Game Bar & Gaming Services
- Clipchamp Video Editor
- Paint 3D
- 3D Viewer
- Mixed Reality Portal

**Information & News:**
- Weather
- News
- Maps
- Bing Search

**Communication:**
- Skype
- Cortana
- People App
- Your Phone (Phone Link)
- Outlook for Windows (new)

**AI Features (Windows 11 25H2+):**
- Windows Copilot (AI Assistant)
- Windows Recall (AI Snapshots)
- AI Fabric Service
- CoreAI Components

**Office & Productivity:**
- Office Hub
- Power Automate
- Solitaire Collection
- Sticky Notes
- To Do

**Utilities:**
- Get Help
- Get Started (Tips)
- Feedback Hub
- Quick Assist
- DevHome

**Media:**
- Media Player
- Sound Recorder
- Photos
- Camera (Nano only)

**Additional (Nano only):**
- Notepad
- Paint
- Windows Terminal

</details>

### 🔧 System Components Removed

- Internet Explorer (legacy package)
- Windows Media Player (legacy)
- WordPad
- Math Input Panel
- Steps Recorder
- LA57 CPU compatibility layer
- Language features (OCR, Speech, Handwriting)
- Windows Defender (Core/Nano/Ultra by default; any variant with `-Defender Remove`)
- Printer drivers (Nano/Ultra) - Ultra also drops the `ntprint*` support repository Nano's `prn*` glob misses
- Scanner/MFD drivers (Nano/Ultra)

**Ultra only** (in addition to everything above):

- Every enabled optional feature, payload dropped from WinSxS (WCF, Work Folders,
  Windows Media Player, XPS/Print-to-PDF, Search Engine Client, MSRDC, NetFx advanced)
- Physical Wi-Fi drivers, Windows Hello Face driver, `helloface.inf` (~293 MB)
- Windows Store, Windows Terminal, Xbox family, Tips, Cortana, Reading List
- Edge DevTools Client, Recall/Copilot UI packages, AI Fabric
- `migwiz` migration wizard, IE F12 developer tools, braille tables, OneCore Speech
- Non-Latin boot fonts (both `boot\fonts` locations)
- Background app activity for the Default user profile, plus the winutil privacy policy block

### ⚙️ Registry Optimizations Applied

<details>
<summary><strong>Click to expand optimizations</strong></summary>

**System Requirements:**
- TPM 2.0 requirement bypass
- Secure Boot requirement bypass
- CPU compatibility check bypass
- RAM requirement bypass (allows <4GB)

**Privacy & Telemetry:**
- All telemetry endpoints disabled
- Enhanced diagnostic data blocking
- Activity history disabled
- Location services disabled
- Advertising ID disabled
- Device name excluded from telemetry
- Feedback notifications disabled

**AI & Privacy (NEW - Windows 11 25H2):**
- Windows AI data analysis completely disabled
- Copilot AI assistant fully removed
- Recall snapshot feature blocked
- AI Fabric service disabled

**User Experience:**
- Sponsored apps blocked
- Consumer features disabled
- Reserved storage disabled
- BitLocker encryption disabled
- Windows Search indexing optimized
- Chat icon removed from taskbar
- Widgets disabled
- Cortana startup disabled

**Performance (NEW):**
- VRAM allocation optimized for gaming
- Non-essential services disabled (4-13 depending on variant; **Ultra: 34 of 260
  Win32 services set to `Start=4`, auto-start cut from 61 to 31** - see
  [⚫ What Makes Ultra Different](#-what-makes-ultra-different))
- Diagnostic services removed
- Telemetry services disabled
- UAC permanently disabled (`EnableLUA=0`) - always on
- Ultimate Performance power plan activated at first logon - always on
- Fast Startup (HiberBoot) disabled - always on

**Update & Cloud:**
- Windows Update disabled (can be manually enabled in Standard)
- Windows Update binaries removed (Core/Nano/Ultra - NON-SERVICEABLE)
- OneDrive backup prompts disabled
- Teams auto-install blocked
- New Outlook installation blocked

</details>

---

## 💾 System Requirements

### For Building ISOs

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| **Operating System** | Windows 10 | Windows 11 |
| **PowerShell** | 5.1 | 7.0+ |
| **RAM** | 8GB | 16GB+ |
| **Free Disk Space** | 20GB | 40GB+ |
| **Processor** | Dual-core | Quad-core+ |
| **Permissions** | Administrator | Administrator |
| **Network** | For oscdimg.exe download | Stable connection |

**Additional Requirements:**
- Windows ADK (optional, oscdimg.exe auto-downloaded if missing)
- Valid Windows 11 ISO file
- Antivirus temporarily disabled (optional, may interfere)

### For Running Built ISOs

**✅ System requirements are bypassed!** Tiny11 can run on:

- **CPU**: Any x64/ARM64 processor (Pentium, Core 2 Duo, etc.)
- **RAM**: 1GB minimum (2GB+ recommended)
- **Storage**: 10GB minimum (20GB+ recommended)
- **TPM**: Not required (completely bypassed)
- **Secure Boot**: Not required (bypassed)
- **UEFI/BIOS**: Both supported

**✨ Perfect for:**
- Old laptops (2010+)
- Low-spec hardware
- Virtual machines
- Testing environments
- Educational purposes

---

## 🏗️ GitHub Actions Workflows

### Automated Builds via CI/CD

All three variants support automated building through GitHub Actions:

#### 1. Build Tiny11 (Standard)
**File**: `.github/workflows/build-tiny11.yml`

**Inputs:**
```yaml
windows_iso_url:        # Windows 11 ISO download URL
  required: true
  
image_index:            # Windows edition
  type: choice
  options: [1, 4, 6, 7]  # Home, Education, Pro, Pro N
  
skip_cleanup:           # Debug mode (keep artifacts)
  type: boolean
  default: false
```

#### 2. Build Tiny11 Core (Ultra-Minimal)
**File**: `.github/workflows/build-tiny11-core.yml`

**Inputs:**
```yaml
windows_iso_url:        # Same as Standard
image_index:            # Same as Standard
skip_cleanup:           # Same as Standard
enable_dotnet35:        # 🆕 Enable .NET Framework 3.5
  type: boolean
  default: false
preserve_winre:         # 🆕 Preserve winre.wim (real hardware / 24H2+ builds)
  type: boolean
  default: false
```

#### 3. Build Nano11 (EXTREME Minimal)
**File**: `.github/workflows/build-nano11.yml`

**Inputs:**
```yaml
windows_version:        # Version string (24H2, 25H2, etc.)
  required: true
  
windows_iso_url:        # Same as above
image_index:            # Same as above
language:               # Language name (English, etc.)
  default: "English"
  
skip_cleanup:           # Same as above
preserve_winre:         # 🆕 Preserve winre.wim (real hardware / 24H2+ builds)
  type: boolean
  default: false
```

### Workflow Features

✨ **Automated download** - Fetches ISO automatically  
🔐 **Checksum verification** - Validates ISO integrity  
📦 **Artifact upload** - ISO + checksums available  
📊 **Build statistics** - Performance metrics tracked

---

## 📊 Build Performance

| Variant | Download Time | Build Time | Total Time | Output Size |
|---------|--------------|------------|------------|-------------|
| **Standard** | 5-15 min | 45-80 min | **50-95 min** | ~4-5GB |
| **Core** | 5-15 min | 30-45 min | **35-60 min** | ~3-4GB |
| **Nano** | 5-15 min | <40 min | **~45-55 min** | ~2-2.9GB |
| **Ultra** | 5-15 min | <40 min | **~45-55 min** | ~2-2.5GB (target) |

*Build times measured on GitHub Actions standard runners (2-core, 7GB RAM).
Ultra size is a target until the first build completes - the log reports the
actual MB reclaimed by each step.*

**Factors affecting build time:**
- ISO download speed
- Number of apps to remove (more apps = longer compression)
- WinSxS optimization (Core/Nano/Ultra)
- Runner performance
- Concurrent builds

---

## 🐛 Troubleshooting

### Common Issues & Solutions

<details>
<summary><strong>"Script must run as Administrator"</strong></summary>

**Problem**: PowerShell not running with elevated privileges

**Solutions:**
1. Right-click PowerShell → "Run as Administrator"
2. Let script auto-elevate (it will restart automatically)
3. In VS Code: Run as admin before opening

</details>

<details>
<summary><strong>"Insufficient disk space"</strong></summary>

**Problem**: Not enough free space on C:\ drive

**Solutions:**
1. Free up at least 30GB on C:\
2. Use `-SCRATCH` parameter to specify different drive:
   ```powershell
   .\tiny11maker-headless.ps1 -ISO E -INDEX 1 -SCRATCH D
   ```
3. Clean Windows temp files: `cleanmgr`
4. Check disk space: `Get-PSDrive C`

</details>

<details>
<summary><strong>"ISO creation fails" / "oscdimg.exe error"</strong></summary>

**Problem**: Missing oscdimg.exe or corrupted installation

**Solutions:**
1. Install Windows ADK:
   - Download: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
   - Install "Deployment Tools" only
2. Let script download oscdimg.exe automatically (requires internet)
3. Verify antivirus isn't blocking the script
4. Check file permissions on script directory

</details>

<details>
<summary><strong>"Build failures in GitHub Actions"</strong></summary>

**Problem**: Workflow fails during automated build

**Solutions:**
1. Check workflow logs for specific error
2. Enable `skip_cleanup: true` to preserve artifacts
3. Verify ISO URL is accessible and correct
4. Ensure GitHub Actions has sufficient runner space

**Common causes:**
- Invalid ISO URL (404 error)
- Network timeout during download
- Insufficient runner disk space

</details>

<details>
<summary><strong>"ISO boots but shows errors"</strong></summary>

**Problem**: Generated ISO boots but has missing features

**Solutions:**
1. Verify you used the correct variant:
   - Standard: Most features intact
   - Core: Some features unavailable
   - Nano: Many features broken (expected)
2. Check if you need .NET 3.5 (Core only):
   ```powershell
   -ENABLE_DOTNET35
   ```
3. For printing issues: Don't use Nano variant
4. For Windows Defender: Use Standard variant
5. Rebuild with Standard variant if Core/Nano/Ultra too aggressive

</details>

<details>
<summary><strong>Install fails around the 15% mark (0x8007000B)</strong></summary>

**Problem**: Setup dies near 15% (early in "Installing Windows") on EFI/VM installs
when `winre.wim` was stripped from `Recovery\WinREAgent` (issue #95)

**Solutions:**
1. Rebuild with `-PreserveWinRE` - required for **any** install target (VM or real
   hardware), not just real hardware
2. `run.ps1` prompts for this automatically for Core/Nano/Ultra

</details>

<details>
<summary><strong>OOBE region/keyboard pages say "Something went wrong", setup hangs after skipping them</strong></summary>

**Problem**: On Ultra, `ooberegion` and `oobekeyboard` error out; skipping both lets
setup continue a little further and then freeze.

**Cause**: service tuning used to set every service outside the keep lists to
`Start = 4` - including all 24 per-user service templates (the OOBE user loses
`UnistoreSvc`/`ConsentUxUserSvc`/`CredentialEnrollmentManagerUserSvc`, so the XAML
pages fail) and ~170 stock-Manual services setup later requests on demand (SCM
answers error 1058 and the page hangs). Fixed in `Tune-Services`: keep lists win,
already-`Start=4` stays off, per-user templates and stock-Manual services keep their
stock value, only stock-Auto debloat targets are disabled.

**If you still see it:**
1. Confirm the ISO was built from a commit containing the classification fix
   (build log line: `auto-start 61 -> 31, manual 195, disabled 34 (24 per-user
   templates kept at stock Start...)`)
2. Rebuild with `-PreserveWinRE` (a broken WinRE also aborts setup early)
3. Capture the exact error text/code from the failing page

</details>

<details>
<summary><strong>"Checksums don't match"</strong></summary>

**Problem**: Downloaded ISO checksum verification fails

**Solutions:**
1. Re-download ISO from official source
2. Verify download completed fully (check file size)
3. Scan for disk errors: `chkdsk /f`
4. Try different download mirror
5. Compare with official checksums from Microsoft

**Verify checksum:**
```powershell
Get-FileHash -Path "tiny11.iso" -Algorithm SHA256
```

</details>

---

## 🔐 Security Considerations

### ⚠️ Important Security Information

**Before using Tiny11:**

1. **Modified Windows Images** → May have security implications
   - No official Microsoft support
   - Potential compatibility issues
   - Use at your own risk

2. **Windows Defender Removed or Disabled** (Core/Nano default; Standard opt-in via `-Defender`)
   - Install third-party antivirus (Avast, Kaspersky, etc.)
   - Keep antivirus updated
   - Consider `-Defender Keep` for better security

3. **⚫ Ultra: NO FIREWALL and NO DEFENDER** (`mpssvc` Disabled, Defender
   removed by default; the Base Filtering Engine `BFE` stays Manual/startable but
   nothing runs without the firewall service)
   - Acceptable for a NAT / host-only VM; **do not bridge an Ultra VM to a network
     you care about**, and never use it on real hardware
   - This is the single biggest difference between Ultra and the other three variants

4. **UAC Disabled - always** (`EnableLUA=0` in every image)
   - No elevation prompts: anything running as admin applies silently
   - Re-enable after install: `reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 1 /f` + reboot

5. **Updates Disabled by Default**
   - Manually enable if needed: `services.msc` → Windows Update
   - No automatic security patches
   - Monitor security advisories manually

6. **Privacy vs. Functionality Trade-off**
   - Telemetry disabled → Better privacy
   - Some features may not work without telemetry
   - Cloud features limited/disabled

7. **Production Use NOT Recommended**
   - Use for testing/development only
   - Not suitable for business-critical systems
   - Consider official Windows for production

### 🔒 Security Best Practices

✅ **Download from official sources only**
  - Microsoft: https://www.microsoft.com/software-download/windows11
  - Your own fork (workflow artifacts / releases)

✅ **Verify checksums before installation**
  ```powershell
  Get-FileHash -Path "tiny11.iso" -Algorithm SHA256
  # Compare with official checksum
  ```

✅ **Test in VM before bare-metal installation**
  - Use VirtualBox, Hyper-V, or VMware
  - Verify functionality meets your needs
  - Check for compatibility issues

✅ **Backup important data before installing**
  - Full system backup recommended
  - Document current configuration
  - Have recovery media ready

✅ **Use valid Windows license**
  - Tiny11 is NOT a Windows activator
  - Legal Windows license required
  - Respect Microsoft's terms of service

### 🚨 Vulnerability Reporting

Found a security issue? **DO NOT create a public GitHub issue!**

📧 **Email**: frankiekelechi@gmail.com  
🔒 **Subject**: `[SECURITY] Tiny11 Vulnerability Report`  
📋 **See**: [SECURITY.md](SECURITY.md) for full disclosure policy

---

## 📖 Documentation

### 📚 Available Documentation

- **[README.md](README.md)** - This file (overview & quick start)
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute
- **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)** - Community guidelines
- **[SECURITY.md](SECURITY.md)** - Security policy & reporting
- **[LICENSE](LICENSE)** - MIT License terms

### 🎓 Tutorials & Guides

- **Windows Edition Index Numbers**:
  - `1` = Windows 11 Home
  - `4` = Windows 11 Education
  - `6` = Windows 11 Pro
  - `7` = Windows 11 Pro N (without media features)

- **Finding Edition Index**:
  ```powershell
  # Mount ISO first, then:
  dism /Get-WimInfo /WimFile:E:\sources\install.wim
  ```

- **Manual OOBE Bypass**: Edit `autounattend.xml` for custom configurations

---

## 🤝 Contributing

We welcome contributions from the community! Tiny11 Automated serves **2,000+ users** worldwide.

### Ways to Contribute

- 🐛 [Report bugs](https://github.com/kelexine/tiny11-automated/issues/new?template=bug_report.yml)
- ✨ [Request features](https://github.com/kelexine/tiny11-automated/issues/new?template=feature_request.yml)
- 📝 Improve documentation
- 🧪 Test new builds
- 💻 Submit pull requests
- 🌍 Translate documentation
- ⭐ Star the repository

### Contribution Guidelines

1. Read [CONTRIBUTING.md](CONTRIBUTING.md)
2. Fork the repository
3. Create a feature branch (`git checkout -b feature/amazing-feature`)
4. Test your changes locally (see testing section below)
5. Commit with clear messages (`git commit -m 'feat: add amazing feature'`)
6. Push to your fork (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### 🧪 Testing

Build-number parsing tests are in `tests/Test-BuildNumberParsing.Tests.ps1` (Pester):

```powershell
Invoke-Pester .\tests\Test-BuildNumberParsing.Tests.ps1
```

No network access is required to run the test suite.

### Contributor Recognition

All contributors are recognized in:
- Release notes
- CONTRIBUTORS.md file
- Project README

**By contributing, you agree to our [Code of Conduct](CODE_OF_CONDUCT.md) and [MIT License](LICENSE).**

---

## 💬 Community

### Connect With Us

- **🗨️ GitHub Discussions**: [Ask questions](https://github.com/kelexine/tiny11-automated/discussions) - Q&A and ideas
- **🐛 Issue Tracker**: [Report bugs](https://github.com/kelexine/tiny11-automated/issues) - Bug reports only

### Community Stats

- 👥 **Active Users**: 3,000+
- 📥 **Total Downloads**: 19,000+
- 📈 **Weekly Downloads**: 3,000 (growing!)
- ⭐ **GitHub Stars**: 11
- 🍴 **Forks**: 8

### Get Help

1. **Read the docs** - Check README and wiki first
2. **Search issues** - Someone may have asked before
3. **Create discussion** - For general questions
4. **File issue** - For confirmed bugs only

---

## 📝 License

### Licensing Information

- **Tiny11 Automated** (headless scripts, CI/CD): MIT License © 2025 kelexine
- **Inspired by tiny11builder**: Original concept and interactive scripts by [ntdevlabs](https://github.com/ntdevlabs/tiny11builder), MIT License — the headless automation in this project was built on top of that foundation
- **Individual files**: See copyright notices in each file

### MIT License Summary

✅ **Permitted**:
- Commercial use
- Modification
- Distribution
- Private use

❌ **Limitations**:
- No warranty
- No liability

📋 **Conditions**:
- License and copyright notice must be included
- Proper attribution required

**Full license**: [LICENSE](LICENSE)

---

## ⚖️ Disclaimer

### Legal Disclaimer

**This tool is provided "as is" without warranty of any kind, express or implied.**

The authors (kelexine, ntdevlabs) are **NOT responsible** for:

❌ System damage from using modified Windows images  
❌ Data loss or corruption  
❌ Violation of Microsoft's terms of service  
❌ Legal issues from improper use  
❌ Compatibility problems  
❌ Security vulnerabilities  
❌ Performance issues  

### Your Responsibilities

✅ **You must** have a valid Windows license  
✅ **You must** understand the risks  
✅ **You must** backup your data  
✅ **You must** comply with applicable laws  
✅ **You must** use responsibly and ethically  

**Use at your own risk.** See [LICENSE](LICENSE) and [SECURITY.md](SECURITY.md) for details.

---

## 🔗 Important Links

### Official Resources

- **📦 GitHub Repository**: https://github.com/thanhdtr/tiny11-automated
- **🐛 Issue Tracker**: https://github.com/kelexine/tiny11-automated/issues
- **📋 Releases**: https://github.com/kelexine/tiny11-automated/releases (notes only)
- **💬 Discussions**: https://github.com/kelexine/tiny11-automated/discussions

### Related Projects

- **🔧 Original tiny11builder**: https://github.com/ntdevlabs/tiny11builder
- **🪟 Microsoft Windows 11**: https://www.microsoft.com/software-download/windows11
- **🛠️ Windows ADK**: https://learn.microsoft.com/windows-hardware/get-started/adk-install

### Author

- **👨‍💻 kelexine**: [GitHub](https://github.com/kelexine) | [Telegram](https://t,me/kelexine2)
- **✉️ Email**: [Email Me](frankiekelechi@gmail.com)
- **💖 Sponsor**: [GitHub Sponsors](https://github.com/sponsors/kelexine) or [Buy Me a Coffee](https://buymeacoffee.com/kelexine)

---

## 🙏 Acknowledgments

### Special Thanks

- **ntdevlabs** - Creator of original tiny11builder
- **Microsoft** - Windows 11 operating system
- **Community contributors** - Bug reports, feature requests, and PRs
- **2,000+ users worldwide** - Your feedback drives improvement

### Support the Project

If Tiny11 Automated has helped you:

- ⭐ **Star the repository** - Show your support
- 🍴 **Fork and contribute** - Help improve it
- 📢 **Share with others** - Spread the word
- 💖 **Sponsor development** - Fund new features (optional)
