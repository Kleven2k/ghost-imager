# Physics, Engineering & Competing Technology

Research performed 2026-06-29. Covers: (1) NIR tissue physics, (2) OPA657 TIA engineering, (3) competing modalities.

---

## 1. NIR tissue physics

### The biological window

Human tissue has a transparency window from roughly 700–900 nm (NIR-I) where the two main absorbers — water and haemoglobin — have local minima. This is why all optical tissue instruments target this range.

At the two planned wavelengths:

| Wavelength | HbO₂ absorption | HHb absorption | Net |
|---|---|---|---|
| 750 nm | Low | **High** | Deoxygenated blood absorbs more |
| 850 nm | **High** | Low | Oxygenated blood absorbs more |

This is the standard NIRS wavelength pair. It is chosen specifically because the extinction coefficients of HbO₂ and HHb cross near 800 nm (the isosbestic point), so one wavelength is HbO₂-sensitive and the other is HHb-sensitive. The differential signal gives oxygenation.

### Penetration depth — realistic numbers

"5–10 cm" figures quoted online refer to high-power therapeutic devices. For a diffuse reflectance geometry at diagnostic power levels:

- Epidermis + papillary dermis: 0.1–0.5 mm (both wavelengths sample this equally)
- Reticular dermis: 1–3 mm — **primary sampling volume for both wavelengths**
- Subcutaneous fat / superficial vessel plexus: 3–8 mm — sampled more by 850 nm than 750 nm

The depth difference between 750 nm and 850 nm in a reflectance geometry is not dramatic — roughly 1–2 mm shift in mean photon path depth. This is enough to distinguish dermal from subdermal perfusion, but not enough to image a cm-deep artery. The relevant clinical targets (diabetic foot skin microvasculature, burn wound depth, neonatal skin perfusion) all live in the 1–5 mm range — within reach.

Key optical properties of skin at NIR (from Wright et al., Biomedical Optics Express, 2023):
- Reduced scattering coefficient μ'ₛ: ~1–2 mm⁻¹ (wavelength dependent, decreases with wavelength)
- Absorption coefficient μₐ: ~0.01–0.05 mm⁻¹ (dominated by Hb in vascularised dermis)
- At 750 nm: μ'ₛ is ~10% higher than at 850 nm → shallower mean photon path
- At 850 nm: slightly deeper penetration, more sensitive to subdermal vessels

### Modified Beer-Lambert law — how depth discrimination works

The measured signal S at wavelength λ follows:

```
ΔOD(λ) = ε_HbO2(λ) × Δ[HbO2] × DPF(λ) × d
        + ε_HHb(λ)  × Δ[HHb]  × DPF(λ) × d
```

Where DPF (differential path length factor) accounts for scattering and encodes the depth information. DPF is wavelength-dependent — at 750 nm it is slightly smaller than at 850 nm, meaning photons travel a shorter effective path, sampling a shallower volume.

Combining measurements at both wavelengths with known extinction coefficients gives a 2×2 system for Δ[HbO2] and Δ[HHb] — the basis of NIRS. Integrating this into CGI's spatial reconstruction gives you a per-pixel oxygenation estimate at two depth weightings.

**Realistic expectation:** depth discrimination will separate "superficial" from "slightly deeper" rather than giving cm-resolution depth maps. For the clinical targets listed in `CGI_PLATFORM.md`, this is sufficient.

### Source-detector separation (complementary mechanism)

Varying the lateral distance between the DMD illumination spot and the detector collection area changes the banana-shaped photon path depth. Larger separation → deeper sampling. This is independent of wavelength and provides a second handle on depth. No extra hardware — just changing the probe geometry or masking patterns in software.

---

## 2. OPA657 TIA engineering

### Why OPA657

The FET input stage gives input bias current in the fA range — critical because photodiode shot noise is the dominant noise source at low light, not the amplifier. The 1.6 GHz GBW product is overkill for CGI alone but matters for the Ramsey photon-counting path.

### Key specs (from datasheet)

| Parameter | Value |
|---|---|
| GBW | 1.6 GHz (decompensated, stable at gain ≥7) |
| Input voltage noise | 4.8 nV/√Hz |
| Input current noise | 1.3 fA/√Hz |
| Supply voltage | ±5 V |
| Slew rate | 700 V/µs |

### Bandwidth with FDS100

FDS100 photodiode: active area 13 mm², junction capacitance Cd ≈ 20 pF at 0 V reverse bias (drops to ~7 pF at −15 V).

TIA bandwidth for decompensated op-amp with feedback resistor Rf and feedback capacitor Cf:

```
f_-3dB ≈ √(GBW / (2π × Rf × Cd))   [when Cf minimises peaking]
```

Practical values:

| Rf | Bandwidth | Transimpedance gain |
|---|---|---|
| 10 kΩ | ~5 MHz | 10 kV/A |
| 100 kΩ | ~1.6 MHz | 100 kV/A |
| 1 MΩ | ~500 kHz | 1 MV/A |

**For CGI:** Pattern rate is ~3.8 kHz, integration window ~200 µs. You need the TIA to settle within 200 µs → bandwidth >5 kHz is sufficient. Even 1 MΩ / 500 kHz is 100× more bandwidth than required. Use 100 kΩ as a starting point — gives adequate gain without sacrificing bandwidth.

**For lock-in detection (pulsatile signal):** Cardiac signal is 0.5–4 Hz. Lock-in reference can be the DMD pattern rate (3.8 kHz). The TIA bandwidth of 1+ MHz is irrelevant here — the relevant bandwidth is the post-detection lock-in filter, not the TIA.

### Noise floor estimate

At 100 kΩ transimpedance, dominant noise sources:

- Johnson noise in Rf: √(4kTRf) × bandwidth = 1.3 pA/√Hz × √(BW)
- Input current noise: 1.3 fA/√Hz × Rf = 0.13 nV/√Hz referred to output (negligible)
- Input voltage noise peaked up by Cd: 4.8 nV/√Hz × (1 + Cd/Cf) at high frequency

For 1 MHz bandwidth: Johnson noise ≈ 1.3 µA RMS at the input. FDS100 responsivity at 750–850 nm: ~0.4–0.5 A/W. So noise-equivalent power ≈ 3 µW over 1 MHz bandwidth. For CGI with integration over 200 µs, effective noise bandwidth is 5 kHz → NEP ≈ 0.2 µW. With a milliwatt laser, SNR is >60 dB before Hadamard differential gain.

### PCB layout notes

OPA657 is sensitive to stray capacitance at the inverting input — even 0.5 pF can cause oscillation. Keep the inverting input trace short, guard ring around the input, and Cf must be physically close to the IC. SOT-23 package recommended over DIP for the inverting node capacitance reasons.

---

## 3. Competing technology

### Overview

| Modality | Spatial? | Depth-selective? | Camera required? | Cost (hardware) | Contact? |
|---|---|---|---|---|---|
| Pulse oximetry | No — 1 point | No | No | < $50 | Yes |
| Laser Doppler flowmetry (LDF) | No — 1 point | No | No | $2k–10k | Yes |
| Laser speckle contrast imaging (LSCI) | **Yes — 2D** | **No** (<1 mm) | **Yes** | $500–5k | No |
| Multi-spectral LSCI (MS-LSCI) | **Yes — 2D** | Partial | **Yes** | $5k+ | No |
| fNIRS | No — few channels | ~3 cm bulk | No | $5k–50k | Yes (optodes) |
| OCT | Yes — 3D | ~1–2 mm | No (but complex) | $50k+ | No |
| Photoacoustic imaging | Yes — 3D | cm-scale | No | $50k+ | Yes (gel) |
| **CGI-NIR (this system)** | **Yes — 2D** | **Partial (~1–2 mm)** | **No** | **< $500** | **No** |

### Modality-by-modality

#### Pulse oximetry
Single point, measures SpO₂ at one location. No spatial information. Cannot detect localised perfusion deficits — if one toe is ischaemic, pulse ox on the finger doesn't know. Cheap and ubiquitous, which is why the spatial gap is clinically significant.

#### Laser Doppler flowmetry (LDF)
Measures blood flow velocity from Doppler shift of backscattered laser light. Single-point, contact probe. Provides a perfusion index in arbitrary units. Gold standard for single-point microvascular assessment but gives no spatial map. Slow to scan spatially.

#### Laser speckle contrast imaging (LSCI)
Full-field 2D blood flow map — the closest competitor. Fast (video rate). But: **requires a camera**, **no depth resolution** (samples <1 mm superficial layer only), sensitive to motion and ambient light. Can be built for ~$500 with a cheap camera + laser + software. Clinical LSCI devices (Moor Instruments, Perimed) cost $20k–60k.

**This system vs. LSCI:** no camera, partial depth discrimination, lower frame rate (1.1 s vs. video rate). LSCI wins on speed; this system wins on depth and detector freedom. The winning argument is multi-wavelength depth discrimination — LSCI fundamentally cannot do this without adding complexity that undermines its simplicity.

#### Multi-spectral LSCI (MS-LSCI)
Adds multiple laser wavelengths to LSCI to attempt depth resolution (PMC11853228). Still requires a camera. More expensive and complex. This is the closest overlap with the proposed system — and it confirms both that the need is real and that camera-free depth discrimination is an open problem.

#### fNIRS
Measures bulk tissue oxygenation using multiple optode pairs, typically targeting brain cortex through skull (~3 cm depth). Spatial resolution is poor — governed by optode spacing (~1–3 cm). Primarily a neuroscience tool. OpenNIRS and similar reduce cost to ~$500 DIY. Not a perfusion imaging tool — gives a few oxygenation channels, not a spatial map.

**This system vs. fNIRS:** better spatial resolution (64×64 vs. ~16 channels), lower depth (dermis not cortex), cheaper hardware, different application space. Not direct competitors.

#### OCT (optical coherence tomography)
Coherence-gated depth imaging. Excellent axial resolution (~5–10 µm), 1–2 mm depth in tissue. Cannot image through scattering beyond ~1 mm effectively. Cost: $50k–200k. Used for retinal imaging, dermatology, cardiology (intravascular OCT). The resolution advantage is irrelevant for perfusion mapping — the cost and complexity are prohibitive for the bedside use case.

#### Photoacoustic imaging
Combines pulsed laser with ultrasound detection. Can image blood vessels cm deep with ~100 µm resolution. The gold standard for deep vascular imaging. Requires ultrasound transducer, coupling gel, pulsed laser, and expensive signal processing hardware. Cost: $50k+. Research-grade systems at universities. Not a bedside / low-cost instrument.

### The genuine differentiator

No modality in the table above combines:

1. 2D spatial map (not single-point)
2. Camera-free (single-pixel detector)
3. Multi-wavelength depth discrimination
4. < $500 hardware cost
5. Non-contact
6. FPGA real-time acquisition

Points 1–3 together are unique. The absence of a camera (point 2) is what makes NIR-optimised detection possible: silicon cameras degrade past 900 nm, but a single silicon PIN photodiode (FDS100) is flat-responsive to 1100 nm. This opens NIR-II wavelength options that camera-based systems cannot access without expensive InGaAs sensors.

---

## References

- Wright, A. J. et al. (2023). Relevance and utility of the in-vivo and ex-vivo optical properties of the skin reported in the literature: a review. *Biomedical Optics Express*, 14(7), 3555. doi:10.1364/BOE.493588
- Guven, M. et al. (2023). Comparison of laser speckle contrast imaging with laser Doppler perfusion imaging for tissue perfusion measurement. *Microcirculation*. doi:10.1111/micc.12795
- PMC11853228 — Multi-spectral LSCI for depth-resolved blood perfusion (2025)
- OPA657 datasheet — Texas Instruments. [ti.com/lit/ds/symlink/opa657.pdf](https://www.ti.com/lit/ds/symlink/opa657.pdf)
- PMC3288249 — Laser Speckle Contrast Imaging of Cerebral Blood Flow (review)
- PMC7364176 — fNIRS clinical applications in neuroscience (review)
