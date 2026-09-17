"""Send frames at the board, then read latency and counters back over the serial line."""

import argparse
import ctypes
import ctypes.util
import statistics
import struct
import sys
import threading
import time

import serial

ETH_TYPE = 0x88B5
BOARD_MAC = bytes.fromhex("020000000000")
SEQ_OFFSET = 14
MIN_FRAME = 60
MAX_FRAME = 1514

COUNTER_NAMES = ["port0 overflow", "port0 drop", "port1 overflow", "port1 drop"]
COUNTER_ADDRS = [0x40, 0x44, 0x48, 0x4C]

CMD_ADDR = 0x00
CMD_CLEAR = 0x1
CMD_SNAPSHOT = 0x2

PROBE_MIN = 0x50
PROBE_MAX = 0x54
PROBE_COUNT = 0x58
PROBE_SUM_LO = 0x5C
PROBE_SUM_HI = 0x60
PROBE_ERROR = 0x64

TICK_NS = 8.0
SWEEP_SIZES = [64, 128, 256, 512, 1024, 1514]


class TimeVal(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_int32)]


class PktHdr(ctypes.Structure):
    _fields_ = [("ts", TimeVal), ("caplen", ctypes.c_uint32), ("len", ctypes.c_uint32)]


class BpfProgram(ctypes.Structure):
    _fields_ = [("bf_len", ctypes.c_uint), ("bf_insns", ctypes.c_void_p)]


def load_pcap():
    path = ctypes.util.find_library("pcap")
    if path is None:
        sys.exit("libpcap not found")
    lib = ctypes.CDLL(path)
    lib.pcap_create.restype = ctypes.c_void_p
    lib.pcap_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    for name in ("pcap_set_snaplen", "pcap_set_promisc", "pcap_set_timeout",
                 "pcap_set_immediate_mode", "pcap_activate", "pcap_setdirection"):
        fn = getattr(lib, name)
        fn.restype = ctypes.c_int
        fn.argtypes = [ctypes.c_void_p] if name == "pcap_activate" else [
            ctypes.c_void_p,
            ctypes.c_int,
        ]
    lib.pcap_compile.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(BpfProgram),
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_uint,
    ]
    lib.pcap_setfilter.argtypes = [ctypes.c_void_p, ctypes.POINTER(BpfProgram)]
    lib.pcap_sendpacket.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    lib.pcap_next_ex.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.POINTER(PktHdr)),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
    ]
    lib.pcap_geterr.restype = ctypes.c_char_p
    lib.pcap_geterr.argtypes = [ctypes.c_void_p]
    lib.pcap_close.argtypes = [ctypes.c_void_p]
    return lib


def open_capture(lib, iface):
    err = ctypes.create_string_buffer(256)
    handle = lib.pcap_create(iface.encode(), err)
    if not handle:
        sys.exit("pcap_create failed: %s" % err.value.decode())
    lib.pcap_set_snaplen(handle, 2048)
    lib.pcap_set_promisc(handle, 1)
    lib.pcap_set_timeout(handle, 1)
    lib.pcap_set_immediate_mode(handle, 1)
    rc = lib.pcap_activate(handle)
    if rc < 0:
        sys.exit("pcap_activate failed: %s" % lib.pcap_geterr(handle).decode())
    if lib.pcap_setdirection(handle, 1) != 0:
        sys.exit("pcap_setdirection failed: %s" % lib.pcap_geterr(handle).decode())
    prog = BpfProgram()
    rule = ("ether proto 0x%04x" % ETH_TYPE).encode()
    if lib.pcap_compile(handle, ctypes.byref(prog), rule, 1, 0xFFFFFFFF) != 0:
        sys.exit("pcap_compile failed: %s" % lib.pcap_geterr(handle).decode())
    if lib.pcap_setfilter(handle, ctypes.byref(prog)) != 0:
        sys.exit("pcap_setfilter failed: %s" % lib.pcap_geterr(handle).decode())
    return handle


def host_mac(iface):
    import subprocess

    out = subprocess.check_output(["ifconfig", iface]).decode()
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0] == "ether":
            return bytes.fromhex(parts[1].replace(":", ""))
    sys.exit("no hardware address on %s" % iface)


def build_frame(src, seq, size):
    body = struct.pack("!I", seq)
    pad = size - 14 - len(body)
    return BOARD_MAC + src + struct.pack("!H", ETH_TYPE) + body + b"\x00" * pad


class Receiver(threading.Thread):
    def __init__(self, lib, handle):
        super().__init__(daemon=True)
        self.lib = lib
        self.handle = handle
        self.stamps = {}
        self.count = 0
        self.first = None
        self.last = None
        self.running = True

    def run(self):
        hdr = ctypes.POINTER(PktHdr)()
        data = ctypes.POINTER(ctypes.c_ubyte)()
        while self.running:
            rc = self.lib.pcap_next_ex(
                self.handle, ctypes.byref(hdr), ctypes.byref(data)
            )
            if rc != 1:
                continue
            now = time.perf_counter()
            raw = bytes(ctypes.string_at(data, SEQ_OFFSET + 4))
            seq = struct.unpack("!I", raw[SEQ_OFFSET : SEQ_OFFSET + 4])[0]
            self.stamps.setdefault(seq, now)
            if self.first is None:
                self.first = now
            self.last = now
            self.count += 1


def run_throughput(lib, handle, rx, src, count, size, settle):
    rx.first = None
    rx.last = None
    base = rx.count
    frames = [build_frame(src, 1_000_000 + i, size) for i in range(count)]
    failed = 0
    start = time.perf_counter()
    for frame in frames:
        if lib.pcap_sendpacket(handle, frame, len(frame)) != 0:
            failed += 1
    push = time.perf_counter() - start
    time.sleep(settle)
    got = rx.count - base
    span = (rx.last - rx.first) if (rx.first and rx.last and rx.last > rx.first) else None
    wire = None if span is None else got * (size + 20) * 8 / span / 1e6
    return got, push, span, wire, failed


def read_register(port, addr):
    port.reset_input_buffer()
    port.write(bytes([0x52, addr]))
    raw = port.read(4)
    if len(raw) != 4:
        raise RuntimeError("serial read timed out at 0x%02x" % addr)
    return struct.unpack("<I", raw)[0]


def write_register(port, addr, value):
    port.reset_input_buffer()
    port.write(bytes([0x57, addr]) + struct.pack("<I", value))
    ack = port.read(1)
    if ack != b"K":
        raise RuntimeError("no write acknowledgement at 0x%02x" % addr)


def probe_command(port, bit):
    write_register(port, CMD_ADDR, bit)
    write_register(port, CMD_ADDR, 0)


def probe_read(port):
    count = read_register(port, PROBE_COUNT)
    total = read_register(port, PROBE_SUM_LO) | (read_register(port, PROBE_SUM_HI) << 32)
    low = read_register(port, PROBE_MIN)
    high = read_register(port, PROBE_MAX)
    err = read_register(port, PROBE_ERROR)
    return {
        "count": count,
        "min_ns": low * TICK_NS,
        "max_ns": high * TICK_NS,
        "avg_ns": (total * TICK_NS / count) if count else 0.0,
        "overflow": err & 0xFFFF,
        "unpaired": (err >> 16) & 0xFFFF,
    }


def relative_stdev(values):
    if len(values) < 2:
        return 0.0
    mean = statistics.fmean(values)
    if mean == 0:
        return 0.0
    return 100.0 * statistics.stdev(values) / mean


def one_trial(lib, handle, rx, src, port, size, count, settle):
    probe_command(port, CMD_CLEAR)
    dropped = read_register(port, COUNTER_ADDRS[1])
    got, push, span, wire, failed = run_throughput(lib, handle, rx, src, count, size, settle)
    probe_command(port, CMD_SNAPSHOT)
    stats = probe_read(port)
    stats["stray"] = read_register(port, COUNTER_ADDRS[1]) - dropped
    stats["sent"] = count
    stats["returned"] = got
    stats["push_s"] = push
    stats["wire_mbps"] = wire
    stats["failed"] = failed
    return stats


def print_table(rows):
    print("")
    print("latency at the pins, first bit in to last bit out, 8 ns resolution")
    print("")
    print("  bytes  paired   min us   avg us   max us   rsd %  return Mb/s  unpaired  overflow  stray  unsent")
    for r in rows:
        print("  %5d  %6d  %7.3f  %7.3f  %7.3f  %6.2f  %11s  %8d  %8d  %5d  %6d" % (
            r["size"],
            r["count"],
            r["min_ns"] / 1000.0,
            r["avg_ns"] / 1000.0,
            r["max_ns"] / 1000.0,
            r["rsd"],
            "%.1f" % r["wire_mbps"] if r["wire_mbps"] else "n/a",
            r["unpaired"],
            r["overflow"],
            r["stray"],
            r["failed"],
        ))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iface", default="en13", help="host ethernet interface")
    ap.add_argument("--serial", default="/dev/cu.usbserial-AV0JX88M")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--size", type=int, help="single frame size without checksum")
    ap.add_argument("--sweep", action="store_true", help="run the standard size sweep")
    ap.add_argument("--count", type=int, default=5000, help="frames per trial")
    ap.add_argument("--iterations", type=int, default=3)
    ap.add_argument("--settle", type=float, default=0.5)
    args = ap.parse_args()

    if args.sweep:
        sizes = SWEEP_SIZES
    else:
        sizes = [args.size or 64]
    for size in sizes:
        if not MIN_FRAME <= size <= MAX_FRAME:
            sys.exit("size must be between %d and %d" % (MIN_FRAME, MAX_FRAME))

    lib = load_pcap()
    handle = open_capture(lib, args.iface)
    src = host_mac(args.iface)
    rx = Receiver(lib, handle)
    rx.start()

    print("interface %s  source %s" % (args.iface, src.hex(":")))
    print("%d iterations of %d frames per size" % (args.iterations, args.count))

    rows = []
    with serial.Serial(args.serial, args.baud, timeout=2) as port:
        before = [read_register(port, a) for a in COUNTER_ADDRS]
        for size in sizes:
            trials = [
                one_trial(lib, handle, rx, src, port, size, args.count, args.settle)
                for _ in range(args.iterations)
            ]
            best = trials[-1]
            rows.append({
                "size": size,
                "count": sum(t["count"] for t in trials),
                "min_ns": min(t["min_ns"] for t in trials),
                "max_ns": max(t["max_ns"] for t in trials),
                "avg_ns": statistics.fmean([t["avg_ns"] for t in trials]),
                "rsd": relative_stdev([t["avg_ns"] for t in trials]),
                "wire_mbps": best["wire_mbps"],
                "unpaired": sum(t["unpaired"] for t in trials),
                "stray": sum(t["stray"] for t in trials),
                "failed": sum(t["failed"] for t in trials),
                "overflow": sum(t["overflow"] for t in trials),
            })
        after = [read_register(port, a) for a in COUNTER_ADDRS]

    rx.running = False
    print_table(rows)

    print("")
    print("counters over the serial line, change during this run")
    for name, was, now in zip(COUNTER_NAMES, before, after):
        print("  %-16s %d" % (name, now - was))


if __name__ == "__main__":
    main()
