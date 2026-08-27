"""Depth × wavelength feasibility sweep.

Runs the CGI reconstruction across a grid of (depth, wavelength) combinations
and produces:
  1. A grid of reconstructions (one panel per cell)
  2. A heatmap of SNR vs depth and wavelength
  3. A printed table of SNR values

This is the figure to attach to the grant application.

Usage:
    python sw/sweep.py
"""
import numpy as np
import matplotlib.pyplot as plt

from phantom import letter_phantom
from scatter import apply_scatter, transmittance_factor
from reconstruct import (
    hadamard_patterns,
    simulate_bucket,
    reconstruct,
    reconstruction_snr,
    normalize_for_display,
)


# ── Sweep configuration ──────────────────────────────────────────────────────

SIZE         = 32
DEPTHS_MM    = [1.0, 2.0, 3.0, 5.0, 8.0]
WAVELENGTHS  = [532, 660, 750, 850]
PHOTON_COUNT = 2.5e4   # photons/pattern at the brightest, realistic for a
                       # 10 mW laser + APD + 250 µs/pattern + tissue losses
DARK_SIGMA   = 50.0    # APD dark + electronic noise floor
SEED         = 42


def run_cell(image, patterns, depth_mm, wavelength_nm, rng):
    """One (depth, wavelength) point. Returns (recon, snr)."""
    def scatter_fn(x):
        return apply_scatter(x, depth_mm=depth_mm, wavelength_nm=wavelength_nm)

    # Beer-Lambert transmittance: light that survives absorption to reach the
    # detector. Drops fast for green (high μa), slow for NIR (low μa).
    t = transmittance_factor(depth_mm=depth_mm, wavelength_nm=wavelength_nm)

    buckets = simulate_bucket(
        image, patterns,
        scatter_fn=scatter_fn,
        transmittance_factor=t,
        shot_noise=True,
        dark_sigma=DARK_SIGMA,
        photon_count=PHOTON_COUNT,
        rng=rng,
    )
    recon = reconstruct(patterns, buckets, image.shape)
    snr = reconstruction_snr(recon, image)
    return recon, snr


def main():
    img = letter_phantom(size=SIZE, letter="G")
    patterns = hadamard_patterns(SIZE * SIZE)

    n_d = len(DEPTHS_MM)
    n_w = len(WAVELENGTHS)

    print(f"Sweep: {n_d} depths × {n_w} wavelengths = {n_d * n_w} reconstructions")
    print(f"  image: {SIZE}×{SIZE}, patterns: {patterns.shape[0]}")
    print(f"  photon_count={PHOTON_COUNT:.1e}, dark_sigma={DARK_SIGMA}\n")

    recons = np.empty((n_d, n_w), dtype=object)
    snr_grid = np.zeros((n_d, n_w))

    # Same RNG seed per cell so the noise realization doesn't bias comparisons.
    for i, d in enumerate(DEPTHS_MM):
        for j, w in enumerate(WAVELENGTHS):
            rng = np.random.default_rng(SEED)
            recon, snr = run_cell(img, patterns, d, w, rng)
            recons[i, j] = normalize_for_display(recon)
            snr_grid[i, j] = snr
            print(f"  depth={d:4.1f} mm  λ={w} nm  →  SNR = {snr:6.2f} dB")

    # ── Figure 1: reconstruction grid ────────────────────────────────────────
    fig, axes = plt.subplots(n_d, n_w + 1, figsize=(2.4 * (n_w + 1), 2.4 * n_d))

    # Leftmost column: ground truth in every row for reference
    for i in range(n_d):
        axes[i, 0].imshow(img, cmap="gray", vmin=0, vmax=1)
        axes[i, 0].set_ylabel(f"{DEPTHS_MM[i]:.1f} mm", fontsize=10)
        axes[i, 0].set_xticks([])
        axes[i, 0].set_yticks([])
        if i == 0:
            axes[i, 0].set_title("Ground truth", fontsize=10)

    for i in range(n_d):
        for j in range(n_w):
            ax = axes[i, j + 1]
            ax.imshow(recons[i, j], cmap="gray", vmin=0, vmax=1)
            ax.set_xticks([])
            ax.set_yticks([])
            if i == 0:
                ax.set_title(f"{WAVELENGTHS[j]} nm", fontsize=10)
            ax.text(0.5, -0.12, f"{snr_grid[i, j]:.1f} dB",
                    transform=ax.transAxes, ha="center", fontsize=9)

    fig.suptitle(
        f"CGI reconstruction vs depth and wavelength  "
        f"(image: letter G, {SIZE}×{SIZE}, {patterns.shape[0]} Hadamard patterns)",
        fontsize=11,
    )
    plt.tight_layout()
    plt.savefig("sw/sweep_grid.png", dpi=120, bbox_inches="tight")
    print("\nSaved: sw/sweep_grid.png")

    # ── Figure 2: SNR heatmap + line plot ────────────────────────────────────
    fig2, (ax_h, ax_l) = plt.subplots(1, 2, figsize=(12, 4.5))

    im = ax_h.imshow(snr_grid, aspect="auto", cmap="viridis")
    ax_h.set_xticks(range(n_w))
    ax_h.set_xticklabels([f"{w}" for w in WAVELENGTHS])
    ax_h.set_yticks(range(n_d))
    ax_h.set_yticklabels([f"{d:.1f}" for d in DEPTHS_MM])
    ax_h.set_xlabel("Wavelength (nm)")
    ax_h.set_ylabel("Tissue depth (mm)")
    ax_h.set_title("Reconstruction SNR (dB)")
    for i in range(n_d):
        for j in range(n_w):
            ax_h.text(j, i, f"{snr_grid[i, j]:.1f}",
                      ha="center", va="center",
                      color="white" if snr_grid[i, j] < snr_grid.max() * 0.6 else "black",
                      fontsize=9)
    plt.colorbar(im, ax=ax_h, label="SNR (dB)")

    for j, w in enumerate(WAVELENGTHS):
        ax_l.plot(DEPTHS_MM, snr_grid[:, j], "o-", label=f"{w} nm")
    ax_l.set_xlabel("Tissue depth (mm)")
    ax_l.set_ylabel("Reconstruction SNR (dB)")
    ax_l.set_title("SNR vs depth, by wavelength")
    ax_l.axhline(0, color="gray", linestyle="--", alpha=0.5)
    ax_l.legend()
    ax_l.grid(alpha=0.3)

    plt.tight_layout()
    plt.savefig("sw/sweep_snr.png", dpi=120, bbox_inches="tight")
    print("Saved: sw/sweep_snr.png")

    plt.show()


if __name__ == "__main__":
    main()
