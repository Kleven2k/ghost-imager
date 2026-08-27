# Shopping List — Stage 2 Hardware

What to buy to get from "simulation passes" to "first photons under FPGA control."

Prices confirmed 2026-06-29.

> **This file is the single source of truth for what to buy.** README.md and
> [CGI_PLATFORM.md](CGI_PLATFORM.md) describe the system and the longer-term NIR/tissue
> vision; where any of them names a part, this list wins. Canonical choices:
> DMD = `DLPDLCR2000EVM`, detector = FDS100 + OPA657 DIY TIA (APD dropped),
> first light at 532 nm, TIA on perfboard first (PCB later for the NIR path).

---

## Already have

- **Nexys Video Artix-7 FPGA board**
- **PC + USB cable**

---

## Decision log

- **APD dropped**: Hamamatsu C12702 is $793 (tariff-inflated). Replaced with DIY TIA: FDS100 + OPA657 (~$44 total). CGI doesn't need APD gain — a bright laser + PIN photodiode is sufficient. Fallback: BeamQ APD module at $169 if the TIA refuses to behave (order only if you hit a wall).
- **532nm first**: Proves the full FPGA pipeline end-to-end cheaply. NIR (785nm + 850nm) comes after first ghost image — see Phase 2 below.

---

## Confirmed order — ~$230 total

### Today — Mouser (single cart)

| Part | Description | Price |
|---|---|---|
| `DLPDLCR2000EVM` | TI DLP LightCrafter Display 2000 DMD | $119 |
| `OPA657U` | 1.6GHz FET-input op-amp (TIA core) | $24 |

[Mouser DLPDLCR2000EVM](https://www.mouser.com/ProductDetail/Texas-Instruments/DLPDLCR2000EVM) — **27 in stock, ships immediately.** 12-week factory lead time if stock runs out. Order now.

### Today — Thorlabs

| Part | Description | Price |
|---|---|---|
| `FDS100` | Large-area silicon PIN photodiode, 350–1100nm | ~$20 |

### Today — eBay

| Item | Description | Price |
|---|---|---|
| 532nm OD6+ safety goggles | Certified laser safety, green beam | ~$25 |

**Buy these before the laser arrives.** OD6+ at 532nm is the minimum for a 30mW beam.

### This week — CivilLaser (slow shipping, order now)

| Item | Description | Price |
|---|---|---|
| 532nm 5–30mW TTL module | DPSS green laser, dot, 16×70mm, TTL modulation input | ~$30 |

[civillaser.com](https://www.civillaser.com) — slow boat shipping, order immediately so it arrives before you're ready to use it.

### Any time — passives + perfboard

| Item | Price |
|---|---|
| 100kΩ 1% resistor (Rf), 1pF capacitor (Cf), decoupling caps, perfboard | ~$10 |

Source from DigiKey, Mouser, or whatever you have on hand.

---

## TIA build notes

- Start with **Rf = 100kΩ**, **Cf = 1pF** (adjust for stability vs. bandwidth).
- OPA657U is SOT-23 — stray capacitance at the inverting input causes oscillation. Keep that trace short, guard ring, Cf physically close.
- Power: ±5V. The Nexys Video has no ±5V rail — use a small bench PSU or a ±5V PMOD regulator module.
- Build on perfboard first. Verify with a scope before soldering anything permanent.
- **Perfboard is sufficient for the 532 nm proof-of-concept.** The noise estimate in [physics-and-competitors.md](physics-and-competitors.md) gives >60 dB SNR margin at 532 nm, so layout-induced noise doesn't yet matter. Move to a KiCad/JLCPCB layout only for the NIR / low-light path (Phase 2), where the OPA657 inverting-node stray capacitance actually degrades the noise floor.
- **Fallback**: BeamQ APD module ~$169 if the TIA doesn't come together. Order only after exhausting TIA debugging.

---

## The 12-week window

The DMD is in stock and ships now, but factory lead time for restocks is 12 weeks. That window is your friend: **build and characterize the FDS100 + OPA657 frontend while you wait.** By the time the DMD arrives, you'll already know your detector works. The only thing left will be optical alignment.

---

## Phase 2 — NIR tissue path (after first ghost image)

Add these after a working visible-light ghost image confirms the pipeline.

| Item | Source | Price |
|---|---|---|
| 785nm diode module, ~20mW | AliExpress / CivilLaser | ~$20–30 |
| 850nm diode module, ~20mW | AliExpress / CivilLaser | ~$15–25 |
| NIR goggles, 740–1100nm OD4+ | Thorlabs LG9C (~$100) or certified eBay (~$30) | ~$30–100 |
| Longpass filter 750nm (for detector) | Edmund Optics / AliExpress | ~$30–60 |

The 785nm / 850nm pair is the standard NIRS wavelength pair for oxygenation discrimination via Beer-Lambert. FDS100 is already responsive at both wavelengths — no detector change.

---

## Nice to have (buy when needed)

| Item | Why | Price |
|---|---|---|
| Oscilloscope (Rigol DS1054Z or borrow) | TIA debugging without a scope is guesswork | ~$400 / free |
| Small optical breadboard | Alignment stability | ~$60–120 |
| Kinematic mounts + posts ×2 | Two-axis beam steering | ~$50–150 |
| Lenses f=25/50/100mm | Beam expansion, collection onto FDS100 | ~$30–80 |
| ND filter set | Attenuate when detector saturates | ~$20 |
| Dark enclosure (cardboard + matte black paint) | Stray light is #1 enemy of bucket detector | $0–10 |

---

## What not to buy

- **Hamamatsu APD** — $793, not needed unless TIA fails completely (use BeamQ at $169 first)
- **Camera** — not needed for CGI
- **Pulsed laser** — only for photoacoustic
- **Second FPGA board** — one Nexys Video runs both Ghost Imager and Ramsey
