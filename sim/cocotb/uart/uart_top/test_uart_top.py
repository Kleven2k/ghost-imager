import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in uart_top_tb_wrapper.sv
CLK_HZ    = 1_000_000
BAUD      = 115_200
BIT_TICKS = CLK_HZ // BAUD   # = 8

# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def loopback(dut):
    """Continuously drive dut.rx from dut.tx — wires the line back in software."""
    while True:
        await RisingEdge(dut.clk)
        dut.rx.value = int(dut.tx.value)


async def reset(dut):
    dut.rst_n.value   = 0
    dut.tx_start.value = 0
    dut.tx_data.value  = 0
    dut.rx.value       = 1            # idle line high
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def send_byte(dut, byte):
    """Pulse tx_start for one cycle with tx_data set."""
    # Wait until UART is not busy
    while int(dut.tx_busy.value) == 1:
        await RisingEdge(dut.clk)

    dut.tx_data.value  = byte
    dut.tx_start.value = 1
    await RisingEdge(dut.clk)
    dut.tx_start.value = 0
    dut.tx_data.value  = 0


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
    """After reset, tx line is idle-high, rx_valid is low, tx_busy is low."""
    await start_clock(dut)
    await reset(dut)
    assert int(dut.tx.value)       == 1, "tx should idle high"
    assert int(dut.rx_valid.value) == 0, "rx_valid should be low after reset"
    assert int(dut.tx_busy.value)  == 0, "tx_busy should be low when idle"


@cocotb.test()
async def test_loopback_single_byte(dut):
    """Send a byte via tx_start; loopback wires tx→rx; check rx_data matches."""
    await start_clock(dut)
    cocotb.start_soon(loopback(dut))
    await reset(dut)

    send_task = cocotb.start_soon(send_byte(dut, 0x55))
    rx = await wait_for_rx_valid(dut)
    await send_task
    assert rx == 0x55, f"expected 0x55, got 0x{rx:02x}"


@cocotb.test()
async def test_loopback_all_zeros(dut):
    await start_clock(dut)
    cocotb.start_soon(loopback(dut))
    await reset(dut)

    send_task = cocotb.start_soon(send_byte(dut, 0x00))
    rx = await wait_for_rx_valid(dut)
    await send_task
    assert rx == 0x00, f"expected 0x00, got 0x{rx:02x}"


@cocotb.test()
async def test_loopback_all_ones(dut):
    await start_clock(dut)
    cocotb.start_soon(loopback(dut))
    await reset(dut)

    send_task = cocotb.start_soon(send_byte(dut, 0xFF))
    rx = await wait_for_rx_valid(dut)
    await send_task
    assert rx == 0xFF, f"expected 0xFF, got 0x{rx:02x}"


@cocotb.test()
async def test_tx_busy_during_send(dut):
    """tx_busy must rise while a byte is in flight and fall after it completes."""
    await start_clock(dut)
    cocotb.start_soon(loopback(dut))
    await reset(dut)

    await send_byte(dut, 0xA5)
    await RisingEdge(dut.clk)
    assert int(dut.tx_busy.value) == 1, "tx_busy should be high during transmission"

    # Drain the full frame: start + 8 data + stop = 10 bit times, plus margin
    await ClockCycles(dut.clk, BIT_TICKS * 10 + 4)
    assert int(dut.tx_busy.value) == 0, "tx_busy should fall after transmission"


@cocotb.test()
async def test_loopback_byte_sequence(dut):
    """Send several bytes back-to-back through loopback, decode each."""
    await start_clock(dut)
    cocotb.start_soon(loopback(dut))
    await reset(dut)

    payload = [0x01, 0xA5, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF]
    received = []

    for b in payload:
        send_task = cocotb.start_soon(send_byte(dut, b))
        rx = await wait_for_rx_valid(dut)
        await send_task
        received.append(rx)

    assert received == payload, f"mismatch: sent {payload}, got {received}"
