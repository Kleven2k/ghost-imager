import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10  # arbitrary — csr_handler is fully synchronous, no baud rate

# Packet TYPEs (must match csr_handler.sv)
TYPE_CSR_WRITE     = 0x10
TYPE_CSR_READ      = 0x11
TYPE_CSR_ACK       = 0x03
TYPE_CSR_READ_RESP = 0x13

# CSR addresses (must match architecture.md §8)
ADDR_CTRL        = 0x00
ADDR_STATUS      = 0x01
ADDR_N_PATTERNS  = 0x02
ADDR_T_SETTLE    = 0x03
ADDR_T_SAMPLE    = 0x04
ADDR_MODE        = 0x05
ADDR_DUMP_PERIOD = 0x06
ADDR_SCRATCH     = 0x07


# ── Helpers ───────────────────────────────────────────────────────────────────

async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())


async def reset(dut):
    """Assert reset (active-low) for 4 cycles, deassert, then wait one rising edge."""
    dut.rst_n.value           = 0
    dut.rx_msg_type.value     = 0
    dut.rx_msg_len.value      = 0
    dut.rx_payload_byte.value = 0
    dut.rx_payload_valid.value = 0
    dut.rx_msg_done.value     = 0
    dut.rx_crc_ok.value       = 0
    dut.tx_payload_req.value  = 0
    dut.tx_busy.value         = 0
    dut.status_in.value       = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def drive_rx_packet(dut, msg_type, payload, crc_ok=True):
    """Simulate a packet arriving from uart_interface.

    Streams the payload bytes one per clock with rx_payload_valid high, then
    pulses rx_msg_done + rx_crc_ok on the cycle after the last byte.
    """
    dut.rx_msg_type.value = msg_type
    dut.rx_msg_len.value  = len(payload)

    for b in payload:
        dut.rx_payload_byte.value  = b
        dut.rx_payload_valid.value = 1
        await RisingEdge(dut.clk)

    dut.rx_payload_valid.value = 0
    dut.rx_msg_done.value      = 1
    dut.rx_crc_ok.value        = 1 if crc_ok else 0
    await RisingEdge(dut.clk)
    dut.rx_msg_done.value      = 0
    dut.rx_crc_ok.value        = 0


async def consume_tx_packet(dut, timeout_cycles=200):
    """Pretend to be uart_interface on the TX side.

    Waits for tx_send to pulse, then:
      1. Captures tx_msg_type and tx_msg_len.
      2. Raises tx_busy.
      3. Captures byte 0 (already on tx_payload_byte).
      4. For each subsequent byte (1..N-1), pulses tx_payload_req for one cycle
         and captures the byte one cycle later.
      5. Drops tx_busy after the last byte.

    Returns (msg_type, payload_bytes).
    """
    # Wait for tx_send
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.tx_send.value) == 1:
            break
    else:
        raise TimeoutError("tx_send never pulsed")

    msg_type = int(dut.tx_msg_type.value)
    msg_len  = int(dut.tx_msg_len.value)

    # csr_handler exits TX_SENDING on (tx_started && !tx_busy). We need to raise
    # tx_busy before that condition can fire — assert it the cycle after tx_send.
    dut.tx_busy.value = 1
    await RisingEdge(dut.clk)

    payload = [int(dut.tx_payload_byte.value)]   # byte 0 was loaded with tx_send

    print(f"[probe] after byte0: state={int(dut.dbg_csr_tx_state.value)} "
          f"resp_is_read={int(dut.dbg_resp_is_read.value)} "
          f"read_addr=0x{int(dut.dbg_read_addr.value):02x} "
          f"csr_read_value=0x{int(dut.dbg_csr_read_value.value):08x} "
          f"tx_byte_idx={int(dut.dbg_tx_byte_idx.value)} "
          f"tx_busy={int(dut.tx_busy.value)} "
          f"byte0=0x{payload[0]:02x}")

    for i in range(msg_len - 1):
        dut.tx_payload_req.value = 1
        await RisingEdge(dut.clk)
        dut.tx_payload_req.value = 0
        await RisingEdge(dut.clk)
        b = int(dut.tx_payload_byte.value)
        print(f"[probe] after byte{i+1}: state={int(dut.dbg_csr_tx_state.value)} "
              f"tx_byte_idx={int(dut.dbg_tx_byte_idx.value)} "
              f"csr_read_value=0x{int(dut.dbg_csr_read_value.value):08x} "
              f"byte={b:02x}")
        payload.append(b)

    dut.tx_busy.value = 0
    await RisingEdge(dut.clk)

    return msg_type, payload


def encode_value_le(value):
    """Encode a 32-bit value as 4 little-endian bytes."""
    return [
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
    ]


def decode_value_le(bytes_):
    """Decode 4 little-endian bytes as a 32-bit value."""
    return (bytes_[0]) | (bytes_[1] << 8) | (bytes_[2] << 16) | (bytes_[3] << 24)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_reset_state(dut):
    """After reset, all CSR outputs read zero and no TX is in progress."""
    await start_clock(dut)
    await reset(dut)

    assert int(dut.ctrl_reg.value)        == 0
    assert int(dut.n_patterns_reg.value)  == 0
    assert int(dut.t_settle_reg.value)    == 0
    assert int(dut.t_sample_reg.value)    == 0
    assert int(dut.mode_reg.value)        == 0
    assert int(dut.dump_period_reg.value) == 0
    assert int(dut.scratch_reg.value)     == 0
    assert int(dut.tx_send.value)         == 0


@cocotb.test()
async def test_csr_write_updates_register(dut):
    """Write 0xDEADBEEF to SCRATCH, verify scratch_reg gets the value."""
    await start_clock(dut)
    await reset(dut)

    value = 0xDEADBEEF
    payload = [ADDR_SCRATCH] + encode_value_le(value)
    await drive_rx_packet(dut, TYPE_CSR_WRITE, payload)

    # Give the FSM one extra cycle to commit
    await ClockCycles(dut.clk, 2)
    assert int(dut.scratch_reg.value) == value, \
        f"expected scratch=0x{value:08x}, got 0x{int(dut.scratch_reg.value):08x}"


@cocotb.test()
async def test_csr_write_emits_ack(dut):
    """A CSR write should generate an ACK packet (type=0x03, payload=[addr])."""
    await start_clock(dut)
    await reset(dut)

    payload = [ADDR_N_PATTERNS] + encode_value_le(0x1000)
    drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_WRITE, payload))
    msg_type, ack_payload = await consume_tx_packet(dut)
    await drive_task

    assert msg_type == TYPE_CSR_ACK, f"expected type 0x{TYPE_CSR_ACK:02x}, got 0x{msg_type:02x}"
    assert ack_payload == [ADDR_N_PATTERNS], f"unexpected ACK payload: {ack_payload}"


@cocotb.test()
async def test_csr_read_returns_value(dut):
    """Write a value, then read it back. Verify READ_RESP carries the value."""
    await start_clock(dut)
    await reset(dut)

    value = 0xCAFEBABE
    # Write first
    write_payload = [ADDR_SCRATCH] + encode_value_le(value)
    drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_WRITE, write_payload))
    await consume_tx_packet(dut)  # consume the ACK
    await drive_task
    await ClockCycles(dut.clk, 4)

    # Sanity probe: scratch_reg should now hold the value
    assert int(dut.scratch_reg.value) == value, \
        f"PROBE: scratch_reg should be 0x{value:08x} after write, got 0x{int(dut.scratch_reg.value):08x}"

    # Now read
    drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_READ, [ADDR_SCRATCH]))
    msg_type, resp_payload = await consume_tx_packet(dut)
    await drive_task

    assert msg_type == TYPE_CSR_READ_RESP, f"expected type 0x{TYPE_CSR_READ_RESP:02x}, got 0x{msg_type:02x}"
    assert len(resp_payload) == 5, f"expected 5-byte payload, got {len(resp_payload)}"
    assert resp_payload[0] == ADDR_SCRATCH, f"addr echo mismatch: {resp_payload[0]:02x}"
    recovered = decode_value_le(resp_payload[1:])
    assert recovered == value, f"expected 0x{value:08x}, got 0x{recovered:08x}"


@cocotb.test()
async def test_status_reg_is_read_only(dut):
    """A write to STATUS should be ignored (silently). A read returns status_in."""
    await start_clock(dut)
    await reset(dut)

    dut.status_in.value = 0x12345678
    await RisingEdge(dut.clk)

    # Try to write — should be ignored, but ACK still fires (per current contract).
    write_payload = [ADDR_STATUS] + encode_value_le(0xFFFFFFFF)
    drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_WRITE, write_payload))
    await consume_tx_packet(dut)
    await drive_task
    await ClockCycles(dut.clk, 2)

    # Now read STATUS — should return status_in, not the attempted write value.
    drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_READ, [ADDR_STATUS]))
    _, resp_payload = await consume_tx_packet(dut)
    await drive_task

    recovered = decode_value_le(resp_payload[1:])
    assert recovered == 0x12345678, \
        f"STATUS read should return status_in (0x12345678), got 0x{recovered:08x}"


@cocotb.test()
async def test_bad_crc_is_ignored(dut):
    """A packet with crc_ok=0 should not commit to the register file."""
    await start_clock(dut)
    await reset(dut)

    payload = [ADDR_SCRATCH] + encode_value_le(0xBADBAD)
    await drive_rx_packet(dut, TYPE_CSR_WRITE, payload, crc_ok=False)
    await ClockCycles(dut.clk, 4)

    assert int(dut.scratch_reg.value) == 0, \
        f"bad-CRC write should not commit, but scratch_reg = 0x{int(dut.scratch_reg.value):08x}"


@cocotb.test()
async def test_multiple_register_writes(dut):
    """Write distinct values to several registers; verify each one independently."""
    await start_clock(dut)
    await reset(dut)

    writes = [
        (ADDR_CTRL,        0x00000001),
        (ADDR_N_PATTERNS,  0x00001000),
        (ADDR_T_SETTLE,    0x000003E8),
        (ADDR_T_SAMPLE,    0x00004E20),
        (ADDR_MODE,        0x00000003),
        (ADDR_DUMP_PERIOD, 0x00000010),
        (ADDR_SCRATCH,     0xDEADBEEF),
    ]

    for addr, value in writes:
        payload = [addr] + encode_value_le(value)
        drive_task = cocotb.start_soon(drive_rx_packet(dut, TYPE_CSR_WRITE, payload))
        await consume_tx_packet(dut)  # drain the ACK so the TX FSM returns to IDLE
        await drive_task
        await ClockCycles(dut.clk, 2)

    assert int(dut.ctrl_reg.value)        == 0x00000001
    assert int(dut.n_patterns_reg.value)  == 0x00001000
    assert int(dut.t_settle_reg.value)    == 0x000003E8
    assert int(dut.t_sample_reg.value)    == 0x00004E20
    assert int(dut.mode_reg.value)        == 0x00000003
    assert int(dut.dump_period_reg.value) == 0x00000010
    assert int(dut.scratch_reg.value)     == 0xDEADBEEF
