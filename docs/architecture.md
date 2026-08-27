# Ghost Imager — Architecture

Design spec for the FPGA computational ghost imaging (CGI) build on the Nexys Video Artix-7. Written for self-reference; assumes fluency with FPGA design and CGI fundamentals. Phase numbers match the roadmap in [`README.md`](../README.md).

---

## 1. Scope & non-goals

**In scope.** Module boundaries, signal-level interfaces, clock domains, FSM behavior, BRAM layout, fixed-point widths, UART framing, CSR map, simulation strategy, and the shared-interface surface with [Ramsey](https://github.com/).

**Non-goals (deferred).** Final compressed-sensing algorithm (Phase 7), optical/mechanical layout, dual-modality scheduling between Ghost Imager and Ramsey, on-chip floating-point reconstruction, AXI/MIG integration.

### Language & style

**SystemVerilog** (IEEE 1800-2012 subset supported by Vivado). VHDL was considered for its stricter type system but rejected: cocotb is the verification strategy (§11), so SV's looseness is caught in Python tests rather than at compile, and the open-source SV tooling (Verilator, Icarus, yosys) is more mature than the VHDL equivalents for a solo project. If this codebase ever needs to ship into a regulated environment (defense, aerospace, submarine deployment), a rewrite is the smallest line item in that effort.

To recover VHDL-like safety, the following rules are enforced on every file:

- `` `default_nettype none `` at the top of every module — implicit nets become compile errors.
- `always_ff` and `always_comb` only; never bare `always`.
- `logic` only; never `reg` or `wire`.
- Enums for all FSM states; packed structs for register maps and bus payloads.
- `verilator --lint-only -Wall` runs on every commit (pre-commit hook), even though Verilator is not the primary simulator.
- Every module has a cocotb testbench before it is integrated into `top.sv`.

---

## 2. Top-level block diagram

```
                            clk_sys (100 MHz, on-board OSC)
                            clk_dmd (~33 MHz, MMCM-derived)
                            srst_sys, srst_dmd (sync resets per domain)

  ┌──────────────┐  start/done   ┌──────────────────────┐
  │  UART CSR    │◀─────────────▶│  Pattern Sequencer   │
  │  (host iface)│  csr_rw_bus   │  FSM   (clk_sys)     │
  └─────┬────────┘               └─┬─────────┬─────────┬┘
        │                          │         │         │
        │ dump_req                 │ pat_req │ smp_req │ acc_we
        ▼                          ▼         ▼         ▼
  ┌──────────────┐           ┌──────────┐ ┌────────┐ ┌──────────────┐
  │ UART         │◀── b_i,   │ Pattern  │ │ Bucket │ │ Correlation  │
  │ Streamer     │   H_i[p]  │ BRAM     │ │ Detect │ │ Accumulator  │
  │ (clk_sys)    │           │ (ROM/RAM)│ │ Chain  │ │ (BRAM, MAC)  │
  └─────┬────────┘           └────┬─────┘ └───┬────┘ └─────┬────────┘
        │ tx                      │ pat_bits  │ b_i        │ acc_rd
        ▼                         ▼           │            │
     RS232                  ┌──────────────┐  │            │
                            │ DMD Ctrl     │◀─┘            │
                            │ (clk_dmd)    │               │
                            └──────┬───────┘               │
                                   │ RGB+VSYNC             │
                                   ▼                       ▼
                            DLP2000 LightCrafter      → (read by UART Streamer)

  CDC crossings (2-FF synchronizers via cdc_sync from fpga-instruments-lib):
    clk_sys → clk_dmd : pat_req, pat_bits (held stable by handshake)
    clk_dmd → clk_sys : dmd_done
```

Single MMCM produces `clk_dmd` from `clk_sys`. Everything except the DMD parallel-output stage lives in `clk_sys`.

---

## 3. Pattern Sequencer FSM

Drives the per-pattern acquisition loop. Runs in `clk_sys`.

```
                ┌──────┐ start
                │ IDLE │────────────┐
                └──────┘            ▼
                              ┌─────────────┐
              done◀───────────│ LOAD_PATTERN│  (read pattern row from BRAM)
                              └──────┬──────┘
                                     ▼
                              ┌─────────────┐
                              │ ASSERT_DMD  │  (pat_req → DMD ctrl, wait dmd_ack)
                              └──────┬──────┘
                                     ▼
                              ┌─────────────┐
                              │ SETTLE_WAIT │  (countdown T_SETTLE_CYC)
                              └──────┬──────┘
                                     ▼
                              ┌─────────────┐
                              │   SAMPLE    │  (gate bucket detector T_SAMPLE_CYC)
                              └──────┬──────┘
                                     ▼
                              ┌─────────────┐
                              │ ACCUMULATE  │  (stream pat bits + b_i to correlator)
                              └──────┬──────┘
                                     ▼
                              ┌─────────────┐  idx==N_PATTERNS-1: → IDLE (done)
                              │    NEXT     │  else: idx++, → LOAD_PATTERN
                              └─────────────┘
```

**Parameters** (compile-time generics, all overridable via CSR at runtime):
- `N_PATTERNS` — default 4096 (matches 64×64 image).
- `T_SETTLE_CYC` — default 1000 cycles (10 µs @ 100 MHz).
- `T_SAMPLE_CYC` — default 20000 cycles (200 µs @ 100 MHz).

**Pattern source.** Pattern BRAM: 4096 entries × 4096-bit rows is too wide for one BRAM; instead store row-streamed as 4096 × 64-bit and burst 64 reads per pattern (64 cycles, negligible vs. sample window). For Phase 1 we use a single 256-bit-wide row for 16×16 patterns and revisit when scaling.

**Handshakes.** `pat_req`/`dmd_ack` to DMD controller; `smp_req`/`smp_valid` from bucket chain; `acc_we`/`acc_done` to correlator.

---

## 4. DMD Controller (DLP2000)

Drives the TI DLP2000 LightCrafter Mini.

**Interface choice.** DLP2000 supports parallel RGB+VSYNC+HSYNC video input and an I²C/SPI config channel. We use:
- **Parallel video** for pattern data (24-bit RGB pins, but we only drive R[0] in binary mode → 1 bpp). Carries pattern frames at `clk_dmd`.
- **SPI** at boot only, to initialize DLP2000 registers (binary mode, internal pattern timing off, external trigger optional). Reuses `spi_master` from `fpga-instruments-lib`.

**Native resolution** 640×360. First cut: 64×64 logical patterns scaled 10× (filling 640×360 with a 64×64 grid → 10×5 pixel tiles, central region only; corners unused). Scale factor parameterized.

**Frame format.** One DLP2000 frame per `pat_req`. The controller reads the packed pattern row from BRAM and shifts it out across the parallel bus respecting VSYNC/HSYNC timing pulled from the DLP2000 datasheet. `dmd_ack` rises when the frame has been latched.

**Pin map.** Defined in `constraints/nexys_video.xdc`. PMOD assignment TBD — reserve PMOD JA (top row) for DMD parallel + control; see §12.

---

## 5. Bucket Detector Chain

Two physical paths, both routed to a PMOD. Mode selected at runtime via `MODE` CSR.

**Mode A — comparator → GPIO (photon-counting-like).**
APD → TIA → fast comparator → PMOD single-ended 3.3 V LVCMOS. Inside the FPGA: a gated counter ticks each rising edge (or each high cycle, configurable) during the `SAMPLE` state. Counter width 16 bits. Output `b_i` is the count at `smp_valid`.

**Mode B — ADC (linear integration).**
APD → TIA → ADC (Pmod AD1 or ADS7950 on Pmod). `adc_iface_pmod` from `fpga-instruments-lib` samples at its native rate (e.g. 1 MS/s) into a 16-bit accumulator gated by the `SAMPLE` window. Output `b_i` is the sum, clipped to 16 bits.

Both modes present the same 16-bit unsigned `b_i` / `smp_valid` interface to the correlator.

---

## 6. Correlation Accumulator

Per-pixel running sum:
```
  acc[p] += b_i  if  H_i[p] == 1
  acc[p] += 0    if  H_i[p] == 0     (binary patterns → conditional add, no multiplier)
```
For ±1 Hadamard differential mode, store the basis bit and conditionally add or subtract; sign extends the 16-bit `b_i` into the 32-bit signed accumulator.

**BRAM layout.** One true-dual-port BRAM, 36 Kb, configured 4096 × 32-bit signed for a 64×64 image (16384 B exactly — fits in a single 36K block on Artix-7).
- Port A: write port (FSM-driven), address = pixel index.
- Port B: read port exposed to UART streamer for partial-sum snapshots while acquisition is still running.

**Fixed-point widths.**
- `b_i` : 16-bit unsigned.
- `acc` : 32-bit signed. Headroom: 2^31 / (2^16 · 4096) ≈ 8, so ~8× safety margin at full N=4096. If `N_PATTERNS` grows past ~16k or `b_i` saturates often, widen to 40-bit.
- **Overflow.** One sticky `overflow` bit in `STATUS` raised if any per-pixel add wraps. Implemented as `(prev_msb == add_msb) && (prev_msb != sum_msb)` check.

**Throughput.** One add per pattern per pixel is naive (4096 cycles per pattern). Instead, process pattern as 64-bit words: 64 pixels per cycle using parallel conditional adders into 64 BRAM banks. For Phase-1 simplicity we accept the naive single-port version; bank-parallel is a Phase-4 optimization.

---

## 7. UART Streamer

**Line settings.** 8N1. 115200 baud for Phase-1 bring-up, parameterized baud-rate generator so we can move to 921600 once stable. Reuses `uart_tx`/`uart_rx` from `fpga-instruments-lib`.

**Frame format.** (As implemented in [`rtl/uart/uart_interface.sv`](../rtl/uart/uart_interface.sv).)
```
  ┌──────┬──────┬──────────┬─────────────┬──────────┐
  │ SOF  │ TYPE │ LEN (BE) │   PAYLOAD   │  CRC8    │
  │ 0xAA │  1B  │   2 B    │   LEN bytes │   1 B    │
  └──────┴──────┴──────────┴─────────────┴──────────┘
```
LEN is big-endian (high byte first). CRC is an 8-bit XOR over the PAYLOAD bytes
only (not TYPE/LEN). The original CRC-16/CCITT plan was dropped in favour of the
simpler XOR-8 the interface now implements; revisit if link errors warrant it.

**TYPEs.**
| TYPE | Direction | Payload |
|---|---|---|
| `0x01` | FPGA→PC | Partial-sum dump: `n_pixels` × int32, big-endian (MSB first), one packet. Emitted by `uart_streamer`. |
| `0x02` | FPGA→PC | Status: `{busy:1, done:1, overflow:1, mode:1, idx:16}` packed into 4 B |
| `0x03` | FPGA→PC | Ack for a CSR write |
| `0x10` | PC→FPGA | CSR write: `addr:8, value:32` |
| `0x11` | PC→FPGA | CSR read request: `addr:8` |
| `0x12` | PC→FPGA | Dump request |

The PC-side parser lives in [`sw/reconstruct.py`](../sw/reconstruct.py); same framing must be mirrored there.

**Streaming policy.** On-demand snapshot on `0x12` from PC, plus optional periodic auto-dump every `K` patterns (`K` lives in a CSR; 0 disables).

---

## 8. CSR / control register map

Memory-mapped over UART (TYPE `0x10`/`0x11`). 8-bit address space, 32-bit registers. No AXI; keep it lean. AXI-Lite wrapper may be added later if/when we want to drop in as Vivado IP — listed in §13.

| Addr | Name | RW | Bits | Notes |
|---|---|---|---|---|
| `0x00` | `CTRL` | RW | `[0]=start, [1]=stop, [2]=soft_reset` | Start auto-clears |
| `0x01` | `STATUS` | RO | `[0]=busy, [1]=done, [2]=overflow, [3]=mode, [31:16]=idx` | |
| `0x02` | `N_PATTERNS` | RW | u16 | Overrides generic default |
| `0x03` | `T_SETTLE` | RW | u16, in `clk_sys` cycles | |
| `0x04` | `T_SAMPLE` | RW | u16, in `clk_sys` cycles | |
| `0x05` | `MODE` | RW | `[0]=0:comparator, 1:ADC; [1]=hadamard_diff_en` | |
| `0x06` | `DUMP_PERIOD` | RW | u16, 0 = off | Auto-dump every K patterns |
| `0x07` | `SCRATCH` | RW | u32 | Connectivity sanity check |

---

## 9. Timing budget

Per-pattern, target 4 kHz pattern rate (DLP2000 binary-mode limit, datasheet ~4 kHz refresh for 1-bpp):
- `LOAD_PATTERN` (64 BRAM reads): ~640 ns.
- `ASSERT_DMD` + DMD frame latch: ~10 µs (dominated by DMD micromirror flip + parallel frame time).
- `SETTLE_WAIT`: 10 µs (configurable; tune empirically).
- `SAMPLE`: 200 µs (gives the bucket detector a long integration window — biggest knob for SNR).
- `ACCUMULATE` (naive 4096 cycles @ 100 MHz): ~41 µs.

Sum ≈ 262 µs/pattern → ~3.8 kHz. End-to-end for `N_PATTERNS=4096`: ~1.1 s. Acceptable for Phase 1–5; bank-parallel accumulator (§6) drops `ACCUMULATE` to ~640 ns and unblocks scaling.

---

## 10. Clocking & reset

- **MMCM**: `clk_sys` (100 MHz, from `sysclk` on Nexys Video) → `clk_dmd` (~33 MHz, integer divide). Output buffers via `BUFG`.
- **Reset**: external button → debounce → async-assert/sync-deassert reset generator per domain (`srst_sys`, `srst_dmd`).
- **CDC**: only two crossings, both single-bit handshake-style:
  - `pat_req` (`clk_sys` → `clk_dmd`): held until `dmd_ack`. 2-FF synchronizer on each side via `cdc_sync`.
  - `dmd_ack` (`clk_dmd` → `clk_sys`): same.
  - Multi-bit `pat_bits` is safe because it is held stable for the lifetime of the handshake; no synchronizer needed beyond the request edge.

---

## 11. Simulation strategy

cocotb at `sim/`, one TB per module plus a top-level integration TB.

| TB | DUT | What it asserts |
|---|---|---|
| `tb_pattern_sequencer.py` | `pattern_sequencer.sv` | FSM walks all states in order for `N_PATTERNS` iterations; timing knobs honored within ±1 cycle |
| `tb_dmd_controller.py` | `dmd_controller.sv` | RGB+VSYNC waveform matches DLP2000 timing constraints; `dmd_ack` asserts after exactly one frame |
| `tb_correlator.py` | `correlator.sv` | Compares accumulator BRAM against a numpy reference for a known (b, H) pair; overflow flag fires correctly |
| `tb_uart_streamer.py` | `uart_streamer.sv` | Round-trip a CSR write+ack and a partial-sum dump; CRC verified |
| `tb_top.py` | `top.sv` | End-to-end: synthetic bucket samples for a known Hadamard set → dumped image matches `sw/reconstruct.py` reference within fixed-point error bound |

Reference numpy model lives in `sw/reconstruct.py` so the same code path validates both simulation and live PC reconstruction.

---

## 12. Ramsey integration surface

Documented now so neither project has to refactor when they meet on the same board.

### Shared RTL primitives (from `fpga-instruments-lib`)

| Primitive | Used by GI | Used by Ramsey | Notes |
|---|---|---|---|
| `spi_master` | DMD init, APD-bias DAC | ADF4351, APD-bias DAC | Generic, parameterized CPOL/CPHA/word width |
| `uart_tx`, `uart_rx` | Host iface | Host iface | Parameterized baud |
| `adc_iface_pmod` | Bucket Mode B | Photon-count integration | Same Pmod ADC |
| `cdc_sync` | All CDC | All CDC | 2-FF, parameterized width |
| `bram_dp` | Pattern BRAM, accumulator BRAM | Sequencer opcode BRAM, histogram BRAM | True dual-port wrapper around Xilinx primitive |

### Shared SPI bus convention

Single `spi_master` core arbitrated by a round-robin scheduler; one CS per slave. All slaves MSB-first.

| Slave | CS owner | CPOL | CPHA | Max SCK | Notes |
|---|---|---|---|---|---|
| DLP2000 config | GI | 0 | 0 | 10 MHz | Boot-time init only |
| APD-bias DAC | shared | 0 | 0 | 10 MHz | Either project may set bias; arbitration via mutex CSR |
| ADF4351 | Ramsey | 0 | 0 | 20 MHz | Ramsey owns |

### Shared timing sequencer pattern

Both projects use the same FSM template: an opcode list in BRAM (`{opcode:4, duration:20, target_mask:8}`) feeding a sequencer that emits gated pulse trains. Ghost Imager uses opcodes `LOAD/ASSERT/WAIT/SAMPLE/ACC/NEXT`; Ramsey uses MW/laser/readout opcodes. The mechanical FSM is identical; only the opcode decoder differs. Detail will live in the Ramsey architecture doc once it exists; cross-link from there.

### PMOD allocation (Nexys Video)

| PMOD | Owner | Use |
|---|---|---|
| JA | GI | DMD parallel + VSYNC/HSYNC + control |
| JB | GI | Bucket detector (comparator) + ADC (Mode B) |
| JC | Ramsey | ADF4351 SPI + MW gate |
| XADC header | shared | Temperature monitoring |
| FMC | reserved | Future high-speed ADC if we outgrow Pmod ADC |

---

## 13. Open questions / TODOs

- **ADC part choice.** Pmod AD1 (1 MS/s, 12-bit, 2-ch) is cheap and shared with Ramsey; ADS7950 (1 MS/s, 12-bit, 4-ch) gives spare channels for housekeeping. Decision deferred until APD/TIA noise is characterized.
- **Hadamard pattern source.** Pre-load via host-side script over UART, or generate on-chip via a Walsh recursion? Preloading is simpler and lets us experiment with random and Hadamard from the same FSM; on-chip generation saves BRAM at scale. Default: preload for Phase 1, revisit for Phase 6.
- **AXI-Lite wrapper.** Not needed now, but the CSR map (§8) is small enough to bridge to AXI-Lite trivially if we later want to package the core as a Vivado IP for system integration.
- **Differential bucket mode.** Reference photodiode picking off the laser before the DMD would let us normalize out laser intensity drift. Wire-in TBD on the optical bench.
- **Negative-pattern (Hadamard ±1) strategy.** Two sub-frames per measurement (positive then negative) vs. dual-DMD vs. single-DMD with sign-bit-driven add/subtract in the correlator. Default plan: single-DMD with sign bit in the correlator (already provisioned in §6).
- **Bank-parallel accumulator** (§6) — defer to post-Phase-4 optimization.
- **`uart_streamer` scaling.** Three things are correct only at the current Stage-1 scale (accumulator depth == `PATTERN_WIDTH`, 32-bit words) and must be revisited when the correlator grows to a real 64×64 / 4096-pixel accumulator:
  1. In `top.sv`, the dump `n_pixels` is hardwired to `PATTERN_WIDTH`. Once accumulator depth ≠ pattern-row width, this must come from a pixel-count parameter/CSR, not `PATTERN_WIDTH`.
  2. `uart_streamer.rd_addr` is `$clog2(PATTERN_WIDTH)` bits; if `n_pixels` ever exceeds `PATTERN_WIDTH` the address wraps silently. Widen `rd_addr` to the accumulator depth.
  3. The streamer FSM is hardcoded to 4-byte (`ACC_WIDTH=32`) words despite the "multiple of 8" comment — `byte_idx` is 2 bits and the staging logic only covers 4 bytes. Generalize or constrain the parameter if `ACC_WIDTH` changes.
- **TX arbiter robustness.** The `top.sv` arbiter (csr_handler vs. uart_streamer onto one `uart_interface` TX) is verified only against half-duplex host behavior (no CSR command issued while a dump is in flight). The `pending_csr` path is designed to handle a mid-dump CSR send but has no dedicated test. Add an arbiter test that pipelines a CSR write during a dump before relying on it.
