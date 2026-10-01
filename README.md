# CHI_Interconnect

AMBA 5 CHI (IHI0050H subset) coherent interconnect in Verilog: RN-F, HN-F with
LLC and snoop filter, SN-F with an AXI bridge, MN for DVM, and a crossbar fabric.

## Layout

| Path | Content |
|---|---|
| `chi_top.v`, `common/`, `fabric/`, `hn/`, `mn/`, `rn/`, `sn/` | RTL |
| `sim/tb/` | Self-checking testbenches (`tb_CHI` is the main directed suite, `tb_chi_random_stress` the random one) |
| `sim/checkers/` | Protocol checker bound into every `chi_top`, coherence scoreboards |
| `sim/formal/` | Helpers included by `tb_CHI` under `CHI_FORMAL` |
| `scripts/` | xsim run scripts (Vivado 2024.1, PowerShell) |
| `docs/` | Fix roadmap and status (Vietnamese) |

## Running

```powershell
# one testbench; logs in reports/<Tag>/xsim.log
.\scripts\run_tb_chi_xsim.ps1 -Top tb_CHI -PlusArgs "CHK_SPEC_ALL"
# every testbench, with all spec rules of the protocol checker
.\scripts\run_regression.ps1
# random stress: seeds 1-8 x {2 RN, 3 RN, real clock gate}
.\scripts\run_stress_seeds.ps1
```

Pass `-VivadoBin <path>` if Vivado is not in `D:\Xilinx\Vivado\2024.1\bin`.
