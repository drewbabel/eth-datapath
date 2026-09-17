#   make MOD=rr_arbiter           		    compile rtl/ + that tb, run (test FAIL exits nonzero)
#   make wave MOD=rr_arbiter        		same, then open the waveform in surfer (opens even on FAIL)
#   make view MOD=rr_arbiter         		open testbench waveform in surfer (error if .vcd missing)
#   make formal MOD=rr_arbiter  		    run every SymbiYosys task in formal/$(MOD).sby (FAIL exits nonzero)
#   make trace MOD=rr_arbiter    		    print a formal counterexample as text
#   make view-formal MOD=rr_arbiter 	    open a formal waveform in surfer
#   make elaborate              		    check the board top resolves before a cloud build
#   make clean                  		    delete build artifacts (build/, *.vcd)

RTL := $(wildcard rtl/*.sv)
# Vendored library search
LIB := -y lib/eth/rtl -y lib/eth/lib/axis/rtl -y lib/uart/rtl -Y .v -Y .sv
VENDORED_ETH  := iddr oddr ssio_ddr_in ssio_ddr_out rgmii_phy_if eth_mac_1g_rgmii_fifo \
       eth_mac_1g_rgmii eth_mac_1g axis_gmii_rx axis_gmii_tx lfsr
VENDORED_AXIS := axis_fifo axis_async_fifo axis_async_fifo_adapter sync_reset
TB  := $(firstword $(wildcard tb/$(MOD)_tb.sv lib/*/tb/$(MOD)_tb.sv))
SIM := build/sim
WAVE_STATE := tb/$(MOD).ron
FORMAL := formal/$(MOD).sby

run:
	@test -n "$(MOD)" || { echo "usage: make MOD=<module>  (e.g. MOD=rr_arbiter)"; exit 1; }
	@mkdir -p build
	iverilog -g2012 $(LIB) -s $(MOD)_tb -o $(SIM) $(RTL) $(TB)
	vvp $(SIM)

wave:
	@test -n "$(MOD)" || { echo "usage: make wave MOD=<module>"; exit 1; }
	@mkdir -p build
	iverilog -g2012 $(LIB) -s $(MOD)_tb -o $(SIM) $(RTL) $(TB)
	-vvp $(SIM)
	surfer $$(ls *.vcd 2>/dev/null | head -1) $$(test -f $(WAVE_STATE) && echo "-s $(WAVE_STATE)") &

view:
	@test -n "$(MOD)" || { echo "usage: make view MOD=<module>"; exit 1; }
	@test -f "tb/$(MOD).ron" || { echo "Error: tb/$(MOD).ron not found"; exit 1; }
	@test -f "$$(ls tb/*.vcd 2>/dev/null | head -1)" || { echo "Error: no .vcd found in tb/"; exit 1; }
	surfer $$(ls tb/*.vcd 2>/dev/null | head -1) -s tb/$(MOD).ron &

formal:
	@test -n "$(MOD)" || { echo "usage: make formal MOD=<module>  (e.g. MOD=rr_arbiter)"; exit 1; }
	@tasks=$$(sby --dumptasks $(FORMAL)); \
	if [ -z "$$tasks" ]; then sby -f $(FORMAL); \
	else for t in $$tasks; do echo "== $(MOD): $$t =="; sby -f $(FORMAL) $$t || exit 1; done; fi

# Run directory picker
define pick_run
	test -n "$(MOD)" || { echo "usage: make $@ MOD=<module>  (e.g. MOD=rr_arbiter)" >&2; exit 1; }; \
	runs=$$(for d in formal/$(MOD)/ formal/$(MOD)_*/; do [ -f "$$d/status" ] && echo "$${d%/}"; done); \
	[ -n "$$runs" ] || { echo "No runs for $(MOD), try: make formal MOD=$(MOD)" >&2; exit 1; }; \
	if [ $$(echo "$$runs" | wc -l) -eq 1 ]; then echo "$$runs"; else \
	  i=0; for d in $$runs; do i=$$((i+1)); \
	    printf '  %d) %-12s %-6s%s\n' $$i "$$(basename $$d | sed 's/^$(MOD)_//')" \
	      "$$(cut -d' ' -f1 $$d/status)" \
	      "$$(find $$d -name trace.yw 2>/dev/null | head -1 | sed 's/.*/counterexample/')" >&2; \
	  done; \
	  printf 'Select task: ' >&2; read n; \
	  sel=$$(echo "$$runs" | sed -n "$${n}p" 2>/dev/null); \
	  [ -d "$$sel" ] || { echo "No task $$n" >&2; exit 1; }; \
	  echo "$$sel"; fi
endef

trace:
	@dir=$$($(pick_run)); test -n "$$dir" || exit 1; \
	yw=$$(find $$dir -name 'trace.yw' 2>/dev/null | head -1); \
	test -n "$$yw" || { echo "Error: no trace.yw in $$dir/, that run has no counterexample"; exit 1; }; \
	yosys-witness display $$yw | cat

view-formal:
	@dir=$$($(pick_run)); test -n "$$dir" || exit 1; \
	vcd=$$(find $$dir -name '*.vcd' 2>/dev/null | head -1); \
	test -n "$$vcd" || { echo "Error: no .vcd found in $$dir/"; exit 1; }; \
	echo "surfer $$vcd"; \
	surfer $$vcd $$(test -f $$dir.ron && echo "-s $$dir.ron") &


elaborate:
	@t=$$(mktemp -d); mkdir -p $$t/src; \
	for f in rtl/*.sv lib/uart/rtl/*.sv boards/nexys_video/board_top.sv; do \
	  sed -e 's/parameter string /parameter /' -e '/default_nettype/d' "$$f" > $$t/src/$$(basename $$f); \
	done; \
	{ echo "read_verilog -lib -specify +/xilinx/cells_sim.v"; \
	  echo "read_verilog -lib +/xilinx/cells_xtra.v"; \
	  for f in $(VENDORED_ETH); do echo "read_verilog lib/eth/rtl/$$f.v"; done; \
	  for f in $(VENDORED_AXIS); do echo "read_verilog lib/eth/lib/axis/rtl/$$f.v"; done; \
	  echo "read_verilog -sv $$t/src/*.sv"; \
	  echo "hierarchy -top board_top -check"; } > $$t/check.ys; \
	yosys -q -s $$t/check.ys 2>&1 | grep -E "^ERROR" && exit 1; \
	echo "ELABORATE OK"

clean:
	rm -rf build *.vcd sim_build results.xml

.DEFAULT_GOAL := run
.PHONY: run wave view formal trace view-formal elaborate clean
