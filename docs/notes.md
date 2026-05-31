# Notes — Ghost Imaging Background

Personal reference notes on what ghost imaging is, the variants, and how they relate. Companion to [`architecture.md`](architecture.md) (which is implementation-focused).

---

## What ghost imaging is, in one paragraph

Reconstruct a 2D image of an object using a **single-pixel detector that has no spatial resolution** (a "bucket"). Instead of a camera, you illuminate the object with a sequence of known structured light patterns and record the *total* light intensity for each pattern. Correlating the patterns with the bucket readings reconstructs the image. The trick is that the *correlation* between known patterns and measured bucket intensity carries the spatial information — no camera needed on the object arm.

Reconstruction formula (all three variants):

$$
\hat{I}(x,y) \;=\; \frac{1}{N}\sum_{i=1}^{N} \bigl(b_i - \langle b\rangle\bigr)\,P_i(x,y)
$$

Where `b_i` is the bucket reading for pattern `i` and `P_i(x,y)` is the i-th pattern. What changes between variants is **where `P_i` comes from**.

---

## The three variants

### 1. Quantum GI (QGI) — the original, 1995

- **Light source**: SPDC (spontaneous parametric down-conversion) — pump laser through a nonlinear crystal (BBO etc.) produces entangled photon pairs.
- **Pattern source**: one photon of each pair (the *idler*) goes to a spatially-resolving camera; the other (the *signal*) goes to the object + bucket. `P_i` is the i-th camera frame, kept only if there was a coincidence click on the bucket.
- **Required hardware**: pump laser, nonlinear crystal, cooled single-photon cameras (ICCD / SPAD array), coincidence electronics (ns–ps window), vibration isolation, days of alignment.
- **Cost / complexity**: lab-scale, expensive, hard.
- **Speed**: pair-rate limited — historically minutes to hours per image.

### 2. Computational GI (CGI) — what this project builds, Shapiro 2008

- **Light source**: ordinary laser.
- **Pattern source**: a DMD (digital micromirror device) projects *commanded* patterns. You don't measure `P_i` — you already have it in BRAM because you put it there.
- **Required hardware**: DMD (~$30–80), one APD, an FPGA.
- **Cost / complexity**: hobbyist-to-grad-student scale.
- **Speed**: DMD-limited, ~kHz pattern rate → ~seconds per image.

### 3. Thermal / pseudothermal GI — the middle rung

- **Light source**: laser + rotating ground-glass diffuser → real speckle patterns.
- **Pattern source**: a beamsplitter sends the speckle field two ways — one arm to the object + bucket, the other to a reference camera that measures `P_i` directly.
- **Required hardware**: laser, diffuser, beamsplitter, camera, bucket detector. No entanglement, no DMD.
- **Why it exists**: historically the bridge that proved entanglement wasn't necessary for ghost imaging. The patterns are real light (like QGI) but classical (like CGI).
- **Where it fits in this project**: Phase 8 of the roadmap — same FPGA, same correlator, same bucket; only the optical front-end changes (add diffuser + beamsplitter + camera).

---

## CGI vs. QGI — side by side

| | CGI (this project) | QGI |
|---|---|---|
| **Pattern source** | Commanded — DMD pattern in BRAM | Measured — camera frame on idler arm |
| **Light source** | Ordinary laser | SPDC entangled pair source |
| **Object arm detector** | Bucket (APD/TIA → ADC or comparator) | Bucket (SPAD, gated for coincidence) |
| **Reference arm** | Doesn't exist — replaced by BRAM | Real optical path with a spatially-resolving camera |
| **Synchronization** | Deterministic FPGA clocks DMD + ADC together | Coincidence-timing electronics, ns–ps window |
| **Physics required** | Classical correlation | Genuine entanglement (in the original formulation) |
| **Cost** | ~$100s | ~$10k–100k+ |
| **Speed** | kHz, seconds per image | Hz, minutes–hours per image |
| **Image quality on a normal bench** | Equal or better | — |

The reconstruction math is identical; only the source of `P_i` differs.

---

## What entanglement actually buys, when it does

CGI is cheaper, faster, and matches QGI for normal-bench imaging. QGI survives because entanglement offers a few capabilities classical light fundamentally cannot:

1. **Wavelength flexibility.** Signal and idler can be at different wavelengths. You can probe an object at mid-IR (where good cameras don't exist) while reading the pattern in visible (where they do). CGI can't do this.
2. **Sub-shot-noise SNR** in very low photon-flux regimes. Real but modest (factor of √2-ish).
3. **Background rejection.** Coincidence gating discards any photon not paired with its twin → strong rejection of ambient light, scattering, dark counts. Useful for noisy environments.
4. **Foundational interest.** For ~15 years after the 1995 experiment, the field genuinely debated whether ghost imaging *required* entanglement. Shapiro's 2008 paper (the first reference in the README) settled it: no. But the question drove a lot of quantum-optics theory.

For practical use — imaging through scattering media, low-light bio, single-pixel LIDAR — everyone uses CGI.

---

## Why we're climbing the easy rung first

CGI is the **practically accessible** variant. It does real, useful imaging with cheap parts and fits naturally onto an FPGA. The architecture we're building (deterministic pattern/sample sync, on-chip correlation accumulator in BRAM, streaming partial reconstruction) carries over almost unchanged to thermal GI — only the optical front-end changes. The roadmap is exactly this ladder:

```
CGI (Phase 1–7)  →  thermal GI (Phase 8)  →  quantum GI (long-term)
```

Same FPGA core, increasingly exotic optics.

---

## Reconstruction quality ladder

Independent of CGI/thermal/quantum, the *math* used to reconstruct can be more or less sophisticated. Roadmap covers all three:

1. **Raw correlation sum** (Phase 1, always works): `Î = Σ b_i · H_i`. Needs `N ≥ pixels`; noisy.
2. **Hadamard basis with differential measurement** (Phase 6): structured patterns + subtract complement-pattern measurement to cancel DC drift. Better SNR, same N.
3. **Compressed sensing / OMP** (Phase 7): assumes the image is sparse in some basis; reconstructs from `M << N` measurements. Runs on PC initially; candidate for partial FPGA acceleration.

---

## Glossary

- **Bucket detector** — a single-pixel detector with no spatial resolution. Just measures total photon flux. In this project: APD → TIA → comparator (or ADC).
- **APD** — avalanche photodiode. High-gain photodetector, good for low-light.
- **TIA** — transimpedance amplifier. Converts APD current to voltage.
- **DMD** — digital micromirror device. An array of microscopic mirrors that flip between two angles to make a binary spatial light modulator. The DLP2000 in this project is 640×360.
- **SPDC** — spontaneous parametric down-conversion. The nonlinear-optics process that produces entangled photon pairs from a pump laser and a crystal. The "quantum" in QGI.
- **Coincidence detection** — registering a click on detector A *only* if detector B also clicked within some narrow time window. The technique that pairs each idler-camera frame with its signal-bucket photon in QGI.
- **Speckle** — the random granular intensity pattern that forms when coherent light scatters off a rough surface. The pattern source in thermal GI.
- **Hadamard pattern** — orthogonal ±1 binary patterns from the Hadamard matrix. Good basis for ghost imaging because the patterns are mutually uncorrelated.
- **Compressed sensing** — reconstruction technique that recovers a signal from far fewer measurements than its dimension, assuming the signal is sparse in some basis.

---

## Key references (also in README)

- **Shapiro, J. H. (2008). Computational ghost imaging. *Phys. Rev. A* 78(6).** The paper that founded CGI and proved entanglement isn't required.
- **Bromberg, Y. et al. (2009). Ghost imaging with a single detector. *Phys. Rev. A* 79(5).** Early experimental CGI.
- **Duarte, M. F. et al. (2008). Single-pixel imaging via compressive sampling. *IEEE Signal Processing Magazine*.** Compressed sensing for single-pixel imaging.
- **Pittman, T. B. et al. (1995). Optical imaging by means of two-photon quantum entanglement. *Phys. Rev. A* 52(5).** The original QGI experiment.
