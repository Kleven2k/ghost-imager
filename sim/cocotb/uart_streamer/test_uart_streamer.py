"""
Cocotb tests for uart_streamer (single-packet 0x01 dump).

The DUT has no internal sub-modules — both external interfaces (BRAM port B,
uart_interface TX) are stubbed by coroutines here.

BRAM model: responds to rd_addr with a 1-cycle registered-read latency.
uart_interface model: detects tx_send, drives tx_busy, pulses tx_payload_req
  for each byte 1 .. LEN-1, then drops tx_busy to signal packet complete.

Protocol under test: one packet, TYPE 0x01, LEN = n_pixels*4, payload = all
accumulator words back-to-back, each word big-endian (MSB first).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Must match uart_streamer_tb_wrapper parameters
PATTERN_WIDTH = 4
BYTES_PER_WORD = 4   # ACC_WIDTH=32 → 4 bytes per accumulator word

MSG_DUMP = 0x01

# Known accumulator contents for the four simulated pixels
TEST_MEM = [0xDEADBEEF, 0x12345678, 0xCAFEBABE, 0xABCD1234]

# Simulated byte-transmission gap (cycles per byte in the model).
# The real uart_interface at 115200/100 MHz needs 868 cycles; 8 is fine for sim.
MODEL_BYTE_CYCLES = 8


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def reset(dut):
    dut.rst_n.value          = 0
    dut.stream_start.value   = 0
    dut.n_pixels.value       = 0
    dut.rd_data.value        = 0
    dut.tx_payload_req.value = 0
    dut.tx_busy.value        = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def bram_model(dut, mem):
    """
    Simulate the correlator BRAM port B with 1-cycle registered-read latency.

    On every rising edge, read the current rd_addr and write the corresponding
    mem entry to rd_data. The DUT will see the new rd_data on the NEXT rising
    edge — exactly the behaviour of a Xilinx BRAM with registered output.
    """
    while True:
        await RisingEdge(dut.clk)
        addr = int(dut.rd_addr.value)
        dut.rd_data.value = mem[addr] if addr < len(mem) else 0


async def receive_dump(dut, n_pixels):
    """
    Drive the uart_interface TX stub for one dump packet.

    Waits for tx_send, captures the header (type/len) and all payload bytes in
    order, driving tx_busy / tx_payload_req to keep the DUT FSM moving.

    Returns (msg_type, msg_len, [payload bytes]).
    """
    total_bytes = n_pixels * BYTES_PER_WORD

    # ---- wait for tx_send (one-cycle strobe from DUT) ----
    while True:
        await RisingEdge(dut.clk)
        if dut.tx_send.value == 1:
            break

    # Header fields are held stable from BRAM_DATA; sample them now.
    msg_type = int(dut.tx_msg_type.value)
    msg_len  = int(dut.tx_msg_len.value)

    # Byte 0 was pre-staged by the DUT before asserting tx_send. The DUT is now
    # in TX_SENDING and has not yet touched tx_payload_byte, so capture it.
    payload = [int(dut.tx_payload_byte.value)]

    # Signal to the DUT that the uart_tx is now busy.
    dut.tx_busy.value = 1

    # Fire tx_payload_req for bytes 1 .. total_bytes-1. After each pulse the DUT
    # stages the next byte via a registered write (and, at word boundaries, a
    # prefetched BRAM word), so wait one extra RisingEdge before sampling.
    for _ in range(total_bytes - 1):
        await ClockCycles(dut.clk, MODEL_BYTE_CYCLES)
        dut.tx_payload_req.value = 1
        await RisingEdge(dut.clk)   # DUT sees req → registered tx_payload_byte update
        dut.tx_payload_req.value = 0
        await RisingEdge(dut.clk)   # registered update is now visible to us
        payload.append(int(dut.tx_payload_byte.value))

    # Simulate CRC byte, then release tx_busy.
    await ClockCycles(dut.clk, MODEL_BYTE_CYCLES)
    dut.tx_busy.value = 0

    return msg_type, msg_len, payload


def expected_payload(mem, n_pixels):
    """Concatenate the first n_pixels words as big-endian bytes."""
    out = []
    for word in mem[:n_pixels]:
        out += [
            (word >> 24) & 0xFF,
            (word >> 16) & 0xFF,
            (word >>  8) & 0xFF,
             word        & 0xFF,
        ]
    return out


async def wait_for_done(dut, limit=40):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if dut.stream_done.value == 1:
            return True
    return False


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_stream_4_pixels(dut):
    """Stream all 4 pixels as one 0x01 packet; verify header + big-endian payload."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    bram_task = cocotb.start_soon(bram_model(dut, TEST_MEM))

    dut.n_pixels.value = 4
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    # stream_busy should rise immediately (registered on the same edge as start)
    await RisingEdge(dut.clk)
    assert dut.stream_busy.value == 1, "stream_busy did not rise after stream_start"

    msg_type, msg_len, payload = await receive_dump(dut, 4)

    assert msg_type == MSG_DUMP,       f"TYPE: got {msg_type:#04x}, expected {MSG_DUMP:#04x}"
    assert msg_len  == 4 * BYTES_PER_WORD, f"LEN: got {msg_len}, expected {4*BYTES_PER_WORD}"

    exp = expected_payload(TEST_MEM, 4)
    assert payload == exp, (
        f"payload: got {[hex(b) for b in payload]}, expected {[hex(b) for b in exp]}"
    )

    assert await wait_for_done(dut),   "stream_done never asserted"
    assert dut.stream_busy.value == 0, "stream_busy should be low after stream_done"

    bram_task.cancel()


@cocotb.test()
async def test_stream_1_pixel(dut):
    """Degenerate case: n_pixels=1. One word, no word-boundary prefetch."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    bram_task = cocotb.start_soon(bram_model(dut, TEST_MEM))

    dut.n_pixels.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    msg_type, msg_len, payload = await receive_dump(dut, 1)

    assert msg_type == MSG_DUMP,        f"TYPE: got {msg_type:#04x}"
    assert msg_len  == BYTES_PER_WORD,  f"LEN: got {msg_len}, expected {BYTES_PER_WORD}"
    assert payload == expected_payload(TEST_MEM, 1), (
        f"got {[hex(b) for b in payload]}, expected {[hex(b) for b in expected_payload(TEST_MEM,1)]}"
    )

    assert await wait_for_done(dut),   "stream_done not seen for n_pixels=1"
    assert dut.stream_busy.value == 0, "stream_busy should be low"

    bram_task.cancel()


@cocotb.test()
async def test_n_pixels_zero(dut):
    """n_pixels=0: stream_start is a no-op — no packet, no busy."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    dut.n_pixels.value = 0
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    for _ in range(30):
        await RisingEdge(dut.clk)
        assert dut.tx_send.value     == 0, "tx_send should not fire for n_pixels=0"
        assert dut.stream_busy.value == 0, "stream_busy should not rise for n_pixels=0"
        assert dut.stream_done.value == 0, "stream_done should not fire for n_pixels=0"


@cocotb.test()
async def test_tx_busy_blocks_send(dut):
    """
    If tx_busy is high when the DUT reaches TX_WAIT, it must hold off
    until tx_busy drops before firing tx_send.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)

    bram_task = cocotb.start_soon(bram_model(dut, TEST_MEM))

    # Pre-assert tx_busy to block the DUT in TX_WAIT
    dut.tx_busy.value  = 1
    dut.n_pixels.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    # DUT should be busy (BRAM_ADDR → BRAM_DATA → TX_WAIT) but tx_send
    # must NOT fire while tx_busy is high
    await ClockCycles(dut.clk, 20)
    assert dut.tx_send.value      == 0, "tx_send fired while tx_busy was high"
    assert dut.stream_busy.value  == 1, "stream_busy should be high"

    # Release tx_busy — DUT should fire tx_send within a few cycles
    dut.tx_busy.value = 0
    send_seen = False
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.tx_send.value == 1:
            send_seen = True
            break
    assert send_seen, "tx_send did not fire after tx_busy was released"

    # Finish the packet so the DUT returns to IDLE cleanly
    dut.tx_busy.value = 1
    for _ in range(BYTES_PER_WORD - 1):
        await ClockCycles(dut.clk, MODEL_BYTE_CYCLES)
        dut.tx_payload_req.value = 1
        await RisingEdge(dut.clk)
        dut.tx_payload_req.value = 0
    await ClockCycles(dut.clk, MODEL_BYTE_CYCLES)
    dut.tx_busy.value = 0

    bram_task.cancel()
