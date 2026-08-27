"""
Integration test: uart_streamer + real uart_interface + real bram_dp.

Preloads known accumulator words into the BRAM (port A), triggers a dump, and
decodes the REAL serial bytes off tx_pin. Verifies the full on-wire frame:

    SOF(0xAA) | TYPE(0x01) | LEN_HI | LEN_LO | payload(LEN bytes) | CRC(XOR8)

payload = accumulator words back-to-back, each big-endian (MSB first).
CRC = XOR of payload bytes only (matches uart_interface TX FSM).
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Must match wrapper parameters
PATTERN_WIDTH  = 4
ACC_WIDTH      = 32
BYTES_PER_WORD = ACC_WIDTH // 8
CYCLES_PER_BIT = 8          # CLK_HZ / BAUD = 1_000_000 / 125_000

SOF      = 0xAA
MSG_DUMP = 0x01

TEST_MEM = [0xDEADBEEF, 0x12345678, 0xCAFEBABE, 0xABCD1234]


async def reset(dut):
    dut.rst_n.value        = 0
    dut.pre_we.value       = 0
    dut.pre_addr.value     = 0
    dut.pre_din.value      = 0
    dut.stream_start.value = 0
    dut.n_pixels.value     = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def preload(dut, mem):
    """Write each word into the BRAM via port A, one per clock."""
    for addr, word in enumerate(mem):
        dut.pre_we.value   = 1
        dut.pre_addr.value = addr
        dut.pre_din.value  = word
        await RisingEdge(dut.clk)
    dut.pre_we.value = 0
    await RisingEdge(dut.clk)


async def uart_monitor(dut, out_bytes):
    """
    Decode 8N1 bytes off tx_pin (LSB first) and append to out_bytes.

    Idle line is high. On a falling edge (start bit) sample the 8 data bits at
    their centres, CYCLES_PER_BIT apart.
    """
    # Ensure we start from an idle-high line.
    while dut.tx_pin.value != 1:
        await RisingEdge(dut.clk)

    while True:
        # Wait for start bit (line goes low).
        while dut.tx_pin.value != 0:
            await RisingEdge(dut.clk)

        # Move to the centre of bit 0: one full bit (start) + half a bit.
        await ClockCycles(dut.clk, CYCLES_PER_BIT + CYCLES_PER_BIT // 2)

        val = 0
        for i in range(8):
            val |= (int(dut.tx_pin.value) & 1) << i   # LSB first
            await ClockCycles(dut.clk, CYCLES_PER_BIT)

        out_bytes.append(val)
        # Now near the centre of the stop bit; loop will resync on next start bit.


def expected_payload(mem, n_pixels):
    out = []
    for word in mem[:n_pixels]:
        out += [(word >> 24) & 0xFF, (word >> 16) & 0xFF,
                (word >> 8) & 0xFF,  word & 0xFF]
    return out


@cocotb.test()
async def test_full_dump(dut):
    """End-to-end: preload 4 words, dump, decode the real serial frame."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    await preload(dut, TEST_MEM)

    received = []
    cocotb.start_soon(uart_monitor(dut, received))

    n = len(TEST_MEM)
    dut.n_pixels.value = n
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    # Wait for the streamer to finish the packet.
    done = False
    for _ in range(20000):
        await RisingEdge(dut.clk)
        if dut.stream_done.value == 1:
            done = True
            break
    assert done, "stream_done never asserted"

    # Let the last byte (CRC) + stop bit finish serializing.
    await ClockCycles(dut.clk, CYCLES_PER_BIT * 12)

    payload = expected_payload(TEST_MEM, n)
    expected_frame = [SOF, MSG_DUMP,
                      (len(payload) >> 8) & 0xFF, len(payload) & 0xFF] + payload
    crc = 0
    for b in payload:
        crc ^= b
    expected_frame.append(crc)

    assert received == expected_frame, (
        f"\n  got:      {[hex(b) for b in received]}"
        f"\n  expected: {[hex(b) for b in expected_frame]}"
    )


@cocotb.test()
async def test_single_word_dump(dut):
    """n_pixels=1: smallest packet, no word-boundary prefetch."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    await preload(dut, TEST_MEM)

    received = []
    cocotb.start_soon(uart_monitor(dut, received))

    dut.n_pixels.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 1
    await RisingEdge(dut.clk)
    dut.stream_start.value = 0

    done = False
    for _ in range(8000):
        await RisingEdge(dut.clk)
        if dut.stream_done.value == 1:
            done = True
            break
    assert done, "stream_done never asserted"
    await ClockCycles(dut.clk, CYCLES_PER_BIT * 12)

    payload = expected_payload(TEST_MEM, 1)
    crc = 0
    for b in payload:
        crc ^= b
    expected_frame = [SOF, MSG_DUMP, 0x00, len(payload)] + payload + [crc]

    assert received == expected_frame, (
        f"\n  got:      {[hex(b) for b in received]}"
        f"\n  expected: {[hex(b) for b in expected_frame]}"
    )
