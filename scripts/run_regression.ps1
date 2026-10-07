param(
    [string]$VivadoBin = "D:\Xilinx\Vivado\2024.1\bin",
    [string[]]$Tops = @(
        "tb_CHI",
        "tb_chi_soc_cluster_ip",
        "tb_chi_soc_cluster_ip_deep",
        "tb_chi_soc_mmio_2m_arbiter",
        "tb_riscv_cache_maintenance",
        "tb_riscv_dcache_writeback_chi",
        "tb_riscv_core_amo",
        "tb_riscv_l1_axi_to_chi_bridge_mmio",
        "tb_chi_boundary_roundtrip",
        "tb_chi_dat_boundary_attrs",
        "tb_chi_dat_dataid_rx",
        "tb_chi_fabric_qos_xbar3",
        "tb_chi_rn_f_qos_xbar4",
        "tb_chi_snoop_txnid_3rn",
        "tb_chi_link_layer",
        "tb_chi_random_stress"
    ),
    [string]$Prefix = "reg",
    [string]$RunTime = "2ms",
    [int]$WallTimeoutSec = 900,
    # Phase-2 spec rules of the protocol checker (chi_checker_binds binds it
    # into every chi_top). Each phase-2 step adds its rules here once the RTL
    # is clean against them; pass -SpecPlusArgs "" to run without them.
    [string]$SpecPlusArgs = "CHK_SPEC_ALL",
    # Leave out the CoreMark dual-core run at the end (about 3 minutes).
    [switch]$SkipCoreMark
)

# Run every self-checking testbench and print one verdict per testbench.
# A testbench FAILS when its log has any failure marker, or when a node
# reports a transaction timeout: timeouts must not be hidden behind a PASS.
# CoreMark dual-core runs last, through scripts/run_coremark_dual_core_xsim.ps1.

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
# The flat GitHub export (scripts/export_github.sh) ships only the CHI-only
# testbenches: the SoC/RISC-V ones need the core, which it does not carry.
if ((Test-Path -LiteralPath (Join-Path $repoRoot "chi_top.v")) -and
    -not $PSBoundParameters.ContainsKey("Tops")) {
    $Tops = @($Tops | Where-Object { Test-Path -LiteralPath (Join-Path $repoRoot "sim/tb/$_.sv") })
}
$runner = Join-Path $PSScriptRoot "run_tb_chi_xsim.ps1"
# "ERROR:" keeps the colon: test names such as T05_MMIO_READ_ERROR_RESPONSE_*
# are not failures, while tool and testbench errors all print "ERROR:".
$failPattern = "TEST FAIL|FAIL:|\bFAIL\b|Fatal|FATAL|ERROR:|transaction timeout|timeout txn|WALL TIMEOUT|\`$stop"
$passPattern = "PASS"
$results = @()

foreach ($top in $Tops) {
    $tag = "$Prefix/$top"
    $log = Join-Path $repoRoot "reports/$tag/xsim.log"
    $verdict = "PASS"
    $detail = ""
    try {
        $runArgs = @{ VivadoBin = $VivadoBin; Top = $top; Tag = $tag; Quiet = $true;
                      RunTime = $RunTime; WallTimeoutSec = $WallTimeoutSec }
        if ($SpecPlusArgs -ne "") { $runArgs.PlusArgs = $SpecPlusArgs }
        & $runner @runArgs
    } catch {
        $verdict = "BUILD_FAIL"
        $detail = $_.Exception.Message
    }
    if ($verdict -eq "PASS") {
        if (-not (Test-Path -LiteralPath $log)) {
            $verdict = "NO_LOG"
        } else {
            $bad = Select-String -Path $log -Pattern $failPattern -CaseSensitive | Select-Object -First 3
            $good = Select-String -Path $log -Pattern $passPattern -SimpleMatch | Select-Object -First 1
            $finished = Select-String -Path $log -Pattern '$finish called' -SimpleMatch | Select-Object -First 1
            if ($bad) {
                $verdict = "FAIL"
                $detail = ($bad | ForEach-Object { $_.Line.Trim() }) -join " | "
            } elseif (-not $finished) {
                $verdict = "HANG"
                $last = Select-String -Path $log -Pattern "TEST START" | Select-Object -Last 1
                $detail = "did not reach `$finish within $RunTime; last: " +
                          $(if ($last) { $last.Line.Trim() } else { "no test started" })
            } elseif (-not $good) {
                $verdict = "NO_PASS"
                $detail = "no PASS marker (did the testbench finish?)"
            }
        }
    }
    $results += [pscustomobject]@{ Testbench = $top; Verdict = $verdict; Detail = $detail }
    Write-Host ("[{0,-10}] {1} {2}" -f $verdict, $top, $detail)
}

# CoreMark dual-core (roadmap 4.4): the only test that runs real firmware on
# both harts through the L1 caches and the interconnect. It has its own
# runner and project file, and is left out of the flat export (no core) and
# of a run with an explicit -Tops list. In a fresh git worktree it needs
# CHI_Interconnect.sim/sim_1/behav/xsim/glbl.v copied from the main checkout.
$cmRunner = Join-Path $PSScriptRoot "run_coremark_dual_core_xsim.ps1"
if (-not $SkipCoreMark -and -not $PSBoundParameters.ContainsKey("Tops") -and
    (Test-Path -LiteralPath $cmRunner) -and
    -not (Test-Path -LiteralPath (Join-Path $repoRoot "chi_top.v"))) {
    $cmLog = Join-Path $repoRoot "reports/coremark/xsim_coremark_dual_core.log"
    if (Test-Path -LiteralPath $cmLog) { Remove-Item -LiteralPath $cmLog -Force }
    $verdict = "PASS"
    $detail = ""
    try {
        & $cmRunner -VivadoBin $VivadoBin -SplitImages 1 -StartMask 3 -TimeoutCycles 3000000 *>&1 | Out-Null
    } catch {
        $detail = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $cmLog)) {
        $verdict = "BUILD_FAIL"
    } elseif (-not (Select-String -Path $cmLog -Pattern "[COREMARK] PASS" -SimpleMatch)) {
        $verdict = "FAIL"
        $bad = Select-String -Path $cmLog -Pattern "[COREMARK] FAIL" -SimpleMatch | Select-Object -First 1
        if ($bad) { $detail = $bad.Line.Trim() }
    } else {
        $score = Select-String -Path $cmLog -Pattern "[COREMARK] CoreMark=" -SimpleMatch | Select-Object -First 1
        $detail = if ($score) { $score.Line.Trim() } else { "" }
    }
    $results += [pscustomobject]@{ Testbench = "coremark_dual_core"; Verdict = $verdict; Detail = $detail }
    Write-Host ("[{0,-10}] {1} {2}" -f $verdict, "coremark_dual_core", $detail)
}

$failed =@($results | Where-Object { $_.Verdict -ne "PASS" })
Write-Host ""
Write-Host ("REGRESSION SUMMARY: {0}/{1} passed" -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) { exit 1 }
