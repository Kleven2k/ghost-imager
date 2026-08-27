# Medical Extensions

Five medical-instrument projects that reuse the Ghost Imager hardware stack (FPGA + APD + laser + optics). Roughly ordered by **buildable solo with current budget** → **needs a real research partner**.

This isn't a roadmap — it's a list of "if you keep going, here's what the platform genuinely enables." Companion to [`shopping-list.md`](shopping-list.md) (what to buy) and [`journey.md`](journey.md) (the CGI build path).

The honest framing: the gap between "I built a prototype" and "this can be used on a patient" is enormous and gated by IRB approval, regulatory clearance, and clinical validation. None of what's below is intended as a medical device. The point is that the *signal acquisition* and *reconstruction algorithms* used in commercial medical instruments are accessible to a hobbyist, and building working DIY versions is genuinely educational and (in some cases) publishable.

---

## 1. Pulse oximeter (SpO₂)

**What it is.** Measures blood-oxygen saturation by shining red (660 nm) and near-IR (940 nm) light through a fingertip and looking at differential absorption of oxygenated vs. deoxygenated hemoglobin. The "ratio of ratios" of the AC components at each wavelength gives SpO₂ directly.

**Hardware overlap with Ghost Imager.**
- APD as the photodetector (sensitive enough to catch the AC pulse component cleanly).
- FPGA for deterministic LED timing, alternating-wavelength multiplexing, and ratiometric calculation.
- **Add**: one red LED (~$2), one IR LED (~$2), a finger clip or 3D-printed probe (free).

**Why it matters.** Pulse oximetry is the single most-deployed continuous medical sensor in the world — every hospital bed, every ambulance, every COVID home-test kit. The algorithm (Beer-Lambert + AC/DC ratio + motion-artifact rejection) is open literature and a great FPGA DSP exercise. Commercial chips are black boxes; building one from scratch teaches you what's actually happening.

**Realistic ambition.** A working SpO₂ + heart-rate reader with ~1% accuracy under cooperative conditions — comparable to consumer wearables, well below medical-grade (which is ±2% but validated across skin tones, perfusion states, and motion).

**Why this is the right first medical extension.** Cheapest, most parts-overlap, fastest path to "working device that does something useful." ~$10 of new parts on top of the existing stack.

**References.**
- Webster, *Design of Pulse Oximeters* (1997) — the canonical textbook.
- The Maxim MAX30100 datasheet is the easiest commercial reference design to cross-check against.

---

## 2. Photoplethysmography (PPG) + heart-rate variability (HRV)

**What it is.** Single-wavelength version of the above — just measures the optical pulse waveform. Beat-to-beat timing extracts R-R intervals; spectral analysis of those gives HRV metrics (LF, HF, LF/HF ratio).

**Hardware overlap.** Same as pulse oximetry minus one LED. Lower spec floor — even a green LED (530 nm) into the fingertip works.

**Why it matters.** HRV is the basis for:
- **Cardiac autonomic neuropathy** screening (especially diabetic patients).
- **Stress / mental-state monitoring** (LF/HF ratio is a sympathetic-vs-parasympathetic proxy).
- **Sleep-stage classification** (HRV changes track REM/NREM transitions).
- **Arrhythmia detection** (premature beats show up as R-R outliers).

Whoop, Oura, Apple Watch all do this. Doing it on FPGA gives you sub-millisecond timing precision the consumer devices don't have — relevant if you ever want to do real research on autonomic-response timing.

**Realistic ambition.** Continuous-monitoring PPG with ECG-comparable HRV accuracy (within ~5 ms RMSE on R-R intervals). Could feed a real clinical study with cardiologist collaboration.

**References.**
- Allen, "Photoplethysmography and its application in clinical physiological measurement," *Physiological Measurement* (2007). The foundational review.
- Task Force of ESC/NASPE, "Heart rate variability: standards of measurement..." *Circulation* (1996). Defines the metrics.

---

## 3. Diffuse optical spectroscopy / NIRS

**What it is.** Shine near-IR light into tissue at one location, collect the diffusely-scattered signal at a different location (typically 1–3 cm away). The modified Beer-Lambert law relates the optical-density change to concentration changes in oxy- and deoxy-hemoglobin. Continuous-wave NIRS is the entry point; frequency-domain and time-domain NIRS add quantitative absolute concentrations and depth resolution but cost more.

**Hardware overlap.**
- APD as the diffuse detector ✓
- FPGA for synchronous detection (modulate LEDs at ~kHz, lock-in detect to reject ambient light) ✓
- **Add**: NIR LEDs (760 nm + 850 nm, ~$10 total), a coupling probe (cardboard + black foam works for a prototype).

**Why it matters.** NIRS is a $500M+ medical market (Artinis, NIRx, Hitachi). Used for:
- **Functional brain imaging** (fNIRS — an alternative to fMRI, mobile, no magnets).
- **Muscle oxygenation** in sports science (Moxy, BSX are consumer-ish examples).
- **Neonatal brain monitoring** in NICUs (NIRS doesn't need sedation, unlike fMRI).
- **Wound healing assessment**.

A DIY single-channel prototype is publishable in *Biomedical Optics Express* and is increasingly common in neuroscience labs that can't afford the $20k–$100k commercial systems.

**Realistic ambition.** A one-channel CW-NIRS system measuring oxygenation changes during a finger-tapping task on motor cortex, or muscle deoxygenation during a forearm-grip test. Scaling to multi-channel (8, 16, 32 detectors) requires more APDs but the FPGA core extends cleanly.

**References.**
- Scholkmann et al., "A review on continuous wave functional near-infrared spectroscopy and imaging instrumentation and methodology," *NeuroImage* (2014). Comprehensive instrumentation review.
- Wabnitz et al., "Performance assessment of time-domain optical brain imagers," *Journal of Biomedical Optics* (2014). For the more ambitious TD-NIRS route.

---

## 4. Ghost imaging through tissue

**What it is.** Exactly the through-diffuser demo from [`journey.md`](journey.md) Stage 6, but with biological tissue (chicken breast, ex-vivo) instead of frosted glass. The bucket detector + correlation reconstruction is *unaffected* by the scattering between the object and the detector — that's the whole point.

**Hardware overlap.** Literally everything on the [`shopping-list.md`](shopping-list.md), plus a piece of chicken breast.

**Why it matters.** Imaging through scattering biological tissue is *the* unsolved problem in non-invasive medical imaging. X-rays penetrate but ionize. Ultrasound has limited resolution. MRI is huge and expensive. Optical methods (which carry rich molecular contrast — oxygenation, fluorescence, polarization) are limited by scattering.

If you can push CGI to even **32×32 resolution at 1 cm tissue depth**, that's publishable. Recent papers (2022–2024) doing similar things at hobbyist-equivalent hardware:
- Tajahuerce et al., "Image transmission through dynamic scattering media by single-pixel photodetection," *Optics Express* 22(14) (2014).
- Wang et al., "Single-pixel imaging through a 2.5 m biological tissue mimicking phantom," various recent works.

The "through-diffuser" Stage 6 milestone in `journey.md` is the same demo physically — just swap the diffuser for tissue once it works.

**Realistic ambition.** Recognizable silhouette imaging of an opaque object behind 2–5 mm of biological tissue. Within reach of a DIY CGI setup. Push to 1 cm and you're at the edge of what hobbyist-scale optics can do, but not beyond.

**Why this is the project's "killer medical application."** It's the natural extension of what you're already building — no new hardware, just a different sample, and the research community is actively interested.

---

## 5. Photoacoustic imaging (PAI)

**What it is.** Pulse a laser into tissue → absorbed light heats tiny tissue volumes → they thermally expand → emit ultrasound waves → pick up the waves with a piezo transducer → reconstruct an image. Hybrid technique: optical contrast (you see blood vessels because hemoglobin absorbs strongly), ultrasound resolution (sub-100 µm at clinical depths).

**Hardware overlap.**
- FPGA for nanosecond timing, ADC sampling, image reconstruction ✓
- **Add**:
  - A **pulsed** laser — the 532 nm CW laser on the shopping list won't work. Need a Q-switched diode laser or pulsed LED at ~1 kHz, ~ns pulses. ~$300–500 extra. (Or a passively-Q-switched microchip laser if you want to spend more.)
  - Piezoelectric transducer (~$30, e.g. a 1 MHz medical-ultrasound transducer salvaged from a "DIY ultrasound" kit).
  - Coupling gel (free — ultrasound gel from any pharmacy).

**Why it matters.** PAI is one of the most active medical-imaging research areas right now. Clinical applications under active development:
- **Vascular imaging** — see blood vessels without contrast agents.
- **Breast-cancer screening** — vascular signature of tumors visible without ionizing radiation.
- **Skin-cancer depth assessment**.
- **Hypoxia mapping** in tumors (oxy- vs. deoxy-hemoglobin have different optical spectra).
- **Drug-delivery monitoring** in small animals.

The FPGA's deterministic ns-scale timing is *exactly* what this needs — laser-trigger / ADC-sample sync must be sub-ns repeatable for image reconstruction.

**Realistic ambition.** Image major surface vessels in your own forearm at ~1 cm depth with mm-scale resolution. Several hobbyist-scale builds exist in the literature; the bottleneck is always the pulsed laser cost.

**Why it's tier-5.** Requires the biggest additional spend (~$300–500 for the pulsed laser) and the most domain learning (acoustic-wave reconstruction is its own field). But the platform you've built is genuinely a good starting point — most academic PAI labs use custom FPGA boards for exactly this kind of timing-critical acquisition.

**References.**
- Wang & Hu, "Photoacoustic tomography: in vivo imaging from organelles to organs," *Science* (2012). The canonical review.
- Beard, "Biomedical photoacoustic imaging," *Interface Focus* (2011). Excellent technical introduction.

---

## What's deliberately not on this list

A few medical-imaging targets get asked about but I don't think they're realistic for a solo hobbyist starting from the Ghost Imager platform:

- **Optical Coherence Tomography (OCT)** — the most clinically-impactful optical imaging technique of the last 30 years, used for every retinal scan. Builds on a Michelson interferometer. *But* requires a broadband superluminescent diode (~$1k), precision translation stage, and serious phase-stable optics. A hobbyist OCT build is its own 1–2 year project on top of this one.
- **Fluorescence lifetime imaging (FLIM)** — needs pulsed laser + time-correlated single-photon counting electronics. Your APD + FPGA could do TCSPC with picosecond timing modules added (~$500). Impressive if done well, but the spend climbs fast.
- **Diffuse correlation spectroscopy (DCS)** — measures blood flow (not just oxygenation) via speckle decorrelation. Possible with your hardware in principle, but requires a long-coherence laser and very-fast detector readout. Edge of feasibility.

---

## Path forward, if any of this appeals

If you finished Stage 6 of `journey.md` (through-diffuser CGI) and wanted to push toward medical applications, the natural order is:

1. **Pulse oximeter first** (1–2 weekends). Cheapest extension, fastest "working device" payoff, teaches you the biomedical-signals workflow end-to-end.
2. **CGI-through-tissue second** (already on the Ghost Imager roadmap). Closest to publishable.
3. **NIRS third** if you find you like the biomedical-optics direction — modest extra hardware, real applications, growing research community.
4. **Photoacoustic** only if you're willing to spend on a pulsed laser and have a year to give it.

None of this is a deliverable promise. The Ghost Imager system *enables* these — it doesn't commit you to any of them.
