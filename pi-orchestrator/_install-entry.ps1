# Install a convenient entry point for orchestrator mode.
# Creates a shim on PATH that launches a normal PowerShell window running
# orchestrate.ps1 from the canonical agent-lab directory.
# ASCII-only source: Windows PowerShell 5.1 reads .ps1 as ANSI.

$ErrorActionPreference = "Stop"

# Resolve the launcher relative to this script: <repo>/pi-orchestrator/_install-entry.ps1
# -> <repo>/agent-lab/orchestrate.ps1
$repoRoot = Split-Path -Parent $PSScriptRoot
$lab = Join-Path $repoRoot "agent-lab"
if (-not (Test-Path (Join-Path $lab "orchestrate.ps1"))) {
    Write-Error "orchestrate.ps1 not found under $lab"
    exit 1
}
$shim = Join-Path $env:APPDATA "npm\pi-orchestrator.cmd"

$content = @"
@echo off
rem Entry point for Pi orchestrator mode. Installed by pi-orchestrator/_install-entry.ps1
if "%~1"=="" (
  start "pi-orchestrator" powershell -NoExit -ExecutionPolicy Bypass -File "$lab\orchestrate.ps1"
) else (
  powershell -NoExit -ExecutionPolicy Bypass -File "$lab\orchestrate.ps1" -Task %*
)
"@

Set-Content -LiteralPath $shim -Value $content -Encoding ASCII
Write-Host "installed shim: $shim"
Write-Host ""
Write-Host "usage:"
Write-Host "  pi-orchestrator                       interactive orchestrator window"
Write-Host "  pi-orchestrator ""派一个 doc-worker 分析 ...""   one-shot task"
