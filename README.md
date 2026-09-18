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

Subtracting the time a frame of each size occupies the wire leaves 296 ns at every size. Forwarding costs 37 cycles of the 125 MHz clock and holds constant across a 24x range of frame length. Injecting frames past the controller's receive path shortens every row by 152 ns, which splits those 37 cycles into 19 in the controller's receive path and 18 in switching and transmit.

RFC 8238 defines latency for a forwarding device as first bit in to last bit out, measured at the ports. A free-running counter stamps a frame on arrival and on departure, a queue pairs the two, and minimum, maximum, sum and count read back over a serial link. Each row is 3 iterations of 5,000 frames, with relative standard deviation across iterations at or below 0.03% against the 10% ceiling RFC 8239 sets.

## Throughput

| Frame (bytes) | Frames/s | Percent of line rate | Payload (Mb/s) |
|---------------|----------|----------------------|----------------|
| 64 | 1,404,494 | 98.9 | 719.1 |
| 128 | 816,993 | 99.3 | 836.6 |
| 256 | 444,840 | 99.6 | 911.0 |
| 512 | 232,775 | 99.8 | 953.4 |
| 1024 | 119,161 | 99.9 | 976.2 |
| 1514 | 81,222 | 99.9 | 983.8 |

RFC 2544 defines throughput as the highest offered rate a device forwards with zero loss, so each row is a binary search on the idle gap between frames. Frames are generated inside the design and injected at the datapath input, which keeps the host out of the traffic path, and every row forwarded 100,000 of 100,000.
