# Journey

A rough map of what needs to happen, what counts as progress, and what the milestones feel like from the inside. No dates. No deadlines. This is a solo project with limited resources — pace is whatever pace is. Companion to [`architecture.md`](architecture.md) (the technical spec) and [`notes.md`](notes.md) (the physics background).

The roadmap in [`README.md`](../README.md) lists 8 phases at the implementation level; this doc zooms out to milestones, what makes each one *feel* done, and what to be honest with yourself about along the way.

---

## Stage 0 — Foundations

**What needs to happen.** Get the toolchain working end-to-end before any optics show up. Vivado installed, board talking, a "hello world" bitstream loaded, UART round-tripping a byte from PC to FPGA and back. Python venv on the PC side with numpy + matplotlib + pyserial. A trivial cocotb test that runs `pytest` and passes.

**Done when.** You can blink an LED from RTL, send a byte over UART, and run a sim — all without consulting notes.

**Why it matters.** Every hour of debugging this stuff later costs 10× more once optics are also involved. Tooling pain has to be paid up front.

**Honest note.** Easy to underestimate. Vivado is enormous and weird; first project setup often takes a weekend on its own.

---

## Stage 1 — The FPGA core, in simulation

**What needs to happen.** Build the modules in [`architecture.md`](architecture.md) — Pattern Sequencer, correlator BRAM, UART streamer, CSR map — and verify each in cocotb against a numpy reference. No DMD, no APD, no optics. Synthetic bucket samples in, reconstructed image out, matches numpy.

**Done when.** You feed a known Hadamard set + synthetic `b_i` to the top-level testbench and the BRAM dump matches the numpy reconstruction within fixed-point error bounds.

**Why it matters.** This is where you prove the *math and the pipeline* work, decoupled from optical alignment hell. Once this is solid, every later bug is provably in the analog/optical domain.

**Honest note.** Resist the urge to skip simulation and "just try it on hardware." Hardware-only debugging on a mixed analog+digital system is how solo projects die.

---

## Stage 2 — First photons

**What needs to happen.** DMD arrives. APD arrives. Laser arrives. Get the DMD displaying a static pattern via the FPGA. Get the APD producing a sensible voltage when light hits it. Read the APD signal back through the FPGA over UART. Two separate sanity checks, not yet wired together.

**Done when.** You can command the DMD to show a checkerboard and *see* it (project onto a wall). You can wave a hand in front of the APD and watch the bucket counter change on the PC.

**Why it matters.** First contact with the physical world. Every assumption baked into the simulation now meets reality.

**Honest note.** This is where the project stops being software. Expect alignment frustration, expect the APD to be noisier than you hoped, expect to discover the DLP2000 datasheet is incomplete in important ways. Budget patience.

---

## Stage 3 — End-to-end first image

**What needs to happen.** Connect everything. Project a sequence of random binary patterns onto a backlit silhouette (a paper cutout of a letter, say). Bucket integrates. FPGA correlates. PC reads the BRAM dump and renders the reconstruction.

**Done when.** A recognizable image of *something you can identify* appears on the PC. It will be noisy. It will be 32×32 or 64×64. It will look like a 1995 webcam capture. That's fine. **It is a ghost image, made by your FPGA.**

**Why it matters.** This is the moment the project stops being theoretical. Everything before this was infrastructure; everything after this is improvement. If you stop here, you've already built something real.

**Honest note.** This is the most likely place to plateau, and the most rewarding place to *not* stop. Most hobbyist optics projects get to "I see something" and then drift. Pushing past this is what separates a demo from an instrument.

---

## Stage 4 — Making it actually good

**What needs to happen.** Move from random patterns to Hadamard basis with differential measurement. Tune integration windows. Shield the detector. Build an enclosure to kill stray light. Calibrate. Get the noise floor down. The image gets crisper, the acquisition gets faster, the system gets repeatable.

**Done when.** The same object photographed twice produces visibly similar reconstructions. You can recognize fine detail (not just silhouette). Acquisition is reliably under a few seconds.

**Why it matters.** This is the difference between "I made it work once" and "I built an instrument." Repeatability is the actual engineering deliverable.

**Honest note.** Most of the work here is unglamorous — grounding, shielding, mechanical stability, characterizing the APD. Less RTL, more bench skills. This stage is where you become *good at instruments*, which is a more valuable thing to become than "good at FPGAs."

---

## Stage 5 — Compressed sensing

**What needs to happen.** PC-side OMP (orthogonal matching pursuit) or similar sparse-reconstruction algorithm. Compare reconstructions at `M = N`, `M = N/4`, `M = N/16` measurements. Show that you can get a useful image from far fewer patterns than pixels.

**Done when.** A side-by-side plot showing reconstruction quality vs. measurement count, with a clear demonstration that sparsity assumptions buy you something.

**Why it matters.** This is where the project gains a real intellectual story. "I built a single-pixel camera that needs 4096 patterns" is fine. "I built one that reconstructs from 500 patterns by exploiting sparsity" is a different kind of statement.

**Honest note.** All on the PC, no new hardware. Easier than it sounds because the libraries exist. The hard part is understanding what's happening, not implementing it.

---

## Stage 6 — One interesting physics result

**What needs to happen.** Pick *one*. Don't try to do all three.

- **Through-diffuser imaging** — put frosted glass between the DMD and the object. A normal camera sees nothing; your system reconstructs the image. The most visually striking result available on this budget, and the one most aligned with the underwater-sensing long-term vision.
- **Pseudothermal GI** — replace the DMD-pattern source with a rotating ground-glass diffuser + reference camera. Reuses the entire FPGA core. A pure physics demo: same correlation math, completely different optical front end.
- **Time-of-flight CGI** — swap the APD for a SPAD with picosecond timing, build a basic single-pixel LIDAR. Harder, more expensive, more impressive if it works.

**Done when.** You have one demonstration that produces a "huh, that shouldn't work, but it does" reaction from a technical viewer.

**Why it matters.** This is what makes the project memorable rather than just complete. Recommendation: through-diffuser. Highest reward-to-difficulty ratio, ties directly to the README's underwater vision.

**Honest note.** Don't pick this stage until Stage 4 is rock-solid. Trying to do interesting physics on an unstable platform is how projects die slowly.

---

## Stage 7 — Far future, low priority

These are kept in the README for the architectural disciplining they provide, not as serious solo deliverables.

- **Ramsey integration.** Dual-modality optical CGI + NV magnetometry on shared hardware. Each half is solo-doable; integrating them with shared optics into a working sensor is a multi-person, multi-year program. Treat as "if a collaborator appears."
- **Quantum GI.** Entangled-pair source alone is ~$10k+ and the alignment skills take a year to develop. Practical applications all use CGI anyway. This is research-vehicle territory, not a destination.

**Done when.** Almost certainly never, alone, on this budget. That is fine. The vision exists to shape architectural choices today, not to be a deliverable.

---

## What "done" means

There is no done. There is "Stage N is solid enough that Stage N+1 is the right thing to work on." If you stop at Stage 3 you have a real ghost image. If you stop at Stage 4 you have a real instrument. If you stop at Stage 6 you have a portfolio-grade physics demo. All three are legitimate stopping points.

---

## What you're actually building

Not a product. Not a paper. A platform — and, more importantly, a version of yourself who can build platforms like this. The instrument is the artifact; the skill is the result. Both compound.

Skills you'll have by Stage 4 that you don't have now:

- Deterministic real-time DSP on FPGA — rare, hireable, applicable to RF, instrumentation, quantum control.
- End-to-end systems thinking spanning optics, analog, digital, embedded, and PC software. Almost nobody has all of these.
- The instinct for what fails first in a mixed-domain system, and the discipline to verify in simulation before fighting hardware.

Those skills outlast any specific result.

---

## Pace

Whatever pace happens, happens. Solo projects survive by being something you want to come back to, not by hitting deadlines. If a stage is dragging, the question isn't "how do I push through" — it's "is this stage actually the right one, or did I skip something at the previous stage that's now blocking me?" Usually it's the second.

The single most useful habit: when you sit down for a session, write one sentence about what you intend to accomplish, and one sentence at the end about what you actually did. After a month you can read the diff and see whether you're moving.
