<#
.SYNOPSIS
  Tworzy PR z backportem zmergowanego PR-a z master na master-gcp (git cherry-pick -x).

.DESCRIPTION
  Bierze squash-commit powstały z merge'a PR-a na master, cherry-pickuje go na nową gałąź
  odchodzącą od master-gcp i otwiera PR przez GitHub CLI (gh).
  Wymaga: git, gh (zalogowany: gh auth login; dla GitHub Enterprise ustaw GH_HOST albo --hostname).

.EXAMPLE
  .\scripts\backport.ps1 -PullRequest 1234

.EXAMPLE
  # po ręcznym rozwiązaniu konfliktu i 'git cherry-pick --continue':
  .\scripts\backport.ps1 -PullRequest 1234 -Continue
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$PullRequest,
    [string]$Source = 'master',
    [string]$Target = 'master-gcp',
    [switch]$Continue,
    [switch]$Draft
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$LabelNeeded = 'needs-gcp-backport'
$LabelDone   = 'backported'

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

foreach ($cmd in 'git', 'gh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Nie znaleziono '$cmd' w PATH."
    }
}

# --- dane oryginalnego PR-a ---------------------------------------------------
$pr = Invoke-Native gh @('pr', 'view', "$PullRequest", '--json', 'state,title,url,baseRefName,mergeCommit') |
    ConvertFrom-Json

if ($pr.state -ne 'MERGED') { throw "PR #$PullRequest nie jest zmergowany (stan: $($pr.state))." }
if ($pr.baseRefName -ne $Source) { throw "PR #$PullRequest był mergowany do '$($pr.baseRefName)', oczekiwano '$Source'." }

$sha    = $pr.mergeCommit.oid
$branch = "backport/$PullRequest-to-$Target"

if ($Continue) {
    # --- kontynuacja po rozwiązaniu konfliktu -----------------------------------
    $current = Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($current -ne $branch) { throw "Jesteś na '$current', a powinieneś być na '$branch'." }

    $cpHead = Invoke-Native git @('rev-parse', '--git-path', 'CHERRY_PICK_HEAD')
    if (Test-Path -LiteralPath $cpHead) {
        throw "Cherry-pick nadal trwa. Rozwiąż konflikty, 'git add', potem 'git cherry-pick --continue'."
    }
}
else {
    # --- start: nowa gałąź + cherry-pick ----------------------------------------
    if (Invoke-Native git @('status', '--porcelain')) {
        throw 'Drzewo robocze nie jest czyste. Zacommituj lub schowaj zmiany (git stash).'
    }

    $startBranch = Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')

    Invoke-Native git @('fetch', 'origin', $Source, $Target) | Out-Null

    if (Invoke-Native git @('branch', '--list', $branch, "origin/$branch", '--all')) {
        throw "Gałąź '$branch' już istnieje (lokalnie lub na origin). Backport był już robiony?"
    }

    Invoke-Native git @('switch', '-c', $branch, '--no-track', "origin/$Target") | Out-Null

    # squash-commit ma 1 rodzica; zwykły merge-commit wymaga -m 1
    $parentCount = ((Invoke-Native git @('rev-list', '--parents', '-n', '1', $sha)) -split '\s+').Count - 1
    $pickArgs = @('cherry-pick', '-x')
    if ($parentCount -gt 1) { $pickArgs += @('-m', '1') }
    $pickArgs += $sha

    & git @pickArgs
    if ($LASTEXITCODE -ne 0) {
        $unmerged = Invoke-Native git @('diff', '--name-only', '--diff-filter=U')
        if (-not $unmerged) {
            # brak konfliktów, a mimo to błąd = zmiana już jest na master-gcp (pusty cherry-pick)
            & git cherry-pick --abort
            Invoke-Native git @('switch', $startBranch) | Out-Null
            Invoke-Native git @('branch', '-D', $branch) | Out-Null
            throw "Cherry-pick $sha jest pusty - master-gcp już zawiera te zmiany."
        }

        Write-Host ''
        Write-Host 'KONFLIKT przy cherry-picku. Co dalej:' -ForegroundColor Yellow
        Write-Host '  1. Rozwiąż konflikty w plikach, potem: git add <pliki>'
        Write-Host '  2. git cherry-pick --continue'
        Write-Host "  3. .\scripts\backport.ps1 -PullRequest $PullRequest -Continue"
        Write-Host "Przerwanie: git cherry-pick --abort; git switch $startBranch; git branch -D $branch"
        exit 1
    }
}

# --- push + PR ----------------------------------------------------------------
Invoke-Native git @('push', '-u', 'origin', $branch) | Out-Null

# linia (cherry picked from commit <sha>) w opisie PR jest sprawdzana przez pipeline i przeżywa squash
$body = "Backport #$PullRequest ($($pr.url))`n`n(cherry picked from commit $sha)"

$createArgs = @(
    'pr', 'create',
    '--base', $Target,
    '--head', $branch,
    '--title', "[Backport $Target] $($pr.title)",
    '--body', $body
)
if ($Draft) { $createArgs += '--draft' }

$newPr = Invoke-Native gh $createArgs
Write-Host "Utworzono PR: $newPr" -ForegroundColor Green

# --- porządki na oryginalnym PR-ze (best effort) --------------------------------
try {
    Invoke-Native gh @('pr', 'comment', "$PullRequest", '--body', "Backport na ``$Target``: $newPr") | Out-Null
    Invoke-Native gh @('pr', 'edit', "$PullRequest", '--remove-label', $LabelNeeded, '--add-label', $LabelDone) | Out-Null
}
catch {
    Write-Warning "Nie udało się zaktualizować labeli/komentarza na PR #$PullRequest: $($_.Exception.Message)"
}

if (-not $Continue) {
    Invoke-Native git @('switch', $startBranch) | Out-Null
}
