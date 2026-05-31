# Ghost Imager — Claude Code Context

FPGA-based computational ghost imaging (CGI) on the Nexys Video Artix-7. Solo project. See [`README.md`](README.md) for the physics, [`docs/architecture.md`](docs/architecture.md) for the design spec, [`docs/journey.md`](docs/journey.md) for the build stages, [`docs/notes.md`](docs/notes.md) for background, [`docs/shopping-list.md`](docs/shopping-list.md) for the BOM.

Sister project: **Ramsey** (FPGA NV-center magnetometry). Shared primitives belong in a future `fpga-instruments-lib`. When making a primitive (UART, BRAM, sync), assume it will be ported to Ramsey verbatim — keep names and port signatures library-friendly.

---

## Stack

- **RTL**: SystemVerilog (IEEE 1800-2012 subset Vivado accepts). No VHDL.
- **Simulator**: Icarus Verilog 12.0 via **cocotb 2.0**.
- **Synthesis**: Vivado WebPACK (Artix-7 `xc7a200tsbg484-1`).
- **Python**: 3.11 in `.venv/` at the repo root. `numpy`, `matplotlib`, `pyserial`, `cocotb`, `pytest`.
- **OS**: Windows 11 + PowerShell. Bash also available — use it for `ls`/`grep`/`find`; PowerShell for everything else.

---

## RTL style rules (enforced)

- `` `timescale 1ns/1ps `` and `` `default_nettype none `` at the top of **every** module.
- `always_ff` and `always_comb` only — never bare `always`.
- `logic` only — never `reg` or `wire` inside modules. Ports use `input wire logic ...` / `output logic ...`.
- **Synchronous reset everywhere** (Xilinx Artix-7 recommendation): `always_ff @(posedge clk) begin if (!rst_n) ... end`. No `@(posedge clk or negedge rst_n)`.
- **Active-low reset** (`rst_n`) project-wide. No mixing.
- FSM states declared as `typedef enum logic [N:0] { ... } state_t;`. No magic numbers, no `parameter` constants for state encoding.
- Multi-bit constants are always sized: `8'h00`, `16'd0`, `'0`. Never bare `0`.
- One driver per signal. Each always_ff block owns its own state and **only** its state.

---

## Module conventions

- `<thing>_tx.sv` / `<thing>_rx.sv` → low-level halves.
- `<thing>_top.sv` → thin wrapper that instantiates both halves and presents the production port signature. **Not** a synthesis top — that's `rtl/top.sv`.
- `<thing>_interface.sv` → protocol/framing layer one level above the byte/word transport (e.g. packet framer over UART byte transport).
- `<thing>_handler.sv` → state-aware module that consumes a protocol layer and dispatches to functional units (e.g. `csr_handler` consumes packets and updates a register file).
- Port naming: signals named for their **role**, not their direction. `tx_valid` / `tx_ready` for internal interfaces; `tx_start` / `tx_busy` at user-facing boundaries (matches Ramsey).
- Mirror Ramsey's port signatures where prior art exists, even at minor cost of local naming — library compatibility trumps local elegance.

---

## Testbench pattern

Every RTL module has its own cocotb test directory mirroring the rtl path:

```
rtl/<area>/<module>.sv
sim/cocotb/<area>/<module>/
  ├── <module>_tb_wrapper.sv   ← thin SV shim that instantiates the DUT + $dumpvars
  ├── runner_<module>.py       ← compile+run driver (iverilog → vvp + cocotb)
  └── test_<module>.py         ← cocotb test cases
```

- **Test first.** Every module gets cocotb tests *before* it's wired into anything else.
- **Parameter overrides in the wrapper** for sim speed — e.g. `uart_tx` defaults to `CLK_HZ=100_000_000` for synthesis but the wrapper overrides to `CLK_HZ=1_000_000` so `CYCLES_PER_BIT=8` instead of 868 (~100× faster sim). Test file constants must match the wrapper.
- **Debug probes belong in the wrapper.** Tap DUT internals via `assign dbg_xxx = dut.xxx;` and expose as wrapper outputs. Cheap to leave in place for future debugging.
- Runners follow a fixed shape — copy `runner_uart_tx.py` as the template and edit paths/module names. `REPO_ROOT = Path(__file__).resolve().parents[4]` (assuming the standard depth).

### cocotb gotchas that bite repeatedly

1. **Signal-write latency.** After `dut.sig.value = X`, the FSM does NOT see the new value at the next `RisingEdge`. Wait one extra `RisingEdge` for the write to settle into the simulation timeline. Worst when paired with a flop input — the flop samples whatever was registered *before* the write applied.
2. **One-cycle strobes.** Signals like `rx_valid`, `tx_payload_req`, `rx_msg_done` are single-cycle pulses. The consumer must already be polling/awaiting on the cycle the strobe fires — `await drive_thing(); await wait_for_strobe()` will miss the strobe (it fired during `drive_thing`). Pattern: `cocotb.start_soon(drive_thing())` + `await wait_for_strobe()` in parallel.
3. **`units=` not `unit=`** for `Clock(...)`. cocotb 2.0 deprecated the singular form but still accepts it with a warning.

---

## Where things live

```
ghost-imager/
├── rtl/
│   ├── uart/        uart_tx, uart_rx, uart_top, uart_interface
│   ├── csr/         csr_handler
│   ├── lib/         cdc_sync, bram_dp   (destined for fpga-instruments-lib)
│   └── top.sv       synthesizable top (not built yet)
├── sim/cocotb/      mirrors rtl/ structure
├── sw/              PC-side Python (reconstruct.py, etc.)
├── constraints/     nexys_video.xdc
└── docs/            architecture.md, journey.md, notes.md, shopping-list.md
```

---

## Working style

- **One module at a time.** Build module → write test → run test → fix → commit. Don't bundle.
- **Verify in sim before writing more RTL.** Bugs caught in cocotb cost minutes; bugs caught on hardware cost hours.
- **No premature abstraction.** Don't wrap two XOR gates in a `crc_handler.sv`. Don't make an SV `interface` for a UART that's used in one place. Wait until two consumers exist.
- **Architectural decisions live in [`docs/architecture.md`](docs/architecture.md).** When something pinned-down changes (CRC choice, BRAM mode, reset polarity), update the doc *and* the code in the same change.
- **Don't add features beyond what the current task needs.** A bug fix is a bug fix. A new module is a new module. No "while we're here" refactors unless asked.

---

## Tone

- Code review style: concrete and direct. Numbered bugs with line refs, suggested fixes inline.
- No emoji in code, files, or docs unless explicitly asked.
- Use markdown link syntax for file references — `[rtl/uart/uart_tx.sv](rtl/uart/uart_tx.sv)` — so the IDE makes them clickable.
- Match terseness to the question. A factual question gets a 1–3 sentence answer, not a section-headed essay. Save long explanations for when they're asked for.

---

## What this project is *not* trying to be

- Not a product. Not aiming at submarines today (long-term vision; rewrite-friendly is fine).
- Not chasing quantum ghost imaging — CGI is the practical destination. See [`docs/notes.md`](docs/notes.md).
- Not over-optimized. Solo project. Pace = whatever pace happens.
