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
    Phase B Fix    - ADMIN REQUIRED: takeown, icacls, stop camsvc, truncate file, start camsvc
    Phase C Verify - confirm size ~= 0 KB

  Flags:
    -DryRun    detection only, modifies nothing
    -SelfTest  demo mode: fabricates fake files under %TEMP%, runs the whole flow.
               No admin, never touches the real system. Never use on a real machine.

.PARAMETER TargetFile
  Path to the wal file to inspect/fix. Defaults to the real ProgramData path.

.PARAMETER MinSizeBytes
  Threshold above which the file is considered abnormal. Default 1GB.

.PARAMETER DryRun
  Only detect and report.

.PARAMETER SelfTest
  Demo mode with fabricated files under %TEMP%.
#>
[CmdletBinding()]
param(
    [string]$TargetFile = 'C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db-wal',
    [long]$MinSizeBytes = 1GB,
    [switch]$DryRun,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'

function Write-Step { Write-Host "[STEP] $($args -join ' ')" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[ OK ] $($args -join ' ')" -ForegroundColor Green }
function Write-Warn  { Write-Host "[WARN] $($args -join ' ')" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "[FAIL] $($args -join ' ')" -ForegroundColor Red }

# ---------- SelfTest: fabricate files under TEMP and shrink threshold ----------
$effectiveMin = $MinSizeBytes
$demoRoot = $null
$isDemoTarget = $false
if ($SelfTest) {
    Write-Step "SelfTest demo mode: fabricating fake files under %TEMP% (real system untouched)"
    $demoRoot = Join-Path $env:TEMP "dsh-skill-demo-CapabilityAccess"
    if (Test-Path $demoRoot) { Remove-Item $demoRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $demoRoot -Force | Out-Null

    $normalFile = Join-Path $demoRoot "CapabilityAccessManager.db"   # small -> ignored
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
    Write-Step "DryRun: detection only, nothing modified. Re-run without -DryRun (as Administrator) to fix."
    exit 0
}

# ---------- Phase B: Fix (mirrors the proven runbook) ----------
Write-Step "Phase B fix: takeown -> icacls -> stop camsvc -> truncate -> start camsvc"

if (-not $isDemoTarget) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Fail "ADMIN REQUIRED. Right-click PowerShell -> Run as administrator (title bar must read 'Administrator: Windows PowerShell'), then re-run. Ordinary windows will get access denied on takeown/icacls."
        exit 1
    }

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
