# Ghost Imager

An FPGA-based computational ghost imaging system built on the Nexys Video Artix-7 board. Part of a broader instrumentation platform alongside [Ramsey](https://github.com/), an FPGA-based quantum defect sensor readout system for NV centers and SiC point defects.

---

## Overview

Ghost imaging reconstructs a spatial image of an object using a single-pixel (bucket) detector that has no spatial resolution. Instead of a camera, structured light patterns are projected onto the object sequentially. The integrated intensity response at the bucket detector, correlated with the known patterns, is sufficient to reconstruct the image.

This project implements **computational ghost imaging (CGI)** — the practically accessible variant where the patterns are known a priori (no entangled photons required), enabling deterministic FPGA-driven acquisition and on-chip reconstruction.

---

## Why FPGA

A PC-based CGI system works but sacrifices deterministic timing. The FPGA provides:

- **Sub-microsecond synchronization** between DMD pattern transitions and ADC sampling — no OS jitter
- **On-chip correlation accumulation** in BRAM — reconstruction is complete the moment acquisition ends
- **Pipelined acquisition** — continuous pattern-project / sample / accumulate loop at full DMD rate
- **Integration with Ramsey** — shared timing sequencer, SPI bus, and optical frontend enables future dual-modality operation (optical imaging + magnetic field sensing in the same volume)

---

## System Architecture

```
FPGA (Nexys Video Artix-7)
│
├── Pattern Sequencer FSM
│     └── Steps through Hadamard / random patterns stored in BRAM
│           └── Fires trigger to DMD, waits settling time, gates ADC sample
│
├── DMD Interface
│     └── SPI / parallel GPIO to DLP2000 LightCrafter Mini
│
├── Bucket Detector Chain
│     └── APD → TIA → comparator (or ADC) → PMOD GPIO
│
├── Correlation Accumulator
│     └── Fixed-point MAC: running sum of b_i * H_i per pixel, stored in BRAM
│
└── UART Streaming
      └── Partial sums streamed to PC for live preview during acquisition
```

---

## Hardware

| Component | Part | Notes |
|---|---|---|
| FPGA board | Digilent Nexys Video Artix-7 | Shared with Ramsey |
| DMD | TI DLP2000 LightCrafter Mini | ~$30–80, SPI + parallel interface |
| Light source | 532 nm DPSS laser module (TTL mod) | Shared with Ramsey optical frontend |
| Detector | APD + TIA + comparator breakout | PMOD connection, 3.3V logic output |
| ADC | On-board or external via PMOD | Integration mode for CGI bucket signal |

The detector frontend is designed to serve both CGI (linear integration mode) and Ramsey (photon counting mode) from the same hardware.

---

## Reconstruction

**Phase 1 — correlation sum (simple, always works):**

$$\hat{I} = \sum_{i=1}^{N} b_i H_i$$

Where $b_i$ is the bucket intensity for pattern $i$ and $H_i$ is the known pattern matrix.

**Phase 2 — Hadamard basis:**

Random patterns require O(N) measurements for N pixels. Hadamard patterns with differential measurement reduce noise and can reconstruct from fewer measurements.

**Phase 3 — compressed sensing (OMP):**

With structured sparsity assumptions, reconstruct from M << N measurements. Reconstruction runs on PC (Python / numpy) initially; candidate for partial FPGA acceleration later.

---

## Build Roadmap

- [ ] **Phase 1** — DMD controller: project a known static pattern, verify over SPI
- [ ] **Phase 2** — ADC readout: verify bucket detector samples synchronously
- [ ] **Phase 3** — Pattern + sample synchronizer: core timing loop FSM
- [ ] **Phase 4** — BRAM accumulator: on-chip correlation sum
- [ ] **Phase 5** — UART streaming: live partial reconstruction preview on PC
- [ ] **Phase 6** — Hadamard basis + differential ghost imaging
- [ ] **Phase 7** — Compressed sensing reconstruction (PC-side, Python)
- [ ] **Phase 8** — Scaling toward thermal GI and eventual quantum GI

---

## Relation to Ramsey

Ghost Imager and Ramsey share:

- **FPGA board** — Nexys Video Artix-7
- **Optical frontend** — same APD, TIA, and 532 nm laser
- **SPI bus conventions** — ADF4351 (Ramsey MW source), APD bias controller, DMD all on compatible SPI masters
- **Timing sequencer pattern** — pulse gating FSM structure is directly analogous
- **Shared RTL primitives** — SPI master, UART controller, ADC interface live in [`fpga-instruments-lib`](https://github.com/)

The long-term integration goal is a dual-modality sensor: ghost imaging for optical scene reconstruction through scattering media, combined with NV magnetometry for simultaneous magnetic field mapping of the same volume. Target application: underwater sensing.

---

## Repository Structure

```
ghost-imager/
├── rtl/
│   ├── top.sv
│   ├── pattern_sequencer.sv
│   ├── dmd_controller.sv
│   ├── correlator.sv
│   └── uart_streamer.sv
├── constraints/
│   └── nexys_video.xdc
├── sim/
│   └── tb_pattern_sequencer.py       # cocotb
├── sw/
│   └── reconstruct.py                # PC-side reconstruction + preview
├── docs/
│   └── architecture.md
└── README.md
```

---

## Related Projects

- **[Ramsey](https://github.com/)** — FPGA-based quantum defect sensor readout (NV centers, SiC point defects)
- **[fpga-instruments-lib](https://github.com/)** — Shared RTL primitives (SPI, UART, TDC, ADC interface)

---

## References

- Shapiro, J. H. (2008). Computational ghost imaging. *Physical Review A*, 78(6).
- Bromberg, Y. et al. (2009). Ghost imaging with a single detector. *Physical Review A*, 79(5).
- Duarte, M. F. et al. (2008). Single-pixel imaging via compressive sampling. *IEEE Signal Processing Magazine*.
- Degen, C. L. et al. (2017). Quantum sensing. *Reviews of Modern Physics*, 89(3).
