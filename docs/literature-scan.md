# Literature Scan — CGI + Biomedical / Tissue

Scan performed 2026-06-28. Cross-referenced against [`CGI_PLATFORM.md`](CGI_PLATFORM.md).
User-supplied paper triage added 2026-06-30 (see "Scan 2" below).
Build-path scan added 2026-06-30 (see "Scan 3" below).

---

## Already in docs

These are cited in `CGI_PLATFORM.md` and covered:

- **Yu et al., J. Biophotonics (2025)** — non-contact heart rate via ghost imaging. MAE 4.24 bpm. Preprint arXiv:2406.02640. Works in low-light / non-line-of-sight. **No depth selectivity, no tissue penetration, visible wavelengths.**
- **Hussein & Moazeni, JBO (2025)** — multi-spectral LSCI for depth-resolved perfusion. Multi-wavelength + depth: yes. Single-pixel: no — requires a camera array. CGI: no.
- **Carp et al., Neurophotonics (2023)** — DCS limitations for deep tissue sensing.
- **Tajahuerce et al., Optics Express (2014) / arXiv:1411.2731** — single-pixel structured illumination through 6 mm chicken breast. Visible wavelengths. Compressive sensing. No coherent source required. **First proof of single-pixel imaging through biological tissue.**

---

## New finds

### 1. FPGA-based real-time single-pixel imaging
**Gibson et al., Scientific Reports (2022).** "Real-time single-pixel imaging using a system on a chip field-programmable gate array." PMC9388629.

- SoC-FPGA (Xilinx Zynq) running correlation-based reconstruction, 40 fps at 128×128.
- Notes that ghost imaging correlation is "suitable for FPGA because of low memory usage and simplicity of calculation."
- 10× speedup over CPU reconstruction.
- **Relevance:** Validates our architecture. No medical application — pure imaging. Gap: no NIR, no tissue, no physiological signal.

### 2. Multi-wavelength ghost imaging — comprehensive review
**Spielmann et al., Vicinagearth / Springer Nature (2025, Dec).** "Multi-wavelength ghost imaging: a review." doi:10.1007/s44336-025-00013-0.

- Reviews all multi-wavelength CGI implementations: spectroscopic, LiDAR, terahertz, UV.
- NIR implementations described for airborne remote sensing (3D LiDAR with sparsity solver).
- **No biomedical / tissue application reviewed.** This confirms the gap is real — the multi-wavelength CGI literature is entirely in remote sensing and spectroscopy, not tissue imaging.

### 3. Single-pixel through turbid media (confirmed Tajahuerce detail)
**arXiv:1411.2731 (Tajahuerce group, 2014).** Already in docs but key detail now confirmed:

- Uses *incoherent* structured illumination (not laser speckle). DMD + white light LED works.
- Experimentally retrieved image of target through 6 mm chicken breast at **visible** wavelengths.
- Compressive sensing reduces required measurements.
- **What this project adds vs. this paper:** NIR wavelengths (deeper penetration), multi-wavelength (depth discrimination), FPGA-real-time (vs. offline PC), pulsatile signal extraction.

### 4. Bio-inspired ghost imaging through scattering (remote sensing)
**PMC12839350 (2026).** Self-attention model for scattering-robust ghost imaging.

- 24.5–25.5 dB PSNR under high scattering. Inference <0.12 s.
- Remote sensing context. **Not biomedical.** Shows deep learning can help but irrelevant to FPGA path.

### 5. MS-LSCI (confirmed Hussein & Moazeni class of work)
**PMC11853228 (2025).** "Multi-spectral laser speckle contrast imaging for depth-resolved blood perfusion."

- Multiple laser wavelengths + speckle analysis → blood perfusion at multiple depths.
- Requires widefield camera, not single-pixel detector.
- **The closest multi-wavelength + depth + perfusion work, but fundamentally camera-based.** This is the direct competitor architecture.

---

## Gap analysis

The literature falls into four quadrants:

| | Single-pixel / CGI | Camera-based |
|---|---|---|
| **Visible, static target** | Tajahuerce 2014 (through tissue) | Lots of work |
| **Visible, physiological** | Yu 2025 (heart rate, surface only) | rPPG (iPhones etc.) |
| **NIR, depth-resolved** | **Nobody** | Hussein/MS-LSCI (depth perfusion) |
| **NIR, physiological** | **Nobody** | NIRS, pulse oximeters |

**The empty cell** — NIR + single-pixel + depth-resolved + physiological signal — is what this project occupies.

The specific combination that appears unoccupied in the literature:
1. Computational ghost imaging (DMD + single-pixel bucket)
2. NIR wavelengths (750 + 850 nm, tissue window)
3. Multi-wavelength differential → depth discrimination via Beer-Lambert
4. Pulsatile / hemodynamic signal extraction
5. FPGA-real-time acquisition and on-chip correlation

No paper reviewed combines all five. The closest partial overlaps:
- Yu 2025: (1) + (4), missing (2)(3)(5)
- Tajahuerce 2014: (1), missing (2)(3)(4)(5)
- Hussein MS-LSCI 2025: (3) + (4), missing (1)(2)(5) — different modality entirely

---

## Recommended references to add to README / CGI_PLATFORM.md

```
Gibson, G. M. et al. (2022). Real-time single-pixel imaging using a system on a chip
  field-programmable gate array. Scientific Reports, 12, 13519.
  doi:10.1038/s41598-022-18187-8

Spielmann, C. et al. (2025). Multi-wavelength ghost imaging: a review.
  Vicinagearth, 2(1), 4. doi:10.1007/s44336-025-00013-0

Tajahuerce, E. et al. (2014). Imaging at depth in tissue with a single-pixel camera.
  arXiv:1411.2731. [Expanded from Optics Express citation already in docs]

Shimobaba, T. et al. (2017). Computational ghost imaging using deep learning.
  arXiv:1710.08343. [Phase-7 few-measurement / denoising benchmark]

Li, Y.-G. et al. (2025). Optical diffraction neural networks assisted computational
  ghost imaging through dynamic scattering media. arXiv:2511.22913.
  [Through-scatter SOTA; 30% sampling, 1-2 mfp limit]

[B1] Anti-scattering medium computational ghost imaging with modified Hadamard
  patterns (2023). arXiv:2304.07495. [DMD + Hadamard + through-scatter — closest
  match to this build]

Sun, M.-J. et al. (2017). A Russian Dolls ordering of the Hadamard basis for
  compressive single-pixel imaging. Scientific Reports, 7, 3464. [Phase-6 ordering]

Yu, W.-K. (2019). Super sub-Nyquist single-pixel imaging by means of cake-cutting
  Hadamard basis sort. arXiv:1903.11175. [Phase-6 ordering; <0.2% sampling]

Lopez-Garcia, L. et al. (2020). Super sub-Nyquist single-pixel imaging by total
  variation ascending ordering of the Hadamard basis. Scientific Reports, 10, 9338.
  [Phase-6 ordering — cheapest to compute; implement first]

Computational ghost imaging using a field-programmable gate array (2018).
  arXiv:1810.05670. [Direct FPGA-CGI prior art for this project]

Robust 3D reconstruction in turbid water at low sampling rates via dual-DMD
  single-pixel system (2024). Photonics, 13, 446. doi:10.3390/photonics13050446.
  [Underwater / through-scatter branch]
```

---

## Scan 2 — user-supplied paper triage (2026-06-30)

Six papers handed in for assessment, ranked by usefulness to *this* project
(FPGA CGI, DMD, single-pixel photodiode, through-scatter ambition, Hadamard/CS
roadmap). Tier = how directly it informs the current build.

### Tier 1 — read these

**S1. Shimobaba et al. (2017), "Computational ghost imaging using deep learning."** arXiv:1710.08343.
- Trains a neural net to denoise CGI reconstructions: noisy/few-measurement input -> low-noise image.
- **Relevance:** Directly maps to the Phase-7 "fewer measurements" goal (DL alternative to OMP/compressed sensing). Sets the benchmark for "how few measurements can I get away with," which is the whole game once every measurement is expensive (through tissue/fog). Foundational, heavily cited.

**S2. Li et al. (2025), "Optical diffraction neural networks assisted CGI through dynamic scattering media."** arXiv:2511.22913.
- DMD + single-pixel + 780 nm (NIR) imaging through *rotating* diffusers (dynamic scatter, harder than a static diffuser). Reconstruction via differential GI + physics-informed untrained net.
- **Transferable numbers:** satisfactory reconstruction at **30% sampling**; degradation sets in beyond **1-2 transport mean free paths** of multi-layer scatter.
- **Relevance:** This is the through-scatter killer-app at current SOTA, on our exact hardware class and our Phase-2 wavelength. Take the architecture, wavelength, and the scatter-depth limit numbers as targets. The optical-neural-network front end (two phase SLMs) is exotic and NOT replicable here — ignore that part.

### Tier 2 — bookmark, not now

**S6. *Optics & Lasers in Engineering* (2025), PII S0143816625006128.** Paywalled.
- **Could not confirm title or contents** (403 / not surfaced in search). Strong applied-optics venue, plausibly relevant. **Do not rely on until the title or an open PDF is available** — flagged honestly as unassessed.

**S4. Vellekoop-style "Non-diffractive computational ghost imaging" (2016).** Optics Express 24(13), 14172.
- Bessel-beam "non-diffracting" speckle extends depth-of-field 2-3x, sharpens lateral resolution ~1.5x.
- **Relevance:** Limited. It is a **phase-SLM** technique; our binary-amplitude **DMD cannot generate these patterns**. Revisit only if depth-of-field at unknown object distance becomes a real problem.

### Tier 3 — tangential to the current optical-CGI-on-FPGA build

**S3. "Photoacoustic computational ghost imaging" (2022).** Optics Letters 47(6), 1462.
- Hadamard CGI with **single-detector ultrasound** (not optical); beats raster scanning for contrast under limited radiant exposure.
- **Relevance:** Only to the tier-5 photoacoustic extension in [`medical-extensions.md`](medical-extensions.md). Conceptual reference, not a build guide for the optical instrument.

**S5. "Computational Ghost Imaging with the Human Brain" (2023).** Intelligent Computing, doi:10.34133/icomputing.0014.
- Uses a **human observer's brain** as the feedback element in the imaging loop. Not FPGA, not single-pixel hardware.
- **Relevance:** None to the instrument. Skip. (Note: the *journal* iComputing has genuinely relevant on-chip single-pixel work — see B2 below — just not this DOI.)

### Bonus finds surfaced during the scan (not in the user's list, more on-target)

**B1. "Anti-scattering medium CGI with modified Hadamard patterns."** arXiv:2304.07495.
- DMD + Hadamard + through-scatter — squarely our hardware and our goal. Strongest single match to the build. **Read alongside S2.**

**B2. "Instant single-pixel imaging: on-chip real-time implementation based on the instant ghost imaging algorithm."** arXiv:2002.00126 / ResearchGate 339628996.
- On-chip / real-time single-pixel reconstruction — directly relevant to the FPGA on-chip-correlation goal. Companion to Gibson 2022 (Scan 1, #1).

### Takeaway

Almost every modern CGI paper is now about **reducing the number of measurements**
(deep learning, compressed sensing, smart Hadamard ordering), because the
bottleneck is no longer building the rig — it is that N patterns = N measurements
is slow and degrades through scatter. This validates the Phase-6/7 roadmap
(Hadamard + compressed sensing): the project is aimed at the field's actual
open problem. **Action: pull S6's title/PDF for proper assessment; read S1, S2, B1.**

---

## Scan 3 — build-path scan (2026-06-30)

Searched the gaps the first two scans left: Hadamard pattern *ordering* (Phase-6),
through-fog/turbid-water (the underwater goal + through-scatter), more FPGA-CGI
prior art, differential-Hadamard SNR theory (Phase-6), and practical DMD/DLP
build notes. Grouped by the roadmap phase each one informs.

### Phase-6 — Hadamard basis + pattern ordering (fewer measurements)

These solve the "N patterns = N measurements is slow" problem by choosing *which*
Hadamard patterns to send first, so a partial scan already gives a usable image.
Directly actionable in `sw/` (the ordering is a reconstruction-side change, no RTL impact).

- **Sun et al. (2017), "A Russian Dolls ordering of the Hadamard basis for compressive single-pixel imaging."** Sci. Rep. 7, 3464. Orders the basis so each prefix is a complete lower-resolution scan. The original "smart ordering" paper.
- **Yu (2019), "Super sub-Nyquist single-pixel imaging by means of cake-cutting Hadamard basis sort."** arXiv:1903.11175. Reconstructs up to 1024x1024 at **sampling ratios below 0.2%**. Strongest ordering result.
- **"Super sub-Nyquist SPI by total-variation ascending ordering of the Hadamard basis" (2020).** Sci. Rep. 10, 9338. Cheaper to compute than Russian-doll / cake-cutting (matters for large frames). **Recommended default ordering to implement first** — best simplicity/performance trade.
- **"Hadamard single-pixel imaging based on positive patterns" (2023).** Photonics 10(4), 395. How to handle that a DMD can only project **non-negative** (0/1) patterns, not +-1 — exactly our binary-amplitude DMD constraint.

### Phase-6 — differential Hadamard (SNR + DMD binary mode)

- **Differential-measurement Hadamard SPI (general result).** Complementary positive/negative patterns: averages out i.i.d. noise (SNR up), and one can reconstruct from positive patterns only (measurements down ~1/2). This is the theory behind the "differential Hadamard" already in the Phase-2 plan and `architecture.md` Section 6. Confirms the single-DMD sign-bit approach is the standard, correct choice.

### Phase-5/8 — more FPGA / on-chip CGI prior art (beyond Gibson 2022)

- **"Computational ghost imaging using a field-programmable gate array" (2018).** arXiv:1810.05670. **Direct prior art for this entire project** — CGI reconstruction on an FPGA. Not in earlier scans. **Read it.**
- **"Instant single-pixel imaging: on-chip real-time implementation" (2020).** arXiv:2002.00126. On-chip "instant ghost imaging" algorithm; low-memory correlation form suited to FPGA. (Also flagged as B2 in Scan 2.)
- **WiMi SoC-FPGA real-time single-pixel (2023, industry).** Confirms the SoC-FPGA + ghost-imaging-correlation approach at 40 fps / 128x128, 10x over CPU — same architecture class as `top.sv` + `correlator.sv`. Validates the design direction; no paper to read, just a data point.

### Underwater / through-scatter (the README long-term goal)

- **"Robust 3D reconstruction in turbid water at low sampling rates via dual-DMD single-pixel system" (2024).** Photonics 13, 446. doi:10.3390/photonics13050446. Turbid-water single-pixel 3D at low sampling — squarely the underwater branch.
- **"Computational framework for turbid-water single-pixel imaging by polynomial regression and feature enhancement" (2023).** IEEE Xplore 10190155. Reconstruction-side turbidity correction.
- **Underwater CGI at up to ~9.3 attenuation lengths (2023); CGI through fog demonstrated (2025).** Concrete evidence the same instrument images through fog *and* water — the "one technique, three scattering media (fog / water / tissue)" thesis. Several use deep-learning reconstruction (U-Net/attention) at low sampling — a `sw/`-side option, not RTL.

### Practical DMD/DLP build notes

- **Multiple CGI builds disassemble a TI LightCrafter (4500 / 2000) to bench-mount the bare DMD** and drive it directly — the same access pattern we need with the DLPDLCR2000EVM. Confirms the "drive the DMD from the FPGA over the parallel/expansion header" approach is standard practice, not a hack.
- Typical detector in these builds: **SPAD** (photon-counting, low light) or **photodiode** (our FDS100 path). Reflection *and* transmission geometries both appear — consistent with our reflectance-geometry product concept.

### Takeaway

Two papers are direct prior art the earlier scans missed: **arXiv:1810.05670 (FPGA CGI)**
and the **Hadamard-ordering trio** (Russian-doll / cake-cutting / TV-ordering). The
ordering work is the highest-value near-term read — it is a pure `sw/`-side change
that can cut measurements by 10-100x with no hardware change, directly serving
Phase-6/7. **Action: read 1810.05670 and the TV-ordering paper; implement TV or
cake-cutting ordering in `sw/reconstruct.py` when Phase-6 starts.**

---

## Search terms used

- "computational ghost imaging biological tissue scattering medical sensing"
- "single pixel imaging tissue perfusion pulsatile blood vessel PPG"
- "ghost imaging heart rate photoplethysmography single pixel detector"
- "multi-wavelength ghost imaging depth discrimination NIR tissue"
- "structured illumination single pixel camera biomedical scattering depth-resolved"
- "ghost imaging scattering tissue depth NIR 750nm 850nm perfusion"
- "FPGA single pixel camera real-time ghost imaging biomedical"
