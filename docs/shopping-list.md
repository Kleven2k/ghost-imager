# Shopping List — Stage 1 & Stage 2

What you need to buy to get from "empty repo" to "first photons hitting a bucket detector under FPGA control" — i.e. through Stage 2 of [`journey.md`](journey.md). Stage 1 is pure simulation and needs nothing physical beyond the FPGA you already own; Stage 2 is where the optics and analog frontend show up.

Prices are rough, in USD, ordered from "definitely need" to "nice to have." Total for the must-haves: **~$250–400**.

---

## Already have

- **Nexys Video Artix-7 FPGA board** — the brain. Has PMODs, USB-UART, plenty of BRAM for a 64×64 accumulator.
- **PC + USB cable** — for programming, UART, and PC-side reconstruction.

---

## Stage 1 — Simulation only

Nothing to buy. All software:

- **Vivado** (free WebPACK edition supports Artix-7)
- **Python 3.11+** with `numpy`, `matplotlib`, `pyserial`, `cocotb`, `pytest`
- **Icarus Verilog or Verilator** (cocotb backend, both free)
- **GTKWave** (free waveform viewer)

Stage 1 is where you de-risk everything cheap. Don't buy hardware until the simulation works.

---

## Stage 2 — Must-haves

### 1. DMD — TI DLP2000 LightCrafter Mini eval module

- **Cost**: ~$80–100 from TI store or DigiKey/Mouser
- **Why this one**: cheapest DMD with a usable interface, documented, hobbyist-accessible. 640×360 native resolution, enough for 64×64 logical patterns scaled 10×.
- **Watch out**: it expects an HDMI/parallel video input designed for a smartphone projector use case. Driving it with arbitrary patterns from an FPGA is doable but the datasheet is incomplete in places. Budget time for this.
- **Alternative**: DLP3010 eval module is ~$300 and easier to drive — only if budget allows.

### 2. Laser — 532 nm green laser module with TTL modulation

- **Cost**: ~$20–40 on AliExpress, ~$80–150 from Thorlabs (CPS532 class)
- **Power**: 5–30 mW is plenty. *Don't* buy >50 mW for a hobby project — eye safety becomes serious.
- **Why 532 nm**: cheap, bright, well-matched to silicon APD peak sensitivity, shared with the Ramsey vision in the README.
- **Get TTL mod input** if available — useful later for gating.
- **⚠️ Buy laser safety goggles rated OD 4+ at 532 nm at the same time. Non-negotiable. ~$30.**

### 3. Photodetector — APD module or fast photodiode + TIA

Two viable paths at the hobbyist level:

**Path A — Hamamatsu C12702 series APD module** (~$200–400)
- Built-in TIA, single +5 V supply, analog output. Just works.
- Expensive but eliminates an entire class of "is my analog frontend broken" debugging.
- *Recommendation for solo project with limited time.*

**Path B — Thorlabs APD120A or similar** (~$1000+)
- Better performance, lab-grade. Probably overkill.

**Path C — Photodiode + DIY TIA** (~$30 in parts)
- Thorlabs FDS100 photodiode (~$15) + an op-amp TIA you build yourself (OPA657 or similar, ~$15).
- Cheapest. Educational. Will likely be noisy and frustrating. Only choose this path if the analog circuit design is something you *want* to learn.

**Recommendation**: Path A unless you have a specific reason. The bucket detector being a black box that "just works" lets you focus on the FPGA/optics interaction, which is where the project's actual learning lives.

### 4. Laser safety goggles

- **Cost**: ~$30 from Thorlabs (LG3 or LG9) or eBay
- **Spec**: OD 4+ at 532 nm
- **Why**: A 30 mW green laser into your eye is a permanent injury, instantly. This is the only item on this list where the consequence of skipping it is irreversible.

### 5. Dark enclosure

- **Cost**: ~$0–50
- Cardboard box painted matte black inside works for Stage 2–3. A proper black-anodized aluminum enclosure costs more but isn't needed yet.
- Stray light is the #1 enemy of the bucket detector. Don't underestimate this.

---

## Stage 2 — Strongly recommended

### 6. Small optical breadboard

- **Cost**: ~$60–120
- Thorlabs MB1530 (15×30 cm) or AliExpress equivalent.
- **Why**: trying to align a laser → DMD → object → APD on a wooden desk with tape is a recipe for misery. A breadboard with M6 tapped holes lets components stay put.
- *Skip only if you're really budget-constrained.* Will cost you time instead of money.

### 7. Kinematic mounts and posts

- **Cost**: ~$50–150 depending on how many
- 2–3 kinematic mirror mounts + posts + post holders is the minimum for steerable optics.
- AliExpress kinematic mounts are ~$15 each and good enough for hobbyist use. Thorlabs equivalents are $80+ each but worth it if you can afford.

### 8. A few cheap lenses

- **Cost**: ~$30–80
- One short-focal-length lens to expand the laser beam onto the DMD (f ≈ 25–50 mm).
- One collection lens to focus light onto the APD active area (f ≈ 50–100 mm).
- AliExpress sells uncoated lenses for ~$5 each — fine for visible-light hobby use.

### 9. PMOD-compatible breakout / cables

- **Cost**: ~$10–20
- PMOD ribbon cable, perfboard, header pins for hand-wiring the DMD and detector connections.
- Don't underestimate connector hassle.

---

## Stage 2 — Nice to have

### 10. Oscilloscope

- **Cost**: $0 (borrow) to $400 (Rigol DS1054Z)
- Will save you many hours when the analog frontend is misbehaving. If you don't have access to one, this is the single most valuable lab tool you can acquire.
- A cheap USB scope ($100ish) also works.

### 11. Beamsplitter cube

- **Cost**: ~$30–80
- Not needed for basic CGI, but mandatory if you ever want to do pseudothermal GI (Stage 6 in `journey.md`). Buy when you get there.

### 12. ND filters (neutral density)

- **Cost**: ~$20 for a hobbyist set
- For attenuating the laser when the detector saturates. You will need these eventually. Easy to buy later.

### 13. Diffuser (frosted glass)

- **Cost**: ~$10–30
- For the through-diffuser demo (also Stage 6). Even a piece of bathroom-window glass works.

### 14. Object targets

- **Cost**: $0
- Printed paper masks, a small toy, a coin, a USAF-1951 resolution test chart (free PDF, print on transparency).

---

## Total budget

| Tier | Items | Cost |
|---|---|---|
| **Bare minimum to do Stage 2** | DMD + laser + APD (Path A) + goggles + cardboard box | ~$330 |
| **Comfortable Stage 2** | + optical breadboard + mounts + lenses + cables | ~$550 |
| **Comfortable through Stage 4** | + scope + ND filters + beamsplitter + diffuser | ~$900 |
| **Path C (DIY analog)** swap | Replace APD module with photodiode + TIA | save ~$200 |

---

## Notes on sourcing

- **AliExpress / eBay** — fine for lenses, mounts, posts, lasers (with caveats), breadboards. Quality is hit-or-miss; expect to receive at least one dud.
- **Thorlabs** — gold standard, but pricey. Worth it for the APD module, goggles, and anything optical-quality-critical.
- **DigiKey / Mouser** — for the DMD, electronics, connectors. Fast shipping, real datasheets.
- **TI store** — direct for the DLP2000.

**Lead times**: DMD and APD often have 1–4 week lead times. Order them as soon as Stage 1 is underway so they arrive when you're ready.

---

## What *not* to buy yet

- **Camera (any kind)** — not needed for CGI. Only needed for pseudothermal GI (Stage 6).
- **SPAD / time-tagger** — only needed for LIDAR demo (Stage 6).
- **InGaAs APD** — only needed for SWIR demo, far future.
- **Vibration-isolated optical table** — wildly overkill for this scale.
- **Anything related to entangled photon pairs** — see [`notes.md`](notes.md) on why QGI isn't the destination.

Resist scope creep. Buy what Stage 2 needs, finish Stage 2, then decide.
