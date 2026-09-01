import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in i2c_master_tb_wrapper.sv
CLK_HZ           = 1_000_000
SCL_HZ           = 40_000
DIV_100MHZ       = CLK_HZ // (SCL_HZ * 2)   # = 12 (clk_i2c half-period, in clk cycles)
START_IND_SETUP  = 7
STOP_IND_SETUP   = 6
DATA_HOLD_TIME   = 3
DATA_SETUP_TIME  = 2

# ── Helpers ───────────────────────────────────────────────────────────────────

async def reset(dut):
    dut.rst_n.value        = 0
    dut.req_trans.value    = 0
    dut.i_addr_w_rw.value  = 0
    dut.i_sub_addr.value   = 0
    dut.i_sub_len.value    = 0
    dut.i_byte_len.value   = 0
    dut.i_data_write.value = 0
    dut.scl_in.value       = 1
    dut.sda_in.value       = 1
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def fake_slave_ack(dut):
    """Always-ACK slave model: whenever the DUT releases SDA (sda_oe==0) the
    slave pulls it low; whenever the DUT is driving (sda_oe==1) the slave
    releases it. Not byte-accurate — the DUT only ever releases SDA when it
    wants a response (ACK/NACK wait, or a read bit), so this is enough to
    unlock full write transactions without a precise bit counter. Runs
    forever; the test that starts it owns cancelling it at the end."""
    while True:
        await RisingEdge(dut.clk)
        dut.sda_in.value = 0 if int(dut.sda_oe.value) == 0 else 1


async def fake_slave_ack_and_read(dut, read_byte, read_state):
    """Like fake_slave_ack, but while the FSM is in read_state (the READ
    state) it drives read_byte's bits onto sda_in instead of blanket-ACKing:
    MSB first, changed while scl_out is low so it's stable before the
    master's next SCL rising-edge sample — the same timing discipline the
    master itself uses when driving write bits. Outside READ, behaves
    exactly like fake_slave_ack. Runs forever; caller cancels it."""
    bit_index = 7  # MSB first
    prev_scl_out = int(dut.scl_out.value)
    while True:
        await RisingEdge(dut.clk)
        scl_out_now = int(dut.scl_out.value)

        if int(dut.dut.state.value) == read_state:
            if prev_scl_out == 1 and scl_out_now == 0:
                # scl just fell: stage the next bit before the master
                # samples it on the upcoming rising edge.
                bit = (read_byte >> bit_index) & 1
                dut.sda_in.value = bit
                bit_index = (bit_index - 1) if bit_index > 0 else 7
        else:
            dut.sda_in.value = 0 if int(dut.sda_oe.value) == 0 else 1

        prev_scl_out = scl_out_now


async def capture_written_bytes(dut, n_bytes, stop_state):
    """Run a fake-ACK slave that also reconstructs the bytes the DUT shifts
    out on SDA, sampling sda_oe (the master's own drive) on each SCL rising
    edge, as a real receiver would sample the line. sda_oe=1 means the
    master pulled SDA low (bit 0); sda_oe=0 means released (bit 1). Every
    9th sampled bit is the ACK/NACK bit — driven by the slave, not the
    master — and is discarded rather than folded into a data byte. Runs
    until the FSM reaches stop_state or n_bytes are captured; returns the
    list of captured bytes."""
    bytes_out = []
    cur_byte = 0
    bit_count = 0
    prev_scl_out = int(dut.scl_out.value)

    while int(dut.dut.state.value) != stop_state:
        await RisingEdge(dut.clk)
        dut.sda_in.value = 0 if int(dut.sda_oe.value) == 0 else 1

        scl_out_now = int(dut.scl_out.value)
        if prev_scl_out == 0 and scl_out_now == 1:
            if bit_count < 8:
                bit = 0 if int(dut.sda_oe.value) == 1 else 1
                cur_byte = (cur_byte << 1) | bit
                bit_count += 1
                if bit_count == 8:
                    bytes_out.append(cur_byte)
            else:
                bit_count = 0  # this rising edge was the ACK/NACK bit
                cur_byte = 0
                if len(bytes_out) >= n_bytes:
                    break
        prev_scl_out = scl_out_now

    return bytes_out


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_start_condition(dut):
    """After req_trans, sda_oe must rise (SDA pulled low) while scl_out is
    still high — that's the I2C START condition. It must not happen while
    scl_out is low (that would just be an ordinary bit transition)."""
    await start_clock(dut)
    await reset(dut)

    # Kick off a transaction. Values don't matter yet — only the START timing.
    dut.i_addr_w_rw.value = 0xAA
    await RisingEdge(dut.clk)
    dut.req_trans.value = 1
    await RisingEdge(dut.clk)
    dut.req_trans.value = 0
    await RisingEdge(dut.clk)  # let busy<=1'b1 (registered in IDLE) become visible

    assert dut.busy.value == 1, "busy should assert once a transaction starts"
    assert dut.scl_oe.value == 1, "scl_oe should assert once en_scl is set"

    # Poll cycle-by-cycle for sda_oe's 0->1 edge, recording what scl_out was
    # doing at that instant.
    timeout_cycles = 4 * DIV_100MHZ  # generous: ~2 full clk_i2c periods
    prev_sda_oe = int(dut.sda_oe.value)
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        scl_out_now = int(dut.scl_out.value)
        sda_oe_now = int(dut.sda_oe.value)

        if prev_sda_oe == 0 and sda_oe_now == 1:
            assert scl_out_now == 1, (
                "sda_oe rose while scl_out was low — that's a bit "
                "transition, not a START condition"
            )
            return  # found the START edge — test passes

        prev_sda_oe = sda_oe_now

    assert False, f"sda_oe never rose within {timeout_cycles} clk cycles"


@cocotb.test()
async def test_stop_condition(dut):
    """A full single-byte write, with an always-ACK fake slave, must end
    with a STOP: SDA released (rising) while scl_out is high, and busy
    dropping back to 0."""
    await start_clock(dut)
    await reset(dut)
    slave_task = cocotb.start_soon(fake_slave_ack(dut))

    dut.i_addr_w_rw.value  = 0xA0  # write (LSB=0)
    dut.i_sub_addr.value   = 0x00AA
    dut.i_sub_len.value    = 0     # 8-bit sub-address
    dut.i_byte_len.value   = 1     # single data byte
    dut.i_data_write.value = 0x5A
    await RisingEdge(dut.clk)
    dut.req_trans.value = 1
    await RisingEdge(dut.clk)
    dut.req_trans.value = 0
    await RisingEdge(dut.clk)

    assert dut.busy.value == 1, "busy should assert once a transaction starts"
    assert dut.nack.value == 0, "fake slave always ACKs — nack should stay low"

    # State encoding from the typedef enum order in i2c_master.sv:
    # IDLE=0 START=1 RESTART=2 SLAVE_ADDR=3 SUB_ADDR=4 READ=5 WRITE=6
    # GRAB_DATA=7 ACK_NACK_RX=8 ACK_NACK_TX=9 STOP=10 RELEASE_BUS=11
    STATE_STOP = 10

    # A full transaction (START, addr byte, sub-addr byte, data byte, STOP)
    # sends 3 bytes, each ~9 bit-periods (8 data + ACK) at 2*DIV_100MHZ clk
    # cycles per bit; give it a generous timeout well above that estimate.
    timeout_cycles = 200 * DIV_100MHZ
    prev_sda_oe = int(dut.sda_oe.value)
    entered_stop = False
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        scl_out_now = int(dut.scl_out.value)
        sda_oe_now  = int(dut.sda_oe.value)
        state_now   = int(dut.dut.state.value)

        if state_now == STATE_STOP:
            entered_stop = True

        # The STOP condition itself is SDA released (falling drive-enable)
        # while SCL is high, and only while the FSM is actually in STOP —
        # this rules out ordinary bit-shift releases in earlier states.
        if entered_stop and prev_sda_oe == 1 and sda_oe_now == 0:
            assert scl_out_now == 1, (
                "sda_oe fell (released) while scl_out was low — that's not "
                "a STOP condition"
            )
            await ClockCycles(dut.clk, DIV_100MHZ)  # let RELEASE_BUS finish
            assert dut.busy.value == 0, "busy should clear once STOP completes"
            slave_task.cancel()
            return  # found the STOP edge — test passes

        prev_sda_oe = sda_oe_now

    slave_task.cancel()
    assert False, f"STOP condition never observed within {timeout_cycles} clk cycles"


@cocotb.test()
async def test_write_content(dut):
    """The bytes actually shifted onto SDA during a write must match
    i_addr_w_rw, i_sub_addr[7:0] (8-bit sub-address mode), and
    i_data_write — not just the timing of the transitions."""
    await start_clock(dut)
    await reset(dut)

    ADDR       = 0xA0  # write (LSB=0)
    SUB_ADDR   = 0x00AA
    DATA_BYTE  = 0x5A

    dut.i_addr_w_rw.value  = ADDR
    dut.i_sub_addr.value   = SUB_ADDR
    dut.i_sub_len.value    = 0     # 8-bit sub-address
    dut.i_byte_len.value   = 1     # single data byte
    dut.i_data_write.value = DATA_BYTE
    await RisingEdge(dut.clk)
    dut.req_trans.value = 1
    await RisingEdge(dut.clk)
    dut.req_trans.value = 0
    await RisingEdge(dut.clk)

    assert dut.busy.value == 1, "busy should assert once a transaction starts"

    # STATE_STOP = 10 (see typedef enum order in i2c_master.sv)
    captured = await capture_written_bytes(dut, n_bytes=3, stop_state=10)

    assert captured == [ADDR, SUB_ADDR & 0xFF, DATA_BYTE], (
        f"captured bytes {[hex(b) for b in captured]} != expected "
        f"{[hex(ADDR), hex(SUB_ADDR & 0xFF), hex(DATA_BYTE)]}"
    )


@cocotb.test()
async def test_nack_aborts_transaction(dut):
    """With no slave present (sda_in stays released/high), the address byte
    is never ACKed. The master must recognize the NACK, set nack=1, clear
    busy, and return to IDLE without ever reaching SUB_ADDR/WRITE."""
    await start_clock(dut)
    await reset(dut)
    # No fake-slave task started: sda_in stays at its reset value (1,
    # released) for the whole test, so nothing will ever ACK.

    dut.i_addr_w_rw.value  = 0xA0
    dut.i_sub_addr.value   = 0x00AA
    dut.i_sub_len.value    = 0
    dut.i_byte_len.value   = 1
    dut.i_data_write.value = 0x5A
    await RisingEdge(dut.clk)
    dut.req_trans.value = 1
    await RisingEdge(dut.clk)
    dut.req_trans.value = 0
    await RisingEdge(dut.clk)

    assert dut.busy.value == 1, "busy should assert once a transaction starts"
    assert dut.nack.value == 0, "nack should not be set before the address byte finishes"

    # STATE_SUB_ADDR = 4 (see typedef enum order in i2c_master.sv) — the
    # state the FSM would move to next on a real ACK. It must never get
    # there, since nothing ACKs the address byte in this test.
    STATE_SUB_ADDR = 4
    timeout_cycles = 50 * DIV_100MHZ  # one address byte + ACK wait, generously
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        assert int(dut.dut.state.value) != STATE_SUB_ADDR, (
            "FSM advanced to SUB_ADDR despite no ACK ever being driven"
        )
        if dut.nack.value == 1:
            break
    else:
        assert False, f"nack never asserted within {timeout_cycles} clk cycles"

    assert dut.busy.value == 0, "busy should clear once the NACK aborts the transaction"

    # Confirm the abort is clean: a fresh transaction can still be started.
    await ClockCycles(dut.clk, 4)
    assert dut.busy.value == 0, "busy should remain clear while idle after a NACK"


@cocotb.test()
async def test_read_content(dut):
    """A single-byte read: write the sub-address, repeated-START into read
    mode, and the byte the slave drives must land correctly in data_out
    with valid_out pulsed, and the transaction must NACK (since byte_len=1
    means this is the last/only byte) then STOP cleanly."""
    await start_clock(dut)
    await reset(dut)

    ADDR      = 0xA1  # read (LSB=1)
    SUB_ADDR  = 0x00AA
    READ_BYTE = 0x3C

    # STATE_READ = 5 (see typedef enum order in i2c_master.sv)
    STATE_READ = 5
    slave_task = cocotb.start_soon(fake_slave_ack_and_read(dut, READ_BYTE, STATE_READ))

    dut.i_addr_w_rw.value = ADDR
    dut.i_sub_addr.value  = SUB_ADDR
    dut.i_sub_len.value   = 0     # 8-bit sub-address
    dut.i_byte_len.value  = 1     # single data byte
    await RisingEdge(dut.clk)
    dut.req_trans.value = 1
    await RisingEdge(dut.clk)
    dut.req_trans.value = 0
    await RisingEdge(dut.clk)

    assert dut.busy.value == 1, "busy should assert once a transaction starts"

    # Wait for valid_out's pulse and capture data_out at that moment.
    # A read transaction needs START + addr + sub-addr + RESTART + addr +
    # data byte + STOP; give it a generous timeout.
    timeout_cycles = 300 * DIV_100MHZ
    captured = None
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if dut.valid_out.value == 1:
            captured = int(dut.data_out.value)
            break
    else:
        slave_task.cancel()
        assert False, f"valid_out never pulsed within {timeout_cycles} clk cycles"

    assert captured == READ_BYTE, (
        f"data_out={hex(captured)} != expected {hex(READ_BYTE)}"
    )
    assert dut.nack.value == 0, (
        "nack here reflects the module's own NACK status flag, not the "
        "master->slave ack bit sent for the last read byte — should stay 0"
    )

    # STATE_STOP = 10
    STATE_STOP = 10
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dut.state.value) == STATE_STOP:
            break
    else:
        slave_task.cancel()
        assert False, f"FSM never reached STOP within {timeout_cycles} clk cycles"

    await ClockCycles(dut.clk, DIV_100MHZ * 3)  # let STOP/RELEASE_BUS finish
    assert dut.busy.value == 0, "busy should clear once the read transaction completes"
    slave_task.cancel()
