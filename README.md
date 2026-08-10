# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

Switching, flow control, arbitration, and control-plane blocks for an Ethernet datapath in SystemVerilog, verified with self-checking testbenches and SymbiYosys proofs, with:

- A 2x2 AXI-Stream switch that routes each packet on its `tdest` field and arbitrates per packet, so beats from two sources never interleave on one output.
- An AXI-Stream skid buffer that breaks the combinational path in both directions and still accepts a beat every cycle.
- A credit sender that spends one credit per accepted beat and stalls its source at zero, which removes the need for a `ready` signal from the far end.
- A receive FIFO that returns one credit per beat drained and presents its output as same-cycle `valid` through a holding register.
- A round-robin arbiter that rotates its priority mask after each grant and holds a grant across a burst.
- A synchronous FIFO whose pointers carry an extra wrap bit, separating full from empty with no occupancy counter.
- An AXI4-Lite register block that honors byte-lane write strobes and answers every request the cycle after it accepts one.

## Verification

| Module | Method |
|--------|--------|
| `axis_switch` | Self-checking testbench + two-engine SymbiYosys prove and cover of routing, packet integrity, symbolic packet tracking, and bounded wait |
| `axis_skid` | Self-checking testbench + two-engine SymbiYosys prove and cover of AXI-Stream compliance and symbolic packet tracking |
| `credit_sender` + `credit_fifo` | Self-checking testbenches + two-engine SymbiYosys prove and cover |
| `rr_arbiter` | Self-checking testbench + SymbiYosys bounded-wait fairness proof |
| `axil_csr` | Self-checking testbench + SymbiYosys prove and cover against ZipCPU `faxil_slave` |
| `sync_fifo` | Self-checking testbench |

A credit sits in exactly one of four places, unspent in the sender, in flight forward, occupying a receive slot, or in flight back, and the four counts always sum to `DEPTH`. Receive-FIFO overflow follows from that sum and is unreachable from the receiver alone, which is why the proof instantiates both endpoints together with a model of the wire between them. The wire model neither drops nor duplicates a beat and is otherwise free to deliver on any schedule, so one proof covers every link latency.

The switch proof reads its arbiter and skid-buffer instances as plain RTL rather than with their own properties enabled, so their `assume` statements cannot constrain the switch's internal signals and rig the result. A solver-chosen source, destination, and beat index track one symbolic beat end to end, which covers every beat on every flow.

Bus compliance on the register block is judged by a third-party property set, Gisselquist's `faxil_slave`, rather than by properties written here. Those properties watch the handshakes and say nothing about stored data, so a shadow copy of one solver-chosen register carries the separate claim that a read returns what the write strobes put there.

## Implementation

Utilization comes from AMD Vivado 2026.1 out-of-context synthesis for the Xilinx Artix-7 XC7A35T, at each module's default parameters.

| Module | LUTs | Flip-flops | Distributed RAM (bits) |
|--------|------|------------|------------------------|
| `credit_sender` | 9 | 5 | 0 |
| `axis_skid` | 14 | 20 | 0 |
| `sync_fifo` | 18 | 18 | 320 |
| `credit_fifo` \* | 19 | 19 | 320 |
| `axil_csr` | 19 | 37 | 1024 |
| `rr_arbiter` | 29 | 9 | 0 |
| `axis_switch` \** | 67 | 50 | 0 |

\* Includes its `sync_fifo` instance, which holds all the distributed RAM and 18 of the 19 flip-flops.

\** Includes one `rr_arbiter` and one `axis_skid` per output.

`vivado/util.tcl` synthesizes each module out of context for that same part and reproduces the counts above.

## Building and running

```
make MOD=credit_fifo               # run a module's testbench
make wave MOD=credit_fifo          # run the testbench and open the waveform in Surfer
make formal MOD=credit_link        # run every SymbiYosys task in the credit link proof
make trace MOD=credit_link         # print a formal counterexample as text
make view-formal MOD=credit_link   # open a formal waveform in Surfer
./synth_stats.sh credit_fifo       # report a module's synthesis cost
```

### Tool versions

Verified with Icarus Verilog 13.0, Yosys 0.66, SymbiYosys 0.66 driving z3 4.16.0 and yices, and Verible for lint.

## Vendored code

Everything under `rtl/`, `tb/` and `formal/` is written here.

`lib/eth/` is Alex Forencich's [verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) under the MIT license, pinned at commit `77320a9`, which supplies the gigabit MAC and the RGMII interface to the board's PHY. Upstream is deprecated in favor of [taxi](https://github.com/fpganinja/taxi) and receives no further changes. Its license and authorship are preserved in `lib/eth/COPYING` and `lib/eth/AUTHORS`.

`formal/faxil_slave.v` is Dan Gisselquist's AXI4-Lite property set from the WB2AXIP project, under the Apache License 2.0.
