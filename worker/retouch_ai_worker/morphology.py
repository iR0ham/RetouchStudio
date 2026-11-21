"""Binary morphology and Gaussian feathering, in NumPy.

The worker used OpenCV for exactly two operations: an elliptical dilation and a
Gaussian blur. The macOS OpenCV wheel links a GPL-configured FFmpeg (x264/x265),
which cannot ship in the app bundle, so both live here now.

The definitions are OpenCV's, not an approximation of them:

* `ellipse_kernel` reproduces `cv2.getStructuringElement(MORPH_ELLIPSE, (2r+1,
  ...))`: row `y` is filled from `r-half` to `r+half` with
  `half = rint(r * sqrt((r² - y²) / r²))`.
* `dilate_binary` is a max filter with a zero border, which is what
  `cv2.dilate` does to a uint8 plane.
* `gaussian_kernel` derives its size the way OpenCV does for `(0, 0)` and a
  sigma: `ksize = int(rint(sigma * 8 + 1)) | 1`, weights `exp(-0.5x²/σ²)`
  normalised in float32.
* `gaussian_blur` runs the two separable passes with BORDER_REFLECT_101 on both
  axes, including across a one-row or one-column plane.

Both filters crop to the support of their input and copy back into a
full-size zero plane. Outside the crop the answer is zero either way — a zero
border and a zero plane agree — so the result is identical to filtering the
whole frame, without the full-frame cost.
"""

from __future__ import annotations

import numpy as np


def ellipse_kernel(radius: int) -> np.ndarray:
    """A 0/1 uint8 elliptical element of size (2r+1, 2r+1)."""
    r = int(radius)
    if r < 0:
        raise ValueError("radius must be non-negative")
    kernel = np.zeros((2 * r + 1, 2 * r + 1), np.uint8)
    if r == 0:
        kernel[0, 0] = 1
        return kernel
    rows = np.arange(-r, r + 1)
    half = np.rint(r * np.sqrt((r * r - rows * rows) / float(r * r))).astype(int)
    for i, h in enumerate(half):
        kernel[i, r - h:r + h + 1] = 1
    return kernel


def dilate_binary(binary: np.ndarray, kernel: np.ndarray) -> np.ndarray:
    """Dilate a 0/1 plane with a zero border, returning the same dtype."""
    src = np.ascontiguousarray(binary, dtype=np.uint8)
    ky, kx = kernel.shape[0] // 2, kernel.shape[1] // 2
    ys, xs = np.nonzero(src)
    if ys.size == 0:
        return np.zeros_like(src)
    y0, y1 = max(0, int(ys.min()) - ky), min(src.shape[0], int(ys.max()) + ky + 1)
    x0, x1 = max(0, int(xs.min()) - kx), min(src.shape[1], int(xs.max()) + kx + 1)
    region = src[y0:y1, x0:x1]
    height, width = region.shape
    padded = np.pad(region, ((ky, ky), (kx, kx)))
    out = np.zeros_like(region)
    for dy, dx in zip(*np.nonzero(kernel)):
        oy, ox = dy - ky, dx - kx
        np.maximum(out, padded[ky + oy:ky + oy + height, kx + ox:kx + ox + width],
                   out=out)
    result = np.zeros_like(src)
    result[y0:y1, x0:x1] = out
    return result


def gaussian_kernel(sigma: float) -> np.ndarray:
    """The float32 1-D kernel OpenCV builds for `(0, 0)` and this sigma."""
    if not sigma > 0:
        raise ValueError("sigma must be positive")
    size = int(np.rint(sigma * 8 + 1)) | 1
    x = np.arange(size) - (size - 1) / 2.0
    weights = np.exp(-0.5 * x * x / (sigma * sigma))
    return (weights / weights.sum()).astype(np.float32)


def _reflect101_index(length: int, pad: int) -> np.ndarray:
    """Sample positions for BORDER_REFLECT_101, folded as often as needed."""
    index = np.arange(-pad, length + pad)
    if length == 1:
        return np.zeros(index.size, dtype=int)
    while True:
        negative, overflow = index < 0, index >= length
        if not negative.any() and not overflow.any():
            return index
        index = np.where(negative, -index, index)
        index = np.where(index >= length, 2 * length - 2 - index, index)


def _blur1d(plane: np.ndarray, kernel: np.ndarray, axis: int) -> np.ndarray:
    length, pad = plane.shape[axis], kernel.size // 2
    padded = np.take(plane, _reflect101_index(length, pad), axis=axis)
    out = np.zeros_like(plane)
    for i, weight in enumerate(kernel):
        if axis == 0:
            out += np.float32(weight) * padded[i:i + length, :]
        else:
            out += np.float32(weight) * padded[:, i:i + length]
    return out


def gaussian_blur(plane: np.ndarray, sigma: float) -> np.ndarray:
    """Separable Gaussian blur, float32 in and out, BORDER_REFLECT_101."""
    source = np.ascontiguousarray(plane, dtype=np.float32)
    kernel = gaussian_kernel(sigma)
    return _blur1d(_blur1d(source, kernel, 0), kernel, 1)
