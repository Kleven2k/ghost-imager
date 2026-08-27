"""Digital phantom generation.

Produces ground-truth objects with optional temporal modulation for the
CGI feasibility simulator. The "object" is a 2-D map of absorption (higher
= more light absorbed = darker reconstruction); the time series modulates
selected pixels to simulate arterial pulsation.
"""
import numpy as np


def vessel_phantom(size=64):
    """A simple synthetic 'vessel' pattern.

    Returns a (size, size) array with values in [0, 1] representing local
    absorption. Background ~0.1, vessel pixels ~0.9.
    """
    img = np.full((size, size), 0.1, dtype=np.float32)

    # A diagonal "vessel"
    for i in range(size):
        col = int(0.3 * size + i * 0.4)
        if 0 <= col < size:
            img[i, col-1:col+2] = 0.9

    # A second curved "vessel"
    for i in range(size):
        col = int(0.7 * size - i * 0.2 + 5 * np.sin(i * 0.2))
        if 0 <= col < size:
            img[i, col-1:col+2] = 0.85

    return img


def letter_phantom(size=64, letter="G"):
    """A blocky letter as a phantom — easier to assess reconstruction quality visually."""
    img = np.full((size, size), 0.1, dtype=np.float32)

    if letter == "G":
        # Hand-drawn "G" using rectangles
        img[10:54, 10:18] = 0.9              # left vertical
        img[10:18, 10:54] = 0.9              # top horizontal
        img[46:54, 10:54] = 0.9              # bottom horizontal
        img[30:54, 46:54] = 0.9              # right partial vertical
        img[30:38, 32:54] = 0.9              # middle horizontal stub

    return img


def pulsatile_modulation(n_samples, fs=100.0, hr_bpm=72.0, amplitude=0.05):
    """Generate a heart-rate-like temporal modulation.

    Returns an array of length n_samples with mean 1.0 and a sinusoidal
    fluctuation at hr_bpm. Amplitude is fractional (0.05 = 5%).
    """
    t = np.arange(n_samples) / fs
    f = hr_bpm / 60.0
    return 1.0 + amplitude * np.sin(2 * np.pi * f * t)


def make_time_series_phantom(spatial, n_samples, vessel_mask=None,
                              fs=100.0, hr_bpm=72.0, amplitude=0.05):
    """Modulate selected pixels of a static phantom over time.

    Returns a (n_samples, H, W) cube. Pixels in vessel_mask pulse;
    other pixels are static. If vessel_mask is None, all "high-absorption"
    pixels (>0.5) pulse.
    """
    H, W = spatial.shape
    if vessel_mask is None:
        vessel_mask = spatial > 0.5

    mod = pulsatile_modulation(n_samples, fs, hr_bpm, amplitude)
    cube = np.broadcast_to(spatial, (n_samples, H, W)).copy()
    cube[:, vessel_mask] *= mod[:, None]
    return cube
