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
        } elseif ($row.Image -eq 'ghidra') {
            Write-Info ("image {0,-9} not built (optional, phase 2)" -f $row.Image)
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
    Write-Host "  4) ghidra    - disassembly (phase 2; large download)"
    $pick = Read-Host "Which"
    $noCache = Confirm-Action "Build without cache?"
    switch ($pick) {
        '1' { Build-Image -Name esptool  -NoCache:$noCache | Out-Null }
        '2' { Build-Image -Name analysis -NoCache:$noCache | Out-Null }
        '3' {
            Build-Image -Name esptool  -NoCache:$noCache | Out-Null
            Build-Image -Name analysis -NoCache:$noCache | Out-Null
        }
        '4' { Build-Image -Name ghidra   -NoCache:$noCache | Out-Null }
        default { Write-Warn "Nothing selected." }
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
    Write-Host "  SETUP" -ForegroundColor Yellow
    Write-Host "    1) Environment check                 2) Build / rebuild images"
    Write-Host "    3) USB device manager                4) Select / create target"
    Write-Host "    V) Recreate host venv"
    Write-Host "  HARDWARE  (read-only)" -ForegroundColor Yellow
    Write-Host "    5) Identify chip                     6) Read eFuses / security posture"
    Write-Host "    7) Read partition table              8) Serial monitor / boot log"
    Write-Host "  ACQUIRE" -ForegroundColor Yellow
    Write-Host "    9) Full acquisition (5+6+7+10)      10) Dump full flash"
    Write-Host "   11) Dump a region"
    Write-Host "  ANALYSE  (offline)" -ForegroundColor Yellow
    Write-Host "   12) Full analysis pipeline           13) Triage a dump"
    Write-Host "   14) Split partitions                 15) Extract filesystems"
    Write-Host "   16) Dump NVS                         17) Hunt flags / secrets"
    Write-Host "  WORKSPACE" -ForegroundColor Yellow
    Write-Host "   18) View reports                     19) Verify artefact hashes"
    Write-Host "   20) Workspace summary"
    Write-Host "  SHELLS" -ForegroundColor Yellow
    Write-Host "   21) Shell in esptool container       22) Shell in analysis container"
    Write-Host "  INFO" -ForegroundColor Yellow
    Write-Host "   23) Docs / playbook                   q) Quit"
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkCyan
}

function Invoke-MenuChoice {
    param([string]$Choice)
    switch ($Choice) {
        '1'  { Invoke-EnvironmentCheck }
        '2'  { Invoke-BuildImages }
        '3'  { Invoke-DeviceManager }
        '4'  { Invoke-TargetManager }
        'v'  { Initialize-Venv -Force | Out-Null }
        '5'  { Invoke-Hardware -Command @('esp-detect.sh') }
        '6'  { Invoke-Hardware -Command @('esp-efuse.sh') }
        '7'  { Invoke-Hardware -Command @('esp-parttable.sh') }
        '8'  { Invoke-Monitor }
        '9'  { Invoke-Hardware -Command @('esp-acquire.sh') }
        '10' { Invoke-Hardware -Command @('esp-dump.sh') }
        '11' { Invoke-DumpRegion }
        '12' { Invoke-Analysis -Command @('fw-pipeline.sh') }
        '13' { Invoke-Analysis -Command @('fw-triage.sh') }
        '14' { Invoke-Analysis -Command @('fw-split.py') }
        '15' { Invoke-Analysis -Command @('fw-fs.py') }
        '16' { Invoke-Analysis -Command @('fw-nvs.py') }
        '17' { Invoke-Analysis -Command @('fw-hunt.sh') }
        '18' { Show-Reports }
        '19' { if (Assert-Target) { Invoke-HostPython -Script 'verify.py' -Arguments @((Get-TargetPath)) } }
        '20' { Invoke-HostPython -Script 'summary.py' -Arguments @((Get-WorkspaceRoot)) }
        '21' { if (Assert-Target) { Enter-ContainerShell -Image esptool -WithDevice } }
        '22' { if (Assert-Target) { Enter-ContainerShell -Image analysis } }
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

# A first run has nothing built and no target; say so once rather than letting
# the operator discover it one failed menu item at a time.
if (-not (Test-ImageExists 'esptool') -or -not (Test-ImageExists 'analysis')) {
    Write-Host ""
    Write-Warn "Tool images are not built yet - run [2] before working on hardware."
}

try {
    while ($true) {
        Show-Menu
        $choice = (Read-Host "Choice").Trim().ToLower()
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
