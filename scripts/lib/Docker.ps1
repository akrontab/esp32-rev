# Docker.ps1 - image lifecycle and container invocation.
#
# Two images with deliberately different privileges:
#   esp32-re/esptool  - gets --device for the badge, is the only image that
#                       ever touches hardware
#   esp32-re/analysis - gets the workspace only, never a device, so analysis
#                       can never accidentally write to the badge

# Note: there is no BLE image. Bluetooth cannot be containerised on Docker
# Desktop / WSL2 - AF_BLUETOOTH sockets fail with EAFNOSUPPORT even in a
# privileged --net=host container, because the WSL2 VM kernel does not expose
# the Bluetooth socket family to containers. BLE runs host-side in the venv
# via bleak's native Windows backend instead. See docs/ble.md.
$script:Images = @{
    esptool  = 'esp32-re/esptool:latest'
    analysis = 'esp32-re/analysis:latest'
    hashcat  = 'esp32-re/hashcat:latest'
    ghidra   = 'esp32-re/ghidra:latest'
}

function Test-DockerReady {
    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Err "docker not found on PATH."; return $false }
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker daemon is not responding. Start Docker Desktop and retry."
        return $false
    }
    return $true
}

function Test-ImageExists {
    param([Parameter(Mandatory)][string]$Name)
    $tag = $script:Images[$Name]
    $id = docker images -q $tag 2>$null
    return -not [string]::IsNullOrWhiteSpace($id)
}

function Get-ImageStatus {
    $rows = foreach ($n in 'esptool', 'analysis', 'hashcat', 'ghidra') {
        $tag = $script:Images[$n]
        $info = docker images --format '{{.Size}}|{{.CreatedSince}}' $tag 2>$null | Select-Object -First 1
        if ($info) {
            $p = $info -split '\|'
            [pscustomobject]@{ Image = $n; Status = 'built'; Size = $p[0]; Built = $p[1] }
        } else {
            [pscustomobject]@{ Image = $n; Status = 'missing'; Size = '-'; Built = '-' }
        }
    }
    $rows
}

function Build-Image {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$NoCache
    )
    if (-not $script:Images.ContainsKey($Name)) { Write-Err "Unknown image '$Name'"; return $false }
    $dockerfile = Join-Path $script:RepoRoot "docker\$Name\Dockerfile"
    if (-not (Test-Path $dockerfile)) {
        Write-Warn "No Dockerfile for '$Name' yet (docker\$Name\Dockerfile)."
        return $false
    }
    Write-Step "Building $($script:Images[$Name]) ..."
    $buildArgs = @('build', '-f', $dockerfile, '-t', $script:Images[$Name])
    if ($NoCache) { $buildArgs += '--no-cache' }
    # Build context is the repo root so the image can COPY scripts/container.
    $buildArgs += $script:RepoRoot
    # Out-Host keeps docker's progress on screen without it becoming this
    # function's return value, which would break the boolean the caller wants.
    & docker @buildArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Err "Build failed for '$Name'."; return $false }
    Write-Ok "Built $($script:Images[$Name])"
    return $true
}

function ConvertTo-DockerPath {
    <# Docker Desktop wants forward slashes; PowerShell hands us backslashes. #>
    param([Parameter(Mandatory)][string]$Path)
    (Resolve-Path $Path).Path -replace '\\', '/'
}

function Invoke-Container {
    <#
      Run a command in one of our images with the target workspace mounted at
      /work. Pass -WithDevice to hand the badge's serial device to the
      container; that is refused unless a device is actually attached.

      This function deliberately returns nothing. The container's own output
      is the point, and anything this emitted on the output stream would force
      callers to pipe - which would swallow that output. The exit code lands
      in $script:LastContainerExit instead.
    #>
    param(
        [Parameter(Mandatory)][string]$Image,
        [Parameter(Mandatory)][string[]]$Command,
        [switch]$WithDevice,
        [switch]$Interactive,
        [string[]]$ExtraArgs = @(),
        [hashtable]$Env = @{}
    )

    $script:LastContainerExit = 1

    if (-not (Test-ImageExists $Image)) {
        Write-Warn "Image '$Image' is not built."
        if (Confirm-Action "Build it now?" -Default) {
            if (-not (Build-Image -Name $Image)) { return }
        } else { return }
    }

    $targetPath = Get-TargetPath
    if (-not $targetPath) { Write-Err "No target selected."; return }
    New-Item -ItemType Directory -Force -Path $targetPath | Out-Null

    $runArgs = @('run', '--rm')
    if ($Interactive) { $runArgs += @('-it') } else { $runArgs += @('-i') }

    $runArgs += @('-v', "$(ConvertTo-DockerPath $targetPath):/work")

    # Environment the container-side scripts rely on (see container/lib/common.sh).
    $envMap = @{
        TARGET = $script:State.Target
        BAUD   = "$($script:State.Baud)"
        CHIP   = "$($script:State.Chip)"
    }
    foreach ($k in $Env.Keys) { $envMap[$k] = $Env[$k] }

    if ($WithDevice) {
        # Resolve the live node rather than trusting the stored path: a
        # re-enumerated badge leaves a stale-but-present dead node that would
        # otherwise be opened and hang. Resolve-BadgeDevice prefers the newest.
        $dev = Resolve-BadgeDevice
        if (-not $dev) {
            Write-Err "No serial device in the Docker VM. Attach the badge via the USB device manager [3]."
            return
        }
        $runArgs += @('--device', "${dev}:${dev}")
        $envMap['SERIAL_PORT'] = $dev
    }

    foreach ($k in $envMap.Keys) {
        if ($null -ne $envMap[$k] -and $envMap[$k] -ne '') { $runArgs += @('-e', "$k=$($envMap[$k])") }
    }

    $runArgs += $ExtraArgs
    $runArgs += $script:Images[$Image]
    $runArgs += $Command

    # No pipe here: an interactive container needs its TTY, and piping would
    # capture the output we want the operator to see.
    & docker @runArgs
    $script:LastContainerExit = $LASTEXITCODE
    if ($script:LastContainerExit -ne 0) {
        Write-Warn "Container exited with code $script:LastContainerExit"
    }
}

function Invoke-GhidraGui {
    <#
      Start Ghidra's GUI in the container, reachable over noVNC at
      http://localhost:6080/vnc.html. Publishes 6080 to localhost only.
    #>
    $script:LastContainerExit = 1
    if (-not (Test-ImageExists 'ghidra')) {
        Write-Warn "Ghidra image is not built."
        if (Confirm-Action "Build it now? (large)" -Default) {
            if (-not (Build-Image -Name ghidra)) { return }
        } else { return }
    }
    $targetPath = Get-TargetPath
    if (-not $targetPath) { Write-Err "No target selected."; return }

    Write-Info "Ghidra GUI will be at:  http://localhost:6080/vnc.html  (click Connect)"
    Write-Info "The workspace is mounted at /work. Ctrl-C in this window stops it."
    $runArgs = @(
        'run', '--rm', '-it',
        '-p', '127.0.0.1:6080:6080',
        '-v', "$(ConvertTo-DockerPath $targetPath):/work",
        '-e', "TARGET=$($script:State.Target)",
        $script:Images['ghidra'], 'gh-gui.sh'
    )
    & docker @runArgs
    $script:LastContainerExit = $LASTEXITCODE
}

function Enter-ContainerShell {
    param([Parameter(Mandatory)][string]$Image, [switch]$WithDevice)
    Write-Info "Workspace is mounted at /work. Tools are on PATH. 'exit' returns to the menu."
    if ($Image -eq 'hashcat') {
        Invoke-CrackContainer -Command @('/bin/bash') -Interactive:$true
    } else {
        Invoke-Container -Image $Image -Command @('/bin/bash') -Interactive:$true -WithDevice:$WithDevice
    }
}

function Test-GpuInDocker {
    <# One-time check that Docker Desktop exposes the NVIDIA GPU to containers. #>
    docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CrackContainer {
    <#
      Run the hashcat image on the local GPU. Needs --gpus all AND
      NVIDIA_DRIVER_CAPABILITIES=all - the CUDA backend (libnvrtc) is only
      reachable with the full driver capability set, not the default subset.
      Also mounts the gitignored wordlists/ dir so big lists are available
      without rebuilding the image.
    #>
    param([Parameter(Mandatory)][string[]]$Command, [switch]$Interactive)
    $script:LastContainerExit = 1

    if (-not (Test-ImageExists 'hashcat')) {
        Write-Warn "hashcat image is not built."
        if (Confirm-Action "Build it now? (large - CUDA base + rockyou)" -Default) {
            if (-not (Build-Image -Name hashcat)) { return }
        } else { return }
    }

    $targetPath = Get-TargetPath
    if (-not $targetPath) { Write-Err "No target selected."; return }
    New-Item -ItemType Directory -Force -Path $targetPath | Out-Null

    $runArgs = @('run', '--rm')
    if ($Interactive) { $runArgs += '-it' } else { $runArgs += '-i' }
    $runArgs += @(
        '--gpus', 'all',
        '-e', 'NVIDIA_DRIVER_CAPABILITIES=all',
        '-v', "$(ConvertTo-DockerPath $targetPath):/work"
    )
    # Optional shared wordlists dir, mounted read-only if present.
    $wl = Join-Path $script:RepoRoot 'wordlists'
    if (Test-Path $wl) {
        $runArgs += @('-v', "$(ConvertTo-DockerPath $wl):/opt/wordlists/extra:ro")
    }
    $runArgs += $script:Images['hashcat']
    $runArgs += $Command

    & docker @runArgs
    $script:LastContainerExit = $LASTEXITCODE
    if ($script:LastContainerExit -ne 0) {
        Write-Warn "hashcat container exited with code $script:LastContainerExit"
    }
}
