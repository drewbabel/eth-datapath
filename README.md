# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

A cut-through gigabit Ethernet switching datapath in SystemVerilog, forwarding between 2 ports on a Digilent Nexys Video FPGA, with:

- A destination-address classifier that reaches a verdict on a frame's first 6 bytes, ahead of a 2-port crossbar arbitrated round-robin and buffered by a skid stage on each output.
- A credit-based link from switch egress to transmit, proved never to let the sender outrun the receiver.
- A 2048-byte elastic buffer on each ingress port, with overflow and drop counters the host can read.
- A 32-bit free-running counter stamping every frame at the receive and transmit pins, reporting minimum, maximum, sum and count.
- A line-rate frame generator inside the design, which keeps the host out of the traffic path during a measurement.
- A 32-register control plane reached over a UART to AXI4-Lite bridge.

## Performance

### Latency

| Frame (bytes) | Minimum (µs) | Mean (µs) | Maximum (µs) | Port to port (µs) |
|---------------|--------------|-----------|--------------|-------------------|
| 64 | 0.720 | 0.720 | 0.720 | 0.872 |
| 128 | 1.232 | 1.232 | 1.232 | 1.384 |
| 256 | 2.256 | 2.256 | 2.256 | 2.408 |
| 512 | 4.304 | 4.304 | 4.304 | 4.456 |
| 1024 | 8.400 | 8.400 | 8.400 | 8.552 |
| 1518 | 12.352 | 12.352 | 12.352 | 12.504 |

Port-to-port time is the frame's own time on the wire plus a constant 296 ns, holding across a 24x range of frame length. That constant is 37 cycles of the 125 MHz clock, 19 in the controller's receive path, and 18 in switching and transmit.

RFC 8238 measures latency first bit in to last bit out at the ports, and RFC 8239 caps relative standard deviation at 10%. Each of the first 3 columns is 20,000 frames at each of 3 offered rates up to line rate, identical at every rate for a deviation of 0.00%.
### Throughput

| Frame (bytes) | Frames/s | Percent of line rate | Payload (Mb/s) |
|---------------|----------|----------------------|----------------|
| 64 | 1,488,095 | 100.0 | 714.3 |
| 128 | 844,595 | 100.0 | 837.8 |
| 256 | 452,899 | 100.0 | 913.0 |
| 512 | 234,962 | 100.0 | 954.9 |
| 1024 | 119,732 | 100.0 | 977.0 |
| 1518 | 81,274 | 100.0 | 984.4 |

RFC 2544 defines throughput as the highest offered rate a device forwards with zero loss. Every row comes from a binary search on the idle gap between frames, settling on a gap that forwarded 100,000 of 100,000.

## Verification

| Method | Scope |
|--------|-------|
| SymbiYosys proofs | `axil_csr` readback at 3 width settings, `axis_skid` payload held across a stall, `axis_switch` one source per output with a frame never interleaved, `rr_arbiter` and `axis_switch` bounded wait, `classifier` at 2 table sizes, `credit_sender` + `credit_fifo` credit conservation |
| Self-checking testbenches | Every module, plus a `datapath_top` test driving the control plane over the bridge |
| Nexys Video | Both tables above, over a live link |

 An inductive proof of credit conservation bounds bytes in flight by free buffer space and makes the link lossless. Note: The vendored Ethernet controller carries no proof.

## Implementation

Post-route utilization per module from AMD Vivado 2026.1 on the Xilinx Artix-7 XC7A200T, reproducible with `vivado/impl_nexys_video.tcl`. A module instantiated on both ports shows the sum of its 2 instances. `tx_shim` merges into the datapath during optimization and has no row of its own.

| Module | Logic LUTs | LUTRAM | Flip-flops | Block RAMs (18 Kb each) |
|--------|------------|--------|------------|-------------------------|
| `credit_sender` | 16 | 0 | 10 | 0 |
| `credit_fifo` | 22 | 8 | 32 | 0 |
| `axis_switch` | 45 | 0 | 34 | 0 |
| `uart_axil` | 122 | 0 | 114 | 0 |
| `frame_gen` | 156 | 0 | 137 | 0 |
| `axil_csr` | 174 | 0 | 549 | 0 |
| `latency_probe` | 197 | 24 | 512 | 0 |
| `eth_mac_1g_rgmii_fifo` | 287 | 28 | 384 | 0 |
| `rx_shim` | 399 | 24 | 448 | 4 |
| `board_top` (total) | 1412 | 84 | 2222 | 4 |

The Ethernet controller and its asynchronous stream queues come from Alex Forencich's `verilog-ethernet`, vendored under `lib/`. The Nexys Video has one Ethernet connector, which port 0 drives and port 1 reaches from the generator.

### Timing

One `MMCME2_BASE` generates 125 MHz for the logic and the transmit clock, a 90-degree copy of that clock for the RGMII output, and 200 MHz for the input delay reference. The routed design meets every constraint in AMD Vivado 2026.1, with 0.435 ns of worst setup slack and 0.056 ns of worst hold slack.

## Building and running

```
make MOD=axis_switch                                        # run a module's testbench
make wave MOD=axis_switch                                   # run it and open the waveform in Surfer
make formal MOD=credit_link                                 # run a module's SymbiYosys proofs
make trace MOD=credit_link                                  # print a formal counterexample as text
make elaborate                                              # check the board top resolves
vivado -mode batch -source vivado/impl_nexys_video.tcl      # build the bitstream
openFPGALoader -b nexysVideo vivado/build/nv/board_top.bit  # flash the bitstream
python3 host/measure.py --iface IFACE --sweep               # measure latency at the ports
python3 host/measure.py --rfc2544 --sweep                   # search for the lossless rate
```
