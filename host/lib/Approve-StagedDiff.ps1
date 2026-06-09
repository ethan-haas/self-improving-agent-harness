<#
  Promotion: temporarily allow writes to protected paths, apply diff, commit, tag,
  archive, re-deny. SYSTEM context only.
#>
function ConvertTo-LineageInt {
    param($v)
    if ($null -eq $v) { return 0 }
    if ($v -is [int] -or $v -is [long]) { return [int]$v }
    $m = [regex]::Match([string]$v, '\d+')
    if ($m.Success) { return [int]$m.Value }
    return 0
}

function Approve-StagedDiff {
    param(
        [string]$Root,
        [string]$CandPath,
        [string]$Tag,
        [double]$HoldoutDelta,
        [double]$BenchDelta,
        [int]$CriticStyle
    )

    $diff = Join-Path $CandPath "diff.patch"
    $manifest = Get-Content (Join-Path $CandPath "manifest.json") -Raw | ConvertFrom-Json

    $hash = (Get-FileHash -Algorithm SHA256 -Path $diff).Hash.ToLower()

    Push-Location $Root
    try {
        git apply $diff | Out-Null
        git add -A | Out-Null
        $msg = "promote: $Tag holdout+$HoldoutDelta bench+$BenchDelta critic-style=$CriticStyle parent=$($manifest.parent)`n`nGeneration: $($manifest.generation)`nAgent: $($manifest.agent)`nManifest-Sha256: $hash"
        git -c user.name="AgentA Host" -c user.email="host@agenta.local" commit -m $msg --no-edit 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-RunnerLog -Level "WARN" -Message "Approve: git commit FAILED (exit $LASTEXITCODE) for $Tag -- HEAD not advanced (check repo git identity)" }
        git -c user.name="AgentA Host" -c user.email="host@agenta.local" tag -a $Tag -m $msg 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-RunnerLog -Level "WARN" -Message "Approve: git tag FAILED (exit $LASTEXITCODE) for $Tag" }

        $genInt = ConvertTo-LineageInt $manifest.generation
        $agentInt = ConvertTo-LineageInt $manifest.agent
        $archDir = Join-Path $Root ("archive\gen-{0:D4}\agent-{1:D4}" -f $genInt, $agentInt)
        New-Item -ItemType Directory -Force -Path $archDir | Out-Null
        Copy-Item $diff (Join-Path $archDir "diff.patch")
        Copy-Item (Join-Path $CandPath "manifest.json") (Join-Path $archDir "manifest.json")
        @{
            tag = $Tag
            task_id = $manifest.task_id
            metric_value = $manifest.metric_value
            metric_direction = $manifest.metric_direction
            repo_root = $manifest.repo_root
            holdout_delta = $HoldoutDelta
            bench_delta = $BenchDelta
            critic_style = $CriticStyle
            manifest_sha256 = $hash
            promoted_at = (Get-Date).ToString("o")
        } | ConvertTo-Json | Out-File -FilePath (Join-Path $archDir "scores.json") -Encoding utf8

        Remove-Item -Recurse -Force $CandPath
    } finally {
        Pop-Location
    }
}

function Test-RewardHackTripwire {
    param([string]$Root, [string]$DiffPath)
    $patterns = @(
        'sys\.settrace',
        'inspect\.stack',
        'os\._exit\(\s*0\s*\)',
        '__import__\(\s*[''"]ctypes',
        'eval\s*\(\s*open\(',
        'subprocess.*--no-verify',
        '0\.97\s*#.*holdout',
        'PYTHONDONTWRITEBYTECODE'
    )
    $diff = Get-Content $DiffPath -Raw
    foreach ($p in $patterns) {
        if ($diff -match $p) { return @{ Tripped = $true; Reason = "pattern matched: $p" } }
    }
    return @{ Tripped = $false }
}
