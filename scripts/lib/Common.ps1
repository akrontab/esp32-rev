# Common.ps1 - shared output, state and workspace handling for the control plane.

$script:StateFile = Join-Path $script:RepoRoot '.badge-state.json'

# --- output -----------------------------------------------------------------

function Write-Info  { param([string]$m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Step  { param([string]$m) Write-Host "[>] $m" -ForegroundColor Blue }
function Write-Ok    { param([string]$m) Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "[x] $m" -ForegroundColor Red }
function Write-Rule  { param([string]$t = '')
    $w = 74
    if ($t) {
        $line = "-- $t " + ('-' * [Math]::Max(0, $w - $t.Length - 4))
    } else {
        $line = '-' * $w
    }
    Write-Host $line -ForegroundColor DarkGray
}

function Confirm-Action {
    param([string]$Prompt, [switch]$Default)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($ans)) { return [bool]$Default }
    return $ans -match '^(y|yes)$'
}

# --- persistent state -------------------------------------------------------
# Survives between runs so you do not re-pick the target and port every time.

function Get-State {
    if (Test-Path $script:StateFile) {
        try { return Get-Content $script:StateFile -Raw | ConvertFrom-Json } catch { }
    }
    [pscustomobject]@{
        Target     = $null
        Chip       = 'auto'
        Baud       = 460800
        BusId      = $null
        HardwareId = $null
        DevicePath = $null
        FlashSize  = $null
    }
}

function Set-State {
    param([Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StateFile -Encoding UTF8
    $script:State = $State
}

function Update-State {
    param([hashtable]$Values)
    $s = $script:State
    foreach ($k in $Values.Keys) {
        # Add-Member is needed for keys absent from an older state file.
        if ($s.PSObject.Properties.Name -contains $k) { $s.$k = $Values[$k] }
        else { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Values[$k] }
    }
    Set-State $s
}

# --- workspaces -------------------------------------------------------------
# One directory per badge/target, holding every artefact for that engagement.

function Get-WorkspaceRoot { Join-Path $script:RepoRoot 'workspace' }

function Get-TargetPath {
    param([string]$Target = $script:State.Target)
    if (-not $Target) { return $null }
    Join-Path (Get-WorkspaceRoot) $Target
}

function Get-Targets {
    $root = Get-WorkspaceRoot
    if (-not (Test-Path $root)) { return @() }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
}

function New-Target {
    param([Parameter(Mandatory)][string]$Name)
    # Keep names filesystem- and container-safe; they become path components.
    $safe = ($Name -replace '[^\w\.-]', '_').Trim('_')
    if (-not $safe) { Write-Err "Invalid target name."; return $null }
    $path = Join-Path (Get-WorkspaceRoot) $safe
    foreach ($sub in 'meta', 'dumps', 'parts', 'extract', 'reports', 'logs') {
        New-Item -ItemType Directory -Force -Path (Join-Path $path $sub) | Out-Null
    }
    $notes = Join-Path $path 'NOTES.md'
    if (-not (Test-Path $notes)) {
        $tpl = Join-Path $script:RepoRoot 'docs\findings-template.md'
        if (Test-Path $tpl) {
            (Get-Content $tpl -Raw).Replace('{{TARGET}}', $safe).Replace('{{DATE}}', (Get-Date -Format 'yyyy-MM-dd')) |
                Set-Content $notes -Encoding UTF8
        }
    }
    Write-Ok "Target workspace ready: workspace\$safe"
    return $safe
}

function Assert-Target {
    <# Most actions are meaningless without a target; offer to make one. #>
    if ($script:State.Target -and (Test-Path (Get-TargetPath))) { return $true }
    Write-Warn "No target selected."
    $name = Read-Host "Name this badge/target (e.g. defcon-badge)"
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $safe = New-Target -Name $name
    if (-not $safe) { return $false }
    Update-State @{ Target = $safe }
    return $true
}

function Get-ArtifactPath {
    param([Parameter(Mandatory)][string]$Relative)
    Join-Path (Get-TargetPath) $Relative
}

function Test-DumpPresent {
    $d = Get-ArtifactPath 'dumps\flash_full.bin'
    return (Test-Path $d)
}
