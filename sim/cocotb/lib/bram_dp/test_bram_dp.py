import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import random

CLK_PERIOD_NS = 10
DATA_WIDTH = 32     # must match wrapper
ADDR_WIDTH = 12     # must match wrapper → depth = 4096


# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset_inputs(dut):
    """BRAM has no reset port — just zero the control inputs so nothing happens."""
    dut.en_a.value   = 0
    dut.we_a.value   = 0
    dut.addr_a.value = 0
    dut.din_a.value  = 0
    dut.en_b.value   = 0
    dut.we_b.value   = 0
    dut.addr_b.value = 0
    dut.din_b.value  = 0
    await RisingEdge(dut.clk)


async def write_a(dut, addr, data):
    """Single-cycle write on port A."""
    dut.en_a.value   = 1
    dut.we_a.value   = 1
    dut.addr_a.value = addr
    dut.din_a.value  = data
    await RisingEdge(dut.clk)
    dut.en_a.value   = 0
    dut.we_a.value   = 0


async def read_a(dut, addr):
    """Issue a read on port A; data appears on dout_a one cycle later."""
    dut.en_a.value   = 1
    dut.we_a.value   = 0
    dut.addr_a.value = addr
    await RisingEdge(dut.clk)
    dut.en_a.value   = 0
    await RisingEdge(dut.clk)
    return int(dut.dout_a.value)


async def write_b(dut, addr, data):
    dut.en_b.value   = 1
    dut.we_b.value   = 1
    dut.addr_b.value = addr
    dut.din_b.value  = data
    await RisingEdge(dut.clk)
    dut.en_b.value   = 0
    dut.we_b.value   = 0


async def read_b(dut, addr):
    dut.en_b.value   = 1
    dut.we_b.value   = 0
    dut.addr_b.value = addr
    await RisingEdge(dut.clk)
    dut.en_b.value   = 0
    await RisingEdge(dut.clk)
    return int(dut.dout_b.value)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_port_a_write_read(dut):
    """Write a value via port A, read it back via port A."""
    await start_clock(dut)
    await reset_inputs(dut)

    await write_a(dut, addr=0x010, data=0xDEADBEEF)
    val = await read_a(dut, addr=0x010)
    assert val == 0xDEADBEEF, f"expected 0xDEADBEEF, got 0x{val:08x}"


@cocotb.test()
async def test_port_b_write_read(dut):
    """Same on port B."""
    await start_clock(dut)
    await reset_inputs(dut)

    await write_b(dut, addr=0x020, data=0xCAFEBABE)
    val = await read_b(dut, addr=0x020)
    assert val == 0xCAFEBABE, f"expected 0xCAFEBABE, got 0x{val:08x}"


@cocotb.test()
async def test_cross_port_visibility(dut):
    """Write on port A, read on port B at the same address.
    Confirms both ports access the same underlying memory."""
    await start_clock(dut)
    await reset_inputs(dut)

    await write_a(dut, addr=0x100, data=0x12345678)
    val = await read_b(dut, addr=0x100)
    assert val == 0x12345678, f"expected 0x12345678, got 0x{val:08x}"


@cocotb.test()
async def test_simultaneous_independent_addresses(dut):
    """Port A and port B write different addresses on the same cycle. Both should persist."""
    await start_clock(dut)
    await reset_inputs(dut)

    dut.en_a.value   = 1
    dut.we_a.value   = 1
    dut.addr_a.value = 0x200
    dut.din_a.value  = 0xAAAA1111

    dut.en_b.value   = 1
    dut.we_b.value   = 1
    dut.addr_b.value = 0x300
    dut.din_b.value  = 0xBBBB2222

    await RisingEdge(dut.clk)

    dut.en_a.value = 0
    dut.we_a.value = 0
    dut.en_b.value = 0
    dut.we_b.value = 0
    await RisingEdge(dut.clk)

    val_a = await read_a(dut, addr=0x200)
    val_b = await read_b(dut, addr=0x300)

    assert val_a == 0xAAAA1111, f"port A: expected 0xAAAA1111, got 0x{val_a:08x}"
    assert val_b == 0xBBBB2222, f"port B: expected 0xBBBB2222, got 0x{val_b:08x}"


@cocotb.test()
async def test_en_low_holds_output(dut):
    """When en_a is low, dout_a should not update even if addr_a changes."""
    await start_clock(dut)
    await reset_inputs(dut)

    await write_a(dut, addr=0x000, data=0x11111111)
    await write_a(dut, addr=0x001, data=0x22222222)

    val0 = await read_a(dut, addr=0x000)
    assert val0 == 0x11111111

    dut.en_a.value   = 0
    dut.addr_a.value = 0x001
    await ClockCycles(dut.clk, 3)
    assert int(dut.dout_a.value) == 0x11111111, \
        "dout_a updated despite en_a=0"


@cocotb.test()
async def test_random_writes_readback(dut):
    """Random write pattern over 32 addresses, then verify each."""
    await start_clock(dut)
    await reset_inputs(dut)

    random.seed(0xDEAD)
    written = {}
    for _ in range(32):
        addr = random.randint(0, 0x7FF)
        data = random.randint(0, (1 << DATA_WIDTH) - 1)
        await write_a(dut, addr=addr, data=data)
        written[addr] = data   # last write wins

    for addr, expected in written.items():
        val = await read_a(dut, addr=addr)
        assert val == expected, \
            f"addr 0x{addr:03x}: expected 0x{expected:08x}, got 0x{val:08x}"


@cocotb.test()
async def test_full_address_range(dut):
    """Spot-check the address corners: 0x000, 0x001, 0xFFE, 0xFFF."""
    await start_clock(dut)
    await reset_inputs(dut)

    pairs = [
        (0x000, 0x00000001),
        (0x001, 0x10000010),
        (0xFFE, 0xFEFEFEFE),
        (0xFFF, 0xFFFFFFFF),
    ]
    for addr, data in pairs:
        await write_a(dut, addr=addr, data=data)

    for addr, expected in pairs:
        val = await read_a(dut, addr=addr)
        assert val == expected, \
            f"addr 0x{addr:03x}: expected 0x{expected:08x}, got 0x{val:08x}"
