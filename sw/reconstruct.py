"""Classical CGI reconstruction + a tier-1 feasibility simulator.

Pipeline:
    ground-truth image
        × Hadamard pattern
        → scatter (Gaussian PSF)
        → sum over pixels → bucket value
        → add noise
        → feed N bucket values to the classical CGI inverse
        → compare reconstruction against ground truth

Run as a script to produce a side-by-side figure:
    no-scatter recon | with-scatter recon | ground truth

This is the same math as rtl/correlator.sv computes on the FPGA. Keeping
both in sync lets the hardware tests use this as a numpy reference.
"""
import numpy as np
from scipy.linalg import hadamard


def hadamard_patterns(n_pixels):
    """Generate a Hadamard pattern basis (rows of ±1 → {0, 1}).

    Returns a (n_patterns, n_pixels) array where each row is one binary
    pattern. n_pixels must be a power of 2 because hadamard() requires it.
    """
    H = hadamard(n_pixels)
    return ((H + 1) // 2).astype(np.int32)   # {-1, +1} → {0, 1}


def simulate_bucket(image, patterns, scatter_fn=None, transmittance_factor=1.0,
                    shot_noise=False, dark_sigma=0.0, photon_count=1e6,
                    rng=None):
    """For each pattern, produce a single bucket-detector reading.

    Args:
        image: (H, W) absorption map in [0, 1]. Higher → more absorption,
               so transmitted intensity = (1 - absorption) × pattern.
        patterns: (N, H*W) binary patterns, flattened.
        scatter_fn: optional callable applied to (pattern_2d * (1-image_2d))
                    before summing. None for the no-scattering baseline.
        shot_noise: add Poisson noise scaled by photon_count.
        dark_sigma: add Gaussian noise with this stddev.
        photon_count: nominal "full bucket" count for shot-noise scaling.

    Returns: (N,) bucket values.
    """
    if rng is None:
        rng = np.random.default_rng(0)

    H, W = image.shape
    transmittance = 1.0 - image      # absorbed → dark
    buckets = np.zeros(patterns.shape[0])

    for i, pat in enumerate(patterns):
        pat_2d = pat.reshape(H, W).astype(np.float32)
        # Scatter the *illumination pattern* before it interacts with the
        # object. Physically: light leaves the DMD as a sharp pattern, scatters
        # as it enters tissue, and the blurred pattern is what actually probes
        # the absorbers. This blurs CGI's spatial selectivity — the right
        # failure mode to model.
        if scatter_fn is not None:
            pat_2d = scatter_fn(pat_2d)
        illum = pat_2d * transmittance
        b = illum.sum()
        buckets[i] = b

    # Normalize so the brightest pattern is ~photon_count, then apply the
    # wavelength/depth-dependent Beer-Lambert transmittance (fewer photons
    # reach the detector at absorbing wavelengths). Only after this scaling
    # does shot noise carry the right relative weight.
    if buckets.max() > 0:
        buckets *= photon_count / buckets.max()
    buckets *= transmittance_factor
    if shot_noise:
        buckets = rng.poisson(np.clip(buckets, 0, None)).astype(np.float64)
    if dark_sigma > 0:
        buckets += rng.normal(0, dark_sigma, size=buckets.shape)

    return buckets


def reconstruct(patterns, buckets, shape):
    """Classical CGI reconstruction.

    Computes correlation: I_recon[p] = Σ_i (b_i - <b>) × pat_i[p]
    Equivalent to the FPGA's bram-accumulator math, but with a DC subtraction
    that improves contrast for non-zero-mean patterns.
    """
    b_mean = buckets.mean()
    acc = (patterns.T @ (buckets - b_mean))
    return acc.reshape(shape)


def normalize_for_display(img):
    """Rescale image to [0, 1] for plotting."""
    a, b = np.percentile(img, [2, 98])
    if b - a < 1e-12:
        return np.zeros_like(img)
    return np.clip((img - a) / (b - a), 0, 1)


def reconstruction_snr(recon, truth):
    """Crude SNR: signal energy of (truth) vs noise energy of (recon - matched truth).

    Match truth to recon via DC subtraction + scaling, then compute
    10*log10(signal_var / residual_var). Higher = recon closer to truth.
    """
    truth_n = truth - truth.mean()
    recon_n = recon - recon.mean()
    # Best scaling factor that minimises ||a*recon_n - truth_n||
    a = (recon_n * truth_n).sum() / max((recon_n**2).sum(), 1e-12)
    residual = a * recon_n - truth_n
    sig_var = (truth_n**2).sum()
    err_var = (residual**2).sum()
    if err_var < 1e-12:
        return float("inf")
    return 10 * np.log10(sig_var / err_var)


# ── Script entry point ───────────────────────────────────────────────────────

if __name__ == "__main__":
    import matplotlib.pyplot as plt
    from phantom import letter_phantom
    from scatter import apply_scatter

    SIZE = 32                      # 32×32 = 1024 patterns; manageable on a laptop
    DEPTH_MM = 3.0                 # how far through tissue
    WAVELENGTH_NM = 850

    img = letter_phantom(size=SIZE, letter="G")
    patterns = hadamard_patterns(SIZE * SIZE)

    def scatter_fn(x):
        return apply_scatter(x, depth_mm=DEPTH_MM, wavelength_nm=WAVELENGTH_NM)

    print(f"Simulating CGI through {DEPTH_MM} mm tissue at {WAVELENGTH_NM} nm…")
    print(f"  pattern count: {patterns.shape[0]}")

    # Three conditions
    rng = np.random.default_rng(42)

    b_clean = simulate_bucket(img, patterns, scatter_fn=None,
                              shot_noise=False, rng=rng)
    b_scatter = simulate_bucket(img, patterns, scatter_fn=scatter_fn,
                                shot_noise=False, rng=rng)
    b_scatter_noisy = simulate_bucket(img, patterns, scatter_fn=scatter_fn,
                                      shot_noise=True, dark_sigma=10.0,
                                      photon_count=1e5, rng=rng)

    recon_clean   = reconstruct(patterns, b_clean,         (SIZE, SIZE))
    recon_scatter = reconstruct(patterns, b_scatter,       (SIZE, SIZE))
    recon_noisy   = reconstruct(patterns, b_scatter_noisy, (SIZE, SIZE))

    print(f"  SNR no-scatter:           {reconstruction_snr(recon_clean,   img):6.2f} dB")
    print(f"  SNR with scatter:         {reconstruction_snr(recon_scatter, img):6.2f} dB")
    print(f"  SNR with scatter + noise: {reconstruction_snr(recon_noisy,   img):6.2f} dB")

    # Figure
    fig, axes = plt.subplots(1, 4, figsize=(14, 4))
    for ax, data, title in zip(
        axes,
        [img,
         normalize_for_display(recon_clean),
         normalize_for_display(recon_scatter),
         normalize_for_display(recon_noisy)],
        ["Ground truth",
         "Recon (no scatter, no noise)",
         f"Recon ({DEPTH_MM} mm tissue, no noise)",
         f"Recon (tissue + shot+dark noise)"],
    ):
        ax.imshow(data, cmap="gray", vmin=0, vmax=1)
        ax.set_title(title, fontsize=10)
        ax.axis("off")

    plt.tight_layout()
    plt.savefig("sw/feasibility_figure.png", dpi=120)
    print("\nSaved: sw/feasibility_figure.png")
    plt.show()
