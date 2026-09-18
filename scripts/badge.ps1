<#
.SYNOPSIS
    ESP32 badge reverse-engineering control plane.

.DESCRIPTION
    Single entry point for every task in this project. All tooling runs in
    Docker containers; nothing is installed on the host except usbipd (which
    is what lets a Linux container see the badge's serial port at all) and a
    project-local .venv for host-side helpers.

    Everything here is read-only with respect to the badge. No menu item
    writes to, erases, or fuses anything.

.PARAMETER Target
    Select or create a target workspace and skip the prompt.

.PARAMETER NoVenv
    Skip host venv creation/activation. Container tooling is unaffected.

.EXAMPLE
    .\scripts\badge.ps1
    .\scripts\badge.ps1 -Target defcon-badge
#>
[CmdletBinding()]
param(
    [string]$Target,
    [switch]$NoVenv
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:OriginalPath = $env:PATH

. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Venv.ps1')
. (Join-Path $PSScriptRoot 'lib\Usbipd.ps1')
. (Join-Path $PSScriptRoot 'lib\Docker.ps1')

$script:State = Get-State

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------

function Invoke-EnvironmentCheck {
    Write-Rule 'Environment check'

    $ok = $true

    # Docker
    if (Test-DockerReady) {
        $ver = docker info --format '{{.ServerVersion}} ({{.OSType}})' 2>$null
        Write-Ok "Docker engine $ver"
    } else { $ok = $false }

    # usbipd
    if (Test-UsbipdReady) {
        $uv = (usbipd --version 2>$null | Select-Object -First 1)
        Write-Ok "usbipd $($uv -split '\+' | Select-Object -First 1)"
    } else { $ok = $false }

    # The Docker VM and its USB/IP support - the single most common thing to
    # be wrong, and the least obvious to diagnose from an error message.
    $distros = (wsl.exe -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($distros -contains $script:DockerDistro) {
        Write-Ok "WSL distro '$($script:DockerDistro)' present"
        Initialize-UsbipdVm
        $mod = wsl.exe -d $script:DockerDistro -- sh -c 'lsmod 2>/dev/null | grep -c vhci_hcd' 2>$null
        if ("$mod".Trim() -match '^[1-9]') {
            Write-Ok "vhci_hcd loaded in the Docker VM (USB passthrough available)"
        } else {
            Write-Warn "vhci_hcd is not loaded - USB passthrough will fail"
            Write-Info "Try: wsl -d $($script:DockerDistro) -- modprobe vhci-hcd"
            $ok = $false
        }
    } else {
        Write-Err "WSL distro '$($script:DockerDistro)' not found - is Docker Desktop using the WSL2 backend?"
        $ok = $false
    }

    # Images
    Write-Host ""
    foreach ($row in Get-ImageStatus) {
        if ($row.Status -eq 'built') {
            Write-Ok ("image {0,-9} {1,-8} built {2}" -f $row.Image, $row.Size, $row.Built)
        } elseif ($row.Image -in 'ghidra', 'hashcat') {
            Write-Info ("image {0,-9} not built (optional; build when needed)" -f $row.Image)
        } else {
            Write-Warn ("image {0,-9} not built - use [2]" -f $row.Image)
        }
    }

    # Host venv
    Write-Host ""
    Write-Info "host venv: $(Get-VenvStatus)"

    # Device + target
    Write-Info "device:    $(Get-DeviceStatusLine)"
    Write-Info "target:    $(if ($script:State.Target) { $script:State.Target } else { '<none selected>' })"

    $free = (Get-PSDrive -Name ($script:RepoRoot.Substring(0,1)) -ErrorAction SilentlyContinue).Free
    if ($free) {
        $gb = [math]::Round($free / 1GB, 1)
        if ($gb -lt 5) { Write-Warn "only ${gb} GB free on this drive" }
        else { Write-Info "disk free: ${gb} GB" }
    }

    Write-Rule
    if ($ok) { Write-Ok "Environment looks good." }
    else { Write-Warn "Some checks failed - see above before working on hardware." }
}

# ---------------------------------------------------------------------------
# menu actions
# ---------------------------------------------------------------------------

function Invoke-BuildImages {
    Write-Rule 'Build images'
    Write-Host "  1) esptool   - serial acquisition (small, needed for hardware)"
    Write-Host "  2) analysis  - offline carving and analysis"
    Write-Host "  3) both"
    Write-Host "  4) hashcat   - local GPU hash cracking (CUDA base + rockyou; large)"
    Write-Host "  5) ghidra    - disassembly, Xtensa + RISC-V (large download)"
    Write-Host "  (BLE needs no image - it runs host-side in the venv; see docs/ble.md)"
    $pick = Read-Host "Which"
    $noCache = Confirm-Action "Build without cache?"
    switch ($pick) {
        '1' { Build-Image -Name esptool  -NoCache:$noCache | Out-Null }
        '2' { Build-Image -Name analysis -NoCache:$noCache | Out-Null }
        '3' {
            Build-Image -Name esptool  -NoCache:$noCache | Out-Null
            Build-Image -Name analysis -NoCache:$noCache | Out-Null
        }
        '4' {
            if (-not (Test-GpuInDocker)) {
                Write-Warn "Docker cannot see the NVIDIA GPU (--gpus all failed)."
                Write-Info "The image will still build, but cracking needs GPU passthrough working."
            }
            Build-Image -Name hashcat -NoCache:$noCache | Out-Null
        }
        '5' { Build-Image -Name ghidra   -NoCache:$noCache | Out-Null }
        default { Write-Warn "Nothing selected." }
    }
}

function Invoke-HostBle {
    <#
      Run a BLE tool host-side in the venv, against the Windows Bluetooth
      stack via bleak. Deliberately NOT containerised: Bluetooth does not work
      in Docker Desktop containers (see docs/ble.md). The target workspace is
      passed as WORK so the tools write into workspace\<target>\ as usual.
    #>
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @())
    if (-not (Assert-Target)) { return }
    $v = Get-VenvPaths
    if (-not (Test-Path $v.Python)) {
        Write-Warn "Host venv not available - run [V] first (BLE needs bleak in the venv)."
        return
    }
    Enable-Venv | Out-Null
    $prev = $env:WORK
    $env:WORK = (Get-TargetPath)
    try {
        & $v.Python (Join-Path $script:RepoRoot "scripts\host\ble\$Script") @Arguments
    } finally {
        $env:WORK = $prev
    }
}

function Invoke-WifiCapabilities {
    # Offline: what WiFi the firmware can do + any stored config, from the dump.
    if (-not (Assert-Target)) { return }
    if (-not (Test-DumpPresent)) {
        Write-Warn "No flash dump yet - WiFi capability analysis reads the firmware."
        if (-not (Confirm-Action "Continue anyway?")) { return }
    }
    Invoke-Container -Image analysis -Command @('fw-wifi.py')
}

function Invoke-WifiScan {
    # Live: passive scan for the badge's SoftAP via the Windows WLAN service.
    # Host-side for the same reason as BLE - no adapter passthrough in containers.
    if (-not (Assert-Target)) { return }
    $v = Get-VenvPaths
    if (-not (Test-Path $v.Python)) { Write-Warn "Host venv not available - run [V] first."; return }
    Enable-Venv | Out-Null
    $prev = $env:WORK; $env:WORK = (Get-TargetPath)
    try {
        Write-Info "Passive WLAN scan - looking for a badge access point."
        & $v.Python (Join-Path $script:RepoRoot "scripts\host\wifi\wifi-scan.py")
    } finally { $env:WORK = $prev }
}

function Invoke-GhidraHeadless {
    if (-not (Assert-Target)) { return }
    $img = Read-Host "App image to analyze [parts/app0.bin]"
    if (-not $img) { $img = 'parts/app0.bin' }
    $full = Get-ArtifactPath ($img -replace '/', '\')
    if (-not (Test-Path $full)) {
        Write-Warn "$img not found. Run the analysis pipeline (split) first to produce parts\."
        return
    }
    Write-Info "Headless Ghidra: maps segments at their load addresses, analyzes, exports decompilation."
    Write-Info "This can take several minutes on a full app image."
    Invoke-Container -Image ghidra -Command @('gh-analyze.sh', "/work/$img")
}

function Invoke-GhidraDumpAnalyze {
    if (-not (Assert-Target)) { return }
    $dump = Read-Host "Full flash dump to analyze [dumps/flash_full.bin]"
    if (-not $dump) { $dump = 'dumps/flash_full.bin' }
    $full = Get-ArtifactPath ($dump -replace '/', '\')
    if (-not (Test-Path $full)) {
        Write-Warn "$dump not found. Acquire a full dump first ([9]/[10])."
        return
    }
    Write-Info "Ghidra over the whole dump: bootloader + every app slot that holds firmware."
    Write-Info "Each image is decompiled into reports\ghidra\<image>\. This runs Ghidra once per image."
    Invoke-Container -Image ghidra -Command @('gh-dump.sh', "/work/$dump")
}

function Invoke-HashId {
    if (-not (Assert-Target)) { return }
    Write-Info "Scanning the workspace for hash-shaped strings (strings, NVS, BLE, extracted files)."
    Invoke-CrackContainer -Command @('hash-id.sh', '--scan')
}

function Invoke-CrackLocal {
    if (-not (Assert-Target)) { return }
    Write-Info "Hashes must all be the SAME type in one file. Use [hash-id] first if unsure."
    Write-Info "Put them in workspace\$($script:State.Target)\reports\ (one per line)."
    $file = Read-Host "Hash file name under reports\ [badge-hashes.txt]"
    if (-not $file) { $file = 'badge-hashes.txt' }
    $mode = Read-Host "hashcat mode (-m): SHA-1=100, MD5=0, NTLM=1000, SHA-256=1400, bcrypt=3200"
    if (-not $mode) { Write-Warn "A mode is required (see hash-id output)."; return }
    $custom = Confirm-Action "Also try a wordlist derived from this badge's own strings?" -Default
    $crackArgs = @('crack.sh', '-m', $mode, "/work/reports/$file")
    if ($custom) { $crackArgs += '--custom' }
    Write-Info "Local GPU pass. If nothing cracks in ~30 min, escalate to the Linode rig (docs/hash-cracking.md)."
    Invoke-CrackContainer -Command $crackArgs
}

function Invoke-BleScan {
    $secs = Read-Host "Scan seconds [10]"; if (-not $secs) { $secs = '10' }
    Invoke-HostBle -Script 'ble-scan.py' -Arguments @('--seconds', $secs)
}

function Invoke-BleDump {
    $addr = Read-Host "Badge BD address (from scan, e.g. BC:E1:00:07:0D:03)"
    if (-not $addr) { Write-Warn "Address required."; return }
    Invoke-HostBle -Script 'ble-dump.py' -Arguments @($addr)
}

function Connect-Badge {
    <#
      One-key badge attach. A badge is normally the only USB-serial device
      present, so auto-detect and attach it - no device-list picking. Falls
      back to the full device manager only when it's ambiguous.
    #>
    if (-not (Test-UsbipdReady)) { return }
    Initialize-UsbipdVm
    $serial = @(Get-UsbDevices | Where-Object IsSerial)
    if ($serial.Count -eq 0) {
        Write-Warn "No USB-serial device found."
        Write-Info "Plug the badge in (and check the cable carries data, not just power)."
        Write-Info "For a non-standard bridge, attach it manually via the USB device manager [3]."
        return
    }
    if ($serial.Count -gt 1) {
        Write-Warn "Several USB-serial devices are present - can't guess which is the badge."
        Write-Info "Pick it in the USB device manager [3]."
        return
    }
    $sel = $serial[0]
    Write-Info "Attaching $($sel.KnownAs) ($($sel.BusId) $($sel.HardwareId))"
    Connect-BadgeDevice -BusId $sel.BusId -HardwareId $sel.HardwareId | Out-Null
}

function Invoke-QuickStart {
    <#
      First-run / get-ready flow: build core images, ensure a target, attach
      the badge - the whole setup in one place instead of four menu dives.
      Every step is idempotent, so it's safe to re-run.
    #>
    Write-Rule 'Quick start'

    # 1. Core images (the two always needed; hashcat/ghidra built on demand).
    $need = @()
    if (-not (Test-ImageExists 'esptool'))  { $need += 'esptool' }
    if (-not (Test-ImageExists 'analysis')) { $need += 'analysis' }
    if ($need) {
        Write-Step "Building core images: $($need -join ', ') (a few minutes, one time)"
        foreach ($n in $need) { Build-Image -Name $n | Out-Null }
    } else {
        Write-Ok "Core images already built."
    }

    # 2. Target.
    if ($script:State.Target -and (Test-Path (Get-TargetPath))) {
        Write-Ok "Target: $($script:State.Target)"
    } else {
        $name = Read-Host "Name this badge/target [badge]"
        if (-not $name) { $name = 'badge' }
        $safe = New-Target -Name $name
        if ($safe) { Update-State @{ Target = $safe } }
    }

    # 3. Attach the badge (skippable - you may just want to analyse a dump).
    if (Confirm-Action "Attach the badge now?" -Default) {
        Connect-Badge
    }

    Write-Rule
    if ($script:State.DevicePath) {
        Write-Ok "Ready. Next: [9] full acquisition, then [12] analysis."
    } else {
        Write-Ok "Set up. Attach a badge ([a]) when ready, then [9] acquire; or analyse an existing dump with [12]."
    }
}

function Invoke-DeviceManager {
    while ($true) {
        Write-Host ""
        Write-Rule 'USB device manager'
        Write-Info "In containers the badge appears as: $(Get-DeviceStatusLine)"
        $vmDevs = Get-VmSerialDevices
        if ($vmDevs) { Write-Info "Serial nodes in the Docker VM: $($vmDevs -join ', ')" }
        Write-Host ""
        $devs = @(Show-UsbDevices)
        Write-Host ""
        Write-Host "  a) Attach a device to the Docker VM"
        Write-Host "  p) Attach persistently (auto-reattach on badge reset)"
        Write-Host "  d) Detach the current device"
        Write-Host "  r) Refresh"
        Write-Host "  b) Back"
        $pick = Read-Host "Choice"

        switch ($pick) {
            { $_ -in 'a', 'p' } {
                if (-not $devs) { Write-Warn "No devices."; break }
                $serial = @($devs | Where-Object IsSerial)
                if ($serial.Count -eq 1) {
                    Write-Info "Only one USB-serial device present: $($serial[0].BusId) ($($serial[0].KnownAs))"
                    $sel = $serial[0]
                } else {
                    $n = Read-Host "Device number"
                    $idx = 0
                    if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $devs.Count) {
                        Write-Warn "Invalid selection."; break
                    }
                    $sel = $devs[$idx - 1]
                }
                if (-not $sel.IsSerial) {
                    Write-Warn "$($sel.Description) does not look like a USB-serial device."
                    if (-not (Confirm-Action "Attach it anyway?")) { break }
                }
                Connect-BadgeDevice -BusId $sel.BusId -HardwareId $sel.HardwareId -AutoAttach:($pick -eq 'p') | Out-Null
            }
            'd' { Disconnect-BadgeDevice }
            'r' { }
            'b' { return }
            default { }
        }
    }
}

function Invoke-TargetManager {
    Write-Rule 'Targets'
    $targets = @(Get-Targets)
    if ($targets) {
        $i = 1
        foreach ($t in $targets) {
            $marker = if ($t -eq $script:State.Target) { '*' } else { ' ' }
            $dump = Join-Path (Join-Path (Get-WorkspaceRoot) $t) 'dumps\flash_full.bin'
            $note = if (Test-Path $dump) {
                "dump: $([math]::Round((Get-Item $dump).Length / 1MB, 2)) MB"
            } else { 'no dump yet' }
            Write-Host ("  {0}{1,2}) {2,-28} {3}" -f $marker, $i, $t, $note)
            $i++
        }
    } else {
        Write-Info "No targets yet."
    }
    Write-Host "   n) New target"
    Write-Host "   b) Back"
    $pick = Read-Host "Choice"
    if ($pick -eq 'b') { return }
    if ($pick -eq 'n') {
        $name = Read-Host "Name (e.g. defcon-badge)"
        if ($name) {
            $safe = New-Target -Name $name
            if ($safe) { Update-State @{ Target = $safe }; Write-Ok "Selected target '$safe'" }
        }
        return
    }
    $idx = 0
    if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $targets.Count) {
        Update-State @{ Target = $targets[$idx - 1] }
        Write-Ok "Selected target '$($targets[$idx - 1])'"
    } else {
        Write-Warn "Invalid selection."
    }
}

function Invoke-Hardware {
    param([Parameter(Mandatory)][string[]]$Command, [switch]$Interactive)
    if (-not (Assert-Target)) { return }
    Invoke-Container -Image esptool -Command $Command -WithDevice -Interactive:$Interactive
}

function Invoke-Analysis {
    param([Parameter(Mandatory)][string[]]$Command, [switch]$Interactive)
    if (-not (Assert-Target)) { return }
    if (-not (Test-DumpPresent)) {
        Write-Warn "No dumps\flash_full.bin in this target yet."
        if (-not (Confirm-Action "Continue anyway?")) { return }
    }
    Invoke-Container -Image analysis -Command $Command -Interactive:$Interactive
}

function Invoke-RunAll {
    <#
      Everything read-only in one command: acquire from the badge (chip,
      eFuses, partition table, full flash dump) then run the offline pipeline
      (carve per-partition bins + triage/NVS/hunt reports + the consolidated
      SUMMARY.md). Badge → full report set, one keypress.
    #>
    if (-not (Assert-Target)) { return }
    Write-Rule 'Full run (acquire + analyse)'
    if (-not $script:State.DevicePath -and -not (Get-VmSerialDevices)) {
        Write-Warn "No badge attached. Attach it first with [a] (or [3])."
        if (-not (Confirm-Action "Continue with offline analysis only (needs an existing dump)?")) { return }
    } else {
        Write-Step "1/2  Acquiring from the badge (identify, eFuses, partitions, full dump)"
        Invoke-Container -Image esptool -Command @('esp-acquire.sh') -WithDevice
        if ($script:LastContainerExit -ne 0) {
            Write-Warn "Acquisition had problems (exit $script:LastContainerExit)."
            if (-not (Confirm-Action "Analyse whatever was captured anyway?" -Default)) { return }
        }
    }
    if (-not (Test-DumpPresent)) {
        Write-Err "No flash dump present - nothing to analyse. Fix acquisition, then re-run."
        return
    }
    Write-Step "2/2  Analysing the dump (carve bins + reports + summary)"
    Invoke-Container -Image analysis -Command @('fw-pipeline.sh')
    Write-Rule
    $summary = Get-ArtifactPath 'reports\SUMMARY.md'
    if (Test-Path $summary) {
        Write-Ok "Done. One-page brief: workspace\$($script:State.Target)\reports\SUMMARY.md"
        Write-Info "View it with [18], or open the workspace folder."
    } else {
        Write-Warn "Finished, but no SUMMARY.md was produced - check the output above."
    }
}

function Invoke-Monitor {
    if (-not (Assert-Target)) { return }
    $baud = Read-Host "Console baud [115200]"
    if (-not $baud) { $baud = '115200' }
    $secs = Read-Host "Capture seconds (0 = until Ctrl-C) [60]"
    if (-not $secs) { $secs = '60' }
    $reset = Confirm-Action "Reset the badge first to capture the boot log?" -Default
    $cmd = @('esp-monitor.py', '--baud', $baud, '--seconds', $secs)
    if ($reset) { $cmd += '--reset' }
    Invoke-Hardware -Command $cmd -Interactive
}

function Invoke-Console {
    if (-not (Assert-Target)) { return }
    $baud = Read-Host "Console baud [115200]"
    if (-not $baud) { $baud = '115200' }
    $eol = Read-Host "Enter sends [lf] (lf/cr/crlf - try cr/crlf if the badge ignores commands)"
    if (-not $eol) { $eol = 'lf' }
    if ($eol -notin 'lf', 'cr', 'crlf') { Write-Warn "Not one of lf/cr/crlf; using lf."; $eol = 'lf' }
    $echo = Confirm-Action "Locally echo what you type? (only if the badge doesn't echo)"
    $reset = Confirm-Action "Reset the badge first to catch the boot log?"
    Write-Info "Two-way terminal: badge output is shown + logged; what you type is sent to it."
    Write-Info "Char-at-a-time, so single-key menus work. Press Ctrl-] to quit (no reset)."
    $cmd = @('esp-console.py', '--baud', $baud, '--eol', $eol)
    if ($echo) { $cmd += '--echo' }
    if ($reset) { $cmd += '--reset' }
    Invoke-Hardware -Command $cmd -Interactive
}

function Invoke-DumpRegion {
    if (-not (Assert-Target)) { return }
    Write-Info "Example: address 0x9000, size 0x6000, name nvs"
    $addr = Read-Host "Address"
    $size = Read-Host "Size"
    $name = Read-Host "Name"
    if (-not $addr -or -not $size) { Write-Warn "Address and size are required."; return }
    Invoke-Hardware -Command @('esp-dump.sh', $addr, $size, $name)
}

function Show-Reports {
    if (-not (Assert-Target)) { return }
    $dir = Get-ArtifactPath 'reports'
    if (-not (Test-Path $dir)) { Write-Warn "No reports yet."; return }
    $files = @(Get-ChildItem $dir -File | Sort-Object Name)
    if (-not $files) { Write-Warn "No reports yet."; return }
    Write-Rule 'Reports'
    $i = 1
    foreach ($f in $files) {
        Write-Host ("  {0,2}) {1,-28} {2,8} bytes" -f $i, $f.Name, $f.Length)
        $i++
    }
    Write-Host "   o) Open the workspace folder"
    $pick = Read-Host "View which"
    if ($pick -eq 'o') { Start-Process (Get-TargetPath); return }
    $idx = 0
    if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $files.Count) {
        Get-Content $files[$idx - 1].FullName | Out-Host -Paging
    }
}

function Show-Docs {
    $docs = Join-Path $script:RepoRoot 'docs'
    Write-Rule 'Documentation'
    Get-ChildItem $docs -Filter *.md -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  {0,-28} {1}" -f $_.Name, $_.Directory.Name) }
    Write-Host ""
    Write-Info "Open the folder with: ii docs"
    if (Confirm-Action "Open the playbook now?" -Default) {
        $pb = Join-Path $docs 'playbook.md'
        if (Test-Path $pb) { Get-Content $pb | Out-Host -Paging }
    }
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------

function Show-Menu {
    $t = if ($script:State.Target) { $script:State.Target } else { '<none>' }
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor DarkCyan
    Write-Host "  ESP32 BADGE RE - CONTROL PLANE" -ForegroundColor Cyan
    Write-Host ("  target: {0,-22} device: {1}" -f $t, (Get-DeviceStatusLine)) -ForegroundColor DarkGray
    Write-Host "==============================================================================" -ForegroundColor DarkCyan
    Write-Host "  START HERE" -ForegroundColor Green
    Write-Host "    new badge?  do   0  ->  R  ->  18    (set up, then dump+analyse, then read)" -ForegroundColor Green
    Write-Host "    0) Quick start    build images, choose a target, attach the badge"
    Write-Host "    R) RUN ALL        dump the badge + offline analysis -> reports/SUMMARY.md"
    Write-Host "   18) Read results   open reports/SUMMARY.md, then leads.txt"
    Write-Host "    more:  a) attach badge    20) workspace summary    23) docs    q) quit" -ForegroundColor DarkGray
    Write-Host "  SETUP" -ForegroundColor Yellow
    Write-Host "    1) Environment check                 2) Build / rebuild images"
    Write-Host "    3) USB device manager (advanced)     4) Select / create target"
    Write-Host "    V) Recreate host venv"
    Write-Host "  HARDWARE  (read-only)" -ForegroundColor Yellow
    Write-Host "    5) Identify chip                     6) Read eFuses / security posture"
    Write-Host "    7) Read partition table              8) Serial monitor / boot log"
    Write-Host "   24) Interactive console (two-way; sends input to the badge)"
    Write-Host "  ACQUIRE" -ForegroundColor Yellow
    Write-Host "    9) Full acquisition (5+6+7+10)      10) Dump full flash"
    Write-Host "   11) Dump a region"
    Write-Host "  ANALYSE  (offline)" -ForegroundColor Yellow
    Write-Host "   12) Full analysis pipeline           13) Triage a dump"
    Write-Host "   14) Split partitions                 15) Extract filesystems"
    Write-Host "   16) Dump NVS                         17) Hunt flags / secrets"
    Write-Host "   35) Triage strings (signal vs noise)"
    Write-Host "  WORKSPACE  (the payoff of RUN ALL)" -ForegroundColor Yellow
    Write-Host "   18) View reports                     19) Verify artefact hashes"
    Write-Host "   20) Workspace summary"
    Write-Host "..... CHALLENGE TOOLS  -  reach for these when a lead points you at one ....." -ForegroundColor DarkCyan
    Write-Host "  BLUETOOTH  (BLE challenges - host-side via venv)" -ForegroundColor Yellow
    Write-Host "   25) Scan for BLE devices             26) Dump badge GATT + read all"
    Write-Host "   27) Notifications / write"
    Write-Host "  WIFI  (capability recon)" -ForegroundColor Yellow
    Write-Host "   31) WiFi capabilities (from dump)    32) Scan for badge AP (host)"
    Write-Host "  HASH CRACKING  (local GPU first; Linode rig is manual escalation)" -ForegroundColor Yellow
    Write-Host "   29) Identify hashes in workspace     30) Crack locally (GPU)"
    Write-Host "  DISASSEMBLY  (Ghidra: Xtensa + RISC-V)" -ForegroundColor Yellow
    Write-Host "   33) Headless analyze app image       34) Ghidra GUI (noVNC :6080)"
    Write-Host "   36) Analyze full dump (bootloader + all app slots)"
    Write-Host "  SHELLS" -ForegroundColor Yellow
    Write-Host "   21) Shell in esptool container       22) Shell in analysis container"
    Write-Host "  INFO" -ForegroundColor Yellow
    Write-Host "   23) Docs / playbook                   q) Quit"
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkCyan
}

function Invoke-MenuChoice {
    param([string]$Choice)
    switch ($Choice) {
        '0'  { Invoke-QuickStart }
        'a'  { Connect-Badge }
        'r'  { Invoke-RunAll }
        '1'  { Invoke-EnvironmentCheck }
        '2'  { Invoke-BuildImages }
        '3'  { Invoke-DeviceManager }
        '4'  { Invoke-TargetManager }
        'v'  { Initialize-Venv -Force | Out-Null }
        '5'  { Invoke-Hardware -Command @('esp-detect.sh') }
        '6'  { Invoke-Hardware -Command @('esp-efuse.sh') }
        '7'  { Invoke-Hardware -Command @('esp-parttable.sh') }
        '8'  { Invoke-Monitor }
        '24' { Invoke-Console }
        '9'  { Invoke-Hardware -Command @('esp-acquire.sh') }
        '10' { Invoke-Hardware -Command @('esp-dump.sh') }
        '11' { Invoke-DumpRegion }
        '12' { Invoke-Analysis -Command @('fw-pipeline.sh') }
        '13' { Invoke-Analysis -Command @('fw-triage.sh') }
        '14' { Invoke-Analysis -Command @('fw-split.py') }
        '15' { Invoke-Analysis -Command @('fw-fs.py') }
        '16' { Invoke-Analysis -Command @('fw-nvs.py') }
        '17' { Invoke-Analysis -Command @('fw-hunt.sh') }
        '35' { Invoke-Analysis -Command @('fw-leads.py') }
        '18' { Show-Reports }
        '19' { if (Assert-Target) { Invoke-HostPython -Script 'verify.py' -Arguments @((Get-TargetPath)) } }
        '20' { Invoke-HostPython -Script 'summary.py' -Arguments @((Get-WorkspaceRoot)) }
        '21' { if (Assert-Target) { Enter-ContainerShell -Image esptool -WithDevice } }
        '22' { if (Assert-Target) { Enter-ContainerShell -Image analysis } }
        '25' { Invoke-BleScan }
        '26' { Invoke-BleDump }
        '29' { Invoke-HashId }
        '30' { Invoke-CrackLocal }
        '31' { Invoke-WifiCapabilities }
        '32' { Invoke-WifiScan }
        '33' { Invoke-GhidraHeadless }
        '34' { if (Assert-Target) { Invoke-GhidraGui } }
        '36' { Invoke-GhidraDumpAnalyze }
        '27' {
            $a = Read-Host "Badge BD address"
            $c = Read-Host "Notify characteristic UUID"
            if ($a -and $c) { Invoke-HostBle -Script 'ble-notify.py' -Arguments @($a, '--notify', $c) }
        }
        '23' { Show-Docs }
        default { Write-Warn "Unknown choice '$Choice'" }
    }
}

# ---------------------------------------------------------------------------
# startup
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "ESP32 badge reverse-engineering toolkit" -ForegroundColor Cyan
Write-Host "All tooling runs in containers. Nothing here writes to the badge." -ForegroundColor DarkGray

if (-not $NoVenv) {
    Initialize-Venv -Quiet | Out-Null
}

if ($Target) {
    if ((Get-Targets) -contains $Target) {
        Update-State @{ Target = $Target }
    } else {
        $safe = New-Target -Name $Target
        if ($safe) { Update-State @{ Target = $safe } }
    }
}

# Fresh setup? Offer the one-shot Quick start rather than making the operator
# discover the build/target/attach steps one failed menu item at a time.
if (-not $Target -and (
        -not (Test-ImageExists 'esptool') -or
        -not (Test-ImageExists 'analysis') -or
        -not $script:State.Target)) {
    Write-Host ""
    Write-Info "Looks like a fresh setup (images or target not ready)."
    if (Confirm-Action "Run Quick start now - build images, pick a target, attach the badge?" -Default) {
        Invoke-QuickStart
    } else {
        Write-Info "Run it anytime with [0]. Attach a badge with [a]."
    }
}

try {
    while ($true) {
        Show-Menu
        $raw = Read-Host "Choice"
        # Read-Host returns $null at EOF (piped/redirected input running out);
        # treat that as quit rather than crashing on a null method call.
        if ($null -eq $raw) { break }
        $choice = $raw.Trim().ToLower()
        if ($choice -in 'q', 'quit', 'exit') { break }
        if (-not $choice) { continue }
        try {
            Invoke-MenuChoice -Choice $choice
        } catch {
            Write-Err $_.Exception.Message
            if ($VerbosePreference -eq 'Continue') { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
        }
        Write-Host ""
        Read-Host "Press Enter to return to the menu" | Out-Null
    }
} finally {
    Disable-Venv
}

Write-Host ""
Write-Info "State saved. Workspaces live in workspace\."
