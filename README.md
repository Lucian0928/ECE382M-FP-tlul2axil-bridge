# ECE382M-7 Final Project Group 13: TL-UL to AXI4-Lite Bridge

Members: Yen-Yu Chen, Chia-Huang Chen, Amaury Jayr, Hao-Yu Chang

| Path | Contents |
|---|---|
| `FP.pdf` | Project proposal |
| `tlul2axil-bridge/bridge/rtl/` | Bridge RTL (`tlul2axil.v`) |
| `tlul2axil-bridge/bridge/tb/` | Testbench and AXI4-Lite slave model |
| `tlul2axil-bridge/bridge/Makefile` | `make sim`, `make regress`, `make nc` (NC-Verilog) |
| `tlul2axil-bridge/report/` | Interim report (docx / pdf) and figures |
| `tlul2axil-bridge/FP_implementation_plan.md` | Implementation plan |

## Run the simulation
```bash
cd tlul2axil-bridge/bridge
make sim          # Icarus Verilog
make nc           # NC-Verilog on the course server
```

## Working together
Please work on a branch and open a pull request instead of pushing to `main` directly:
```bash
git checkout -b your-name/feature
git push -u origin your-name/feature
```
