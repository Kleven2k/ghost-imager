import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10
STAGES = 2   # must match wrapper parameter default


# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_initial_value(dut):
    """Drive 0 into i_sig and let the synchronizer settle. Confirms compile + clocking."""
    await start_clock(dut)
    dut.i_sig.value = 0
    await ClockCycles(dut.clk, STAGES + 2)
    assert int(dut.o_sig_sync.value) == 0


@cocotb.test()
async def test_rising_edge_latency(dut):
    """When i_sig goes 0 → 1, o_sig_sync should follow after exactly STAGES rising edges
    that observe the new value (one extra edge for visibility through the flop)."""
    await start_clock(dut)
    dut.i_sig.value = 0
    await ClockCycles(dut.clk, STAGES + 2)
    assert int(dut.o_sig_sync.value) == 0

    # Drive input high — needs an extra rising edge before the FSM samples it
    dut.i_sig.value = 1
    await RisingEdge(dut.clk)   # this edge samples i_sig=1 into sync_ff[0]

    # Output should remain 0 for STAGES-1 more edges, then go high
    for cyc in range(STAGES):
        if cyc < STAGES - 1:
            assert int(dut.o_sig_sync.value) == 0, \
                f"o_sig_sync went high too early at iteration {cyc}"
        await RisingEdge(dut.clk)

    assert int(dut.o_sig_sync.value) == 1, \
        f"o_sig_sync did not go high after {STAGES} cycles"


@cocotb.test()
async def test_falling_edge_latency(dut):
    """Same latency check for 1 → 0 transition."""
    await start_clock(dut)
    dut.i_sig.value = 1
    await ClockCycles(dut.clk, STAGES + 2)
    assert int(dut.o_sig_sync.value) == 1

    dut.i_sig.value = 0
    await RisingEdge(dut.clk)

    for cyc in range(STAGES):
        if cyc < STAGES - 1:
            assert int(dut.o_sig_sync.value) == 1, \
                f"o_sig_sync went low too early at iteration {cyc}"
        await RisingEdge(dut.clk)

    assert int(dut.o_sig_sync.value) == 0, \
        f"o_sig_sync did not go low after {STAGES} cycles"


@cocotb.test()
async def test_short_pulse_propagates(dut):
    """A 1-cycle pulse on i_sig should appear as a 1-cycle pulse on o_sig_sync,
    delayed by STAGES cycles."""
    await start_clock(dut)
    dut.i_sig.value = 0
    await ClockCycles(dut.clk, STAGES + 2)

    dut.i_sig.value = 1
    await RisingEdge(dut.clk)   # (signal write settles; not yet sampled)
    dut.i_sig.value = 0
    await RisingEdge(dut.clk)   # sample i_sig=1 into sync_ff[0]
    await RisingEdge(dut.clk)   # sync_ff[1] gets the 1 → o_sig_sync=1

    assert int(dut.o_sig_sync.value) == 1, "expected pulse to appear high"

    await RisingEdge(dut.clk)
    assert int(dut.o_sig_sync.value) == 0, "expected pulse to deassert one cycle later"


@cocotb.test()
async def test_steady_input(dut):
    """Holding i_sig steady should produce a steady output (after settling)."""
    await start_clock(dut)
    dut.i_sig.value = 1
    await ClockCycles(dut.clk, STAGES + 5)

    for _ in range(20):
        await RisingEdge(dut.clk)
        assert int(dut.o_sig_sync.value) == 1, "output should be steady high"
