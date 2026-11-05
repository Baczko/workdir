<#
.SYNOPSIS
  Sprawdza, czy każdy commit z master ma odpowiednik na master-gcp.

.DESCRIPTION
  1. 'git rev-list --cherry-pick' odsiewa commity o identycznym patchu (patch-id).
  2. Pozostałe są szukane na master-gcp po linii '(cherry picked from commit <sha>)' (cherry-pick -x).
  3. Commity wpisane w plik .gcp-skip są świadomie pomijane.
  Co zostanie = prawdopodobny brak backportu. Skrypt kończy się kodem 1.

  Opcjonalnie: -MigrationPaths pokazuje różnice w kodzie POZA ścieżkami migracyjnymi
  (powinny być puste - to jest test niezależny od commitów).

.EXAMPLE
  .\scripts\verify-gcp-sync.ps1 -Since 2026-09-01
  .\scripts\verify-gcp-sync.ps1 -MigrationPaths 'src/main/java/pl/firma/gcp/**','k8s/gcp/**' -FailOnDiff
#>
[CmdletBinding()]
param(
    [string]$Source = 'master',
    [string]$Target = 'master-gcp',
    [string]$SkipFile = '.gcp-skip',
    [string]$Since,
    [string[]]$MigrationPaths = @(),
    [switch]$FailOnDiff
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Polecenie nie powiodło się (kod $LASTEXITCODE): $Exe $($Arguments -join ' ')"
    }
    return (($output | Out-String).Trim())
}

Invoke-Native git @('fetch', 'origin', $Source, $Target) | Out-Null

# --- kandydaci: commity z Source bez odpowiednika (patch-id) na Target ----------
$revArgs = @('rev-list', '--no-merges', '--right-only', '--cherry-pick', '--reverse')
if ($Since) { $revArgs += "--since=$Since" }
$revArgs += "origin/$Target...origin/$Source"
$candidates = @((Invoke-Native git $revArgs) -split '\r?\n' | Where-Object { $_ })

# --- lista świadomych pominięć ---------------------------------------------------
$skip = @()
if (Test-Path -LiteralPath $SkipFile) {
    $skip = @(Get-Content -LiteralPath $SkipFile |
        ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
        Where-Object { $_ -match '^[0-9a-fA-F]{7,40}$' })
}

$viaCherryPickX = 0
$skipped = 0
$missing = @()

foreach ($sha in $candidates) {
    if ($skip | Where-Object { $sha.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        $skipped++
        continue
    }

    $ref = Invoke-Native git @('log', "origin/$Target", '-F', "--grep=cherry picked from commit $sha", '-n', '1', '--format=%H')
    if ($ref) {
        $viaCherryPickX++
        continue
    }

    $info = (Invoke-Native git @('log', '-1', '--date=short', '--format=%h%x09%ad%x09%an%x09%s', $sha)) -split "`t", 4
    $missing += [pscustomobject]@{
        Sha     = $info[0]
        Data    = $info[1]
        Autor   = $info[2]
        Tytul   = $info[3]
    }
}

Write-Host "Commity na '$Source' bez patch-równoważnika na '$Target': $($candidates.Count)"
Write-Host "  odnalezione przez 'cherry picked from': $viaCherryPickX"
Write-Host "  pominięte (.gcp-skip):                  $skipped"
Write-Host "  BRAKUJĄCE:                              $($missing.Count)"

$failed = $false

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host "Brakuje na '$Target':" -ForegroundColor Red
    $missing | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    Write-Host "##vso[task.logissue type=error]Brakuje $($missing.Count) commitów z '$Source' na '$Target'. Zrób backport albo dopisz SHA do $SkipFile."
    $failed = $true
}

# --- test niezależny od commitów: różnice w kodzie poza ścieżkami migracyjnymi ----
$paths = @($MigrationPaths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($paths.Count -gt 0) {
    $pathspec = @('.') + ($paths | ForEach-Object { ":(exclude)$_" })
    $diff = Invoke-Native git (@('diff', '--stat', "origin/$Source", "origin/$Target", '--') + $pathspec)

    Write-Host ''
    if ($diff) {
        Write-Host "Różnice master vs master-gcp POZA ścieżkami migracyjnymi:" -ForegroundColor Yellow
        Write-Host $diff
        Write-Host "##vso[task.logissue type=warning]Kod poza ścieżkami migracyjnymi różni się między '$Source' a '$Target'."
        if ($FailOnDiff) { $failed = $true }
    }
    else {
        Write-Host 'Brak różnic poza ścieżkami migracyjnymi.' -ForegroundColor Green
    }
}

if ($failed) { exit 1 }
Write-Host 'OK' -ForegroundColor Green
