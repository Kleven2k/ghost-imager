import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only

# Must match xadc_wiz_0_stub.sv's CONV_LATENCY default
CONV_LATENCY = 5


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def reset(dut, stub_sample=0):
    """stub_sample must be set here, not separately before/after: the stub's
    free-run conversion loop can complete its first conversion within a few
    cycles of reset releasing, so whatever stub_sample_in holds across the
    reset window is what the first sample_valid pulse will carry."""
    dut.rst_n.value          = 0
    dut.vauxp0.value         = 0
    dut.vauxn0.value         = 0
    dut.stub_sample_in.value = stub_sample
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def wait_for_sample_valid(dut, timeout_cycles=CONV_LATENCY + 5):
    """Poll for sample_valid, one RisingEdge at a time, so we never land
    on the exact cycle it pulses and miss it (sample_valid is a one-cycle
    strobe -- see CLAUDE.md's cocotb gotchas)."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.sample_valid.value) == 1:
            return
    assert False, "sample_valid never asserted within timeout"


@cocotb.test()
async def test_reset_state(dut):
    """sample and sample_valid must both be zero immediately after reset,
    before any conversion has had a chance to complete."""
    await start_clock(dut)
    await reset(dut)

    assert int(dut.sample.value) == 0
    assert int(dut.sample_valid.value) == 0


@cocotb.test()
async def test_first_sample_latched(dut):
    """After reset releases, the stub's free-run loop (eoc_out -> den_in)
    should complete a conversion and xadc_interface should latch whatever
    value the stub is holding into sample, with sample_valid pulsing on
    that exact cycle."""
    await start_clock(dut)
    await reset(dut, stub_sample=0xABC)  # 12-bit test pattern

    await wait_for_sample_valid(dut)
    assert int(dut.sample.value) == 0xABC, (
        f"sample={hex(int(dut.sample.value))}, expected 0xabc"
    )


@cocotb.test()
async def test_sample_valid_is_one_cycle_strobe(dut):
    """sample_valid must deassert the cycle after it pulses, not stay high."""
    await start_clock(dut)
    await reset(dut, stub_sample=0x123)

    await wait_for_sample_valid(dut)
    assert int(dut.sample_valid.value) == 1

    await RisingEdge(dut.clk)
    assert int(dut.sample_valid.value) == 0, (
        "sample_valid should deassert the cycle after it pulses"
    )


@cocotb.test()
async def test_continuous_conversion_picks_up_new_value(dut):
    """The free-run loop (den_in tied to eoc_out) means the IP should keep
    converting with no external trigger. If the analog input changes
    between conversions, the next sample_valid pulse should reflect the
    new value -- proving the loop is actually continuous, not one-shot."""
    await start_clock(dut)
    await reset(dut, stub_sample=0x001)

    await wait_for_sample_valid(dut)
    assert int(dut.sample.value) == 0x001

    dut.stub_sample_in.value = 0x7FF
    await wait_for_sample_valid(dut)
    assert int(dut.sample.value) == 0x7FF, (
        f"sample={hex(int(dut.sample.value))}, expected 0x7ff -- "
        "conversion loop did not continue after the first sample"
    )


@cocotb.test()
async def test_multiple_consecutive_samples(dut):
    """Sanity check that the free-run loop keeps producing fresh
    sample_valid pulses indefinitely, not just once after reset."""
    await start_clock(dut)
    await reset(dut, stub_sample=0x555)

    for _ in range(4):
        await wait_for_sample_valid(dut)
        assert int(dut.sample.value) == 0x555
