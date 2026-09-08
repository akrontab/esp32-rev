# Venv.ps1 - project-local Python virtual environment for host-side helpers.
#
# All firmware tooling runs in containers. This venv exists only for the host
# helpers under scripts/host (reports, hash verification, quick dump parsing,
# serial diagnostics) and keeps their dependencies out of the system Python,
# which is the same isolation goal the containers serve.

function Get-VenvPaths {
    $venv = Join-Path $script:RepoRoot '.venv'
    [pscustomobject]@{
        Root    = $venv
        Python  = Join-Path $venv 'Scripts\python.exe'
        Pip     = Join-Path $venv 'Scripts\pip.exe'
        Scripts = Join-Path $venv 'Scripts'
        Stamp   = Join-Path $venv '.requirements.sha256'
    }
}

function Find-HostPython {
    <#
      Locate a usable host interpreter. The Windows Store stub for 'python'
      exits 9009 and opens the Store instead of running, so every candidate is
      probed by actually executing it.
    #>
    $candidates = @()
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) { $candidates += ,@($py.Source, @('-3')) }
    foreach ($name in 'python', 'python3') {
        foreach ($cmd in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
            $candidates += ,@($cmd.Source, @())
        }
    }
    foreach ($c in $candidates) {
        $exe, $pre = $c
        try {
            $probe = @($pre + @('-c', 'import sys; print(sys.version_info[0]*100+sys.version_info[1])'))
            $out = & $exe @probe 2>$null
            if ($LASTEXITCODE -eq 0 -and $out -match '^\d+$' -and [int]$out -ge 308) {
                return [pscustomobject]@{ Exe = $exe; Prefix = $pre; Version = $out }
            }
        } catch { continue }
    }
    return $null
}

function Get-RequirementsHash {
    $req = Join-Path $script:RepoRoot 'requirements.txt'
    if (-not (Test-Path $req)) { return '' }
    (Get-FileHash -Path $req -Algorithm SHA256).Hash
}

function Initialize-Venv {
    <#
      Create the venv if absent, install/refresh pinned requirements when
      requirements.txt has changed, then activate it for this session.
      Returns $true when the venv is usable.
    #>
    param([switch]$Force, [switch]$Quiet)

    $v = Get-VenvPaths

    if ($Force -and (Test-Path $v.Root)) {
        Write-Step "Removing existing venv for a clean rebuild"
        Remove-Item -Recurse -Force $v.Root
    }

    if (-not (Test-Path $v.Python)) {
        $hostPy = Find-HostPython
        if (-not $hostPy) {
            Write-Warn "No host Python 3.8+ found. Host-side helpers will be unavailable."
            Write-Info "Container tooling still works - only scripts/host needs this."
            Write-Info "Install Python from python.org or the Store, then re-run option [V]."
            return $false
        }
        Write-Step "Creating venv at .venv (host Python $($hostPy.Version -replace '^(\d)(\d\d)$','$1.$2'))"
        $mkvenv = @($hostPy.Prefix + @('-m', 'venv', $v.Root))
        & $hostPy.Exe @mkvenv
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $v.Python)) {
            Write-Err "venv creation failed (exit $LASTEXITCODE)"
            return $false
        }
        # Force a dependency install on a freshly created venv.
        if (Test-Path $v.Stamp) { Remove-Item $v.Stamp -Force }
    }

    # Install requirements only when they changed - keeps startup fast.
    $wantHash = Get-RequirementsHash
    $haveHash = if (Test-Path $v.Stamp) { (Get-Content $v.Stamp -Raw).Trim() } else { '' }
    if ($wantHash -and $wantHash -ne $haveHash) {
        Write-Step "Installing pinned host requirements"
        & $v.Python -m pip install --quiet --disable-pip-version-check --upgrade pip
        & $v.Python -m pip install --quiet --disable-pip-version-check -r (Join-Path $script:RepoRoot 'requirements.txt')
        if ($LASTEXITCODE -ne 0) {
            Write-Err "pip install failed (exit $LASTEXITCODE). Host helpers may not work."
            return $false
        }
        Set-Content -Path $v.Stamp -Value $wantHash -NoNewline
        Write-Ok "Host requirements installed"
    }

    Enable-Venv
    if (-not $Quiet) { Write-Ok "venv active: $($v.Root)" }
    return $true
}

function Enable-Venv {
    <#
      Activate in-process. We set the environment directly rather than dot-
      sourcing Activate.ps1 because that script is blocked under a Restricted
      execution policy - this achieves the same result with no policy change.
    #>
    $v = Get-VenvPaths
    if (-not (Test-Path $v.Python)) { return $false }
    if ($env:VIRTUAL_ENV -eq $v.Root) { return $true }

    if (-not $script:OriginalPath) { $script:OriginalPath = $env:PATH }
    $env:VIRTUAL_ENV = $v.Root
    $env:PATH = "$($v.Scripts);$($script:OriginalPath)"
    # Stop the venv from inheriting user site-packages, matching Activate.ps1.
    $env:PYTHONHOME = $null
    # Our host helpers import the same format parsers the containers use.
    $env:PYTHONPATH = Join-Path $script:RepoRoot 'scripts\container\lib'
    return $true
}

function Disable-Venv {
    if ($script:OriginalPath) { $env:PATH = $script:OriginalPath }
    $env:VIRTUAL_ENV = $null
    $env:PYTHONPATH = $null
}

function Get-VenvStatus {
    $v = Get-VenvPaths
    if (-not (Test-Path $v.Python)) { return 'not created' }
    $active = if ($env:VIRTUAL_ENV -eq $v.Root) { 'active' } else { 'inactive' }
    $haveHash = ''
    if (Test-Path $v.Stamp) { $haveHash = (Get-Content $v.Stamp -Raw).Trim() }
    if ((Get-RequirementsHash) -ne $haveHash) { return "$active (requirements changed)" }
    return $active
}

function Invoke-HostPython {
    <# Run one of scripts/host/*.py inside the venv. #>
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @())
    $v = Get-VenvPaths
    if (-not (Test-Path $v.Python)) {
        Write-Warn "Host venv is not available; run option [V] first."
        return
    }
    Enable-Venv | Out-Null
    & $v.Python (Join-Path $script:RepoRoot "scripts\host\$Script") @Arguments
}
