# eth-datapath

[![CI](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml/badge.svg)](https://github.com/drewbabel/eth-datapath/actions/workflows/ci.yml)

A cut-through gigabit Ethernet switching datapath.

## Latency

| Frame (bytes) | Minimum (µs) | Mean (µs) | Maximum (µs) |
|---------------|--------------|-----------|--------------|
| 64 | 0.872 | 0.875 | 0.880 |
| 128 | 1.384 | 1.387 | 1.392 |
| 256 | 2.408 | 2.411 | 2.416 |
| 512 | 4.456 | 4.459 | 4.464 |
| 1024 | 8.552 | 8.555 | 8.560 |
| 1518 | 12.504 | 12.507 | 12.512 |

Subtracting the time a frame of each size occupies the wire leaves 296 ns at every size. Forwarding costs 37 cycles of the 125 MHz clock and holds constant across a 24x range of frame length. Injecting frames past the controller's receive path shortens every row by 152 ns, which splits those 37 cycles into 19 in the controller's receive path and 18 in switching and transmit.

RFC 8238 defines latency for a forwarding device as first bit in to last bit out, measured at the ports. A free-running counter stamps a frame on arrival and on departure, a queue pairs the two, and minimum, maximum, sum and count read back over a serial link. Each row is 3 iterations of 5,000 frames, with relative standard deviation across iterations at or below 0.02% against the 10% ceiling RFC 8239 sets.

## Throughput

| Frame (bytes) | Frames/s | Percent of line rate | Payload (Mb/s) |
|---------------|----------|----------------------|----------------|
| 64 | 1,488,095 | 100.0 | 714.3 |
| 128 | 844,595 | 100.0 | 837.8 |
| 256 | 452,899 | 100.0 | 913.0 |
| 512 | 234,962 | 100.0 | 954.9 |
| 1024 | 119,732 | 100.0 | 977.0 |
| 1518 | 81,274 | 100.0 | 984.4 |

RFC 2544 defines throughput as the highest offered rate a device forwards with zero loss, so each row is a binary search on the idle gap between frames. Frames are generated inside the design and injected at the datapath input, which keeps the host out of the traffic path, and every row forwarded 100,000 of 100,000.
