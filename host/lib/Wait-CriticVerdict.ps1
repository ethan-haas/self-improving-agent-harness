<#
  Tier 7: Fresh-context critic.

  Default mode: STATIC critic. Host runner applies the diff in a sandbox worktree
  and runs a deterministic static analysis pass (ruff -> pyflakes -> regex
  heuristics). Returns APPROVE if clean, REJECT with reason otherwise. No human,
  no API call. Subscription ToS-safe (no claude invocation).

  Human GUI mode: set AGENTA_CRITIC_MODE=human in agenta-runner.xml's env. Then
  the function reverts to the original drop-file-and-wait protocol.

  Style is still rotated mod-5 to influence which checks are emphasized:
    0 security-first  -> heavy on dangerous patterns (eval, subprocess shell=True)
    1 perf-first      -> nested loops, O(n^2) heuristics
    2 readability     -> max line length, function length, naming
    3 contrarian      -> compare diff to LESSONS.md, flag if it undoes a recorded rule
    4 devils-advocate -> require at least ONE concern flagged or auto-REJECT
#>
function Wait-CriticVerdict {
    param(
        [string]$Root,
        [string]$CandPath,
        [int]$Style,
        [int]$TimeoutMin = 60
    )

    $styleNames = @("security-first", "perf-first", "readability-first", "contrarian", "devils-advocate")
    $mode = $env:AGENTA_CRITIC_MODE
    if (-not $mode) { $mode = "static" }

    if ($mode -eq "human") {
        return Wait-HumanCriticVerdict -Root $Root -CandPath $CandPath -Style $Style -TimeoutMin $TimeoutMin
    }

    # Static critic
    $diffPath = Join-Path $CandPath "diff.patch"
    $manifestPath = Join-Path $CandPath "manifest.json"
    $manifest = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw | ConvertFrom-Json } else { $null }
    $baseline = if ($manifest -and $manifest.baseline_commit) { $manifest.baseline_commit } else { "HEAD" }
    # Honor manifest.repo_root for external-repo tasks
    $repoRoot = $Root
    if ($manifest -and ($manifest.PSObject.Properties.Name -contains 'repo_root') -and $manifest.repo_root) {
        $cand = [string]$manifest.repo_root
        if (-not [IO.Path]::IsPathRooted($cand)) { $cand = Join-Path $Root $cand }
        if (Test-Path (Join-Path $cand ".git")) { $repoRoot = (Resolve-Path $cand).Path }
    }

    $sbox = $null
    try {
        $sbox = New-SandboxWorktree -Root $repoRoot -Ref $baseline
        if (-not $sbox) {
            return @{ Verdict = "REJECT"; Reason = "could not stage sandbox for critic"; Style = $styleNames[$Style] }
        }
        & git -C $sbox apply $diffPath 2>$null *>$null
        if ($LASTEXITCODE -ne 0) {
            return @{ Verdict = "REJECT"; Reason = "critic could not apply diff for analysis"; Style = $styleNames[$Style] }
        }

        $issues = @()

        # ruff (preferred) -> pyflakes -> none
        $ruff = Get-Command ruff -ErrorAction SilentlyContinue
        if ($ruff) {
            $ruffOut = & ruff check --output-format=concise $sbox 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errLines = $ruffOut | Where-Object { $_ -match ':\d+:\d+:\s+[EFW]\d+' }
                foreach ($l in $errLines | Select-Object -First 5) { $issues += "ruff: $l" }
            }
        } else {
            $pyflakes = Get-Command pyflakes -ErrorAction SilentlyContinue
            if ($pyflakes) {
                $pfOut = & pyflakes $sbox 2>&1
                if ($LASTEXITCODE -ne 0) {
                    foreach ($l in ($pfOut | Select-Object -First 5)) { $issues += "pyflakes: $l" }
                }
            }
        }

        # Style-specific regex heuristics. Inspect ADDED lines only ('+...' but not '+++' header).
        # Without this filter, removing a dangerous pattern still trips the critic
        # because the '- pickle.loads(...)' line shows up in the diff text.
        $diffText = Get-Content $diffPath -Raw -ErrorAction SilentlyContinue
        $addedText = ""
        if ($diffText) {
            $addedLines = $diffText -split "`n" | Where-Object { $_ -match '^\+[^+]' -or $_ -eq '+' }
            $addedText = ($addedLines -join "`n")
        }
        if ($addedText) {
            switch ($Style) {
                0 {
                    foreach ($p in @('\beval\s*\(','\bexec\s*\(','shell\s*=\s*True','pickle\.loads','yaml\.load\b(?!.*Loader)')) {
                        if ($addedText -match $p) { $issues += "security: ADDED line matches '$p'" }
                    }
                }
                1 {
                    # for-loops are normal in algorithm/template code. Only flag when ratio
                    # to added lines suggests inner-hot-path proliferation.
                    $forLines = [regex]::Matches($addedText, '\bfor\s+\w+\s+in\b').Count
                    $totalAdded = ($addedText -split "`n").Count
                    $ratio = if ($totalAdded -gt 0) { $forLines / [double]$totalAdded } else { 0 }
                    if ($forLines -gt 20 -and $ratio -gt 0.05) {
                        $issues += "perf: $forLines for-loops in $totalAdded added lines (ratio $('{0:N2}' -f $ratio))"
                    }
                }
                2 {
                    # Long-line check applies to source code only. Walk diff file-by-file
                    # so CSV/data/onnx/binary blobs don't trip the gate. Real code legit
                    # has 1-3 lines >120 chars (long error msgs, regex patterns). Trip only
                    # at >10 long lines OR >5% of added code lines.
                    $codeExtensions = @('.py','.js','.ts','.tsx','.jsx','.mjs','.go','.rs','.java','.c','.cpp','.h','.hpp','.cs','.rb','.php','.sh','.ps1')
                    $longLines = 0
                    $codeAdded = 0
                    $currentIsCode = $false
                    foreach ($line in ($diffText -split "`n")) {
                        if ($line -match '^\+\+\+ b/(.+)$') {
                            $cf = $matches[1].Trim()
                            $ext = [IO.Path]::GetExtension($cf).ToLower()
                            $currentIsCode = $codeExtensions -contains $ext
                            continue
                        }
                        if ($line -match '^\+[^+]' -and $currentIsCode) {
                            $codeAdded++
                            if ($line.Length -gt 121) { $longLines++ }
                        }
                    }
                    $ratio = if ($codeAdded -gt 0) { $longLines / [double]$codeAdded } else { 0 }
                    if ($longLines -gt 10 -and $ratio -gt 0.05) {
                        $issues += "readability: $longLines / $codeAdded added code lines exceed 120 chars (ratio $('{0:N2}' -f $ratio))"
                    }
                }
                3 {
                    $lessons = Join-Path $Root "LESSONS.md"
                    if (Test-Path $lessons) {
                        $lessonText = Get-Content $lessons -Raw -ErrorAction SilentlyContinue
                        if ($lessonText -and ($addedText -match '--no-verify') -and ($lessonText -match 'commit before verify')) {
                            $issues += "contrarian: diff adds --no-verify, undoing a LESSONS.md rule"
                        }
                    }
                }
                4 {
                    if ($issues.Count -eq 0) {
                        if ($addedText -match '\bTODO\b') { $issues += "devils: TODO marker in added lines" }
                        if ($addedText -match '\bprint\s*\(') { $issues += "devils: print() in added lines" }
                    }
                }
            }
        }

        if ($issues.Count -eq 0) {
            return @{ Verdict = "APPROVE"; Reason = "no static-critic issues found ($($styleNames[$Style]))"; Style = $styleNames[$Style] }
        }
        return @{ Verdict = "REJECT"; Reason = "static-critic ($($styleNames[$Style])): $(($issues -join '; '))"; Style = $styleNames[$Style] }
    } finally {
        if ($sbox) {
            & git -C $repoRoot worktree remove --force $sbox 2>$null *>$null
            Remove-Item -Recurse -Force $sbox -ErrorAction SilentlyContinue
        }
    }
}

function Wait-HumanCriticVerdict {
    # Original human-loop implementation, preserved behind AGENTA_CRITIC_MODE=human.
    param([string]$Root, [string]$CandPath, [int]$Style, [int]$TimeoutMin = 60)

    $reqId = [guid]::NewGuid().ToString("N").Substring(0, 12)
    $criticDir = Join-Path $Root "agenta\infra\critic-inbox"
    New-Item -ItemType Directory -Force -Path $criticDir | Out-Null

    $reqPath = Join-Path $criticDir "$reqId.request.json"
    $verdictPath = Join-Path $criticDir "$reqId.verdict.json"

    $styleNames = @("security-first", "perf-first", "readability-first", "contrarian", "devils-advocate")
    $request = @{
        id = $reqId
        style = $styleNames[$Style]
        diff_path = Join-Path $CandPath "diff.patch"
        manifest_path = Join-Path $CandPath "manifest.json"
        instructions = "Fresh context. No chat history. Read ONLY the diff. Render verdict APPROVE or REJECT with single sentence reason."
    } | ConvertTo-Json -Depth 5
    $request | Out-File -FilePath $reqPath -Encoding utf8

    & (Join-Path $Root "host\Start-CriticSession.ps1") -RequestId $reqId

    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $verdictPath) {
            $v = Get-Content $verdictPath -Raw | ConvertFrom-Json
            Remove-Item $reqPath, $verdictPath -ErrorAction SilentlyContinue
            return @{ Verdict = $v.verdict; Reason = $v.reason; Style = $styleNames[$Style] }
        }
        Start-Sleep -Seconds 15
    }

    return @{ Verdict = "TIMEOUT"; Reason = "no human critic verdict within $TimeoutMin min"; Style = $styleNames[$Style] }
}
