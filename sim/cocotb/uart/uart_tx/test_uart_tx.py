import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in uart_tx_tb_wrapper.sv
CLK_HZ    = 1_000_000
BAUD      = 115_200
BIT_TICKS = CLK_HZ // BAUD   # = 8

# ── Helpers ───────────────────────────────────────────────────────────────────

async def reset(dut):
    dut.rst_n.value    = 0
    dut.tx_valid.value = 0
    dut.tx_data.value  = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def send_byte(dut, byte):
    """Pulse tx_valid for one cycle with tx_data set."""
    await RisingEdge(dut.clk)
    assert dut.tx_ready.value == 1, "tx_ready should be high before sending"
    dut.tx_data.value  = byte
    dut.tx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.tx_valid.value = 0
    dut.tx_data.value  = 0


async def sample_at_bit_center(dut):
    """Wait BIT_TICKS clock cycles, sample tx at the middle of the bit window."""
    # Caller is assumed to be aligned to the start of a bit window
    # (i.e. just after the edge that began the bit).
    await ClockCycles(dut.clk, BIT_TICKS // 2)
    bit = int(dut.tx.value)
    await ClockCycles(dut.clk, BIT_TICKS - BIT_TICKS // 2)
    return bit


async def receive_byte(dut, timeout_cycles=10_000):
    """Wait for a start bit on tx, then decode start + 8 data + stop. Return the byte."""
    # Wait for the falling edge that marks the start bit.
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.tx.value) == 0:
            break
    else:
        raise TimeoutError("never saw a start bit")

    # We're now one cycle into the start bit. Re-align to the middle of the start bit.
    await ClockCycles(dut.clk, BIT_TICKS // 2 - 1)
    assert int(dut.tx.value) == 0, "start bit not low at its center"

    # Sample 8 data bits, LSB first, each one BIT_TICKS cycles after the previous sample.
    byte = 0
    for i in range(8):
        await ClockCycles(dut.clk, BIT_TICKS)
        byte |= (int(dut.tx.value) & 1) << i

    # Stop bit
    await ClockCycles(dut.clk, BIT_TICKS)
    assert int(dut.tx.value) == 1, "stop bit not high"

    return byte


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_reset_state(dut):
    """After reset, tx is idle-high and tx_ready is asserted."""
    await start_clock(dut)
    await reset(dut)
    assert int(dut.tx.value)       == 1, "tx should idle high"
    assert int(dut.tx_ready.value) == 1, "tx_ready should be high after reset"


@cocotb.test()
async def test_send_single_byte(dut):
    """Send 0x55 (alternating bits) and decode it off the line."""
    await start_clock(dut)
    await reset(dut)
    await send_byte(dut, 0x55)
    rx = await receive_byte(dut)
    assert rx == 0x55, f"expected 0x55, got 0x{rx:02x}"


@cocotb.test()
async def test_send_all_zeros(dut):
    """0x00 — all data bits low — verifies start/stop framing isn't confused."""
    await start_clock(dut)
    await reset(dut)
    await send_byte(dut, 0x00)
    rx = await receive_byte(dut)
    assert rx == 0x00, f"expected 0x00, got 0x{rx:02x}"


@cocotb.test()
async def test_send_all_ones(dut):
    """0xFF — all data bits high — line never returns to idle until stop."""
    await start_clock(dut)
    await reset(dut)
    await send_byte(dut, 0xFF)
    rx = await receive_byte(dut)
    assert rx == 0xFF, f"expected 0xFF, got 0x{rx:02x}"


@cocotb.test()
async def test_tx_ready_deasserts_during_send(dut):
    """tx_ready must drop low while a byte is in flight, then come back."""
    await start_clock(dut)
    await reset(dut)
    await send_byte(dut, 0xA5)

    # After we deassert tx_valid, the FSM is in START — tx_ready should be low.
    await RisingEdge(dut.clk)
    assert int(dut.tx_ready.value) == 0, "tx_ready should be low during transmission"

    # Wait for the full frame (start + 8 data + stop) to drain.
    await ClockCycles(dut.clk, BIT_TICKS * 10 + 4)
    assert int(dut.tx_ready.value) == 1, "tx_ready should return high after transmission"


@cocotb.test()
async def test_send_byte_sequence(dut):
    """Send several bytes back-to-back, decoding each. Verifies the FSM returns to IDLE cleanly."""
    await start_clock(dut)
    await reset(dut)

    payload = [0x01, 0xA5, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF]
    received = []

    for b in payload:
        # Wait for tx_ready before each new byte
        while int(dut.tx_ready.value) == 0:
            await RisingEdge(dut.clk)

        # Kick off send and decode in parallel
        send_task = cocotb.start_soon(send_byte(dut, b))
        rx = await receive_byte(dut)
        await send_task
        received.append(rx)

    assert received == payload, f"mismatch: sent {payload}, got {received}"
