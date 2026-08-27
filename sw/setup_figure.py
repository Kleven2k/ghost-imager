"""Optical-setup schematic for the Ghost Imager CGI experiment.

Renders a publication-style figure of the physical bench layout — the kind of
"experimental setup" diagram found in CGI papers — showing how the components
sit relative to one another and how light flows through the system:

    laser -> beam expander -> fold mirror -> DMD (angled, reflective)
          -> structured light -> object -> collected scatter
          -> photodiode + TIA -> ADC -> FPGA -> reconstructed image

Two ideas the figure is built to make obvious:
  1. The DMD is a REFLECTIVE element hit at an angle. ON-mirrors send light to
     the object; OFF-mirrors dump it into a beam dump. That selective bounce is
     how a flat beam becomes a pattern.
  2. The photodiode is a SINGLE-PIXEL bucket with no imaging optics — it reports
     one number per pattern. The image lives in the patterns, not the detector.
     The FPGA closes the loop: it drives the DMD and reads the bucket, and the
     correlation of the two is the reconstruction.

Usage:
    python sw/setup_figure.py            # writes docs/figures/setup_schematic.png
"""
from pathlib import Path

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Rectangle, FancyBboxPatch, Circle, Polygon
from matplotlib.lines import Line2D

OUT = Path(__file__).resolve().parents[1] / "docs" / "figures" / "setup_schematic.png"

# ── Palette ──────────────────────────────────────────────────────────────────
GREEN   = "#1fbf4f"   # 520-532 nm beam
GREEN_D = "#0f7a2e"
GREY    = "#5a5a5a"
DARK    = "#2b2b2b"
BLUE    = "#1f6feb"   # electrical / control signals
RED      = "#d23c3c"
PANEL   = "#f4f6f8"
DUMP     = "#3a3a3a"


def beam(ax, p0, p1, lw=7, color=GREEN, alpha=0.9, zorder=2):
    """A laser-beam segment: a thick translucent line with a brighter core."""
    ax.plot([p0[0], p1[0]], [p0[1], p1[1]], color=color, lw=lw,
            alpha=0.30, solid_capstyle="round", zorder=zorder)
    ax.plot([p0[0], p1[0]], [p0[1], p1[1]], color=color, lw=lw * 0.4,
            alpha=alpha, solid_capstyle="round", zorder=zorder + 1)


def arrow(ax, p0, p1, color=BLUE, lw=1.8, style="-|>", ls="-", zorder=6):
    ax.add_patch(FancyArrowPatch(
        p0, p1, arrowstyle=style, mutation_scale=14, lw=lw, ls=ls,
        color=color, shrinkA=0, shrinkB=0, zorder=zorder))


def box(ax, xy, w, h, label, fc="white", ec=DARK, tc=DARK, fs=10, lw=1.6, round_=True):
    cx, cy = xy[0] + w / 2, xy[1] + h / 2
    patch = (FancyBboxPatch(xy, w, h, boxstyle="round,pad=0.012,rounding_size=0.02",
                            fc=fc, ec=ec, lw=lw, zorder=4)
             if round_ else Rectangle(xy, w, h, fc=fc, ec=ec, lw=lw, zorder=4))
    ax.add_patch(patch)
    ax.text(cx, cy, label, ha="center", va="center", fontsize=fs,
            color=tc, zorder=5, weight="bold")
    return (cx, cy)


def label(ax, xy, text, fs=8.5, color=DARK, ha="center", va="center", style="italic"):
    ax.text(xy[0], xy[1], text, ha=ha, va=va, fontsize=fs, color=color,
            style=style, zorder=7)


def build():
    fig, ax = plt.subplots(figsize=(12.5, 8.0))
    ax.set_xlim(0, 12.5)
    ax.set_ylim(-0.4, 7.6)
    ax.axis("off")
    ax.set_aspect("equal")

    ax.text(0.2, 7.35, "Computational Ghost Imaging — experimental setup",
            fontsize=14, weight="bold", color=DARK, ha="left")
    ax.text(0.2, 7.0,
            "Resolution lives in the illumination (DMD patterns), not in the detector (single-pixel bucket).",
            fontsize=9.5, color=GREY, ha="left", style="italic")

    # ── 1. Laser ────────────────────────────────────────────────────────────
    lx, ly = 0.5, 4.7
    box(ax, (lx, ly - 0.45), 1.5, 0.9, "Laser\n520–532 nm\n(TTL mod.)",
        fc="#eafaef", ec=GREEN_D, tc=GREEN_D, fs=8.5)
    laser_out = (lx + 1.5, ly)

    # ── 2. Beam expander (so the small beam fills the whole DMD) ─────────────
    bex = 3.0
    beam(ax, laser_out, (bex, ly))
    # simple two-lens expander glyph
    for dx, hh in [(0.0, 0.22), (0.55, 0.5)]:
        ax.add_patch(Polygon([[bex + dx, ly - hh], [bex + dx + 0.12, ly],
                              [bex + dx, ly + hh]], closed=True,
                              fc="#cfe8ff", ec=BLUE, lw=1.2, zorder=4))
        ax.add_patch(Polygon([[bex + dx + 0.12, ly - hh], [bex + dx, ly],
                              [bex + dx + 0.12, ly + hh]], closed=True,
                              fc="#cfe8ff", ec=BLUE, lw=1.2, zorder=4))
    label(ax, (bex + 0.33, ly - 0.85), "beam\nexpander", fs=8)
    expander_out = (bex + 0.67, ly)

    # expanded (wider) beam to the DMD
    dmd_c = (5.7, ly)
    beam(ax, expander_out, dmd_c, lw=12)

    # ── 3. DMD — reflective, hit at an angle ────────────────────────────────
    # Draw as a tilted bar. ON path goes up-right to the object; OFF path goes
    # down-right into a beam dump.
    dmd_angle = 28  # degrees
    dl = 0.95
    a = np.deg2rad(dmd_angle)
    d0 = (dmd_c[0] - dl * np.sin(a), dmd_c[1] - dl * np.cos(a))
    d1 = (dmd_c[0] + dl * np.sin(a), dmd_c[1] + dl * np.cos(a))
    ax.add_patch(Polygon([d0, d1], closed=False))  # placeholder to keep zorder
    ax.plot([d0[0], d1[0]], [d0[1], d1[1]], color=DARK, lw=9,
            solid_capstyle="round", zorder=5)
    # little mirror hatching
    for t in np.linspace(0.15, 0.85, 6):
        mx = d0[0] + t * (d1[0] - d0[0])
        my = d0[1] + t * (d1[1] - d0[1])
        ax.plot([mx - 0.07, mx + 0.07], [my, my], color="#aaaaaa", lw=1, zorder=6)
    label(ax, (dmd_c[0] - 1.35, dmd_c[1] + 1.05),
          "DMD\n(~230k micro-mirrors,\nreflective, 1 bpp)", fs=8.5, color=DARK)

    # ON path: DMD -> object (up and to the right)
    obj_c = (9.2, 6.0)
    beam(ax, dmd_c, obj_c, lw=10)
    label(ax, (7.4, 6.05), "structured\nillumination", fs=8, color=GREEN_D)

    # OFF path: DMD -> beam dump (down and to the right)
    dump_c = (7.3, 2.4)
    beam(ax, dmd_c, dump_c, lw=6, color="#9bbf9b", alpha=0.5)
    ax.add_patch(Rectangle((dump_c[0] - 0.2, dump_c[1] - 0.35), 0.55, 0.7,
                           fc=DUMP, ec=DARK, lw=1.2, zorder=4))
    # absorber teeth
    for yy in np.linspace(dump_c[1] - 0.28, dump_c[1] + 0.28, 4):
        ax.plot([dump_c[0] - 0.2, dump_c[0] + 0.05], [yy, yy], color="#777", lw=1, zorder=5)
    label(ax, (dump_c[0] + 0.08, dump_c[1] - 0.7), "beam dump\n(OFF mirrors)", fs=8, color=GREY)

    # ── 4. Object (the diabetic foot / phantom) ─────────────────────────────
    box(ax, (obj_c[0] - 0.55, obj_c[1] - 0.6), 2.4, 1.2,
        "OBJECT\n(tissue / phantom)", fc="#fff0e8", ec=RED, tc="#a33", fs=9)
    label(ax, (obj_c[0] + 0.65, obj_c[1] - 0.95),
          "pattern is painted onto the scene", fs=8, color=GREY)

    # ── 5. Collection lens + single-pixel detector ──────────────────────────
    # Diffuse scatter from object down to the photodiode.
    pd_c = (9.9, 2.5)
    # scatter shown as several faint diverging rays converging via a lens
    lens_c = (9.9, 4.0)
    for dx in (-0.4, -0.15, 0.1, 0.35):
        beam(ax, (obj_c[0] + 0.4 + dx, obj_c[1] - 0.6),
             (lens_c[0], lens_c[1] + 0.25), lw=3, color="#7fd49a", alpha=0.45)
    # collection lens (biconvex)
    ax.add_patch(Polygon([[lens_c[0] - 0.18, lens_c[1] - 0.45], [lens_c[0], lens_c[1] - 0.32],
                          [lens_c[0] + 0.18, lens_c[1] - 0.45], [lens_c[0] + 0.18, lens_c[1] + 0.45],
                          [lens_c[0], lens_c[1] + 0.32], [lens_c[0] - 0.18, lens_c[1] + 0.45]],
                         closed=True, fc="#cfe8ff", ec=BLUE, lw=1.2, zorder=4))
    label(ax, (lens_c[0] + 0.95, lens_c[1] + 0.15), "collection\nlens", fs=8)
    beam(ax, (lens_c[0], lens_c[1] - 0.45), (pd_c[0], pd_c[1] + 0.45), lw=5, color="#7fd49a", alpha=0.55)

    # photodiode
    ax.add_patch(Circle(pd_c, 0.32, fc="#222", ec=DARK, lw=1.5, zorder=5))
    ax.add_patch(Circle(pd_c, 0.13, fc="#69d", ec="none", zorder=6))
    label(ax, (pd_c[0] + 1.05, pd_c[1] + 0.08),
          "photodiode\n(single pixel —\nno image!)", fs=8, color=DARK, ha="center")

    # TIA + ADC chain
    tia = box(ax, (8.55, 1.05), 1.0, 0.55, "TIA", fc=PANEL, ec=BLUE, tc=BLUE, fs=9)
    adc = box(ax, (9.85, 1.05), 1.0, 0.55, "ADC", fc=PANEL, ec=BLUE, tc=BLUE, fs=9)
    arrow(ax, (pd_c[0], pd_c[1] - 0.32), (tia[0], tia[1] + 0.28), color=BLUE)
    arrow(ax, (tia[0] + 0.5, tia[1]), (adc[0] - 0.5, adc[1]), color=BLUE)
    label(ax, (tia[0] - 0.95, 1.33), "analog\ncurrent", fs=7.5, color=BLUE, ha="right")

    # ── 6. FPGA — closes the loop ───────────────────────────────────────────
    fpga = box(ax, (1.6, 0.7), 3.1, 1.5,
               "FPGA  (Artix-7)\npattern_sequencer · correlator\n"
               r"reconstruct:  $\hat{I}=\sum_i b_i H_i$",
               fc="#eef3ff", ec=BLUE, tc=DARK, fs=8.5)

    # FPGA -> DMD (load each pattern)
    arrow(ax, (fpga[0] + 0.7, fpga[1] + 0.75), (dmd_c[0] - 0.35, dmd_c[1] - 0.95),
          color=BLUE, lw=2.0)
    label(ax, (4.4, 3.1), "load pattern $H_i$\n(parallel RGB + I²C)", fs=8, color=BLUE)

    # ADC -> FPGA (read bucket value back), routed along y=0.95 to clear caption
    rib = 0.95
    arrow(ax, (adc[0], adc[1] - 0.28), (adc[0], rib), color=BLUE, lw=2.0)
    arrow(ax, (adc[0], rib), (fpga[0] + 1.55, rib), color=BLUE, lw=2.0)
    arrow(ax, (fpga[0] + 1.55, rib), (fpga[0] + 1.55, fpga[1] - 0.75), color=BLUE, lw=2.0)
    label(ax, (7.3, rib + 0.22), "read bucket value $b_i$", fs=8, color=BLUE)

    # ── Legend / the key idea ───────────────────────────────────────────────
    legend_handles = [
        Line2D([0], [0], color=GREEN, lw=6, alpha=0.6, label="laser / structured light"),
        Line2D([0], [0], color="#7fd49a", lw=5, alpha=0.6, label="diffuse scatter from object"),
        Line2D([0], [0], color=BLUE, lw=2, label="electrical (control / readout)"),
    ]
    ax.legend(handles=legend_handles, loc="upper right", fontsize=8.5,
              frameon=True, framealpha=0.95, edgecolor="#cccccc",
              bbox_to_anchor=(0.995, 0.93))

    # numbered flow caption along the bottom (two lines, kept clear of the rib)
    cap1 = ("(1) laser  →  (2) expander fills the DMD  →  (3) DMD mirrors carve the beam into pattern $H_i$  "
            "→  (4) pattern lights the object")
    cap2 = ("(5) single photodiode sums the returned light to one number $b_i$  "
            "→  (6) FPGA correlates {$H_i$} with {$b_i$} to reconstruct the image.")
    ax.text(0.2, -0.12, cap1, fontsize=7.5, color=GREY, ha="left", va="bottom")
    ax.text(0.2, -0.36, cap2, fontsize=7.5, color=GREY, ha="left", va="bottom")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT, dpi=170, bbox_inches="tight", facecolor="white")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    build()
