<#
  Tier 3: Property tests
  Runs hypothesis (Python) / fast-check (JS) suites in tests/property/.
#>
function Invoke-PropertyTests {
    param([string]$Root, [string]$DiffPath)
    $propDir = Join-Path $Root "tests\property"
    if (-not (Test-Path $propDir)) {
        return @{ Pass=$true; Reason="no property tests configured (skipped)" }
    }
    Push-Location $Root
    try {
        if (Test-Path (Join-Path $propDir "package.json")) {
            & npx --yes fast-check-runner $propDir 2>$null *>$null
        } else {
            & pytest $propDir -q --hypothesis-seed=random 2>$null *>$null
        }
        if ($LASTEXITCODE -ne 0) { return @{ Pass=$false; Reason="property tests failed" } }
        return @{ Pass=$true }
    } finally { Pop-Location }
}
