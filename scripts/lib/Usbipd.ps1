# Usbipd.ps1 - getting the badge's USB serial adapter into the Docker VM.
#
# Windows cannot hand a COM port to a Linux container directly. The path we
# use is:
#     badge USB --> usbipd bind (host, one-off, admin)
#               --> usbipd attach --wsl docker-desktop
#               --> /dev/ttyUSB0 inside the Docker Desktop WSL VM
#               --> docker run --device=/dev/ttyUSB0
# Containers run in that same VM, so the device node is directly usable.

# The WSL distribution that backs Docker Desktop's engine. Attaching here (and
# not to a user distro) is what makes the device visible to containers.
$script:DockerDistro = 'docker-desktop'

# USB-serial bridges and native-USB Espressif parts commonly found on badges.
$script:KnownSerialIds = @{
    '10c4:ea60' = 'Silicon Labs CP2102/CP2102N'
    '10c4:ea70' = 'Silicon Labs CP2105'
    '1a86:7523' = 'WCH CH340'
    '1a86:5523' = 'WCH CH341'
    '1a86:55d3' = 'WCH CH9102 (native)'
    '1a86:55d4' = 'WCH CH9102F'
    '0403:6001' = 'FTDI FT232R'
    '0403:6010' = 'FTDI FT2232'
    '0403:6014' = 'FTDI FT232H'
    '0403:6015' = 'FTDI FT231X'
    '303a:1001' = 'Espressif USB JTAG/serial (S2/S3/C3/C6)'
    '303a:0002' = 'Espressif ESP32-S2 CDC'
    '303a:4001' = 'Espressif USB device'
    '2341:0043' = 'Arduino-style CDC'
}

function Test-UsbipdReady {
    $cmd = Get-Command usbipd -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Err "usbipd not found. This is the one host-side component we need."
        Write-Info "Install with:  winget install usbipd"
        return $false
    }
    return $true
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-UsbipdElevated {
    <#
      bind/unbind need admin; attach/detach do not. Rather than demand the
      whole control plane run elevated, we raise a single UAC prompt for just
      this one command.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (Test-IsAdmin) {
        # Out-Host so usbipd's own messages reach the operator instead of
        # becoming this function's return value.
        & usbipd @Arguments | Out-Host
        return $LASTEXITCODE
    }
    Write-Info "This step needs Administrator - approve the UAC prompt."
    $p = Start-Process -FilePath 'usbipd' -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}

function Get-UsbDevices {
    <# Parse 'usbipd state' JSON into something we can reason about. #>
    if (-not (Test-UsbipdReady)) { return @() }
    $raw = usbipd state 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }
    try { $state = $raw | ConvertFrom-Json } catch { return @() }

    foreach ($d in $state.Devices) {
        $vidpid = ''
        if ($d.InstanceId -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
            $vidpid = "$($Matches[1]):$($Matches[2])".ToLower()
        }
        [pscustomobject]@{
            BusId       = $d.BusId
            Description = $d.Description
            HardwareId  = $vidpid
            KnownAs     = $script:KnownSerialIds[$vidpid]
            IsBound     = [bool]$d.PersistedGuid
            IsAttached  = [bool]$d.ClientIPAddress
            IsSerial    = $script:KnownSerialIds.ContainsKey($vidpid)
        }
    }
}

function Show-UsbDevices {
    $devs = @(Get-UsbDevices)
    if (-not $devs) { Write-Warn "No USB devices reported by usbipd."; return @() }
    Write-Rule 'USB devices'
    $i = 1
    foreach ($d in $devs) {
        $flags = @()
        if ($d.IsBound)    { $flags += 'bound' }
        if ($d.IsAttached) { $flags += 'ATTACHED' }
        $flagStr = if ($flags) { '[' + ($flags -join ',') + ']' } else { '' }
        $hint = if ($d.KnownAs) { "  <- $($d.KnownAs)" } else { '' }
        $colour = if ($d.IsSerial) { 'Green' } else { 'Gray' }
        Write-Host ("  {0,2}) {1,-6} {2,-11} {3,-42} {4}{5}" -f `
            $i, $d.BusId, $d.HardwareId, $d.Description.Substring(0, [Math]::Min(42, $d.Description.Length)), $flagStr, $hint) `
            -ForegroundColor $colour
        $i++
    }
    Write-Rule
    return $devs
}

function Get-VmSerialDevices {
    <# Serial device nodes currently visible inside the Docker VM. #>
    $out = wsl.exe -d $script:DockerDistro -- sh -c 'ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null' 2>$null
    if (-not $out) { return @() }
    @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DeviceInVm {
    param([Parameter(Mandatory)][string]$DevicePath)
    (Get-VmSerialDevices) -contains $DevicePath
}

# vhci_hcd carries the USB/IP transport; the rest are the drivers that claim a
# badge once it arrives. Loading them all up front is cheap and avoids the
# worst failure mode in this whole pipeline.
$script:VmModules = @(
    'vhci-hcd',     # USB/IP virtual host controller - without it, attach fails
    'cdc-acm',      # native-USB parts: ESP32-S2/S3/C3/C6 -> /dev/ttyACM*
    'cp210x',       # Silicon Labs CP210x  -> /dev/ttyUSB*
    'ch341',        # WCH CH340/CH341
    'ftdi_sio',     # FTDI
    'pl2303'        # Prolific
)

function Initialize-UsbipdVm {
    <#
      Prepare the Docker VM's kernel to receive the badge.

      Docker Desktop loads none of these at boot, and module autoloading does
      not fire for a usbip-attached device. Without the right driver the
      device attaches at USB level and then sits there with nothing claiming
      it: usbipd reports success, dmesg shows the device, and no /dev node
      ever appears. Loading them explicitly is a no-op when already present.
    #>
    # Not named $script - that prefix is PowerShell's scope qualifier and
    # reads as a bug even where it parses.
    $modprobeCmd = ($script:VmModules | ForEach-Object { "modprobe $_ 2>/dev/null" }) -join '; '
    wsl.exe -d $script:DockerDistro -- sh -c "$modprobeCmd; true" 2>&1 | Out-Null
}

function Connect-BadgeDevice {
    <#
      Bind (share) then attach a device to the Docker VM, and remember which
      /dev node appeared so containers can be given it.
    #>
    param(
        [Parameter(Mandatory)][string]$BusId,
        [string]$HardwareId,
        [switch]$AutoAttach
    )

    if (-not (Test-UsbipdReady)) { return $false }
    Initialize-UsbipdVm

    $before = @(Get-VmSerialDevices)

    $dev = (Get-UsbDevices | Where-Object BusId -eq $BusId)
    if (-not $dev) { Write-Err "Bus ID $BusId not found."; return $false }

    if (-not $dev.IsBound) {
        Write-Step "Sharing $BusId with usbipd (one-time per device)"
        $rc = Invoke-UsbipdElevated @('bind', '--busid', $BusId)
        if ($rc -ne 0) { Write-Err "usbipd bind failed (exit $rc)."; return $false }
    }

    Write-Step "Attaching $BusId to the Docker VM ($script:DockerDistro)"
    $attachArgs = @('attach', '--wsl', $script:DockerDistro, '--busid', $BusId)
    if ($AutoAttach) {
        # Re-attaches automatically when the badge resets and re-enumerates,
        # which native-USB parts (S3/C3/C6) do on every reboot.
        $attachArgs += '--auto-attach'
        Write-Info "Auto-attach keeps a window busy; close it to stop re-attaching."
        Start-Process -FilePath 'usbipd' -ArgumentList $attachArgs
        Start-Sleep -Seconds 3
    } else {
        & usbipd @attachArgs | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Err "usbipd attach failed."; return $false }
    }

    # Give the VM a moment to probe the device and bind a tty driver.
    $dev = $null
    foreach ($try in 1..10) {
        Start-Sleep -Milliseconds 500
        $after = @(Get-VmSerialDevices)
        $new = @($after | Where-Object { $before -notcontains $_ })
        if ($new) { $dev = $new[0]; break }
        if ($after -and $try -ge 6) { $dev = $after[0]; break }
    }

    if (-not $dev) {
        Write-Err "Device attached but no /dev/ttyUSB* or /dev/ttyACM* appeared."
        Write-Info "The VM may lack a driver for this bridge, or the badge needs its cable reseated."
        Write-Info "Check with:  wsl -d $script:DockerDistro -- dmesg | tail -20"
        return $false
    }

    Update-State @{ BusId = $BusId; HardwareId = $HardwareId; DevicePath = $dev }
    Write-Ok "Badge available in containers as $dev"
    return $true
}

function Disconnect-BadgeDevice {
    param([string]$BusId = $script:State.BusId)
    if (-not $BusId) { Write-Warn "No device recorded as attached."; return }
    Write-Step "Detaching $BusId"
    & usbipd detach --busid $BusId | Out-Host
    Update-State @{ DevicePath = $null }
    Write-Ok "Detached. The device is back on Windows (as a COM port)."
}

function Get-DeviceStatusLine {
    $s = $script:State
    if (-not $s.DevicePath) { return 'no device attached' }
    if (Test-DeviceInVm $s.DevicePath) { return "$($s.DevicePath) (bus $($s.BusId))" }
    return "$($s.DevicePath) - MISSING, re-attach"
}
