#requires -Version 5.1
<#
.SYNOPSIS
  Fix an abnormally large CapabilityAccessManager.db-wal file (camsvc WAL) per the
  proven runbook: takeown/icacls -> stop camsvc -> TRUNCATE the file -> start camsvc -> verify ~0 KB.

.DESCRIPTION
  Real target (default):
    C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db-wal

  Why truncate, not delete: deleting the file can corrupt the SQLite database used by
  Windows capability access management (camera/mic/location permissions).

  Phases:
    Phase A Detect - report file existence + size vs threshold (default 1GB)
    Phase B Fix    - ADMIN REQUIRED. If the current session is NOT elevated, the script
                     relaunches itself elevated via UAC (Start-Process -Verb RunAs);
                     click "Yes" on the UAC prompt and the fix completes automatically.
    Phase C Verify - confirm size ~= 0 KB

  Flags:
    -DryRun    detection only, modifies nothing
    -SelfTest  demo mode: fabricates fake files under %TEMP%, runs the whole flow.
               No admin, never touches the real system. Never use on a real machine.
    -LogFile   path where the script appends its step output (used by the elevated run
               so the non-elevated caller can show the result afterwards).

.PARAMETER TargetFile
  Path to the wal file to inspect/fix. Defaults to the real ProgramData path.

.PARAMETER MinSizeBytes
  Threshold above which the file is considered abnormal. Default 1GB.

.PARAMETER DryRun
  Only detect and report.

.PARAMETER SelfTest
  Demo mode with fabricated files under %TEMP%.

.PARAMETER LogFile
  Optional file to append step output to.
#>
[CmdletBinding()]
param(
    [string]$TargetFile = 'C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db-wal',
    [long]$MinSizeBytes = 1GB,
    [switch]$DryRun,
    [switch]$SelfTest,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'
$script:LogPath = if ($LogFile) { $LogFile } else { $null }

function Write-Step { Write-LogLine "[STEP] $($args -join ' ')" 'Cyan' }
function Write-Ok    { Write-LogLine "[ OK ] $($args -join ' ')" 'Green' }
function Write-Warn  { Write-LogLine "[WARN] $($args -join ' ')" 'Yellow' }
function Write-Fail  { Write-LogLine "[FAIL] $($args -join ' ')" 'Red' }

function Write-LogLine {
    param([string]$Message, [string]$Color)
    Write-Host $Message -ForegroundColor $Color
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $Message -Encoding UTF8 -ErrorAction Stop } catch {}
    }
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- SelfTest: fabricate files under TEMP and shrink threshold ----------
$effectiveMin = $MinSizeBytes
$demoRoot = $null
$isDemoTarget = $false
if ($SelfTest) {
    Write-Step "SelfTest demo mode: fabricating fake files under %TEMP% (real system untouched)"
    $demoRoot = Join-Path $env:TEMP "dsh-skill-demo-CapabilityAccess"
    if (Test-Path $demoRoot) { Remove-Item $demoRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null

    $normalFile = Join-Path $demoRoot "CapabilityAccessManager.db"     # small -> ignored
    $walFile    = Join-Path $demoRoot "CapabilityAccessManager.db-wal" # big  -> hit
    $fs = [System.IO.File]::Open($normalFile, [System.IO.FileMode]::CreateNew); $fs.SetLength(256KB); $fs.Close()
    $fs = [System.IO.File]::Open($walFile, [System.IO.FileMode]::CreateNew); $fs.SetLength(4MB); $fs.Close()

    $TargetFile = $walFile
    $effectiveMin = 1MB
    $isDemoTarget = $true
    Write-Ok "Fabricated: $normalFile (256KB, ignored) / $walFile (4MB, target)"
}

$dir = Split-Path $TargetFile -Parent

# ---------- Phase A: Detect ----------
Write-Step "Phase A detect: $TargetFile  (threshold >= $effectiveMin)"
if (-not (Test-Path $TargetFile)) {
    Write-Ok "File not found: $TargetFile -> nothing abnormal to fix on this machine."
    if ($SelfTest) { Write-Fail "SelfTest FAILED at detect phase: fabricated target missing."; exit 1 }
    exit 0
}

$item = Get-Item -LiteralPath $TargetFile
$sizeMB = [math]::Round($item.Length / 1MB, 1)
if ($item.Length -ge $effectiveMin) {
    Write-Warn "Offender found: $($item.FullName)  ($sizeMB MB)"
} else {
    Write-Ok "File exists but is only $sizeMB MB (below threshold) -> nothing to fix."
    if ($SelfTest) { Write-Fail "SelfTest FAILED at detect phase: fabricated target was not considered abnormal."; exit 1 }
    exit 0
}

if ($SelfTest) { Write-Ok "SelfTest detect phase passed." }

if ($DryRun) {
    Write-Step "DryRun: detection only, nothing modified. Re-run without -DryRun to fix."
    exit 0
}

# ---------- Elevation gate (real machine only): relaunch elevated via UAC ----------
if (-not $isDemoTarget -and -not (Test-IsAdmin)) {
    Write-Step "Administrator rights required for the fix (takeown/icacls/camsvc)."
    Write-Step "Relaunching elevated via UAC - please click 'Yes' on the User Account Control prompt..."
    $log = Join-Path $env:TEMP ("capability-access-cleaner-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        ('"{0}"' -f $PSCommandPath),
        "-LogFile", ('"{0}"' -f $log)
    )
    if ($PSBoundParameters.ContainsKey('TargetFile') -and $TargetFile -ne 'C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db-wal') {
        $argList += "-TargetFile", ('"{0}"' -f $TargetFile)
    }
    if ($PSBoundParameters.ContainsKey('MinSizeBytes')) {
        $argList += "-MinSizeBytes", [string]$MinSizeBytes
    }
    try {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -Wait -PassThru
        Write-Ok "Elevated run finished (exit code $($p.ExitCode))."
        if (Test-Path $log) {
            Write-Step "Result log:"
            Get-Content -LiteralPath $log -Tail 60 | ForEach-Object { Write-Host "    $_" }
            Write-Ok "Full log: $log"
        }
        exit $p.ExitCode
    } catch {
        Write-Fail "UAC elevation failed or was declined: $($_.Exception.Message)"
        Write-Warn "Alternative: right-click PowerShell -> 'Run as administrator', then run this script again."
        exit 1
    }
}

# ---------- Phase B: Fix (mirrors the proven runbook) ----------
Write-Step "Phase B fix: takeown -> icacls -> stop camsvc -> truncate -> start camsvc"

if (-not $isDemoTarget) {
    Write-Step "takeown /f `"$dir`" /A /R /D Y"
    takeown /f $dir /A /R /D Y | Out-Null
    Write-Step "icacls `"$dir`" /grant Administrators:F /T"
    icacls $dir /grant Administrators:F /T | Out-Null

    Write-Step "Stop-Service -Name camsvc -Force"
    try {
        Stop-Service -Name "camsvc" -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Ok "camsvc stopped."
    } catch {
        Write-Warn "Could not stop camsvc: $($_.Exception.Message)"
    }
}

# Truncate the file (keep the file, empty its content). NEVER delete it.
Write-Step "Truncating file (FileMode.Truncate keeps the file, frees the space)"
try {
    $stream = [System.IO.File]::Open($TargetFile, [System.IO.FileMode]::Truncate)
    $stream.Close()
    Write-Ok "Truncated OK: $TargetFile"
} catch {
    Write-Fail "Truncate failed (file may still be locked): $($_.Exception.Message)"
}

if (-not $isDemoTarget) {
    Write-Step "Start-Service -Name camsvc"
    try {
        Start-Service -Name "camsvc" -ErrorAction Stop
        Write-Ok "camsvc restarted."
    } catch {
        Write-Warn "Could not start camsvc: $($_.Exception.Message)"
    }
}

# ---------- Phase C: Verify ----------
Write-Step "Phase C verify: file size after fix"
$after = Get-Item -LiteralPath $TargetFile
$afterKB = [math]::Round($after.Length / 1KB, 2)
if ($after.Length -lt $effectiveMin) {
    Write-Ok "Verification passed: file is now $afterKB KB (was $sizeMB MB)."
    Write-Ok "If disk space is not released immediately, refresh the filesystem cache (a reboot helps) and rescan."
} else {
    Write-Fail "Verification FAILED: file still $([math]::Round($after.Length/1MB,1)) MB after fix."
    exit 1
}

if ($SelfTest) {
    Write-Ok "SelfTest full flow passed: detect -> fix(truncate) -> verify all OK. Cleaning up demo files..."
    if ($demoRoot -and (Test-Path $demoRoot)) { Remove-Item $demoRoot -Recurse -Force }
}

exit 0
