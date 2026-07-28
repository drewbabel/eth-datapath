#   make MOD=rr_arbiter           		    compile rtl/ + that tb, run (test FAIL exits nonzero)
#   make wave MOD=rr_arbiter        		same, then open the waveform in surfer (opens even on FAIL)
#   make view MOD=rr_arbiter         		open testbench waveform in surfer (error if .vcd missing)
#   make view-formal MOD=rr_arbiter_cover   open formal waveform (error if .vcd missing)
#   make formal MOD=rr_arbiter  		    run every SymbiYosys task in formal/$(MOD).sby (FAIL exits nonzero)
#   make clean                  		    delete build artifacts (build/, *.vcd)

RTL := $(wildcard rtl/*.sv)
TB  := tb/$(MOD)_tb.sv
SIM := build/sim
WAVE_STATE := tb/$(MOD).ron
FORMAL := formal/$(MOD).sby

run:
	@test -n "$(MOD)" || { echo "usage: make MOD=<module>  (e.g. MOD=rr_arbiter)"; exit 1; }
	@mkdir -p build
	iverilog -g2012 -s $(MOD)_tb -o $(SIM) $(RTL) $(TB)
	vvp $(SIM)

wave:
	@test -n "$(MOD)" || { echo "usage: make wave MOD=<module>"; exit 1; }
	@mkdir -p build
	iverilog -g2012 -s $(MOD)_tb -o $(SIM) $(RTL) $(TB)
	-vvp $(SIM)
	surfer $$(ls *.vcd 2>/dev/null | head -1) $$(test -f $(WAVE_STATE) && echo "-s $(WAVE_STATE)") &

formal:
	@test -n "$(MOD)" || { echo "usage: make formal MOD=<module>  (e.g. MOD=rr_arbiter)"; exit 1; }
	sby -f $(FORMAL)

view:
	@test -n "$(MOD)" || { echo "usage: make view MOD=<module>"; exit 1; }
	@test -f "tb/$(MOD).ron" || { echo "Error: tb/$(MOD).ron not found"; exit 1; }
	@test -f "$$(ls tb/*.vcd 2>/dev/null | head -1)" || { echo "Error: no .vcd found in tb/"; exit 1; }
	surfer $$(ls tb/*.vcd 2>/dev/null | head -1) -s tb/$(MOD).ron &

view-formal:
	@test -n "$(MOD)" || { echo "usage: make view-formal MOD=<module>  (e.g. MOD=rr_arbiter)"; exit 1; }
	@test -f "$$(find formal/$(MOD) -name '*.vcd' 2>/dev/null | head -1)" || { echo "Error: no .vcd found in formal/$(MOD)/"; exit 1; }
	surfer $$(find formal/$(MOD) -name '*.vcd' 2>/dev/null | head -1) $$(test -f formal/$(MOD).ron && echo "-s formal/$(MOD).ron") &

clean:
	rm -rf build *.vcd sim_build results.xml

.DEFAULT_GOAL := run
.PHONY: run wave formal view view-formal clean
