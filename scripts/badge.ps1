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
        } elseif ($row.Image -in 'ghidra', 'hashcat', 'arduino') {
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
    Write-Host "  6) arduino   - reference builder for Ghidra name recovery (docs/name-recovery.md)"
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
        '6' { Build-Image -Name arduino  -NoCache:$noCache | Out-Null }
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

function Get-GhidraCandidates {
    # The partitions worth offering to Ghidra, read from the split manifest
    # (meta\parts_manifest.json, which already classifies each one) or, failing
    # that, the raw parts\*.bin files. ESP code images are flagged IsImage.
    $cands = @()
    $manifestPath = Get-ArtifactPath 'meta\parts_manifest.json'
    if (Test-Path $manifestPath) {
        $manifest = $null
        try { $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { }
        foreach ($p in $manifest) {
            $full = Get-ArtifactPath ($p.file -replace '/', '\')
            if (-not (Test-Path $full)) { continue }
            $cands += [pscustomobject]@{
                Label   = $p.label
                File    = $p.file
                KB      = [math]::Round($p.size / 1KB)
                Class   = "$($p.classification)"
                IsImage = ("$($p.classification)" -like 'ESP image*')
            }
        }
    }
    if (-not $cands) {
        $partsDir = Get-ArtifactPath 'parts'
        if (Test-Path $partsDir) {
            foreach ($f in Get-ChildItem $partsDir -Filter '*.bin' | Sort-Object Name) {
                $cands += [pscustomobject]@{
                    Label   = [IO.Path]::GetFileNameWithoutExtension($f.Name)
                    File    = "parts/$($f.Name)"
                    KB      = [math]::Round($f.Length / 1KB)
                    Class   = '(unclassified - run [14] split for details)'
                    IsImage = $true
                }
            }
        }
    }
    # ESP images first, so the natural default is a real app image.
    @($cands | Sort-Object @{ Expression = { -not $_.IsImage } }, Label)
}

function Invoke-GhidraHeadless {
    if (-not (Assert-Target)) { return }

    $cands = Get-GhidraCandidates
    if (-not $cands) {
        Write-Warn "No partitions found. Run [14] split (or [12] pipeline) first to produce parts\."
        return
    }

    Write-Rule 'Ghidra - choose a partition to disassemble'
    $i = 1
    $defaultIdx = 0
    foreach ($c in $cands) {
        if ($defaultIdx -eq 0 -and $c.IsImage) { $defaultIdx = $i }
        $cls = if ($c.Class.Length -gt 50) { $c.Class.Substring(0, 47) + '...' } else { $c.Class }
        $tag = if ($c.IsImage) { '' } else { '   (not code)' }
        Write-Host ("  {0,2}) {1,-10} {2,6} KB  {3}{4}" -f $i, $c.Label, $c.KB, $cls, $tag)
        $i++
    }
    if ($defaultIdx -eq 0) { $defaultIdx = 1 }
    Write-Host "   c) Enter a path manually"
    Write-Host "   (for the bootloader + every app slot in one run, use [36])" -ForegroundColor DarkGray

    $pick = Read-Host "Analyze which [$defaultIdx]"
    if (-not $pick) { $pick = "$defaultIdx" }

    if ($pick -eq 'c') {
        $img = Read-Host "Path under the workspace (e.g. parts/app0.bin)"
        if (-not $img) { return }
    } else {
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $cands.Count) {
            Write-Warn "Not a listed choice."
            return
        }
        $chosen = $cands[$idx - 1]
        if (-not $chosen.IsImage) {
            Write-Warn "$($chosen.Label) is $($chosen.Class) - not an ESP code image; disassembly won't be meaningful."
            if (-not (Confirm-Action "Analyze it anyway?")) { return }
        }
        $img = $chosen.File
    }

    $full = Get-ArtifactPath ($img -replace '/', '\')
    if (-not (Test-Path $full)) {
        Write-Warn "$img not found."
        return
    }
    Write-Info "Headless Ghidra: maps segments at their load addresses, analyzes, exports decompilation + a ranked code-leads.txt."
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

function Invoke-ArduinoReference {
    if (-not (Assert-Target)) { return }

    # Chip from the acquisition metadata (falls back to state / a sane default).
    $chip = ''
    $tj = Get-ArtifactPath 'meta\target.json'
    if (Test-Path $tj) { try { $chip = (Get-Content $tj -Raw | ConvertFrom-Json).chip_arg } catch { } }
    if (-not $chip) { $chip = $script:State.Chip }
    if (-not $chip) { $chip = 'esp32s3' }
    $chip = $chip.ToLower().Replace('-', '')

    # Detected IDF version (from the app descriptor) -> suggest a matching core.
    $idf = ''
    $pm = Get-ArtifactPath 'meta\parts_manifest.json'
    if (Test-Path $pm) {
        try {
            $cls = ((Get-Content $pm -Raw | ConvertFrom-Json) |
                Where-Object { $_.label -like 'app*' } | Select-Object -First 1).classification
            if ($cls -match 'idf=v?(\d+\.\d+\.\d+)') { $idf = $Matches[1] }
        } catch { }
    }
    $suggest = ''
    if ($idf -like '4.4*') { $suggest = '2.0.16' }
    elseif ($idf -like '5.1*') { $suggest = '3.0.7' }

    Write-Rule 'Build an SDK reference for Ghidra name recovery'
    Write-Host "  Chip: $chip"
    if ($idf) { Write-Host "  Badge built with ESP-IDF v$idf (from the app descriptor)." }
    Write-Info "Builds a symbolised reference ELF with arduino-cli so Ghidra can name the SDK"
    Write-Info "functions in the dump. Downloads the core (network); the badge is untouched."
    Write-Info "Match the arduino-esp32 core to the badge's IDF; try a newer/older version and"
    Write-Info "BinDiff if it doesn't line up - see docs\name-recovery.md."

    $label = if ($suggest) { "arduino-esp32 core version [$suggest]" } else { "arduino-esp32 core version [latest]" }
    $ver = Read-Host $label
    if (-not $ver -and $suggest) { $ver = $suggest }   # empty stays empty -> latest

    $profile = if (Confirm-Action "Full profile (pull in WiFi/BLE/ESP-NOW/mbedtls for more symbols)?" -Default) { 'full' } else { 'minimal' }

    Write-Info "Building the reference (core install + compile can take several minutes the first time)."
    Invoke-Container -Image arduino -Command @('arduino-ref.sh', "$ver", "$chip", "$profile") `
        -ExtraArgs @('-v', 'esp32-re-arduino-cache:/root/.arduino15')
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

# ---------------------------------------------------------------------------
# menu model  (nested: a top menu of groups, each opening a submenu). Command
# numbers are unchanged, so docs and muscle memory still hold; a 2-digit
# command number typed anywhere runs it directly.
# ---------------------------------------------------------------------------

$script:MenuGroups = [ordered]@{
    '1' = 'Setup'
    '2' = 'Hardware & Acquire'
    '3' = 'Analyse'
    '4' = 'Workspace'
    '5' = 'Challenge tools'
    '6' = 'Shells & Info'
}

$script:MenuGroupHint = @{
    '1' = 'images, target, venv'
    '2' = 'read the chip, dump it, drive the console'
    '3' = 'offline pipeline, extract, hunt'
    '4' = 'reports, verify, summary'
    '5' = 'BLE, WiFi, hash, Ghidra'
    '6' = 'container shells, docs'
}

# Ordered command catalog. Section renders as a sub-header inside the submenu.
$script:MenuCommands = @(
    [pscustomobject]@{ Id = '1';  Group = '1'; Section = '';          Label = 'Environment check' }
    [pscustomobject]@{ Id = '2';  Group = '1'; Section = '';          Label = 'Build / rebuild images' }
    [pscustomobject]@{ Id = '3';  Group = '1'; Section = '';          Label = 'USB device manager (advanced)' }
    [pscustomobject]@{ Id = '4';  Group = '1'; Section = '';          Label = 'Select / create target' }
    [pscustomobject]@{ Id = 'V';  Group = '1'; Section = '';          Label = 'Recreate host venv' }

    [pscustomobject]@{ Id = '5';  Group = '2'; Section = 'read-only'; Label = 'Identify chip' }
    [pscustomobject]@{ Id = '6';  Group = '2'; Section = 'read-only'; Label = 'Read eFuses / security posture' }
    [pscustomobject]@{ Id = '7';  Group = '2'; Section = 'read-only'; Label = 'Read partition table' }
    [pscustomobject]@{ Id = '8';  Group = '2'; Section = 'read-only'; Label = 'Serial monitor / boot log' }
    [pscustomobject]@{ Id = '24'; Group = '2'; Section = 'read-only'; Label = 'Interactive console (two-way; sends input)' }
    [pscustomobject]@{ Id = '9';  Group = '2'; Section = 'acquire';   Label = 'Full acquisition (5+6+7+10)' }
    [pscustomobject]@{ Id = '10'; Group = '2'; Section = 'acquire';   Label = 'Dump full flash' }
    [pscustomobject]@{ Id = '11'; Group = '2'; Section = 'acquire';   Label = 'Dump a region' }

    [pscustomobject]@{ Id = '12'; Group = '3'; Section = '';          Label = 'Full analysis pipeline' }
    [pscustomobject]@{ Id = '13'; Group = '3'; Section = '';          Label = 'Triage a dump' }
    [pscustomobject]@{ Id = '14'; Group = '3'; Section = '';          Label = 'Split partitions' }
    [pscustomobject]@{ Id = '15'; Group = '3'; Section = '';          Label = 'Extract filesystems' }
    [pscustomobject]@{ Id = '16'; Group = '3'; Section = '';          Label = 'Dump NVS' }
    [pscustomobject]@{ Id = '17'; Group = '3'; Section = '';          Label = 'Hunt flags / secrets' }
    [pscustomobject]@{ Id = '35'; Group = '3'; Section = '';          Label = 'Triage strings (signal vs noise)' }

    [pscustomobject]@{ Id = '18'; Group = '4'; Section = '';          Label = 'View reports (SUMMARY.md, leads.txt)' }
    [pscustomobject]@{ Id = '19'; Group = '4'; Section = '';          Label = 'Verify artefact hashes' }
    [pscustomobject]@{ Id = '20'; Group = '4'; Section = '';          Label = 'Workspace summary' }

    [pscustomobject]@{ Id = '25'; Group = '5'; Section = 'Bluetooth  (host-side via venv)';           Label = 'Scan for BLE devices' }
    [pscustomobject]@{ Id = '26'; Group = '5'; Section = 'Bluetooth  (host-side via venv)';           Label = 'Dump badge GATT + read all' }
    [pscustomobject]@{ Id = '27'; Group = '5'; Section = 'Bluetooth  (host-side via venv)';           Label = 'Notifications / write' }
    [pscustomobject]@{ Id = '31'; Group = '5'; Section = 'WiFi  (capability recon)';                  Label = 'WiFi capabilities (from dump)' }
    [pscustomobject]@{ Id = '32'; Group = '5'; Section = 'WiFi  (capability recon)';                  Label = 'Scan for badge AP (host)' }
    [pscustomobject]@{ Id = '29'; Group = '5'; Section = 'Hash cracking  (local GPU first)';          Label = 'Identify hashes in workspace' }
    [pscustomobject]@{ Id = '30'; Group = '5'; Section = 'Hash cracking  (local GPU first)';          Label = 'Crack locally (GPU)' }
    [pscustomobject]@{ Id = '33'; Group = '5'; Section = 'Disassembly  (Ghidra: Xtensa + RISC-V)';    Label = 'Headless analyze a partition (pick-list)' }
    [pscustomobject]@{ Id = '34'; Group = '5'; Section = 'Disassembly  (Ghidra: Xtensa + RISC-V)';    Label = 'Ghidra GUI (noVNC :6080)' }
    [pscustomobject]@{ Id = '36'; Group = '5'; Section = 'Disassembly  (Ghidra: Xtensa + RISC-V)';    Label = 'Analyze full dump (bootloader + all app slots)' }
    [pscustomobject]@{ Id = '37'; Group = '5'; Section = 'Disassembly  (Ghidra: Xtensa + RISC-V)';    Label = 'Build SDK reference for name recovery' }

    [pscustomobject]@{ Id = '21'; Group = '6'; Section = 'shells';    Label = 'Shell in esptool container' }
    [pscustomobject]@{ Id = '22'; Group = '6'; Section = 'shells';    Label = 'Shell in analysis container' }
    [pscustomobject]@{ Id = '23'; Group = '6'; Section = 'info';      Label = 'Docs / playbook' }
)

# Ids valid for direct entry (case-insensitive), incl. the global quick actions.
$script:ValidIds = @{}
foreach ($c in $script:MenuCommands) { $script:ValidIds[$c.Id.ToLower()] = $true }
foreach ($q in '0', 'r', 'a') { $script:ValidIds[$q] = $true }

function Show-MenuBanner {
    $t = if ($script:State.Target) { $script:State.Target } else { '<none>' }
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor DarkCyan
    Write-Host "  ESP32 BADGE RE - CONTROL PLANE" -ForegroundColor Cyan
    Write-Host ("  target: {0,-22} device: {1}" -f $t, (Get-DeviceStatusLine)) -ForegroundColor DarkGray
    Write-Host "==============================================================================" -ForegroundColor DarkCyan
}

function Show-Menu {
    Show-MenuBanner
    Write-Host "  START HERE" -ForegroundColor Green
    Write-Host "    new badge?  do   0  ->  R  ->  18   (set up, then dump+analyse, then read)" -ForegroundColor Green
    Write-Host "    0) Quick start     R) RUN ALL     18) Read results (reports/SUMMARY.md)"
    Write-Host "  MENUS  (type a number to open a group)" -ForegroundColor Yellow
    foreach ($k in $script:MenuGroups.Keys) {
        Write-Host ("   {0}) {1,-20}{2}" -f $k, $script:MenuGroups[$k], $script:MenuGroupHint[$k])
    }
    Write-Host "    tip: you can still type any command number directly (e.g. 33)" -ForegroundColor DarkGray
    Write-Host "    a) Attach badge     q) Quit" -ForegroundColor DarkGray
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkCyan
}

function Show-Submenu {
    param([Parameter(Mandatory)][string]$Group)
    Show-MenuBanner
    Write-Host ("  {0}   ({1})" -f $script:MenuGroups[$Group].ToUpper(), $script:MenuGroupHint[$Group]) -ForegroundColor Green
    $lastSection = $null
    foreach ($c in $script:MenuCommands | Where-Object { $_.Group -eq $Group }) {
        if ($c.Section -and $c.Section -ne $lastSection) {
            Write-Host ("  {0}" -f $c.Section) -ForegroundColor Yellow
            $lastSection = $c.Section
        }
        Write-Host ("   {0,3}) {1}" -f $c.Id, $c.Label)
    }
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "    b) Back to main menu     q) Quit" -ForegroundColor DarkGray
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
        '37' { Invoke-ArduinoReference }
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
    # $view is 'top' or a group key ('1'..'6'); the loop redraws whichever is
    # current after each action, so running a command from a submenu returns to
    # that submenu.
    $view = 'top'
    while ($true) {
        if ($view -eq 'top') { Show-Menu } else { Show-Submenu -Group $view }
        $label = if ($view -eq 'top') { 'Choice' } else { "$($script:MenuGroups[$view]) >" }
        $raw = Read-Host $label
        # Read-Host returns $null at EOF (piped/redirected input running out);
        # treat that as quit rather than crashing on a null method call.
        if ($null -eq $raw) { break }
        $choice = $raw.Trim().ToLower()
        if ($choice -in 'q', 'quit', 'exit') { break }

        # Resolve the input to a command id to run ($run), or handle navigation.
        $run = $null
        if ($view -eq 'top') {
            if (-not $choice) { continue }
            if ($script:MenuGroups.Contains($choice)) { $view = $choice; continue }  # open a group
            if ($choice -in '0', 'r', 'a', 'v') {
                $run = $choice                                                        # global quick action
            } elseif ($choice.Length -ge 2 -and $script:ValidIds.ContainsKey($choice)) {
                $run = $choice                                                        # 2-digit direct jump
            } else {
                Write-Warn "Pick a group (1-6), a command number (e.g. 33), a) attach, or q) quit."
                Read-Host "Press Enter to continue" | Out-Null
                continue
            }
        } else {
            if (-not $choice -or $choice -in 'b', 'back') { $view = 'top'; continue }  # back to top
            if ($script:ValidIds.ContainsKey($choice)) {
                $run = $choice
            } else {
                Write-Warn "Unknown choice '$choice'. Type a listed number, b) back, or q) quit."
                Read-Host "Press Enter to continue" | Out-Null
                continue
            }
        }

        try {
            Invoke-MenuChoice -Choice $run
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
