"""End-to-end integration test for top.sv.

Drives the whole system the way the PC will: CSR configuration is written over
UART, acquisition is started over UART, and the reconstructed image is pulled
back as a 0x01 dump packet over UART and compared against a numpy reference.

DMD and bucket detector are stubbed by cocotb coroutines; patterns are
backdoor-loaded into the pattern BRAM (the PC would normally upload them too).

Frame format (matches uart_interface):
    SOF(0xAA) | TYPE | LEN_HI | LEN_LO | PAYLOAD | CRC8(xor of payload)
CSR write payload: [addr, val[7:0], val[15:8], val[23:16], val[31:24]] (LE value).
Dump payload: n_pixels x int32, big-endian (MSB first).
"""
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS  = 10
CYCLES_PER_BIT = 8       # CLK_HZ / BAUD = 1_000_000 / 125_000

# Must match wrapper parameter defaults
PATTERN_WIDTH  = 8
N_PATTERNS_MAX = 16
BUCKET_WIDTH   = 12
ACC_WIDTH      = 32

# Must match sim/cocotb/xadc/xadc_interface/xadc_wiz_0_stub.sv's CONV_LATENCY
XADC_CONV_LATENCY = 5

# CSR addresses (architecture.md §8)
ADDR_CTRL       = 0x00
ADDR_N_PATTERNS = 0x02
ADDR_T_SETTLE   = 0x03
ADDR_T_SAMPLE   = 0x04
ADDR_MODE       = 0x05

# Packet TYPEs
TYPE_CSR_WRITE = 0x10
TYPE_CSR_ACK   = 0x03
TYPE_DUMP_REQ  = 0x12
TYPE_DUMP      = 0x01
SOF            = 0xAA

# CSR scratch register (write-only sink, address 0x07) for arbiter probing.
ADDR_SCRATCH = 0x07

STATUS_DONE = 1


# ── Clock / reset ───────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def reset(dut):
    dut.rst_n.value      = 0
    dut.uart_rx.value    = 1     # UART idle is high
    dut.vauxp0.value     = 0
    dut.vauxn0.value     = 0
    dut.gpio4_intf.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


# ── Backdoor BRAM access ────────────────────────────────────────────────────

def backdoor_load_patterns(dut, patterns):
    for i, pat in enumerate(patterns):
        dut.dut.u_pat_bram.mem[i].value = pat & ((1 << PATTERN_WIDTH) - 1)


def backdoor_zero_accumulator(dut):
    for i in range(PATTERN_WIDTH):
        dut.dut.u_corr.acc_mem.mem[i].value = 0


# ── Host-side UART (PC → FPGA on uart_rx) ───────────────────────────────────

async def send_byte(dut, val):
    dut.uart_rx.value = 0                                   # start bit
    await ClockCycles(dut.clk, CYCLES_PER_BIT)
    for i in range(8):                                      # LSB first
        dut.uart_rx.value = (val >> i) & 1
        await ClockCycles(dut.clk, CYCLES_PER_BIT)
    dut.uart_rx.value = 1                                   # stop bit
    await ClockCycles(dut.clk, CYCLES_PER_BIT)


async def send_packet(dut, msg_type, payload):
    crc = 0
    for b in payload:
        crc ^= b
    frame = [SOF, msg_type, (len(payload) >> 8) & 0xFF, len(payload) & 0xFF] + payload + [crc]
    for b in frame:
        await send_byte(dut, b)


async def csr_write(dut, addr, value):
    payload = [addr & 0xFF,
               value & 0xFF, (value >> 8) & 0xFF,
               (value >> 16) & 0xFF, (value >> 24) & 0xFF]
    await send_packet(dut, TYPE_CSR_WRITE, payload)
    # Wait for the ACK to finish transmitting so the next command's send_ack
    # isn't dropped while the CSR TX FSM is still busy.
    await ClockCycles(dut.clk, CYCLES_PER_BIT * 10)
    while int(dut.dut.u_csr.csr_tx_state.value) != 0:      # 0 = TX_IDLE
        await RisingEdge(dut.clk)
    await ClockCycles(dut.clk, 4)


# ── Host-side UART (FPGA → PC on uart_tx) ───────────────────────────────────

async def uart_monitor(dut, out_bytes):
    """Continuously decode 8N1 bytes off uart_tx into out_bytes."""
    while dut.uart_tx.value != 1:
        await RisingEdge(dut.clk)
    while True:
        while dut.uart_tx.value != 0:                      # wait for start bit
            await RisingEdge(dut.clk)
        await ClockCycles(dut.clk, CYCLES_PER_BIT + CYCLES_PER_BIT // 2)
        val = 0
        for i in range(8):
            val |= (int(dut.uart_tx.value) & 1) << i       # LSB first
            await ClockCycles(dut.clk, CYCLES_PER_BIT)
        out_bytes.append(val)


def parse_frames(byte_list):
    """Linearly parse concatenated frames. Returns list of (type, payload, crc_ok)."""
    frames = []
    i = 0
    n = len(byte_list)
    while i + 5 <= n:                                       # min frame = 5 bytes (len 0)
        # Resync on SOF: skip any inter-frame filler (e.g. a stray idle-line
        # 0x00 the bit-bang monitor can latch between transmissions).
        if byte_list[i] != SOF:
            i += 1
            continue
        msg_type = byte_list[i + 1]
        length   = (byte_list[i + 2] << 8) | byte_list[i + 3]
        if i + 4 + length + 1 > n:
            break                                          # incomplete tail
        payload = byte_list[i + 4 : i + 4 + length]
        crc     = byte_list[i + 4 + length]
        xor = 0
        for b in payload:
            xor ^= b
        frames.append((msg_type, payload, xor == crc))
        i += 4 + length + 1
    return frames


# ── Bucket stub ──────────────────────────────────────────────────────────────
# The DMD's old pat_req/dmd_ack handshake no longer exists as a top.sv port:
# dmd_ack is tied permanently high inside top.sv now (dmd_video_if runs off
# pattern_sequencer's own t_settle_reg/t_sample_reg timers, not a per-pattern
# ack). Nothing needs to stub it.
#
# The bucket detector's xadc_wiz_0 IP is replaced by the behavioral stub
# (see sim/cocotb/xadc/xadc_interface/xadc_wiz_0_stub.sv) that free-runs
# continuously and returns whatever is in its stub_sample backdoor register.
# Since xadc_interface has no external trigger (see its header), this
# coroutine's only job is to keep stub_sample updated to the value that
# should appear once pattern_sequencer's SAMPLE window opens -- the stub's
# own free-run loop (period == XADC_CONV_LATENCY cycles) guarantees a
# sample_valid pulse lands inside any t_sample window >= that period.
def stub_sample_path(dut):
    return dut.dut.u_xadc.u_xadc_wiz.stub_sample


async def fake_bucket(dut, bucket_values):
    """Advances stub_sample to the next bucket value each time
    pattern_sequencer's SAMPLE state opens smp_gate. smp_gate has no
    external port anymore (see top.sv), so this reads it via the debug
    hierarchical path into pattern_sequencer's internal signal."""
    pattern_idx = 0
    prev_gate = 0
    while True:
        await RisingEdge(dut.clk)
        gate = int(dut.dut.u_seq.smp_gate.value)
        if gate == 1 and prev_gate == 0:
            if pattern_idx < len(bucket_values):
                stub_sample_path(dut).value = bucket_values[pattern_idx] & ((1 << BUCKET_WIDTH) - 1)
                pattern_idx += 1
        prev_gate = gate


async def wait_for_done(dut, timeout_cycles=20_000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dbg_status.value) & (1 << STATUS_DONE):
            return
    raise TimeoutError("done flag never asserted")


def numpy_reconstruction(patterns, bucket_values):
    acc = np.zeros(PATTERN_WIDTH, dtype=np.int64)
    for pat, b in zip(patterns, bucket_values):
        for p in range(PATTERN_WIDTH):
            if (pat >> p) & 1:
                acc[p] += b
    return acc


def decode_dump(payload):
    """n_pixels x int32, big-endian → list of ints."""
    assert len(payload) % 4 == 0, f"dump payload not word-aligned: {len(payload)}"
    words = []
    for i in range(0, len(payload), 4):
        words.append((payload[i] << 24) | (payload[i+1] << 16) |
                     (payload[i+2] << 8) | payload[i+3])
    return words


async def run_acquisition_and_dump(dut, patterns, bucket_values,
                                   t_settle, t_sample):
    backdoor_load_patterns(dut, patterns)
    backdoor_zero_accumulator(dut)

    cocotb.start_soon(fake_bucket(dut, bucket_values))

    rx_bytes = []
    cocotb.start_soon(uart_monitor(dut, rx_bytes))

    # Configure over UART, then start.
    await csr_write(dut, ADDR_N_PATTERNS, len(patterns))
    await csr_write(dut, ADDR_T_SETTLE,   t_settle)
    await csr_write(dut, ADDR_T_SAMPLE,   t_sample)
    await csr_write(dut, ADDR_MODE,       0)
    await csr_write(dut, ADDR_CTRL,       1)      # start (rising edge of ctrl[0])

    await wait_for_done(dut)

    # Request a dump and let it transmit.
    await send_packet(dut, TYPE_DUMP_REQ, [])
    expected_dump_bytes = PATTERN_WIDTH * (ACC_WIDTH // 8)
    # frame = SOF+TYPE+LEN(2)+payload+CRC; wait until a full 0x01 frame is present.
    for _ in range(40_000):
        await RisingEdge(dut.clk)
        dump = [f for f in parse_frames(rx_bytes) if f[0] == TYPE_DUMP]
        if dump and len(dump[0][1]) == expected_dump_bytes:
            break
    await ClockCycles(dut.clk, CYCLES_PER_BIT * 12)

    frames = parse_frames(rx_bytes)
    dumps = [f for f in frames if f[0] == TYPE_DUMP]
    assert dumps, f"no 0x01 dump frame received; got types {[hex(f[0]) for f in frames]}"
    msg_type, payload, crc_ok = dumps[0]
    assert crc_ok, "dump frame CRC mismatch"
    return decode_dump(payload)


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_four_random_patterns(dut):
    """Configure + acquire + dump over UART; verify the image against numpy."""
    await start_clock(dut)
    await reset(dut)

    patterns      = [0b11001010, 0b01010111, 0b11110000, 0b10100101]
    bucket_values = [0x0010,     0x0020,     0x0030,     0x0040]

    rtl_acc = await run_acquisition_and_dump(
        dut, patterns, bucket_values, t_settle=2, t_sample=2 * XADC_CONV_LATENCY)

    expected = numpy_reconstruction(patterns, bucket_values)
    assert rtl_acc == expected.tolist(), \
        f"\n  expected: {expected.tolist()}\n  got:      {rtl_acc}"


@cocotb.test()
async def test_hadamard_8x8(dut):
    """A real Hadamard basis, end to end over UART."""
    await start_clock(dut)
    await reset(dut)

    H_pm1 = np.array([
        [ 1,  1,  1,  1,  1,  1,  1,  1],
        [ 1, -1,  1, -1,  1, -1,  1, -1],
        [ 1,  1, -1, -1,  1,  1, -1, -1],
        [ 1, -1, -1,  1,  1, -1, -1,  1],
        [ 1,  1,  1,  1, -1, -1, -1, -1],
        [ 1, -1,  1, -1, -1,  1, -1,  1],
        [ 1,  1, -1, -1, -1, -1,  1,  1],
        [ 1, -1, -1,  1, -1,  1,  1, -1],
    ])
    H_bin = (H_pm1 > 0).astype(int)
    patterns = [int("".join(str(b) for b in row[::-1]), 2) for row in H_bin]

    object_brightness = np.array([10, 20, 5, 15, 0, 25, 8, 12])
    bucket_values     = [int(np.dot(object_brightness, H_bin[i])) for i in range(8)]

    rtl_acc = await run_acquisition_and_dump(
        dut, patterns, bucket_values, t_settle=2, t_sample=2 * XADC_CONV_LATENCY)

    expected = numpy_reconstruction(patterns, bucket_values)
    print(f"\nObject:        {object_brightness.tolist()}")
    print(f"Bucket values: {bucket_values}")
    print(f"Expected acc:  {expected.tolist()}")
    print(f"RTL acc:       {rtl_acc}")
    assert rtl_acc == expected.tolist(), \
        f"\n  expected: {expected.tolist()}\n  got:      {rtl_acc}"


# ── Arbiter: CSR send arriving mid-dump ──────────────────────────────────────

# grant_t encoding in top.sv: GNT_NONE=0, GNT_CSR=1, GNT_STR=2.
GNT_STR = 2


async def wait_for_grant(dut, want, timeout_cycles=20_000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dbg_grant.value) == want:
            return
    raise TimeoutError(f"grant never reached {want}")


@cocotb.test()
async def test_csr_send_during_dump(dut):
    """Exercise the arbiter's pending_csr path: issue a CSR write while a dump
    is in flight. Both the dump frame and the deferred CSR ACK must come out
    intact and in order (dump first — it holds the bus; CSR ACK after)."""
    await start_clock(dut)
    await reset(dut)

    patterns      = [0b11001010, 0b01010111, 0b11110000, 0b10100101]
    bucket_values = [0x0010,     0x0020,     0x0030,     0x0040]

    backdoor_load_patterns(dut, patterns)
    backdoor_zero_accumulator(dut)
    cocotb.start_soon(fake_bucket(dut, bucket_values))

    rx_bytes = []
    cocotb.start_soon(uart_monitor(dut, rx_bytes))

    await csr_write(dut, ADDR_N_PATTERNS, len(patterns))
    await csr_write(dut, ADDR_T_SETTLE,   2)
    await csr_write(dut, ADDR_T_SAMPLE,   2 * XADC_CONV_LATENCY)
    await csr_write(dut, ADDR_MODE,       0)
    await csr_write(dut, ADDR_CTRL,       1)
    await wait_for_done(dut)

    # Snapshot the byte count so we only parse frames emitted from here on.
    base = len(rx_bytes)

    # Kick off the dump, wait until the streamer actually owns the TX bus,
    # then fire a CSR write straight into the middle of the dump. send_packet
    # does not drain the ACK, so the CSR send pulse lands while grant==GNT_STR.
    await send_packet(dut, TYPE_DUMP_REQ, [])
    await wait_for_grant(dut, GNT_STR)
    await send_packet(dut, TYPE_CSR_WRITE,
                      [ADDR_SCRATCH, 0xEF, 0xBE, 0xAD, 0xDE])

    # Let both transmissions drain: dump (PATTERN_WIDTH words) + a 1-byte ACK.
    expected_dump_bytes = PATTERN_WIDTH * (ACC_WIDTH // 8)
    for _ in range(80_000):
        await RisingEdge(dut.clk)
        frames = parse_frames(rx_bytes[base:])
        dumps = [f for f in frames if f[0] == TYPE_DUMP and len(f[1]) == expected_dump_bytes]
        acks  = [f for f in frames if f[0] == TYPE_CSR_ACK]
        if dumps and acks:
            break
    await ClockCycles(dut.clk, CYCLES_PER_BIT * 12)

    frames = parse_frames(rx_bytes[base:])
    types  = [hex(f[0]) for f in frames]

    dumps = [f for f in frames if f[0] == TYPE_DUMP]
    acks  = [f for f in frames if f[0] == TYPE_CSR_ACK]
    assert dumps, f"no dump frame after mid-dump CSR write; got types {types}"
    assert acks,  f"deferred CSR ACK never emitted (pending_csr stuck); got types {types}"

    # Dump payload must still be correct — the interleaved CSR send must not
    # have corrupted the bytes the streamer was muxing onto the bus.
    msg_type, dump_payload, crc_ok = dumps[0]
    assert crc_ok, "dump frame CRC mismatch"
    expected = numpy_reconstruction(patterns, bucket_values)
    assert decode_dump(dump_payload) == expected.tolist(), (
        f"dump corrupted by interleaved CSR send\n"
        f"  expected: {expected.tolist()}\n  got:      {decode_dump(dump_payload)}")

    # ACK is for the scratch-reg write and must arrive AFTER the dump (CSR
    # priority does not preempt an in-flight grant; it waits via pending_csr).
    ack_type, ack_payload, ack_crc_ok = acks[0]
    assert ack_crc_ok, "CSR ACK frame CRC mismatch"
    assert ack_payload == [ADDR_SCRATCH], \
        f"ACK addr: got {ack_payload}, expected [{ADDR_SCRATCH:#04x}]"
    assert types.index(hex(TYPE_DUMP)) < types.index(hex(TYPE_CSR_ACK)), \
        f"CSR ACK preempted the in-flight dump; frame order was {types}"

    # And the scratch register actually took the written value.
    assert int(dut.dut.u_csr.scratch_reg.value) == 0xDEADBEEF, \
        f"scratch_reg: got {int(dut.dut.u_csr.scratch_reg.value):#010x}, expected 0xDEADBEEF"
