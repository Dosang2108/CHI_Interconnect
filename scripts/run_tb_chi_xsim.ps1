param(
    [string]$VivadoBin = "D:\Xilinx\Vivado\2024.1\bin",
    [string]$Top = "tb_CHI",
    [string]$Tag = "",
    [string]$PlusArgs = "",
    [string]$Defines = "",
    [string]$RunTime = "",
    [int]$WallTimeoutSec = 0,
    [switch]$SkipCompile,
    [switch]$Quiet
)

# Compile, elaborate and run one self-checking testbench under xsim.
#   .\scripts\run_tb_chi_xsim.ps1 -Tag p0 -PlusArgs "P0_ONLY"   # tb_CHI, only T40/T41
#   .\scripts\run_tb_chi_xsim.ps1 -Tag full                    # tb_CHI full regression
#   .\scripts\run_tb_chi_xsim.ps1 -Top tb_chi_soc_cluster_ip_deep
# Logs land in reports/<Tag> (Tag defaults to Top).

$ErrorActionPreference = "Stop"
if ($Tag -eq "") { $Tag = $Top }
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
# Two layouts: the Vivado project (CHI_Interconnect.srcs/...) and the flat
# GitHub export (scripts/export_github.sh: RTL at the root, sim/ next to it).
$flat = Test-Path -LiteralPath (Join-Path $repoRoot "chi_top.v")
if ($flat) {
    $rtl = $repoRoot
    $rtlSrc = @((Join-Path $repoRoot "chi_top.v")) +
              @("common", "fabric", "hn", "mn", "rn", "sn" | ForEach-Object { Join-Path $repoRoot $_ })
    $core = $null
    $tb = Join-Path $repoRoot "sim/tb/$Top.sv"
    $checkers = Join-Path $repoRoot "sim/checkers"
    $formal = Join-Path $repoRoot "sim/formal"
} else {
    $rtl = Join-Path $repoRoot "CHI_Interconnect.srcs/sources_1/imports/CHI_Interconnect/rtl"
    $rtlSrc = @($rtl)
    $core = Join-Path $repoRoot "CHI_Interconnect.srcs/sources_1/imports/rtl"
    $tb = Join-Path $repoRoot "CHI_Interconnect.srcs/sim_1/new/$Top.sv"
    $checkers = Join-Path $repoRoot "CHI_Interconnect.srcs/sim_1/checkers"
    $formal = Join-Path $repoRoot "formal"
}
if (-not (Test-Path -LiteralPath $tb)) { throw "Testbench not found: $tb" }
$work = Join-Path $repoRoot "reports/$Tag"
New-Item -ItemType Directory -Force -Path $work | Out-Null
Set-Location $work

$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim  = Join-Path $VivadoBin "xsim.bat"
$snapshot = "${Top}_behav"

$files = @()
$files += Get-ChildItem -Path $rtlSrc -Recurse -Filter *.v | ForEach-Object { $_.FullName }
if ($core) { $files += Get-ChildItem -Path $core -Recurse -Filter *.v | ForEach-Object { $_.FullName } }
# Simulation checkers, bound into chi_top by chi_checker_binds (second top).
$tops = @($Top)
if (Test-Path -LiteralPath $checkers) {
    $files += Get-ChildItem -Path $checkers -Filter *.sv | ForEach-Object { $_.FullName }
    $tops += "chi_checker_binds"
}
$files += $tb
$files | ForEach-Object { '"' + ($_ -replace '\\','/') + '"' } | Set-Content -Path files.f -Encoding ASCII

if (-not $SkipCompile) {
    $defArgs = @()
    if ($Defines -ne "") {
        # xvlog is a .bat too: quote NAME=VALUE so cmd.exe keeps it whole.
        foreach ($d in $Defines.Split(" ")) {
            if ($d -match "=") { $d = '"' + $d + '"' }
            $defArgs += @("-d", $d)
        }
    }
    & $xvlog --sv -i (Join-Path $rtl "common") -i $checkers -i $formal @defArgs -f files.f --log xvlog.log | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "xvlog failed, see $work/xvlog.log" }
    & $xelab @tops -s $snapshot --debug off --timescale 1ns/1ps --log xelab.log | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "xelab failed, see $work/xelab.log" }
}

if ($RunTime -ne "") {
    # Bounded run: a testbench that waits forever stops at RunTime instead
    # of hanging the caller; it then has no PASS marker.
    "run $RunTime`nquit" | Set-Content -Path run.tcl -Encoding ASCII
    $runArgs = @($snapshot, "--tclbatch", "run.tcl", "--log", "xsim.log")
} else {
    $runArgs = @($snapshot, "-R", "--log", "xsim.log")
}
if ($PlusArgs -ne "") {
    # xsim is a .bat: cmd.exe splits unquoted arguments on '=', so quote
    # NAME=VALUE plusargs to keep them in one piece.
    foreach ($p in $PlusArgs.Split(" ")) {
        if ($p -match "=") { $p = '"' + $p + '"' }
        $runArgs += @("--testplusarg", $p)
    }
}
if ($WallTimeoutSec -gt 0) {
    $proc = Start-Process -FilePath $xsim -ArgumentList $runArgs -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($WallTimeoutSec * 1000)) {
        & taskkill /T /F /PID $proc.Id | Out-Null
        Add-Content -Path xsim.log -Value "WALL TIMEOUT after $WallTimeoutSec s (simulation killed)"
    }
} else {
    & $xsim @runArgs | Out-Null
}
if (-not $Quiet) {
    Select-String -Path xsim.log -Pattern "TEST (START|PASS|FAIL)|PASS:|FAIL:|REGRESSION|TEST STEP .*(mismatch|exp=)|timeout|Fatal|ERROR" |
        ForEach-Object { $_.Line }
}
