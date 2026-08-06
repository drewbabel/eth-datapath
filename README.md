# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

Switching, flow control, arbitration, and control-plane blocks for an Ethernet datapath in SystemVerilog, verified with reference-model testbenches and SymbiYosys proofs, with:

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
| `axis_switch` | Reference-model testbench + two-engine SymbiYosys prove and cover of routing, packet atomicity, symbolic beat delivery, and bounded wait |
| `axis_skid` | Reference-model testbench + two-engine SymbiYosys prove and cover of AXI-Stream compliance and symbolic beat delivery |
| `credit_sender` + `credit_fifo` | Reference-model testbenches + two-engine SymbiYosys prove and cover |
| `rr_arbiter` | Reference-model testbench + SymbiYosys bounded-wait fairness proof |
| `axil_csr` | Reference-model testbench + SymbiYosys prove and cover against ZipCPU `faxil_slave` |
| `sync_fifo` | Reference-model testbench |

A credit sits in exactly one of four places, unspent in the sender, in flight forward, occupying a receive slot, or in flight back, and the four counts always sum to `DEPTH`. Receive-FIFO overflow follows from that sum and is unreachable from the receiver alone, which is why the proof instantiates both endpoints together with a model of the wire between them. The wire model neither drops nor duplicates a beat and is otherwise free to deliver on any schedule, so one proof covers every link latency.

The switch proof reads its arbiter and skid-buffer instances as plain RTL rather than with their own properties enabled, so their `assume` statements cannot constrain the switch's internal signals and rig the result. A solver-chosen source, destination, and beat index track one symbolic beat end to end, which covers every beat on every flow.

Bus compliance on the register block is judged by a third-party property set, Gisselquist's `faxil_slave`, rather than by properties written here. Those properties watch the handshakes and say nothing about stored data, so a shadow copy of one solver-chosen register carries the separate claim that a read returns what the write strobes put there.

## Implementation

Synthesized for Xilinx 7-series through sv2v and Yosys, at each module's default parameters.

| Module | LUTs | Flip-flops | Distributed RAM (bits) |
|--------|------|------------|------------------------|
| `credit_fifo` \* | 7 | 19 | 512 |
| `credit_sender` | 8 | 5 | 0 |
| `sync_fifo` | 8 | 18 | 512 |
| `axil_csr` | 10 | 37 | 2048 |
| `axis_skid` | 13 | 20 | 0 |
| `rr_arbiter` | 20 | 9 | 0 |
| `axis_switch` \** | 66 | 50 | 0 |

\* Includes its `sync_fifo` instance, which holds all the distributed RAM and 18 of the 19 flip-flops.

\** Includes one `rr_arbiter` and one `axis_skid` per output.

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

Everything under `rtl/`, `tb/` and `formal/` is written here. `lib/eth/` is Alex Forencich's [verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) under the MIT license, vendored as a squashed git subtree so a clone builds with no extra steps, and refreshed with `lib/update-eth.sh`. It supplies the gigabit MAC and the RGMII interface to the board's PHY. Its license and authorship are preserved in `lib/eth/COPYING` and `lib/eth/AUTHORS`.
