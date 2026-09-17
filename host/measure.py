"""Send frames at the board and read its counters back over the serial line."""

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
COUNTER_ADDRS = [0x10, 0x14, 0x18, 0x1C]


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


def run_latency(lib, handle, rx, src, count, size, timeout):
    samples = []
    lost = 0
    for seq in range(count):
        frame = build_frame(src, seq, size)
        start = time.perf_counter()
        lib.pcap_sendpacket(handle, frame, len(frame))
        deadline = start + timeout
        while seq not in rx.stamps and time.perf_counter() < deadline:
            time.sleep(0)
        if seq in rx.stamps:
            samples.append((rx.stamps[seq] - start) * 1e6)
        else:
            lost += 1
    return samples, lost


def run_throughput(lib, handle, rx, src, count, size, settle):
    rx.first = None
    rx.last = None
    base = rx.count
    frames = [build_frame(src, 1_000_000 + i, size) for i in range(count)]
    start = time.perf_counter()
    for frame in frames:
        lib.pcap_sendpacket(handle, frame, len(frame))
    push = time.perf_counter() - start
    time.sleep(settle)
    got = rx.count - base
    span = (rx.last - rx.first) if (rx.first and rx.last and rx.last > rx.first) else None
    wire = None if span is None else got * (size + 20) * 8 / span / 1e6
    return got, push, span, wire


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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--iface", default="en13", help="host ethernet interface")
    ap.add_argument("--serial", default="/dev/cu.usbserial-AV0JX88M")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--size", type=int, default=64, help="frame bytes without checksum")
    ap.add_argument("--latency-count", type=int, default=200)
    ap.add_argument("--throughput-count", type=int, default=5000)
    ap.add_argument("--timeout", type=float, default=0.05)
    ap.add_argument("--settle", type=float, default=0.5)
    ap.add_argument("--skip-serial", action="store_true")
    args = ap.parse_args()

    if not MIN_FRAME <= args.size <= MAX_FRAME:
        sys.exit("size must be between %d and %d" % (MIN_FRAME, MAX_FRAME))

    before = [0] * len(COUNTER_ADDRS)
    if not args.skip_serial:
        with serial.Serial(args.serial, args.baud, timeout=2) as port:
            before = [read_register(port, a) for a in COUNTER_ADDRS]

    lib = load_pcap()
    handle = open_capture(lib, args.iface)
    src = host_mac(args.iface)
    rx = Receiver(lib, handle)
    rx.start()

    print("interface %s  source %s" % (args.iface, src.hex(":")))
    print("frame size %d bytes" % args.size)

    samples, lost = run_latency(
        lib, handle, rx, src, args.latency_count, args.size, args.timeout
    )
    if samples:
        ordered = sorted(samples)
        print("")
        print("round trip over the host stack, microseconds")
        print("  returned %d of %d" % (len(samples), args.latency_count))
        print("  min      %.1f" % ordered[0])
        print("  median   %.1f" % statistics.median(ordered))
        print("  p99      %.1f" % ordered[min(len(ordered) - 1, int(0.99 * len(ordered)))])
        print("  max      %.1f" % ordered[-1])
    else:
        print("no frames came back, %d lost" % lost)

    got, push, span, wire = run_throughput(
        lib, handle, rx, src, args.throughput_count, args.size, args.settle
    )
    print("")
    print("throughput")
    print("  sent      %d frames, host push took %.4f s" % (args.throughput_count, push))
    print("  returned  %d frames (%.1f percent)" % (got, 100.0 * got / args.throughput_count))
    if wire is not None:
        print("  return    %.1f Mb/s measured across %.4f s of returns" % (wire, span))

    rx.running = False

    if args.skip_serial:
        return
    with serial.Serial(args.serial, args.baud, timeout=2) as port:
        print("")
        print("counters over the serial line, change during this run")
        for name, addr, was in zip(COUNTER_NAMES, COUNTER_ADDRS, before):
            print("  %-16s %d" % (name, read_register(port, addr) - was))


if __name__ == "__main__":
    main()
