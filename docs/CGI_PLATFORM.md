# Computational Ghost Imaging Platform
### NV Quantum Sensing · Tissue Perfusion · Navigation

> **Document status and relationship to other docs**
>
> This repository contains three documents with distinct roles:
> - `architecture.md` — authoritative current-state spec: actual RTL module names, present hardware, what is built and tested today
> - `journey.md` — personal research roadmap and decision log
> - `CGI_PLATFORM.md` (this document) — external-facing platform vision for supervisors, collaborators, and funders
>
> **What is built:** The Ramsey RTL core — pulse sequencer, gated photon counter, ADF4351 SPI control, BRAM accumulator, UART interface. The CGI software reconstruction pipeline. Navigation ghost imaging validated in simulation.
>
> **What is being built:** The CGI optical hardware — DMD interface, single-pixel detector front end, PMOD ADC integration, lock-in detection in RTL.
>
> **What is proposed:** The medical tissue sensing application and the quantum ghost imaging extension described in this document.
>
> Module names, wavelengths, and hardware components in this document describe the target system. For current implementation state, `architecture.md` is the source of truth.

---

## Origin

This project began as **Ramsey** — an FPGA-based readout system for nitrogen-vacancy (NV) center ODMR and Ramsey spectroscopy, built on a Nexys Video Artix-7 board. The core hardware stack: ADF4351 PLL microwave source, pulse sequencer, gated photon counter, BRAM accumulator, UART interface.

During development, computational ghost imaging (CGI) was identified as a natural extension — first for navigation through scattering media (fog, turbid water), then as a potential tissue sensing modality for medical applications.

The realization: **the scattering problem is the same physics in all three domains.** One platform, three application layers.

---

## What is Computational Ghost Imaging?

Conventional imaging floods a scene with uniform light and captures the reflected or transmitted image directly. In strongly scattering media — fog, turbid water, biological tissue — this fails because scattered photons carry no spatial information and overwhelm the useful signal.

CGI takes a different approach:

1. Illuminate the target with a sequence of known spatial patterns (Hadamard, random binary) via a DMD
2. Measure only the total integrated intensity — a single number per pattern — with a single-pixel detector
3. Correlate the detector response with each known pattern
4. Reconstruct the spatial signal through this correlation

The single-pixel detector sees everything. The reconstruction separates what came from where.

In scattering media, CGI's second-order intensity correlations suppress phase-randomizing noise — yielding useful signal where conventional imaging fails.

---

## The Medical Application

### The Gap

Non-invasive tissue sensing with light fails for a fundamental reason: scattering destroys spatial and depth information. Every existing method — pulse oximetry, laser Doppler, laser speckle contrast imaging (LSCI), diffuse correlation spectroscopy (DCS) — integrates signal from all depths simultaneously. You cannot cleanly isolate what is happening at a specific depth.

For blood pressure, glucose, and vascular assessment, depth selectivity is clinically useful. Arterial signals buried under venous and capillary background are the target. No existing optical method resolves them cleanly.

### The Hypothesis

Computational ghost imaging, combined with an explicit depth discrimination mechanism, could provide depth-selective pulsatile signal extraction that conventional single-point PPG cannot achieve.

**CGI alone does not give depth resolution** — it provides lateral (x,y) spatial selectivity from a single-pixel detector. Depth requires an additional mechanism. Two are feasible with the planned hardware:

**1. Multi-wavelength CGI**  
Different NIR wavelengths penetrate tissue to different depths due to wavelength-dependent scattering and absorption coefficients. Running CGI at two or more wavelengths (e.g. 750nm and 850nm) and comparing the reconstructed signals provides depth-from-wavelength discrimination via the modified Beer-Lambert law — the same physics NIRS uses, integrated with CGI's lateral spatial selectivity. This is the primary target mechanism.

**2. Source-detector separation geometry**  
Varying the distance between the illumination and collection points changes which depth the dominant banana-shaped photon path samples. Larger separation → deeper probing. This requires no additional hardware — only probe geometry variation — and is complementary to the multi-wavelength approach.

The contribution is therefore: **CGI + multi-wavelength depth discrimination as an integrated system**, providing both lateral spatial selectivity and depth resolution in a single low-cost benchtop instrument. No existing system combines these in the tissue sensing context.

### Prior Work

| Reference | What it shows | What it leaves open |
|---|---|---|
| Yu et al. (2024) | Ghost imaging extracts heart rate from tissue | No depth selectivity; stops at heart rate |
| Hussein & Moazeni, JBO (2025) | Multi-spectral LSCI attempts depth-resolved perfusion | Depth inferred indirectly; no CGI spatial reconstruction |
| Carp et al., Neurophotonics (2023) | DCS limitations — poor SNR, not spatially resolved | Validates the gap this system targets |
| Spatiotemporal PPG literature | Spatially resolved cardiac signal in tissue | Uses cameras, no structured illumination |

**CGI + multi-wavelength depth discrimination for pulsatile tissue sensing: not in the literature.** This is the gap.

### Clinical Applications

All share the same sensing question: *what is the functional perfusion state of tissue within 5–10mm of the skin surface, with lateral spatial resolution and depth selectivity?*

| Application | Clinical burden | CGI advantage |
|---|---|---|
| Sepsis microcirculation | 21.4M deaths/year (GBD 2021, *Lancet Global Health* 2025) | Continuous unattended microvascular monitoring |
| Diabetic foot perfusion | ~1M+ amputations/year (Lazzarini et al., *Diabetologia* 2023) | Spatial perfusion map, home monitoring |
| Burn wound depth assessment | Surgical decision accuracy | Depth discrimination of viable vs necrotic tissue |
| Intraoperative perfusion | Anastomotic leak prevention | Non-contact real-time spatial map |
| Neonatal monitoring | NICU fragility, adhesive damage | Non-contact, non-adhesive |
| Blood pressure waveform | 1.3B hypertensives globally | Depth-isolated arterial waveform morphology |

---

## Hardware Architecture

> Current hardware state and actual module names: see `architecture.md`.  
> The following describes the target system.

### Optical path

```
Laser (850 nm NIR primary, 750 nm secondary for depth discrimination)
    │
    ▼
DLP2000EVM (DMD)          ← Pattern sequence from Artix-7
    │
    │  Structured illumination
    ▼
[ TISSUE / PHANTOM ]
    │
    │  Scattered photons (transmission or reflectance geometry)
    ▼
Collection lens
    │
Bandpass filter (matched to laser wavelength)
    │
    ▼
Single-pixel detector (PDA36A2 or DIY TIA: FDS100 + OPA657)
    │  Note: FDS100 is the discrete photodiode; OPA657 is the TIA op-amp
    ▼
PMOD ADC → Artix-7
```

> **Note on wavelength:** 532 nm green (as used in Ramsey and Yu et al.) is viable for proof-of-concept replication. NIR (750–850 nm) is the target for tissue depth penetration and multi-wavelength depth discrimination.

### FPGA (Artix-7) signal chain

```
Pattern generator → DMD (I2C config + pattern data)
         │
         └── Sync trigger → ADC sample
                                │
                            BRAM: store (pattern_index, intensity)
                                │
                            Correlation reconstruction: I(x,y) = Σ S_n · P_n(x,y)
                                │
                            Multi-wavelength comparison → depth weighting
                                │
                            Lock-in demodulation + bandpass (0.5–4 Hz cardiac)
                                │
                            Pulsatile signal extraction
                                │
                            UART → PC
```

### DIY components

| Component | Notes |
|---|---|
| TIA (OPA657 + FDS100) | FDS100 is the discrete photodiode. OPA657 is the transimpedance op-amp. Perfboard is sufficient for the 532 nm proof-of-concept (SNR margin is large); move to a KiCad/JLCPCB layout for the NIR / low-light path, where OPA657 stray-capacitance noise actually bites. See [shopping-list.md](shopping-list.md) TIA build notes. |
| Laser modulation driver (LT3080) | Constant current source with FPGA modulation input for lock-in carrier |
| Lock-in detection | Implemented in RTL on Artix-7. No commercial lock-in needed. |
| 3D printed optical mounts | Lens holders, finger mount, phantom container housing |
| Intralipid phantom | 1% intralipid solution in DIY acrylic cuvette. Pulsatile aquarium pump for arterial simulation. |

### Budget tiers

| Tier | Cost | Purpose |
|---|---|---|
| Budget | ~€185 | Replicate Yu et al. Static diffuser, DIY TIA, 532 nm |
| Moderate | ~€475 | Full CGI. DLP2000EVM + PDA36A2 + PMOD ADC |
| DIY moderate | ~€355 | Moderate with DIY TIA and laser driver |
| Advanced | ~€1900 | Research grade. APD + dual wavelength + Finapres BP reference |

---

## Software Architecture

The CGI acquisition and reconstruction core is **application-agnostic**. The pipeline is identical whether the system is used for NV tissue sensing in Ramsey, tissue perfusion sensing, or navigation. Application-specific processing sits on top.

```
┌─────────────────────────────────────────────────┐
│              Application Layer                  │
│                                                 │
│  Ramsey NV sensing  │  Tissue perfusion  │  Nav │
│  Spin contrast      │  Cardiac signal    │  Scene│
│  extraction         │  waveform morph.   │  recon│
└────────────────┬────┴────────────────────┴───────┘
                 │
┌────────────────▼────────────────────────────────┐
│           Signal Processing Layer               │
│                                                 │
│  Bandpass filter · VMD · Autocorrelation        │
│  FFT · Lock-in demodulation · Phase averaging   │
│  Multi-wavelength depth weighting               │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│         CGI Reconstruction Layer                │
│                                                 │
│  Correlation: I(x,y) = Σ S_n · P_n(x,y)        │
│  Pattern basis: Hadamard / random binary        │
│  Compressive sensing: undersample sparse signal │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│          Acquisition Layer (Artix-7 RTL)        │
│                                                 │
│  Pattern generator · DMD sync · ADC trigger     │
│  BRAM accumulator · UART streaming              │
│  Lock-in carrier generation                     │
└─────────────────────────────────────────────────┘
```

> Module names in this document (pattern_gen, adc_interface, etc.) are target names.  
> Current RTL module names are in `architecture.md`.

### SNR improvement stack

Applied in order, each independent of the others:

| Technique | SNR gain (ideal) | Realized in tissue | Effort | Cost |
|---|---|---|---|---|
| Lock-in detection | 20–40 dB | ~15–25 dB (motion, 50/60 Hz) | Medium — RTL | €0 |
| Coherent averaging | 10–20 dB | 10–20 dB | Low — software | €0 |
| Hadamard basis | 5–10 dB | 5–10 dB | Low — software | €0 |
| NIR wavelength | 10–20 dB | 10–20 dB | Low — swap laser | €30–50 |
| Transmission geometry | 10–15 dB | 10–15 dB | Arrangement | €0 |
| Dark enclosure | 5–15 dB | 5–15 dB | Mechanical | €5 |
| Compressive sensing | 5–10 dB | 5–10 dB | Algorithm | €0 |
| APD detector | ~10 dB | ~10 dB | Hardware | €380 |

> Lock-in gain depends strongly on carrier frequency separation from dominant noise sources. In tissue at audio rates, 15–25 dB realized gain is a more conservative and honest estimate than the theoretical maximum.

---

## Validation Roadmap

### Phase 1 — Phantom (now, €355)
- Intralipid 1% in cuvette, pulsatile pump at ~1 Hz
- Three conditions: conventional PPG vs CGI uniform illumination vs CGI Hadamard patterns
- **Question: does structured illumination give cleaner signal than uniform?**

### Phase 2 — Depth selectivity
- Multi-wavelength experiment: 750 nm vs 850 nm CGI reconstruction
- Target absorber at known depth; vary depth
- Compare depth discrimination against LSCI baseline
- **Question: does CGI + multi-wavelength resolve depth that LSCI cannot?**

### Phase 3 — Human finger, transmission geometry
- Replace phantom with finger in transmission geometry
- Validate heart rate against pulse oximeter reference
- Extract arterial waveform morphology features
- **Question: does depth-weighted reconstruction isolate arterial from venous signal?**

### Phase 4 — BP correlation
- Finapres continuous BP reference
- Correlate CGI waveform features (augmentation index, rise time, dicrotic notch timing) with reference BP
- **Question: is there BP-correlating information in the depth-isolated arterial signal?**

### Phase 5 — Platform expansion
- Foot reflectance geometry: spatial perfusion map
- Layered burn phantom: viable vs necrotic tissue discrimination
- Neonatal phantom: thin tissue equivalent, non-contact geometry

---

## Future: Quantum Ghost Imaging

CGI is the classical foundation. Quantum ghost imaging (QGI) using entangled photon pairs from SPDC is the longer-term research frontier.

### What QGI could unlock — with honest caveats

**Sub-shot-noise operation**  
Quantum correlations between entangled photon pairs can beat the classical shot noise limit. In practice, the advantage is typically under 3 dB in real systems — not orders of magnitude. More importantly, this advantage is only realised when shot noise is the dominant noise source. In tissue, scattering and motion artifacts typically dominate. Sub-shot-noise operation becomes meaningful at the deeper tissue depths where photon budgets are fundamentally constrained.

**Wavelength multiplexing (imaging with undetected photons)**  
Illuminate tissue at NIR wavelengths optimal for tissue penetration; detect the entangled idler at visible wavelengths where silicon detectors are maximally sensitive. Demonstrated for mid-IR microscopy of biological tissue in *Science Advances* (Kviatkovsky et al., 2021). This is technically achievable at room temperature with standard CMOS detection — no cryogenics required.

**Entanglement survival through tissue**  
Demonstrated experimentally: polarisation entanglement was preserved in ballistic (un-scattered) photons traversing thin rat brain slices at 802 nm (Shi et al., *Scientific Reports*, 2016). Important caveat: this applies to ballistic photons through thin (1–2 mm) slices. At clinically relevant depths (5–10 mm), the scattered fraction dominates and entanglement preservation is substantially degraded. Deep-tissue entanglement survival at clinical depths is an open question — and one this platform could investigate experimentally.

**Interaction-free measurement**  
In principle, detect object properties using photons that did not interact with it. Works for binary detection (present/absent) at low fidelity. In an imaging or sensing context, "approaches zero photon dose" is technically true but operationally optimistic — the efficiency in scattering media is very low with current technology.

### Hardware requirements

| Component | Temperature | Cost |
|---|---|---|
| 405 nm pump laser (single mode) | Room temperature | €800–2000 |
| BBO nonlinear crystal (SPDC source) | Room temperature | €500–1500 |
| Fast SPADs ×2 (coincidence detection) | Room temperature | €2000–8000 |
| TCSPC — Artix-7 RTL implementation | Room temperature | €0 (vs €3000–8000 commercial) |
| **Total** | | **€3300–11500** |

> The Artix-7 nanosecond-precision timing infrastructure from Ramsey maps directly onto TCSPC coincidence detection. This is a meaningful cost reduction vs commercial TCSPC cards.

### Path to QGI

1. CGI proof of concept → published result
2. Published result → Forskningsrådet IKTPLUSS / FRINATEK grant application with preliminary data
3. Grant → SPDC source + SPAD detectors (~€5000–10000)
4. Artix-7 TCSPC implementation → replaces €8000 commercial card
5. QGI tissue experiment → quantify entanglement survival vs depth; measure SNR vs classical CGI

---

## Funding Path (Norway)

| Stage | Source | Requirement |
|---|---|---|
| Phase 1–2 | Self-funded | ~€355 hardware |
| Phase 3–4 | Helse Midt-Norge open project funding | Clinical co-investigator at St. Olavs Hospital |
| QGI hardware | Forskningsrådet IKTPLUSS / FRINATEK | NTNU faculty supervisor + published CGI result as preliminary data |
| Commercialisation | Innovasjon Norge FORNY2020 | Demonstrated clinical result |

Key local asset: NTNU and St. Olavs Hospital are physically integrated in Trondheim — joint appointments and clinical-engineering collaboration are structurally supported.

---

## Competitive Landscape

Existing optical tissue sensing methods and their specific limitations:

| Method | What it does | Specific limitation |
|---|---|---|
| LSCI | Surface perfusion mapping, non-contact | No depth selectivity |
| DCS | Deep tissue blood flow | Poor SNR, not spatially resolved, difficult to miniaturise |
| NIRS | Oxygenation spectroscopy | Requires contrast agents for perfusion; coarse depth resolution |
| Laser Doppler | Microvascular blood flow | Single point, contact required, no spatial mapping |
| Conventional PPG | Pulsatile cardiac signal | Integrates all depths; cannot isolate arterial signal |
| Ultrasound | Anatomical vascular imaging >5mm | Requires trained operator; not continuous or wearable |

**The combination of lateral spatial selectivity + multi-wavelength depth discrimination + continuous unattended monitoring is not provided by any existing method.** The literature gap is triangular: CGI through scattering tissue (physics demonstrated, no physiology), GI for heart rate (physiology demonstrated, no depth), spatially resolved PPG (perfusion mapping, no CGI). This platform targets the intersection.

---

## Key References

| Reference | Relevance |
|---|---|
| Rudd et al., *Lancet* (2020); GBD 2021, *Lancet Global Health* (2025) | Sepsis burden: 11M deaths (2017), updated to 21.4M (2021 inc. COVID) |
| Lazzarini et al., *Diabetologia* (2023) | Global trends in diabetes-related amputations |
| Yu et al. (2024) | Ghost imaging extracts heart rate from tissue. Direct prior work. |
| Hussein & Moazeni, *JBO* (2025) | Multi-spectral LSCI for depth-resolved perfusion. Closest competing method. |
| Carp et al., *Neurophotonics* (2023) | DCS limitations — SNR and depth sensitivity barriers |
| Kviatkovsky et al., *Science Advances* (2021) | Mid-IR tissue microscopy with undetected photons at room temperature |
| Shi et al., *Scientific Reports* (2016) | Entanglement preservation in thin brain tissue at 802 nm — ballistic photons only |
| Brida et al., *Nature Photonics* (2010) | Experimental sub-shot-noise quantum imaging (<3 dB typical) |
| Defienne et al., *Nature Photonics* (2024) | Advances in quantum imaging review |

---

*Built on a Nexys Video Artix-7. Started as a quantum magnetometer. Became something more.*

*Written: 2026-06*
