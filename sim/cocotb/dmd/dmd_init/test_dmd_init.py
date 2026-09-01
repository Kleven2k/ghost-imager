import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in dmd_init_tb_wrapper.sv (i2c_master instance)
CLK_HZ     = 1_000_000
SCL_HZ     = 40_000
DIV_100MHZ = CLK_HZ // (SCL_HZ * 2)   # = 12

# Must match dmd_init.sv's REG_ADDR/REG_DATA ROM exactly.
DLPC2607_ADDR_W = 0x36
EXPECTED_REGS = [
    (0x0B, 0x0000_0000),
    (0x0C, 0x0000_001B),
    (0x0D, 0x0000_0002),
    (0x0E, 0x0000_0000),
    (0x1E, 0x0000_0000),
]

# ── Helpers ───────────────────────────────────────────────────────────────────

async def reset(dut):
    dut.rst_n.value      = 0
    dut.gpio4_intf.value = 1  # DLPC2607 busy — dmd_init must wait
    dut.scl_in.value     = 1
    dut.sda_in.value     = 1
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def fake_slave_ack_and_capture(dut, bytes_out):
    """Runs for the whole test (start this once, never restart it mid-test):
    ACKs every byte the master sends (pulls sda_in low whenever the DUT
    releases SDA), and appends each captured data byte to the caller-owned
    bytes_out list.

    Bit sampling is gated on i2c_master's own state (dut.i2c.state) rather
    than a free-running mod-9 bit counter: only SLAVE_ADDR/SUB_ADDR/WRITE
    carry real data bits, and the STOP+RESTART overhead between back-to-back
    transactions doesn't line up with a clean 9-edges-per-byte cadence — a
    free-running counter drifts by exactly one bit at every transaction
    boundary, which is what caused the earlier byte-misalignment bug here.
    Gating on state also means bit_count is naturally reset (via
    prev_i2c_state tracking) whenever a fresh SLAVE_ADDR begins.

    i2c_master state encoding (see its typedef enum): SLAVE_ADDR=3,
    SUB_ADDR=4, WRITE=6.
    """
    DATA_STATES = (3, 4, 6)  # SLAVE_ADDR, SUB_ADDR, WRITE

    cur_byte = 0
    bit_count = 0
    prev_scl_out = int(dut.scl_out.value)
    prev_i2c_state = int(dut.i2c.state.value)

    while True:
        await RisingEdge(dut.clk)
        dut.sda_in.value = 0 if int(dut.sda_oe.value) == 0 else 1

        i2c_state_now = int(dut.i2c.state.value)
        if i2c_state_now == 3 and prev_i2c_state != 3:
            # Fresh SLAVE_ADDR: a new transaction's address byte is starting.
            bit_count = 0
            cur_byte = 0

        scl_out_now = int(dut.scl_out.value)
        if prev_scl_out == 0 and scl_out_now == 1 and i2c_state_now in DATA_STATES:
            bit = 0 if int(dut.sda_oe.value) == 1 else 1
            cur_byte = (cur_byte << 1) | bit
            bit_count += 1
            if bit_count == 8:
                bytes_out.append(cur_byte)
                bit_count = 0
                cur_byte = 0

        prev_scl_out = scl_out_now
        prev_i2c_state = i2c_state_now


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_full_init_sequence(dut):
    """With an always-ACK slave, dmd_init must wait for gpio4_intf to fall,
    then write all 5 registers in order with the exact expected content,
    and finally assert init_done with init_error staying low."""
    await start_clock(dut)
    await reset(dut)

    captured = []  # shared with the background capture task
    slave_task = cocotb.start_soon(fake_slave_ack_and_capture(dut, captured))

    # gpio4_intf stays high (busy) for a while after reset, matching real
    # DLPC2607 power-up behaviour, then falls to signal auto-init is done.
    await ClockCycles(dut.clk, 10)
    assert dut.init_done.value == 0, "init_done must not assert before gpio4_intf falls"
    dut.gpio4_intf.value = 0

    bytes_per_reg = 6  # device address byte + sub-address byte + 4 data bytes
    total_bytes = bytes_per_reg * len(EXPECTED_REGS)
    # Each byte takes ~2*DIV_100MHZ clk cycles (one bit period) plus ACK
    # overhead; 5 registers x 6 bytes each, generously budgeted.
    timeout_cycles = 40 * total_bytes * DIV_100MHZ
    for _ in range(timeout_cycles):
        if len(captured) >= total_bytes:
            break
        await RisingEdge(dut.clk)
    else:
        slave_task.cancel()
        assert False, (
            f"only captured {len(captured)}/{total_bytes} bytes within "
            f"{timeout_cycles} clk cycles"
        )

    for i, (expected_sub, expected_val) in enumerate(EXPECTED_REGS):
        chunk = captured[i * bytes_per_reg : (i + 1) * bytes_per_reg]
        # chunk = [device_addr_byte, sub_addr_byte, data_byte3(MSB), data2, data1, data0(LSB)]
        assert chunk[0] == DLPC2607_ADDR_W, (
            f"reg #{i}: device address byte {hex(chunk[0])} != {hex(DLPC2607_ADDR_W)}"
        )
        assert chunk[1] == expected_sub, (
            f"reg #{i}: sub-address {hex(chunk[1])} != expected {hex(expected_sub)}"
        )
        got_val = (chunk[2] << 24) | (chunk[3] << 16) | (chunk[4] << 8) | chunk[5]
        assert got_val == expected_val, (
            f"reg {hex(expected_sub)}: data {hex(got_val)} != expected {hex(expected_val)}"
        )

    # Let the last transaction's STOP + dmd_init's own WAIT_DONE settle.
    await ClockCycles(dut.clk, 5 * DIV_100MHZ)

    assert dut.init_done.value == 1, "init_done should assert once all registers are written"
    assert dut.init_error.value == 0, "init_error should stay low — every write was ACKed"

    slave_task.cancel()


@cocotb.test()
async def test_gpio4_intf_gates_start(dut):
    """No I2C activity (i2c_master.busy) should occur while gpio4_intf is
    held high, regardless of how long dmd_init has been out of reset."""
    await start_clock(dut)
    await reset(dut)
    # gpio4_intf stays high (set in reset()) for this whole test.

    for _ in range(50):
        await RisingEdge(dut.clk)
        assert dut.i2c.busy.value == 0, (
            "i2c_master.busy went high while gpio4_intf was still asserted "
            "— dmd_init must wait for auto-init to complete"
        )
        assert dut.init_done.value == 0, "init_done must not assert while gated"

    # Releasing gpio4_intf now should let the first transaction start.
    dut.gpio4_intf.value = 0
    timeout_cycles = 10 * DIV_100MHZ
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.i2c.busy.value == 1:
            return  # transaction started — test passes
    assert False, (
        f"i2c_master never went busy within {timeout_cycles} clk cycles "
        f"after gpio4_intf released"
    )


@cocotb.test()
async def test_nack_aborts_init(dut):
    """With no slave present (sda_in stays released/high, nothing ever
    ACKs), the first register write's address byte gets NACKed. dmd_init
    must latch init_error, never assert init_done, and must not attempt
    any further registers."""
    await start_clock(dut)
    await reset(dut)
    # No fake-slave task started: sda_in stays released for the whole test,
    # so the very first address byte will be NACKed.

    dut.gpio4_intf.value = 0

    # STATE_DONE = 5 (see typedef enum order in dmd_init.sv)
    STATE_DONE = 5
    timeout_cycles = 40 * DIV_100MHZ  # one address byte + ACK wait, generously
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dut.state.value) == STATE_DONE:
            break
    else:
        assert False, f"dmd_init never reached DONE within {timeout_cycles} clk cycles"

    assert dut.init_error.value == 1, "init_error should latch once the write is NACKed"
    assert dut.init_done.value == 0, "init_done must not assert on an aborted (NACKed) init"

    # Confirm it really stopped (didn't loop back and keep trying registers).
    await ClockCycles(dut.clk, 10 * DIV_100MHZ)
    assert int(dut.dut.state.value) == STATE_DONE, "FSM should remain parked in DONE after aborting"
    assert dut.init_done.value == 0, "init_done must stay low after an aborted init"
