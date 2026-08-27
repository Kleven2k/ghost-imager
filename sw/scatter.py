"""Scattering models — Tier 1 (Gaussian PSF approximation).

The diffusion approximation for thick tissue says a delta-function input
produces an output that is approximately Gaussian-blurred. The kernel width
σ scales with tissue depth and reduced scattering coefficient μs'.

This is a stand-in for Monte Carlo simulation (MCX) — Tier 2 work. It's
much faster, easier to reason about, and gives a useful first-order answer.

References:
- Jacques, "Optical properties of biological tissues: a review" (2013)
  for typical μa / μs' values at NIR wavelengths.
- Wang & Wu, "Biomedical Optics: Principles and Imaging" — diffusion eqn.
"""
import numpy as np
from scipy.ndimage import gaussian_filter


# Typical tissue optical properties at NIR (per Jacques 2013).
# μa = absorption, μs' = reduced scattering, both in mm⁻¹.
TISSUE_PROPS = {
    750:  {"mu_a": 0.03, "mu_s_prime": 1.2},   # 750 nm — deeper penetration
    850:  {"mu_a": 0.04, "mu_s_prime": 1.0},   # 850 nm — common NIR
    660:  {"mu_a": 0.05, "mu_s_prime": 1.5},   # 660 nm — red, used in PPG
    532:  {"mu_a": 0.20, "mu_s_prime": 2.5},   # 532 nm — green, surface only
}


def gaussian_psf_sigma(depth_mm, mu_s_prime):
    """Approximate Gaussian PSF width (in mm) for given depth and μs'.

    From diffusion theory: the diffuse photon distribution from a point source
    at depth d in a slab with reduced scattering coefficient μs' has a
    lateral spread σ ~ √(depth × mean_free_path) = √(depth / μs').

    Wait — that gives lower-μs' → wider spread, which is correct: photons
    travel further per scatter, so their lateral excursion is larger. NIR
    (lower μs') therefore produces wider blur than green (higher μs') at
    the same depth. This is opposite to "less scattering = sharper image":
    in the diffuse regime, less scattering means each photon walks further
    sideways before being collected.
    """
    return np.sqrt(depth_mm / max(mu_s_prime, 1e-6))


def apply_scatter(image, depth_mm, wavelength_nm=850, pixel_pitch_mm=0.5):
    """Apply Gaussian-PSF scattering to an image.

    Args:
        image: (H, W) absorption map
        depth_mm: tissue depth the light traveled through
        wavelength_nm: laser wavelength (selects optical properties)
        pixel_pitch_mm: physical size of one pixel on the target plane
    """
    props = TISSUE_PROPS.get(wavelength_nm)
    if props is None:
        raise ValueError(f"Unknown wavelength {wavelength_nm}; add it to TISSUE_PROPS")

    sigma_mm = gaussian_psf_sigma(depth_mm, props["mu_s_prime"])
    sigma_px = sigma_mm / pixel_pitch_mm
    return gaussian_filter(image, sigma=sigma_px)


def transmittance_factor(depth_mm, wavelength_nm=850):
    """Beer-Lambert transmittance through tissue at this wavelength and depth.

    Returns the fraction of input light that survives μa * depth absorption.
    Useful as a multiplicative attenuation in the photon-budget calculation.
    """
    props = TISSUE_PROPS.get(wavelength_nm)
    if props is None:
        raise ValueError(f"Unknown wavelength {wavelength_nm}")
    return np.exp(-props["mu_a"] * depth_mm)
