#!/usr/bin/env pwsh
# The Windows entry point of scripts/check.sh: what this repository checks is written once, in the
# bash file of the same name, and this starts it with the bash git ships.
$ErrorActionPreference = 'Stop'
$git = Get-Command git -ErrorAction SilentlyContinue
$bash = $null
if ($git) {
  $shipped = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin/bash.exe'
  if (Test-Path -LiteralPath $shipped) { $bash = $shipped }
}
if (-not $bash) { $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source }
if (-not $bash) { Write-Host "check: FAIL — no bash on this machine, and the checks are written in it. Git ships one."; exit 1 }
& $bash (Join-Path $PSScriptRoot 'check.sh') @args
exit $LASTEXITCODE
