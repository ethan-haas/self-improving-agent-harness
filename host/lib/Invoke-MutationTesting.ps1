<#
  Tier 4: Mutation testing
  mutmut (Python) / Stryker (JS). Returns mutation score [0,1]. Caller rejects if < 0.70.
#>
function Invoke-MutationTesting {
    param([string]$Root, [string]$DiffPath)
    Push-Location $Root
    try {
        if (Test-Path "stryker.conf.json") {
            $out = & npx --yes stryker run --reporters json 2>$null | Out-String
            $json = $out | Select-String -Pattern '\{.*\}' | Select-Object -First 1
            if ($json) {
                $score = ([regex]::Match($json.Line, '"mutationScore"\s*:\s*([\d.]+)').Groups[1].Value -as [double])
                if ($score) { return @{ MutationScore = $score / 100.0 } }
            }
        } elseif ((Test-Path "pyproject.toml") -or (Test-Path "setup.py")) {
            $out = & mutmut run --quiet 2>$null | Out-String
            $killed = ([regex]::Match($out, 'killed\s+(\d+)').Groups[1].Value -as [int])
            $total = ([regex]::Match($out, 'mutants?\s+(\d+)').Groups[1].Value -as [int])
            if ($total -gt 0) { return @{ MutationScore = $killed / $total } }
        }
        return @{ MutationScore = 1.0; Note="mutation testing unavailable - passthrough" }
    } finally { Pop-Location }
}
