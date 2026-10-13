# Assemble this package from working copies in the Pi agent directory.
#
# This is a DEVELOPMENT convenience, not part of using the package. It exists so the
# extensions can be developed live under ~/.pi/agent/extensions/ and then copied here.
# Users do not need it.
#
# ASCII-only source: Windows PowerShell 5.1 reads .ps1 as ANSI.

$ErrorActionPreference = "Stop"

$pkg  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$agentDir = Join-Path $env:USERPROFILE ".pi\agent"
$lab  = Join-Path (Split-Path -Parent $pkg) "agent-lab"

# --- extensions ---------------------------------------------------------------
foreach ($name in @("subagent", "guard")) {
    $dst = Join-Path $pkg "extensions\$name"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item (Join-Path $agentDir "extensions\$name\*") $dst -Recurse -Force
    Write-Host "extensions/$name  <- copied"
}

# --- agents (shipped in the package, installed to the agent dir) --------------
$pkgAgents = Join-Path $pkg "agents"
New-Item -ItemType Directory -Force -Path $pkgAgents | Out-Null
Copy-Item (Join-Path $agentDir "agents\*.md") $pkgAgents -Force
Write-Host "agents/           <- copied ($((Get-ChildItem $pkgAgents).Count) files)"

# --- prompts ------------------------------------------------------------------
$pkgPrompts = Join-Path $pkg "prompts"
New-Item -ItemType Directory -Force -Path $pkgPrompts | Out-Null
Copy-Item (Join-Path $lab "orchestrator.prompt.md") (Join-Path $pkgPrompts "orchestrator.md") -Force
Write-Host "prompts/orchestrator.md <- copied"

# --- report -------------------------------------------------------------------
Write-Host ""
Write-Host "package tree:"
Get-ChildItem $pkg -Recurse -File | ForEach-Object {
    "  " + $_.FullName.Substring($pkg.Length + 1)
}
