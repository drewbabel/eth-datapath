# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

A cut-through gigabit Ethernet switching datapath.

## Latency

| Frame (bytes) | Minimum (µs) | Mean (µs) | Maximum (µs) |
|---------------|--------------|-----------|--------------|
| 64 | 0.904 | 0.908 | 0.912 |
| 128 | 1.416 | 1.420 | 1.424 |
| 256 | 2.440 | 2.444 | 2.448 |
| 512 | 4.488 | 4.492 | 4.496 |
| 1024 | 8.584 | 8.588 | 8.592 |
| 1514 | 12.504 | 12.508 | 12.512 |

Subtracting the time a frame of each size occupies the wire leaves 296 ns at every size. Forwarding costs 37 cycles of the 125 MHz clock and holds constant across a 24x range of frame length.

RFC 8238 defines latency for a forwarding device as first bit in to last bit out, measured at the ports. A free-running counter stamps a frame on arrival and on departure, a queue pairs the two, and minimum, maximum, sum and count read back over a serial link. Each row is 3 iterations of 5,000 frames, with relative standard deviation across iterations at or below 0.03% against the 10% ceiling RFC 8239 sets.
