import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# Must match wrapper parameter defaults
PATTERN_WIDTH = 64
BUCKET_WIDTH  = 16

# Status word bit positions
STATUS_BUSY     = 0
STATUS_DONE     = 1
STATUS_OVERFLOW = 2
STATUS_MODE     = 3
STATUS_IDX_LO   = 16


# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    """Drive all CSR/handshake inputs to known values, hold reset, deassert."""
    dut.rst_n.value          = 0
    dut.ctrl_reg.value       = 0
    dut.n_patterns_reg.value = 0
    dut.t_settle_reg.value   = 0
    dut.t_sample_reg.value   = 0
    dut.mode_reg.value       = 0

    dut.dmd_ack.value        = 0
    dut.b_i.value            = 0
    dut.smp_valid.value      = 0
    dut.acc_done.value       = 0
    dut.pat_bram_data.value  = 0

    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


# ── Fake hardware coroutines ──────────────────────────────────────────────────
# These pretend to be the DMD, bucket detector, correlator, and BRAM.
# They run forever in the background once started.

async def fake_dmd(dut, ack_latency=2):
    """Watch pat_req; pulse dmd_ack one cycle high after ack_latency cycles."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.pat_req.value) == 1:
            for _ in range(ack_latency):
                await RisingEdge(dut.clk)
            dut.dmd_ack.value = 1
            await RisingEdge(dut.clk)
            dut.dmd_ack.value = 0


async def fake_bucket(dut, sample_value_fn):
    """Whenever smp_gate goes high, deliver one (b_i, smp_valid) pulse.
    sample_value_fn(idx) returns the bucket value for the current pattern."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.smp_gate.value) == 1:
            # Wait a couple cycles inside the sample window, then deliver one sample
            await ClockCycles(dut.clk, 2)
            idx = int(dut.dbg_idx.value)
            dut.b_i.value       = sample_value_fn(idx) & ((1 << BUCKET_WIDTH) - 1)
            dut.smp_valid.value = 1
            await RisingEdge(dut.clk)
            dut.smp_valid.value = 0


async def fake_correlator(dut, captured, ack_latency=1):
    """Watch acc_we; record (pat, b) pairs; pulse acc_done after ack_latency."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.acc_we.value) == 1:
            pat = int(dut.acc_pat.value)
            b   = int(dut.acc_b.value)
            captured.append((pat, b))
            for _ in range(ack_latency):
                await RisingEdge(dut.clk)
            dut.acc_done.value = 1
            await RisingEdge(dut.clk)
            dut.acc_done.value = 0


async def fake_bram(dut, pattern_fn):
    """Combinationally drive pat_bram_data based on pat_bram_addr.
    pattern_fn(addr) returns the PATTERN_WIDTH-bit pattern."""
    while True:
        await RisingEdge(dut.clk)
        addr = int(dut.pat_bram_addr.value)
        dut.pat_bram_data.value = pattern_fn(addr) & ((1 << PATTERN_WIDTH) - 1)


async def pulse_start(dut):
    """Rising edge on ctrl_reg[0]."""
    dut.ctrl_reg.value = 0
    await RisingEdge(dut.clk)
    dut.ctrl_reg.value = 1
    await RisingEdge(dut.clk)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_reset_state(dut):
    """After reset, FSM is IDLE, busy/done are 0, idx is 0."""
    await start_clock(dut)
    await reset(dut)
    assert int(dut.dbg_state.value)  == 0,   "expected IDLE"
    assert int(dut.dbg_idx.value)    == 0
    assert int(dut.status_out.value) & (1 << STATUS_BUSY) == 0
    assert int(dut.status_out.value) & (1 << STATUS_DONE) == 0


@cocotb.test()
async def test_single_pattern_acquisition(dut):
    """Run N=1 pattern through the full pipeline. Verify the correlator
    receives exactly one (pat, bucket) pair with the expected values."""
    await start_clock(dut)
    await reset(dut)

    # Fake hardware bring-up
    captured = []
    cocotb.start_soon(fake_bram(dut, pattern_fn=lambda a: 0xDEADBEEFCAFEBABE))
    cocotb.start_soon(fake_dmd(dut, ack_latency=2))
    cocotb.start_soon(fake_bucket(dut, sample_value_fn=lambda i: 0x1234))
    cocotb.start_soon(fake_correlator(dut, captured, ack_latency=1))

    # Configure CSR
    dut.n_patterns_reg.value = 1
    dut.t_settle_reg.value   = 5
    dut.t_sample_reg.value   = 10

    await pulse_start(dut)

    # Wait for done flag
    for _ in range(500):
        await RisingEdge(dut.clk)
        if int(dut.status_out.value) & (1 << STATUS_DONE):
            break
    else:
        raise TimeoutError("done flag never asserted")

    assert len(captured) == 1, f"expected 1 acc_we pulse, got {len(captured)}"
    pat, b = captured[0]
    assert pat == 0xDEADBEEFCAFEBABE, f"pattern mismatch: got 0x{pat:016x}"
    assert b   == 0x1234,             f"bucket mismatch: got 0x{b:04x}"


@cocotb.test()
async def test_multi_pattern_sequence(dut):
    """Run N=4 patterns. Verify the correlator receives 4 pairs in order,
    with each (pat, b) corresponding to the expected per-index values."""
    await start_clock(dut)
    await reset(dut)

    # Pattern i has all bits set to byte i (so pattern_0 = 0x000..., pattern_1 = 0x010101..., etc.)
    def pat_for(addr):
        return (addr * 0x0101010101010101) & ((1 << PATTERN_WIDTH) - 1)

    # Bucket value for pattern i is just (i + 1) * 0x10
    def bucket_for(idx):
        return (idx + 1) * 0x10

    captured = []
    cocotb.start_soon(fake_bram(dut, pattern_fn=pat_for))
    cocotb.start_soon(fake_dmd(dut, ack_latency=2))
    cocotb.start_soon(fake_bucket(dut, sample_value_fn=bucket_for))
    cocotb.start_soon(fake_correlator(dut, captured, ack_latency=1))

    dut.n_patterns_reg.value = 4
    dut.t_settle_reg.value   = 3
    dut.t_sample_reg.value   = 6

    await pulse_start(dut)

    for _ in range(2000):
        await RisingEdge(dut.clk)
        if int(dut.status_out.value) & (1 << STATUS_DONE):
            break
    else:
        raise TimeoutError("done flag never asserted")

    assert len(captured) == 4, f"expected 4 acc_we pulses, got {len(captured)}"
    for i, (pat, b) in enumerate(captured):
        exp_pat = pat_for(i)
        exp_b   = bucket_for(i)
        assert pat == exp_pat, f"pattern {i} mismatch: expected 0x{exp_pat:016x}, got 0x{pat:016x}"
        assert b   == exp_b,   f"bucket {i} mismatch: expected 0x{exp_b:04x}, got 0x{b:04x}"


@cocotb.test()
async def test_busy_then_done(dut):
    """busy should be high during acquisition, fall when done rises."""
    await start_clock(dut)
    await reset(dut)

    cocotb.start_soon(fake_bram(dut, pattern_fn=lambda a: 0xAA))
    cocotb.start_soon(fake_dmd(dut, ack_latency=1))
    cocotb.start_soon(fake_bucket(dut, sample_value_fn=lambda i: 0x55))
    cocotb.start_soon(fake_correlator(dut, [], ack_latency=1))

    dut.n_patterns_reg.value = 2
    dut.t_settle_reg.value   = 2
    dut.t_sample_reg.value   = 3

    await pulse_start(dut)

    # Wait a few cycles for busy to assert
    busy_seen = False
    for _ in range(20):
        await RisingEdge(dut.clk)
        if int(dut.status_out.value) & (1 << STATUS_BUSY):
            busy_seen = True
            break
    assert busy_seen, "busy never asserted after start"

    # Wait for done
    for _ in range(500):
        await RisingEdge(dut.clk)
        if int(dut.status_out.value) & (1 << STATUS_DONE):
            break
    else:
        raise TimeoutError("done never asserted")

    # busy should now be low
    assert int(dut.status_out.value) & (1 << STATUS_BUSY) == 0, \
        "busy still high after done"


@cocotb.test()
async def test_idx_advances(dut):
    """status_out[31:16] should report the running idx during acquisition."""
    await start_clock(dut)
    await reset(dut)

    cocotb.start_soon(fake_bram(dut, pattern_fn=lambda a: 0x42))
    cocotb.start_soon(fake_dmd(dut, ack_latency=1))
    cocotb.start_soon(fake_bucket(dut, sample_value_fn=lambda i: 0x99))
    cocotb.start_soon(fake_correlator(dut, [], ack_latency=1))

    dut.n_patterns_reg.value = 3
    dut.t_settle_reg.value   = 2
    dut.t_sample_reg.value   = 3

    await pulse_start(dut)

    # Collect a few snapshots of (idx_seen) over time
    idx_seen = set()
    for _ in range(800):
        await RisingEdge(dut.clk)
        idx_now = (int(dut.status_out.value) >> STATUS_IDX_LO) & 0xFFFF
        idx_seen.add(idx_now)
        if int(dut.status_out.value) & (1 << STATUS_DONE):
            break

    # Should have visited idx 0, 1, 2 at some point during the run
    assert {0, 1, 2}.issubset(idx_seen), f"missed indices; saw {sorted(idx_seen)}"
