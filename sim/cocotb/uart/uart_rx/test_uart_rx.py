import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in uart_rx_tb_wrapper.sv
CLK_HZ    = 1_000_000
BAUD      = 115_200
BIT_TICKS = CLK_HZ // BAUD   # = 8

# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    dut.rst_n.value = 0
    dut.rx.value    = 1            # idle line is high
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_byte(dut, byte):
    """Drive a UART frame (start + 8 data LSB-first + stop) onto dut.rx."""
    # Start bit
    dut.rx.value = 0
    await ClockCycles(dut.clk, BIT_TICKS)

    # 8 data bits, LSB first
    for i in range(8):
        dut.rx.value = (byte >> i) & 1
        await ClockCycles(dut.clk, BIT_TICKS)

    # Stop bit
    dut.rx.value = 1
    await ClockCycles(dut.clk, BIT_TICKS)


async def wait_for_rx_valid(dut, timeout_cycles=200):
    """Wait until rx_valid pulses high; return the captured rx_data."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.rx_valid.value) == 1:
            return int(dut.rx_data.value)
    raise TimeoutError("rx_valid never pulsed")


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_reset_state(dut):
    """After reset, rx_valid is low and the FSM is idle (waits on rx)."""
    await start_clock(dut)
    await reset(dut)
    assert int(dut.rx_valid.value) == 0, "rx_valid should be low after reset"


async def send_and_receive(dut, byte):
    """Drive a byte and concurrently wait for rx_valid. Returns the decoded value."""
    drive_task = cocotb.start_soon(drive_byte(dut, byte))
    rx = await wait_for_rx_valid(dut)
    await drive_task
    return rx


@cocotb.test()
async def test_receive_single_byte(dut):
    """Drive 0x55 onto rx and check the decoded byte."""
    await start_clock(dut)
    await reset(dut)
    rx = await send_and_receive(dut, 0x55)
    assert rx == 0x55, f"expected 0x55, got 0x{rx:02x}"


@cocotb.test()
async def test_receive_all_zeros(dut):
    """0x00 — all data bits low — make sure start/stop framing isn't confused."""
    await start_clock(dut)
    await reset(dut)
    rx = await send_and_receive(dut, 0x00)
    assert rx == 0x00, f"expected 0x00, got 0x{rx:02x}"


@cocotb.test()
async def test_receive_all_ones(dut):
    """0xFF — line stays high through all data bits until stop. Only the start bit is low."""
    await start_clock(dut)
    await reset(dut)
    rx = await send_and_receive(dut, 0xFF)
    assert rx == 0xFF, f"expected 0xFF, got 0x{rx:02x}"


@cocotb.test()
async def test_rx_valid_is_one_cycle(dut):
    """rx_valid should pulse high for exactly one clock cycle, not stay asserted."""
    await start_clock(dut)
    await reset(dut)
    await send_and_receive(dut, 0xA5)
    await RisingEdge(dut.clk)
    assert int(dut.rx_valid.value) == 0, "rx_valid should deassert after one cycle"


@cocotb.test()
async def test_receive_byte_sequence(dut):
    """Drive several bytes back-to-back and check each one is decoded."""
    await start_clock(dut)
    await reset(dut)

    payload = [0x01, 0xA5, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF]
    received = []

    for b in payload:
        drive_task = cocotb.start_soon(drive_byte(dut, b))
        rx = await wait_for_rx_valid(dut)
        await drive_task
        received.append(rx)

    assert received == payload, f"mismatch: sent {payload}, got {received}"


@cocotb.test()
async def test_glitch_on_rx_is_ignored(dut):
    """A spurious low pulse shorter than HALF_BIT should not be treated as a start bit."""
    await start_clock(dut)
    await reset(dut)

    # Drive a 1-cycle low glitch on rx, then return to idle
    dut.rx.value = 0
    await ClockCycles(dut.clk, 1)
    dut.rx.value = 1
    await ClockCycles(dut.clk, BIT_TICKS * 2)

    # FSM should re-validate at HALF_BIT-1, see rx high, and bail back to IDLE.
    # No byte should ever arrive.
    for _ in range(BIT_TICKS * 12):
        await RisingEdge(dut.clk)
        assert int(dut.rx_valid.value) == 0, "rx_valid pulsed from a glitch — start-bit validation failed"
