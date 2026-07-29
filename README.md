# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

Flow control and arbitration blocks for an Ethernet datapath in SystemVerilog, verified with reference-model testbenches and SymbiYosys proofs, with:

- A credit sender that spends one credit per accepted beat and stalls its source at zero, which removes the need for a `ready` signal from the far end.
- A receive FIFO that returns one credit per beat drained and presents its output as same-cycle `valid` through a holding register.
- A round-robin arbiter that rotates its priority mask after each grant and holds a grant across a burst.
- A synchronous FIFO whose pointers carry an extra wrap bit, separating full from empty with no occupancy counter.

## Verification

| Module | Method |
|--------|--------|
| `credit_sender` + `credit_fifo` | Reference-model testbenches + two-engine SymbiYosys prove and cover |
| `rr_arbiter` | Reference-model testbench + SymbiYosys bounded-wait fairness proof |
| `sync_fifo` | Reference-model testbench |

A credit sits in exactly one of four places, unspent in the sender, in flight forward, occupying a receive slot, or in flight back, and the four counts always sum to `DEPTH`. Receive-FIFO overflow follows from that sum and is unreachable from the receiver alone, which is why the proof instantiates both endpoints and a model of the wire between them.

## Implementation

Synthesized for Xilinx 7-series through sv2v and Yosys, at the default `WIDTH` of 8 and `DEPTH` of 16.

| Module | LUTs | Flip-flops | Distributed RAM (bits) |
|--------|------|------------|------------------------|
| `credit_fifo` \* | 7 | 19 | 512 |
| `credit_sender` | 8 | 5 | 0 |
| `sync_fifo` | 8 | 18 | 512 |
| `rr_arbiter` | 20 | 9 | 0 |

\* Includes its `sync_fifo` instance, which holds all the distributed RAM and 18 of the 19 flip-flops.

## Building and running

```
make MOD=credit_fifo            # run a module's testbench
make wave MOD=credit_fifo       # run the testbench and open the waveform in Surfer
make formal MOD=credit_link     # run every SymbiYosys task in the credit link proof
./synth_stats.sh credit_fifo    # report a module's synthesis cost
```

### Tool versions

Verified with Icarus Verilog 13.0, Yosys 0.66, SymbiYosys 0.66 driving z3 4.16.0 and yices, and Verible for lint.
