param(
    [string]$VivadoBin = "D:\Xilinx\Vivado\2024.1\bin",
    # Seeds to run for every configuration.
    [int[]]$Seeds = @(1, 2, 3, 4, 5, 6, 7, 8),
    # Configurations: rn2 (2 RNs), rn3 (3 RNs), icg (2 RNs, real clock gate).
    [string[]]$Configs = @("rn2", "rn3", "icg"),
    [int]$Ops = 0,
    [string]$Prefix = "stress",
    [string]$SpecPlusArgs = "CHK_SPEC_ALL",
    [int]$WallTimeoutSec = 1500
)

# Run tb_chi_random_stress over many seeds and configurations and print one
# verdict per run. A run FAILS on any "TEST FAIL", "ERROR:", RN transaction
# timeout, or when it does not reach "TEST PASS:". Meant to be run
# periodically (e.g. nightly) next to run_regression.ps1, which only runs
# seed 1. Reports land in reports/<Prefix>/<config>_s<seed>.
#   .\scripts\run_stress_seeds.ps1
#   .\scripts\run_stress_seeds.ps1 -Seeds 1,2,3 -Configs rn3
# (through powershell -File, give seeds as a comma list, not a range)

$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "run_tb_chi_xsim.ps1"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$failPattern = "TEST FAIL|FATAL|ERROR:|transaction timeout|timeout txn|WALL TIMEOUT|\`$stop"
$results = @()

foreach ($cfg in $Configs) {
    switch ($cfg) {
        "rn2" { $defines = ""; $extra = "" }
        "rn3" { $defines = "STRESS_NUM_RN=3"; $extra = "" }
        "icg" { $defines = "CHI_SIM_REAL_ICG"; $extra = "CG" }
        default { throw "Unknown config '$cfg' (use rn2, rn3, icg)" }
    }
    foreach ($seed in $Seeds) {
        $tag = "$Prefix/${cfg}_s$seed"
        $plus = "SEED=$seed"
        if ($Ops -gt 0) { $plus += " OPS=$Ops" }
        if ($extra -ne "") { $plus += " $extra" }
        if ($SpecPlusArgs -ne "") { $plus += " $SpecPlusArgs" }
        $runArgs = @{ VivadoBin = $VivadoBin; Top = "tb_chi_random_stress";
                      Tag = $tag; PlusArgs = $plus; Quiet = $true;
                      WallTimeoutSec = $WallTimeoutSec }
        if ($defines -ne "") { $runArgs.Defines = $defines }
        $verdict = "PASS"; $detail = ""
        try { & $runner @runArgs | Out-Null } catch { $verdict = "BUILD_FAIL"; $detail = $_.Exception.Message }
        $log = Join-Path $repoRoot "reports/$tag/xsim.log"
        if ($verdict -eq "PASS") {
            if (-not (Test-Path -LiteralPath $log)) {
                $verdict = "NO_LOG"
            } else {
                $bad = Select-String -Path $log -Pattern $failPattern -CaseSensitive | Select-Object -First 2
                $good = Select-String -Path $log -Pattern "TEST PASS:" -SimpleMatch | Select-Object -First 1
                if ($bad) {
                    $verdict = "FAIL"
                    $detail = ($bad | ForEach-Object { $_.Line.Trim() }) -join " | "
                } elseif (-not $good) {
                    $verdict = "NO_PASS"
                }
            }
        }
        $results += [pscustomobject]@{ Config = $cfg; Seed = $seed; Verdict = $verdict; Detail = $detail }
        Write-Host ("[{0,-10}] {1} seed={2} {3}" -f $verdict, $cfg, $seed, $detail)
    }
}

$failed = @($results | Where-Object { $_.Verdict -ne "PASS" })
Write-Host ""
Write-Host ("STRESS SUMMARY: {0}/{1} passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
