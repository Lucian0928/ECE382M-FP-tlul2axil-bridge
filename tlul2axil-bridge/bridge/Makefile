# TL-UL -> AXI4-Lite bridge: simulation
#   make sim               (Icarus Verilog, seed=1)
#   make sim SEED=7 NTRANS=20000
#   make regress           (10 seeds)
#   make nc                (Cadence NC-Verilog on the course server)
RTL    = rtl/tlul2axil.v
TB     = tb/axil_slave_model.v tb/tb_tlul2axil.v
SEED  ?= 1
NTRANS ?= 5000

sim: build/sim.vvp
	vvp -n build/sim.vvp +seed=$(SEED) +ntrans=$(NTRANS)

wave: build/sim.vvp
	vvp -n build/sim.vvp +seed=$(SEED) +ntrans=$(NTRANS) +vcd

build/sim.vvp: $(RTL) $(TB)
	@mkdir -p build
	iverilog -g2005 -Wall -o $@ $(RTL) $(TB)

regress: build/sim.vvp
	@for s in 1 2 3 4 5 6 7 8 9 10; do \
	  printf "seed %-3s " $$s; \
	  vvp -n build/sim.vvp +seed=$$s +ntrans=$(NTRANS) | grep -E "PASS|FAIL"; \
	done

nc:
	ncverilog +access+r $(RTL) $(TB) +seed=$(SEED) +ntrans=$(NTRANS)

clean:
	rm -rf build *.vcd INCA_libs ncverilog.log

.PHONY: sim wave regress nc clean
