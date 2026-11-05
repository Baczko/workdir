<#
.SYNOPSIS
  Bramka dla PR-ów do master-gcp: wymaga referencji do commita z master albo znacznika [gcp-only].

.DESCRIPTION
  Uruchamiaj na checkoutcie PR-a (merge commit refs/pull/N/merge, jak w Azure Pipelines).
  Przechodzi, gdy w commitach PR-a:
    - jest co najmniej jedna linia '(cherry picked from commit <40-znakowy sha>)'
      i WSZYSTKIE takie SHA są na master, albo
    - którykolwiek commit zawiera znacznik [gcp-only] (zmiana czysto migracyjna).
#>
[CmdletBinding()]
param(
    [string]$Source = 'master',
    [string]$Target = 'master-gcp',
    [string]$Marker = '[gcp-only]'
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

# checkout PR w Azure to merge commit: HEAD^1 = master-gcp, HEAD^2 = czoło PR-a
$parents = (Invoke-Native git @('rev-list', '--parents', '-n', '1', 'HEAD')) -split '\s+'
$range = if ($parents.Count -eq 3) { "$($parents[1])..$($parents[2])" } else { "origin/$Target..HEAD" }

$commits = @((Invoke-Native git @('rev-list', '--no-merges', $range)) -split '\r?\n' | Where-Object { $_ })
if ($commits.Count -eq 0) {
    Write-Host 'Brak commitów w PR - nic do sprawdzenia.'
    exit 0
}

$hasMarker = $false
$valid = @()
$invalid = @()

foreach ($c in $commits) {
    $msg = Invoke-Native git @('log', '-1', '--format=%B', $c)

    if ($msg.Contains($Marker)) { $hasMarker = $true }

    foreach ($m in [regex]::Matches($msg, 'cherry picked from commit ([0-9a-f]{40})')) {
        $ref = $m.Groups[1].Value
        & git merge-base --is-ancestor $ref "origin/$Source" 2>$null
        if ($LASTEXITCODE -eq 0) { $valid += $ref } else { $invalid += $ref }
    }
}

if ($invalid.Count -gt 0) {
    Write-Host "##vso[task.logissue type=error]SHA spoza '$Source' w 'cherry picked from': $($invalid -join ', ')"
    exit 1
}

if ($hasMarker) {
    Write-Host "Znacznik $Marker - zmiana tylko pod migrację, OK." -ForegroundColor Green
    exit 0
}

if ($valid.Count -gt 0) {
    Write-Host "Backport z '$Source': $($valid -join ', ') - OK." -ForegroundColor Green
    exit 0
}

Write-Host "##vso[task.logissue type=error]PR do '$Target' musi mieć '(cherry picked from commit <sha z $Source>)' w commicie (git cherry-pick -x) albo znacznik $Marker."
exit 1
