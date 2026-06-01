"""Stage-1 integration test: pattern_sequencer + correlator + pattern BRAM
wired through top.sv, driven by stubbed CSR/DMD/bucket signals from cocotb,
verified against a numpy reference.

When this passes, Stage 1 is done.
"""
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# Must match wrapper parameter defaults
PATTERN_WIDTH  = 8
N_PATTERNS_MAX = 16
BUCKET_WIDTH   = 16
ACC_WIDTH      = 32

STATUS_BUSY = 0
STATUS_DONE = 1


# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    dut.rst_n.value          = 0
    dut.ctrl_reg.value       = 0
    dut.n_patterns_reg.value = 0
    dut.t_settle_reg.value   = 0
    dut.t_sample_reg.value   = 0
    dut.mode_reg.value       = 0

    dut.dmd_ack.value        = 0
    dut.b_i.value            = 0
    dut.smp_valid.value      = 0
    dut.rd_addr.value        = 0

    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def backdoor_load_patterns(dut, patterns):
    """Preload top.u_pat_bram with the given pattern list (one int per pattern)."""
    for i, pat in enumerate(patterns):
        dut.dut.u_pat_bram.mem[i].value = pat & ((1 << PATTERN_WIDTH) - 1)


def backdoor_zero_accumulator(dut):
    """Zero the correlator's accumulator BRAM. iverilog leaves it at X otherwise."""
    for i in range(PATTERN_WIDTH):
        dut.dut.u_corr.acc_mem.mem[i].value = 0


# ── Fake DMD / bucket coroutines ──────────────────────────────────────────────

async def fake_dmd(dut, ack_latency=1):
    """Pulse dmd_ack after each pat_req (edge-triggered on pat_req rising)."""
    prev_req = 0
    while True:
        await RisingEdge(dut.clk)
        req = int(dut.pat_req.value)
        if req == 1 and prev_req == 0:
            for _ in range(ack_latency):
                await RisingEdge(dut.clk)
            dut.dmd_ack.value = 1
            await RisingEdge(dut.clk)
            dut.dmd_ack.value = 0
            req = int(dut.pat_req.value)
        prev_req = req


async def fake_bucket(dut, bucket_values):
    """Deliver one (b_i, smp_valid) pulse per smp_gate window.
    bucket_values[i] is the value for pattern i.

    Edge-triggered on the rising edge of smp_gate (it's held high across many
    cycles during the SAMPLE state, so a level-trigger would fire repeatedly).
    """
    pattern_idx = 0
    prev_gate = 0
    while True:
        await RisingEdge(dut.clk)
        gate = int(dut.smp_gate.value)
        if gate == 1 and prev_gate == 0:
            # Rising edge of smp_gate
            await ClockCycles(dut.clk, 2)
            if pattern_idx < len(bucket_values):
                dut.b_i.value       = bucket_values[pattern_idx] & ((1 << BUCKET_WIDTH) - 1)
                dut.smp_valid.value = 1
                await RisingEdge(dut.clk)
                dut.smp_valid.value = 0
                pattern_idx += 1
            # Need to refresh gate after the inner awaits
            gate = int(dut.smp_gate.value)
        prev_gate = gate


async def pulse_start(dut):
    dut.ctrl_reg.value = 0
    await RisingEdge(dut.clk)
    dut.ctrl_reg.value = 1
    await RisingEdge(dut.clk)


async def wait_for_done(dut, timeout_cycles=10_000):
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.status_out.value) & (1 << STATUS_DONE):
            return
    raise TimeoutError("done flag never asserted")


async def read_pixel(dut, addr):
    """Read pixel via correlator port B."""
    dut.rd_addr.value = addr
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    return int(dut.rd_data.value)


def numpy_reconstruction(patterns, bucket_values):
    """Compute the expected per-pixel accumulator: acc[p] = Σᵢ b_i * pat_i[p]"""
    n_pixels = PATTERN_WIDTH
    acc = np.zeros(n_pixels, dtype=np.int64)
    for pat, b in zip(patterns, bucket_values):
        for p in range(n_pixels):
            if (pat >> p) & 1:
                acc[p] += b
    return acc


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_single_pattern_end_to_end(dut):
    """One pattern, one bucket reading. Each set bit should accumulate b once."""
    await start_clock(dut)
    await reset(dut)

    patterns      = [0b10110100]
    bucket_values = [0x0050]

    backdoor_load_patterns(dut, patterns)
    backdoor_zero_accumulator(dut)

    cocotb.start_soon(fake_dmd(dut, ack_latency=1))
    cocotb.start_soon(fake_bucket(dut, bucket_values))

    dut.n_patterns_reg.value = len(patterns)
    dut.t_settle_reg.value   = 3
    dut.t_sample_reg.value   = 6

    await pulse_start(dut)
    await wait_for_done(dut)

    expected = numpy_reconstruction(patterns, bucket_values)
    for p in range(PATTERN_WIDTH):
        got = await read_pixel(dut, p)
        assert got == expected[p], \
            f"pixel {p}: expected {expected[p]}, got {got}"


@cocotb.test()
async def test_four_random_patterns(dut):
    """Four arbitrary patterns with arbitrary bucket values.
    Verify the full per-pixel sum against numpy."""
    await start_clock(dut)
    await reset(dut)

    patterns      = [0b11001010, 0b01010111, 0b11110000, 0b10100101]
    bucket_values = [0x0010,     0x0020,     0x0030,     0x0040]

    backdoor_load_patterns(dut, patterns)
    backdoor_zero_accumulator(dut)

    cocotb.start_soon(fake_dmd(dut, ack_latency=2))
    cocotb.start_soon(fake_bucket(dut, bucket_values))

    dut.n_patterns_reg.value = len(patterns)
    dut.t_settle_reg.value   = 2
    dut.t_sample_reg.value   = 5

    await pulse_start(dut)
    await wait_for_done(dut)

    expected = numpy_reconstruction(patterns, bucket_values)
    print("\nReconstruction comparison:")
    print(f"  pixel | expected | got")
    print(f"  ------|----------|----")
    for p in range(PATTERN_WIDTH):
        got = await read_pixel(dut, p)
        print(f"    {p}   |   {expected[p]:6d} | {got:6d}")
        assert got == expected[p], \
            f"pixel {p}: expected {expected[p]}, got {got}"


@cocotb.test()
async def test_hadamard_8x8(dut):
    """A real Hadamard basis. For an 8-row Hadamard matrix H (in 0/1 form,
    not ±1), and synthetic bucket values, verify the reconstruction matches numpy.

    This is the closest Stage-1 thing to a real CGI acquisition: known orthogonal
    patterns, deterministic bucket samples, on-chip correlation, off-chip verify.
    """
    await start_clock(dut)
    await reset(dut)

    # 8-row Hadamard, mapped {-1, +1} → {0, 1}. Each row becomes an 8-bit pattern.
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
    H_bin = (H_pm1 > 0).astype(int)   # {0, 1}

    # Convert each row to an integer pattern (bit 0 = column 0)
    patterns = [int("".join(str(b) for b in row[::-1]), 2) for row in H_bin]

    # Synthetic bucket: imagine an object with non-uniform brightness.
    # b_i = sum of (object[p] * H_bin[i, p]). Pick a fake "object."
    object_brightness = np.array([10, 20, 5, 15, 0, 25, 8, 12])
    bucket_values     = [int(np.dot(object_brightness, H_bin[i])) for i in range(8)]

    backdoor_load_patterns(dut, patterns)
    backdoor_zero_accumulator(dut)

    cocotb.start_soon(fake_dmd(dut, ack_latency=1))
    cocotb.start_soon(fake_bucket(dut, bucket_values))

    dut.n_patterns_reg.value = len(patterns)
    dut.t_settle_reg.value   = 2
    dut.t_sample_reg.value   = 5

    await pulse_start(dut)
    await wait_for_done(dut)

    expected = numpy_reconstruction(patterns, bucket_values)
    print(f"\nObject:          {object_brightness.tolist()}")
    print(f"Bucket values:   {bucket_values}")
    print(f"Expected acc:    {expected.tolist()}")
    rtl_acc = []
    for p in range(PATTERN_WIDTH):
        got = await read_pixel(dut, p)
        rtl_acc.append(got)
    print(f"RTL acc:         {rtl_acc}")

    for p in range(PATTERN_WIDTH):
        assert rtl_acc[p] == expected[p], \
            f"pixel {p}: expected {expected[p]}, got {rtl_acc[p]}"

    # Sanity: the Hadamard inverse gives us back the object (up to a factor of N).
    # For an N×N {0,1} Hadamard, decode is (2/N)*H_pm1 @ acc — we just check
    # that the RTL accumulator matches the numpy reference exactly here.
