import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

CLK_PERIOD_NS = 10  # 100 MHz wall-clock; sim time only — RTL is parameter-overridden

# Must match the parameter overrides in dmd_video_if_tb_wrapper.sv
CLK_HZ  = 1_000_000
PCLK_HZ = 500_000
DIV     = (CLK_HZ + PCLK_HZ - 1) // PCLK_HZ  # clk cycles per PCLK period

H_ACTIVE, H_FRONT_PORCH, H_SYNC_WIDTH, H_BACK_PORCH = 16, 2, 2, 2
V_ACTIVE, V_FRONT_PORCH, V_SYNC_WIDTH, V_BACK_PORCH = 16, 1, 1, 1

H_TOTAL = H_ACTIVE + H_FRONT_PORCH + H_SYNC_WIDTH + H_BACK_PORCH
V_TOTAL = V_ACTIVE + V_FRONT_PORCH + V_SYNC_WIDTH + V_BACK_PORCH

BLOCK_W = H_ACTIVE // 8
BLOCK_H = V_ACTIVE // 8

# ── Helpers ───────────────────────────────────────────────────────────────────

async def reset(dut, pattern=0):
    """pattern must be set here, not written separately before/after: the
    reset block latches data from pattern_in[63] directly (see
    dmd_video_if.sv), so whatever pattern_in holds at the moment rst_n
    releases is what pixel (0,0) will show."""
    dut.rst_n.value      = 0
    dut.pattern_in.value = pattern
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def sample(dut):
    """Read the DUT's current (hsync, vsync, dataen, data) without
    advancing time — used right after reset() to observe pixel (0,0),
    whose values are already valid at reset per dmd_video_if.sv's reset
    block (no pclk_en pulse needed to reach them)."""
    return (
        int(dut.hsync.value),
        int(dut.vsync.value),
        int(dut.dataen.value),
        int(dut.data.value),
    )


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def step_pixels(dut, n):
    """Advance n PCLK periods and return the (hsync, vsync, dataen, data)
    tuple reflecting the Nth pixel.

    hsync/vsync/dataen/data are registered in lockstep with h_count/v_count
    (both computed from the *next* counter values on the same pclk_en
    edge — see dmd_video_if.sv), and the reset values already describe
    pixel (0,0) directly rather than a placeholder blanking state. So
    n*DIV clk cycles after reset lands exactly on the Nth pixel's settled
    outputs, with no extra alignment cycle needed."""
    result = None
    for _ in range(n):
        await ClockCycles(dut.clk, DIV)
        # h_count and dataen/hsync/vsync/data are two separate registers
        # both updating on the same clk edge; ReadOnly ensures every
        # signal's post-edge value has settled before sampling, rather
        # than risking a stale value from mid-delta-cycle.
        await ReadOnly()
        result = (
            int(dut.hsync.value),
            int(dut.vsync.value),
            int(dut.dataen.value),
            int(dut.data.value),
        )
    return result


def expected_bit(pattern, h, v):
    """What dmd_video_if.sv should be driving on `data` for physical pixel
    (h, v), given the current pattern_in — bit 63 = logical pixel (0,0),
    row-major, per the module's documented convention."""
    if h >= H_ACTIVE or v >= V_ACTIVE:
        return None  # not in the active area — expect black/blanked
    block_x = h // BLOCK_W
    block_y = v // BLOCK_H
    bit_idx = block_y * 8 + block_x
    return (pattern >> (63 - bit_idx)) & 1


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_dataen_tracks_active_region(dut):
    """dataen must be low during the very first pixel period after reset
    only if that period falls in blanking, and must go high once h_count
    and v_count are both inside the active region. With H_ACTIVE=V_ACTIVE=16
    and all of them nonzero at start, the very first pixel (0,0) IS active,
    so dataen should already be high on the first sampled pixel."""
    await start_clock(dut)
    await reset(dut)

    hsync, vsync, dataen, data = sample(dut)  # h_count = 0, valid immediately at reset
    assert dataen == 1, "pixel (0,0) is in the active region — dataen should be high"

    # Walk H_ACTIVE-1 pixels to reach h_count = H_ACTIVE-1 (still active),
    # then one more to h_count = H_ACTIVE (front porch: dataen should drop).
    await step_pixels(dut, H_ACTIVE - 1)  # now at h_count = H_ACTIVE-1, still active
    hsync, vsync, dataen, data = await step_pixels(dut, 1)  # h_count = H_ACTIVE now
    assert dataen == 0, "dataen should drop once h_count leaves the active region (front porch)"


@cocotb.test()
async def test_hsync_pulse_timing(dut):
    """HSYNC (active-low by default) must assert for exactly H_SYNC_WIDTH
    pixel periods, starting H_FRONT_PORCH periods after the active region
    ends."""
    await start_clock(dut)
    await reset(dut)

    # We're at h_count=0 right after reset (0 steps taken). h_count =
    # H_ACTIVE+H_FRONT_PORCH is the sync pulse's first pixel, so that many
    # steps reaches it exactly.
    steps_to_sync_start = H_ACTIVE + H_FRONT_PORCH
    hsync, _, _, _ = await step_pixels(dut, steps_to_sync_start)
    assert hsync == 0, "hsync should be asserted (active-low) at the start of the sync pulse"

    for _ in range(H_SYNC_WIDTH - 1):
        hsync, _, _, _ = await step_pixels(dut, 1)
        assert hsync == 0, "hsync should stay asserted through H_SYNC_WIDTH pixel periods"

    hsync, _, _, _ = await step_pixels(dut, 1)  # one period past the pulse
    assert hsync == 1, "hsync should deassert once H_SYNC_WIDTH periods have elapsed"


@cocotb.test()
async def test_pixel_content_matches_pattern(dut):
    """With a known pattern loaded, data must match expected_bit() (white
    for bit=1, black for bit=0) at several sampled (h, v) positions across
    the active region, including block boundaries."""
    await start_clock(dut)

    # Alternating pattern: bit i = i % 2, so adjacent logical pixels differ —
    # a strong check that block boundaries are computed correctly, not just
    # that "some" pattern shows up. Set before reset so the reset block's
    # pixel-(0,0) latch (see dmd_video_if.sv) picks up this pattern rather
    # than whatever pattern_in held before.
    pattern = 0
    for bit_idx in range(64):
        if bit_idx % 2 == 0:
            pattern |= (1 << (63 - bit_idx))

    await reset(dut, pattern=pattern)

    # Sample a handful of specific physical pixels by walking pixel-by-pixel
    # from (0,0) and checking whenever we land on one of interest.
    targets = {(0, 0), (1, 0), (2, 0), (BLOCK_W, 0), (BLOCK_W + 1, 0), (0, BLOCK_H), (H_ACTIVE - 1, V_ACTIVE - 1)}
    checked = set()

    h, v = 0, 0
    dataen, data = int(dut.dataen.value), int(dut.data.value)  # pixel (0,0), valid at reset
    while checked != targets:
        if (h, v) in targets:
            exp_bit = expected_bit(pattern, h, v)
            exp_data = 0xFFFFFF if exp_bit else 0x000000
            assert dataen == 1, f"pixel ({h},{v}) should be in the active region"
            assert data == exp_data, (
                f"pixel ({h},{v}): data={hex(data)} != expected {hex(exp_data)} "
                f"(bit={exp_bit})"
            )
            checked.add((h, v))
            if checked == targets:
                break

        h += 1
        if h == H_TOTAL:
            h = 0
            v += 1
        if v == V_TOTAL:
            assert False, f"ran out of frame before covering all targets; missing {targets - checked}"

        _, _, dataen, data = await step_pixels(dut, 1)
