<#
.SYNOPSIS
  Backport zmergowanego PR-a z master na master-gcp (git cherry-pick -x) - bez GitHub CLI.

.DESCRIPTION
  1. Znajduje squash-commit PR-a na master (po numerze '(#1234)' w tytule) albo bierze podany SHA.
  2. Tworzy gałąź backport/<numer>-to-master-gcp od origin/master-gcp i robi 'git cherry-pick -x'.
  3. Pushuje gałąź i otwiera w przeglądarce formularz nowego PR-a z wypełnionym tytułem i opisem
     (w opisie jest linia '(cherry picked from commit <sha>)', którą sprawdza pipeline).
  Wymaga tylko gita i PowerShella.

.EXAMPLE
  .\scripts\backport.ps1 -PullRequest 1234

.EXAMPLE
  # gdy w tytule commita nie ma numeru PR-a:
  .\scripts\backport.ps1 -Sha 3f2a9c1d

.EXAMPLE
  # po ręcznym rozwiązaniu konfliktu i 'git cherry-pick --continue':
  .\scripts\backport.ps1 -PullRequest 1234 -Continue
#>
[CmdletBinding(DefaultParameterSetName = 'ByPr')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByPr')]
    [Parameter(ParameterSetName = 'BySha')]
    [int]$PullRequest,

    [Parameter(Mandatory, ParameterSetName = 'BySha')]
    [string]$Sha,

    [string]$Source = 'master',
    [string]$Target = 'master-gcp',
    [switch]$Continue,
    [switch]$NoBrowser
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

# adres remote'a (https / ssh:// / scp-like) -> adres strony repo w przeglądarce
function ConvertTo-WebUrl {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $u = $RemoteUrl.Trim() -replace '\.git$', ''

    if ($u -match '^https?://') {
        return ($u -replace '^(https?://)[^@/]+@', '$1')
    }
    if ($u -match '^ssh://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$') {
        return "https://$($Matches[1])/$($Matches[2])"
    }
    if ($u -match '^(?:[^@:/]+@)?([^:/]+):(.+)$') {
        return "https://$($Matches[1])/$($Matches[2])"
    }
    throw "Nie umiem zamienić adresu remote'a na URL strony: $RemoteUrl"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Nie znaleziono 'git' w PATH." }

Invoke-Native git @('fetch', 'origin', $Source, $Target) | Out-Null

# --- ustal commit do backportu ----------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'ByPr') {
    # GitHub dopisuje '(#N)' do tytułu squash-commita
    $lines = @((Invoke-Native git @('log', "origin/$Source", '-F', "--grep=(#$PullRequest)", '--format=%H%x09%s')) -split '\r?\n' |
        Where-Object { $_ })
    $hits = @($lines | Where-Object { ($_ -split "`t", 2)[1] -match "\(#$PullRequest\)\s*$" })

    if ($hits.Count -eq 0) {
        throw "Nie znalazłem na '$Source' commita z '(#$PullRequest)' w tytule. Podaj SHA: -Sha <sha> (widać go na stronie zmergowanego PR-a)."
    }
    if ($hits.Count -gt 1) {
        throw "Znaleziono kilka commitów z '(#$PullRequest)':`n$($hits -join "`n")`nPodaj właściwy przez -Sha."
    }
    $commit = ($hits[0] -split "`t")[0]
}
else {
    $commit = Invoke-Native git @('rev-parse', '--verify', "$Sha^{commit}")
    & git merge-base --is-ancestor $commit "origin/$Source"
    if ($LASTEXITCODE -ne 0) { throw "Commit $commit nie znajduje się na '$Source'." }
}

$short   = $commit.Substring(0, 10)
$subject = Invoke-Native git @('log', '-1', '--format=%s', $commit)
$title   = "[Backport $Target] " + ($subject -replace '\s*\(#\d+\)\s*$', '')

if ($PullRequest -gt 0) {
    $label = "#$PullRequest"
    $branch = "backport/$PullRequest-to-$Target"
}
else {
    $label = "commita $short"
    $branch = "backport/$short-to-$Target"
}
$body = "Backport $label z ``$Source```n`n(cherry picked from commit $commit)"

Write-Host "Commit do backportu: $short  $subject"

if ($Continue) {
    # --- kontynuacja po rozwiązaniu konfliktu -------------------------------------
    $current = Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($current -ne $branch) { throw "Jesteś na '$current', a powinieneś być na '$branch'." }

    $cpHead = Invoke-Native git @('rev-parse', '--git-path', 'CHERRY_PICK_HEAD')
    if (Test-Path -LiteralPath $cpHead) {
        throw "Cherry-pick nadal trwa. Rozwiąż konflikty, 'git add', potem 'git cherry-pick --continue'."
    }
}
else {
    # --- start: nowa gałąź + cherry-pick ------------------------------------------
    if (Invoke-Native git @('status', '--porcelain')) {
        throw 'Drzewo robocze nie jest czyste. Zacommituj lub schowaj zmiany (git stash).'
    }

    & git show-ref --verify --quiet "refs/heads/$branch"
    $existsLocal = ($LASTEXITCODE -eq 0)
    $existsRemote = [bool](Invoke-Native git @('ls-remote', '--heads', 'origin', $branch))
    if ($existsLocal -or $existsRemote) {
        throw "Gałąź '$branch' już istnieje (lokalnie lub na origin). Backport był już robiony?"
    }

    $startBranch = Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')
    Invoke-Native git @('switch', '-c', $branch, '--no-track', "origin/$Target") | Out-Null

    # squash-commit ma 1 rodzica; zwykły merge-commit wymaga -m 1
    $parentCount = ((Invoke-Native git @('rev-list', '--parents', '-n', '1', $commit)) -split '\s+').Count - 1
    $pickArgs = @('cherry-pick', '-x')
    if ($parentCount -gt 1) { $pickArgs += @('-m', '1') }
    $pickArgs += $commit

    & git @pickArgs
    if ($LASTEXITCODE -ne 0) {
        $unmerged = Invoke-Native git @('diff', '--name-only', '--diff-filter=U')
        if (-not $unmerged) {
            # brak konfliktów, a mimo to błąd = zmiana już jest na master-gcp (pusty cherry-pick)
            & git cherry-pick --abort
            Invoke-Native git @('switch', $startBranch) | Out-Null
            Invoke-Native git @('branch', '-D', $branch) | Out-Null
            throw "Cherry-pick $short jest pusty - '$Target' już zawiera te zmiany."
        }

        $retry = if ($PullRequest -gt 0) { "-PullRequest $PullRequest" } else { "-Sha $commit" }
        Write-Host ''
        Write-Host 'KONFLIKT przy cherry-picku. Co dalej:' -ForegroundColor Yellow
        Write-Host '  1. Rozwiąż konflikty w plikach, potem: git add <pliki>'
        Write-Host '  2. git cherry-pick --continue'
        Write-Host "  3. .\scripts\backport.ps1 $retry -Continue"
        Write-Host "Przerwanie: git cherry-pick --abort; git switch $startBranch; git branch -D $branch"
        exit 1
    }
}

# --- push + formularz PR-a ---------------------------------------------------------
Invoke-Native git @('push', '-u', 'origin', $branch) | Out-Null

$web = ConvertTo-WebUrl (Invoke-Native git @('remote', 'get-url', 'origin'))
$prUrl = "$web/compare/$Target...$branch" +
    '?expand=1' +
    '&title=' + [uri]::EscapeDataString($title) +
    '&body=' + [uri]::EscapeDataString($body)

Write-Host ''
Write-Host 'Gałąź wypchnięta. Utwórz PR (formularz jest wypełniony):' -ForegroundColor Green
Write-Host $prUrl

if (-not $NoBrowser) {
    try { Start-Process $prUrl } catch { Write-Warning 'Nie udało się otworzyć przeglądarki - użyj linku powyżej.' }
}

if ($PullRequest -gt 0) {
    Write-Host ''
    Write-Host "Pamiętaj: na PR #$PullRequest zmień label 'needs-gcp-backport' na 'backported'." -ForegroundColor Yellow
}

if (-not $Continue) {
    Invoke-Native git @('switch', $startBranch) | Out-Null
}