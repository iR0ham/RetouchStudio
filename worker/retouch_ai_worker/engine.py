"""Job engines: what the worker can actually do.

Heavy imports (mlx, torch, mflux, sam2) are lazy and happen inside the job, so
the protocol, catalog and UI paths work on a machine where the models were never
installed, and unit tests never touch a GPU.

Every job writes its artefacts to its own directory and returns paths plus
measurements. The input photo is decoded from shared memory, a data URL or an
allowed path, and is never written back.
"""
from __future__ import annotations

import os
import queue
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image

from .catalog import Catalog
from .protocol import BUDGET_EXCEEDED, INVALID_PARAMS, WorkerError
from .transport import BufferRegistry, read_image

MULTIPLE = 16
# MI-GAN's 512 pipeline is a texture filler, not a scene painter: past a
# quarter of the frame its output turns to mush, so larger holes go to FLUX.
INPAINT_MAX_FRACTION = 0.25
# Swin2SR x4 tiles: 256 input is the fastest measured size on MPS here
# (6.2 s per tile; 128 costs 1.4 s but needs 4x the tiles, 512 costs 27 s).
# The overlap is blended so the same texture does not restart at a tile edge.
UPSCALE_TILE = 256
UPSCALE_MAX_OUTPUT = 40_000_000
MEMORY_BUDGET_GB = float(os.environ.get("RETOUCH_AI_MEMORY_BUDGET_GB", "7.5"))
MLX_CACHE_GB = float(os.environ.get("RETOUCH_AI_MLX_CACHE_GB", "4.0"))
# Weights that get paged out cost seconds per denoising step. Wiring them keeps
# a job stable at ~5 GB instead of letting the system swap them between jobs.
MLX_WIRED_GB = float(os.environ.get("RETOUCH_AI_MLX_WIRED_GB", "6.0"))


class Cancelled(Exception):
    pass


@dataclass
class Context:
    job_id: str
    workdir: Path
    cancel: Callable[[], bool]
    progress: Callable[[dict], None]
    allow_roots: tuple[Path, ...] = ()
    buffers: BufferRegistry | None = None
    out_shm: str | None = None
    metrics: dict = field(default_factory=dict)

    def emit(self, stage: str, **fields) -> None:
        self.progress({"stage": stage, **fields})

    def check_cancel(self) -> None:
        if self.cancel():
            raise Cancelled(self.job_id)

    def image(self, params: dict, key: str) -> np.ndarray:
        if key not in params:
            raise WorkerError(INVALID_PARAMS, f"{key} is required")
        return read_image(params[key], self.allow_roots, self.workdir)

    def publish(self, array: np.ndarray) -> dict:
        if self.buffers is None or not self.out_shm:
            return {}
        return self.buffers.publish(self.out_shm, array)


def _square_box(mask: np.ndarray, context: float, width: int, height: int) -> tuple[int, int, int, int]:
    ys, xs = np.nonzero(mask > 127)
    if xs.size == 0:
        raise WorkerError(INVALID_PARAMS, "mask is empty")
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()), int(ys.max())
    pad = int(round(max(x1 - x0, y1 - y0) * context))
    x0, x1 = max(0, x0 - pad), min(width, x1 + pad + 1)
    y0, y1 = max(0, y0 - pad), min(height, y1 + pad + 1)
    side = max(x1 - x0, y1 - y0)
    x0 = max(0, min(width - side, x0 - (side - (x1 - x0)) // 2))
    y0 = max(0, min(height - side, y0 - (side - (y1 - y0)) // 2))
    x1, y1 = min(width, x0 + side), min(height, y0 + side)
    return x0, y0, x1, y1


def _snap(value: float) -> int:
    return max(MULTIPLE, int(round(value / MULTIPLE) * MULTIPLE))


def region_alpha(mask: np.ndarray, dilate: int = 4, feather: int = 2) -> np.ndarray:
    """The only pixels an edit may touch, as 0…1 alpha.

    The feather is forced to zero outside the dilated mask, so a resampled
    version of this plane can never bleed past the authorized region.
    """
    import cv2

    binary = (mask > 127).astype(np.uint8)
    if dilate > 0:
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (dilate * 2 + 1, dilate * 2 + 1))
        binary = cv2.dilate(binary, kernel)
    alpha = binary.astype(np.float32)
    if feather > 0:
        alpha = cv2.GaussianBlur(alpha, (0, 0), feather)
        alpha[binary == 0] = 0.0
    return alpha


def composite(original: np.ndarray, generated: np.ndarray, mask: np.ndarray,
              dilate: int = 4, feather: int = 2) -> tuple[np.ndarray, np.ndarray]:
    """Strict compositor: outside dilate(mask) the original bytes survive."""
    alpha = region_alpha(mask, dilate, feather)
    out = original.copy()
    region = alpha > 0
    if region.any():
        a = alpha[..., None]
        blended = original.astype(np.float32) * (1 - a) + generated.astype(np.float32) * a
        out[region] = np.clip(blended[region], 0, 255).astype(np.uint8)
    return out, region


def mask_policy(fraction: float) -> str:
    """Which rendering path a mask may use.

    Evidence: a mask that wraps around the subject produced seams in patch mode
    even at 8 % coverage, while a full-frame render at native size was clean.
    Keep patch rendering for genuinely small masks until the Phase 1 quality set
    says otherwise.
    """
    if fraction <= 0.06:
        return "patch"
    if fraction <= 0.45:
        return "full-frame"
    return "too-large"


def _axis_tiles(length: int, tile: int, overlap: int) -> list[tuple[int, int]]:
    """Tile spans along one axis, each at most `tile` long.

    The last span is moved back to the edge rather than left short, so every
    tile has the same amount of context; that grows the overlap with its
    neighbour, which the weights below account for.
    """
    if length <= tile:
        return [(0, length)]
    step = max(1, tile - overlap)
    starts = list(range(0, length - tile + 1, step))
    if starts[-1] + tile < length:
        starts.append(length - tile)
    return [(s, s + tile) for s in starts]


def _axis_plan(length: int, tile: int, overlap: int) -> list[tuple[int, int, np.ndarray]]:
    """Spans plus per-pixel weights whose complementary ramps sum to one in
    every overlap. Without this, the tile that was written last would win at a
    hard edge and leave a visible seam."""
    spans = _axis_tiles(length, tile, overlap)
    plans = []
    for index, (start, end) in enumerate(spans):
        weight = np.ones(end - start, dtype=np.float32)
        if index > 0:
            span = min(spans[index - 1][1] - start, end - start)
            if span > 0:
                weight[:span] = np.linspace(0, 1, span + 1,
                                            dtype=np.float32)[:-1]
        if index + 1 < len(spans):
            span = min(end - spans[index + 1][0], end - start)
            if span > 0:
                weight[-span:] = np.minimum(
                    weight[-span:],
                    np.linspace(0, 1, span + 1, dtype=np.float32)[:-1][::-1])
        plans.append((start, end, weight))
    return plans


SWIN_WINDOW = 8


def _pad_to_window(array: np.ndarray, window: int = SWIN_WINDOW) -> tuple[np.ndarray, int, int]:
    """Reflect-pad the bottom and right edges up to the window size.

    Swin2SR splits its input into non-overlapping windows, so every tile has to
    be a whole number of windows. Tiles cut from a large photo are all `tile`
    wide, but the final tile of a small photo is the photo itself, which may be
    any size. The returned height and width are the unpadded ones, so the
    caller can cut the matching region out of the 4x output.
    """
    height, width = array.shape[:2]
    pad_y, pad_x = (-height) % window, (-width) % window
    if pad_y or pad_x:
        array = np.pad(array, ((0, pad_y), (0, pad_x), (0, 0)), mode="reflect")
    return array, height, width


class Engine:
    def __init__(self, catalog: Catalog, allow_roots: tuple[Path, ...] = ()) -> None:
        self.catalog = catalog
        self.allow_roots = allow_roots
        self._flux = None
        self._sam = None
        self._sam_source = None
        self._migan = None
        self._swin = None
        self._active: Context | None = None
        self._work: queue.Queue = queue.Queue()
        self._runner = threading.Thread(target=self._loop, name="engine", daemon=True)
        self._runner.start()

    def run(self, kind: str, params: dict, ctx: Context) -> dict:
        handler = getattr(self, f"_job_{kind}", None)
        if handler is None:
            raise WorkerError(INVALID_PARAMS, f"unknown job kind {kind!r}")
        # MLX streams and torch device state are thread-local, and a model built
        # on one thread cannot be used from another. Every job therefore runs on
        # this one engine thread, whatever connection submitted it.
        return self._execute_on_engine(handler, params, ctx)

    def _loop(self) -> None:
        while True:
            handler, params, ctx, reply = self._work.get()
            try:
                reply.put((True, self._execute(handler, params, ctx)))
            except BaseException as exc:  # noqa: BLE001 - re-raised on the caller
                reply.put((False, exc))

    def _execute_on_engine(self, handler, params: dict, ctx: Context):
        reply: queue.Queue = queue.Queue(maxsize=1)
        self._work.put((handler, params, ctx, reply))
        ok, value = reply.get()
        if ok:
            return value
        raise value

    def _execute(self, handler, params: dict, ctx: Context) -> dict:
        self._active = ctx
        try:
            return handler(params, ctx)
        finally:
            self._active = None

    # ------------------------------------------------------------------
    def _job_ping(self, params: dict, ctx: Context) -> dict:
        import platform

        return {"pong": True, "machine": platform.machine(), "pid": os.getpid()}

    # ------------------------------------------------------------------
    def _job_mask(self, params: dict, ctx: Context) -> dict:
        image = ctx.image(params, "image")
        height, width = image.shape[:2]
        points = params.get("points") or []
        box = params.get("box")
        if not points and not box:
            raise WorkerError(INVALID_PARAMS, "points or box are required for a mask job")
        box_array = None
        if box is not None:
            if (not isinstance(box, (list, tuple)) or len(box) != 4
                    or any(not isinstance(v, (int, float)) for v in box)):
                raise WorkerError(INVALID_PARAMS, "box must be [x0, y0, x1, y1]")
            x0, y0, x1, y1 = (float(v) for v in box)
            if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
                raise WorkerError(INVALID_PARAMS, "box is outside the image",
                                  {"box": [x0, y0, x1, y1], "size": [width, height]})
            box_array = np.array([x0, y0, x1, y1], dtype=np.float32)
        self._ensure_sam()
        started = time.perf_counter()
        if self._sam_source is None or not np.array_equal(self._sam_source, image):
            self._sam.set_image(image)
            self._sam_source = image
        encode_s = time.perf_counter() - started
        ctx.check_cancel()
        coords = labels = None
        if points:
            coords = np.array([[float(p[0]), float(p[1])] for p in points], dtype=np.float32)
            labels = np.array([int(p[2]) if len(p) > 2 else 1 for p in points], dtype=np.int32)
        started = time.perf_counter()
        masks, scores, _ = self._sam.predict(point_coords=coords, point_labels=labels,
                                             box=box_array,
                                             multimask_output=False)
        prompt_s = time.perf_counter() - started
        mask = (masks[0] > 0) if masks.ndim == 3 else (masks > 0)
        mask_u8 = (mask.astype(np.uint8) * 255)
        target = ctx.workdir / "mask.png"
        Image.fromarray(mask_u8).save(target)
        return {"mask": str(target), "encode_s": round(encode_s, 3),
                "prompt_s": round(prompt_s, 3), "score": float(np.ravel(scores)[0]),
                "fraction": float(mask.mean()), "size": [width, height],
                **ctx.publish(mask_u8)}

    # ------------------------------------------------------------------
    def _job_patch_edit(self, params: dict, ctx: Context) -> dict:
        source = ctx.image(params, "image")
        height, width = source.shape[:2]

        # An explicit full-frame request comes from a preset that redraws the
        # whole picture, so it has no mask to measure and no policy to apply.
        if params.get("full_frame"):
            prompt = str(params.get("prompt") or "").strip()
            if not prompt:
                raise WorkerError(INVALID_PARAMS, "prompt is required")
            return self._full_frame(source, prompt, params, ctx, 1.0)

        if params.get("mask"):
            mask = ctx.image(params, "mask")
            mask = np.array(Image.fromarray(mask).convert("L"))
            if mask.shape != (height, width):
                mask = np.array(Image.fromarray(mask).resize((width, height), Image.NEAREST))
        else:
            result = self._job_mask(params, ctx)
            with Image.open(result["mask"]) as image:
                mask = np.array(image.convert("L"))

        fraction = float((mask > 127).mean())
        engine = str(params.get("engine") or "patch")
        if fraction <= 0:
            raise WorkerError(INVALID_PARAMS, "mask is empty")
        if engine == "inpaint" or (engine == "auto" and fraction <= INPAINT_MAX_FRACTION):
            return self._inpaint(source, mask, params, ctx)
        if engine not in ("patch", "auto"):
            raise WorkerError(INVALID_PARAMS, f"unknown engine {engine!r}")
        policy = mask_policy(fraction)
        if policy == "too-large":
            raise WorkerError(INVALID_PARAMS,
                              "mask covers too much of the frame for a generative edit",
                              {"fraction": round(fraction, 3)})

        prompt = str(params.get("prompt") or "").strip()
        if not prompt:
            raise WorkerError(INVALID_PARAMS, "prompt is required")

        if policy == "full-frame":
            return self._full_frame(source, prompt, params, ctx, fraction)

        patch_long = int(params.get("patch", 512))
        x0, y0, x1, y1 = _square_box(mask, float(params.get("context", 0.25)), width, height)
        crop = source[y0:y1, x0:x1]
        patch_w = _snap(patch_long * crop.shape[1] / max(crop.shape[:2]))
        patch_h = _snap(patch_long * crop.shape[0] / max(crop.shape[:2]))
        crop_path = ctx.workdir / "crop.png"
        Image.fromarray(crop).resize((patch_w, patch_h), Image.LANCZOS).save(crop_path)

        model = self._ensure_flux(ctx)
        ctx.check_cancel()
        started = time.perf_counter()
        generated = self._generate(model, prompt, crop_path, patch_w, patch_h, params, ctx)
        generate_s = time.perf_counter() - started

        patch = generated.convert("RGB").resize((x1 - x0, y1 - y0), Image.LANCZOS)
        full = source.copy()
        full[y0:y1, x0:x1] = np.array(patch)
        dilate, feather = int(params.get("dilate", 4)), int(params.get("feather", 2))
        out, region = composite(source, full, mask, dilate, feather)
        alpha = region_alpha(mask, dilate, feather)
        outside_identical = bool(np.array_equal(out[~region], source[~region]))

        # One rectangle carries both the edited pixels and their alpha, so the
        # app can re-composite the same edit at export size without guessing
        # where the blend ends. The margin covers the blur's tail; the alpha is
        # exactly zero there, so nothing outside the dilation can change.
        margin = dilate + int(np.ceil(feather * 3))
        ex0, ey0 = max(0, x0 - margin), max(0, y0 - margin)
        ex1, ey1 = min(width, x1 + margin), min(height, y1 + margin)
        result_path = ctx.workdir / "result.png"
        Image.fromarray(out).save(result_path)
        patch_path = ctx.workdir / "patch.png"
        Image.fromarray(full[ey0:ey1, ex0:ex1]).save(patch_path)
        alpha_path = ctx.workdir / "alpha.png"
        Image.fromarray(np.round(alpha[ey0:ey1, ex0:ex1] * 255).astype(np.uint8)).save(alpha_path)
        return {
            "output": str(result_path),
            "mode": "patch",
            "patch": str(patch_path),
            "alpha": str(alpha_path),
            "box": [ex0, ey0, ex1, ey1],
            "image_size": [width, height],
            "dilate": dilate,
            "feather": feather,
            "patch_size": [patch_w, patch_h],
            "bbox": [x0, y0, x1, y1],
            "outside_pixels_identical": outside_identical,
            "changed_pixels": int((out != source).any(axis=2).sum()),
            "mask_fraction": round(fraction, 4),
            "authorized_fraction": round(float(region.mean()), 4),
            "generate_s": round(generate_s, 2),
            **ctx.publish(out),
        }

    # ------------------------------------------------------------------
    def _job_inpaint(self, params: dict, ctx: Context) -> dict:
        source = ctx.image(params, "image")
        height, width = source.shape[:2]
        mask = ctx.image(params, "mask")
        mask = np.array(Image.fromarray(mask).convert("L"))
        if mask.shape != (height, width):
            mask = np.array(Image.fromarray(mask).resize((width, height), Image.NEAREST))
        return self._inpaint(source, mask, params, ctx)

    def _inpaint(self, source: np.ndarray, mask: np.ndarray,
                 params: dict, ctx: Context) -> dict:
        height, width = source.shape[:2]
        fraction = float((mask > 127).mean())
        if fraction <= 0:
            raise WorkerError(INVALID_PARAMS, "mask is empty")
        if fraction > INPAINT_MAX_FRACTION:
            raise WorkerError(INVALID_PARAMS,
                              "mask is too large for the inpaint model",
                              {"fraction": round(fraction, 3),
                               "limit": INPAINT_MAX_FRACTION})

        session = self._ensure_migan()
        # The author's pipeline takes 255 for known pixels and 0 for the hole.
        known = np.where(mask > 127, 0, 255).astype(np.uint8)
        image_input = np.ascontiguousarray(source.transpose(2, 0, 1)[None])
        ctx.check_cancel()
        ctx.emit("inpaint", engine="migan")
        started = time.perf_counter()
        generated = session.run(None, {"image": image_input,
                                       "mask": known[None, None]})[0]
        generate_s = time.perf_counter() - started
        generated = np.transpose(generated[0], (1, 2, 0))
        if generated.shape[:2] != (height, width):
            generated = np.array(Image.fromarray(generated).resize((width, height),
                                                                  Image.LANCZOS))

        dilate, feather = int(params.get("dilate", 4)), int(params.get("feather", 2))
        out, region = composite(source, generated, mask, dilate, feather)
        alpha = region_alpha(mask, dilate, feather)
        outside_identical = bool(np.array_equal(out[~region], source[~region]))

        ys, xs = np.nonzero(mask > 127)
        bx0, by0 = int(xs.min()), int(ys.min())
        bx1, by1 = int(xs.max()) + 1, int(ys.max()) + 1
        ay, ax = np.nonzero(alpha > 0)
        ex0, ey0 = int(ax.min()), int(ay.min())
        ex1, ey1 = int(ax.max()) + 1, int(ay.max()) + 1

        result_path = ctx.workdir / "result.png"
        Image.fromarray(out).save(result_path)
        patch_path = ctx.workdir / "patch.png"
        Image.fromarray(generated[ey0:ey1, ex0:ex1]).save(patch_path)
        alpha_path = ctx.workdir / "alpha.png"
        Image.fromarray(np.round(alpha[ey0:ey1, ex0:ex1] * 255).astype(np.uint8)).save(alpha_path)
        return {
            "output": str(result_path),
            "mode": "patch",
            "engine": "inpaint",
            "patch": str(patch_path),
            "alpha": str(alpha_path),
            "box": [ex0, ey0, ex1, ey1],
            "image_size": [width, height],
            "dilate": dilate,
            "feather": feather,
            "bbox": [bx0, by0, bx1, by1],
            "outside_pixels_identical": outside_identical,
            "changed_pixels": int((out != source).any(axis=2).sum()),
            "mask_fraction": round(fraction, 4),
            "authorized_fraction": round(float(region.mean()), 4),
            "generate_s": round(generate_s, 2),
            **ctx.publish(out),
        }

    # ------------------------------------------------------------------
    def _full_frame(self, source: np.ndarray, prompt: str, params: dict,
                    ctx: Context, fraction: float) -> dict:
        height, width = source.shape[:2]
        max_side = int(params.get("max_side", 1024))
        scale = min(1.0, max_side / max(width, height))
        render_w = _snap(width * scale)
        render_h = _snap(height * scale)
        reference = ctx.workdir / "reference.png"
        Image.fromarray(source).resize((render_w, render_h), Image.LANCZOS).save(reference)

        model = self._ensure_flux(ctx)
        ctx.check_cancel()
        started = time.perf_counter()
        generated = self._generate(model, prompt, reference, render_w, render_h, params, ctx)
        generate_s = time.perf_counter() - started
        out = np.array(generated.convert("RGB").resize((width, height), Image.LANCZOS))
        result_path = ctx.workdir / "result.png"
        Image.fromarray(out).save(result_path)
        return {
            "output": str(result_path),
            "mode": "full-frame",
            "render_size": [render_w, render_h],
            "mask_fraction": round(fraction, 4),
            "generate_s": round(generate_s, 2),
            **ctx.publish(out),
        }

    # ------------------------------------------------------------------
    def _generate(self, model, prompt: str, reference: Path, width: int, height: int,
                  params: dict, ctx: Context):
        peak = 4.0 + (width * height) / (1024 * 1024) * 3.2
        if peak > MEMORY_BUDGET_GB:
            raise WorkerError(BUDGET_EXCEEDED,
                              "estimated peak memory exceeds the budget",
                              {"estimated_gb": round(peak, 2), "budget_gb": MEMORY_BUDGET_GB})
        generated = model.generate_image(
            seed=int(params.get("seed", 42)),
            prompt=prompt,
            num_inference_steps=int(params.get("steps", 4)),
            width=width,
            height=height,
            guidance=float(params.get("guidance", 1.0)),
            image_paths=[str(reference)],
        )
        return generated.image

    # ------------------------------------------------------------------
    def _job_upscale(self, params: dict, ctx: Context) -> dict:
        import torch

        source = ctx.image(params, "image")
        tile = int(params.get("tile", UPSCALE_TILE))
        tile = max(64, min(512, tile))
        overlap = max(8, tile // 16)
        height, width = source.shape[:2]
        scale = 4
        if height * width * scale * scale > UPSCALE_MAX_OUTPUT:
            raise WorkerError(
                INVALID_PARAMS, "upscaled image would be too large",
                {"pixels": height * width * scale * scale,
                 "limit": UPSCALE_MAX_OUTPUT})

        model, device = self._ensure_swin()

        rows = _axis_plan(height, tile, overlap)
        cols = _axis_plan(width, tile, overlap)
        total = len(rows) * len(cols)
        started = time.perf_counter()
        acc = np.zeros((height * scale, width * scale, 3), dtype=np.float32)
        weights = np.zeros((height * scale, width * scale), dtype=np.float32)

        done = 0
        for y0, y1, wy in rows:
            for x0, x1, wx in cols:
                ctx.check_cancel()
                rgb = source[y0:y1, x0:x1].astype(np.float32) / 255.0
                padded, tile_h, tile_w = _pad_to_window(rgb)
                tensor = torch.from_numpy(padded).permute(2, 0, 1)[None].to(device)
                with torch.no_grad():
                    generated = model(tensor).reconstruction[0]
                generated = generated[:, :tile_h * scale, :tile_w * scale]
                generated = generated.permute(1, 2, 0).clamp(0, 1).cpu().numpy()
                weight = np.outer(np.repeat(wy, scale), np.repeat(wx, scale))
                oy0, ox0 = y0 * scale, x0 * scale
                acc[oy0:oy0 + weight.shape[0], ox0:ox0 + weight.shape[1]] += \
                    generated * weight[..., None]
                weights[oy0:oy0 + weight.shape[0], ox0:ox0 + weight.shape[1]] += weight
                done += 1
                ctx.emit("upscale", tile=done, tiles=total)

        weights[weights == 0] = 1.0
        output = np.clip(acc / weights[..., None], 0, 1)
        result = ctx.workdir / "upscaled.png"
        Image.fromarray((output * 255).round().astype(np.uint8)).save(result)
        return {"output": str(result), "scale": scale, "device": device,
                "tile": tile, "overlap": overlap, "tiles": total,
                "image_size": [width, height],
                "output_size": [width * scale, height * scale],
                "seconds": round(time.perf_counter() - started, 2),
                **ctx.publish((output * 255).round().astype(np.uint8))}

    # ------------------------------------------------------------------
    def _ensure_swin(self):
        if self._swin is not None:
            return self._swin
        import torch
        from transformers import Swin2SRForImageSuperResolution

        root = self.catalog.require("swin2sr-x4")
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        model = Swin2SRForImageSuperResolution.from_pretrained(
            str(root), local_files_only=True).to(device).eval()
        self._swin = (model, device)
        return self._swin

    # ------------------------------------------------------------------
    def _ensure_sam(self) -> None:
        if self._sam is not None:
            return
        root = self.catalog.require("sam2.1-hiera-tiny")
        from sam2.build_sam import build_sam2
        from sam2.sam2_image_predictor import SAM2ImagePredictor

        checkpoint = str(root / "sam2.1_hiera_tiny.pt")
        sam2 = build_sam2("configs/sam2.1/sam2.1_hiera_t.yaml", checkpoint, device="mps")
        self._sam = SAM2ImagePredictor(sam2)
        self._sam_source = None

    def _ensure_migan(self):
        if self._migan is not None:
            return self._migan
        import onnxruntime as ort

        root = self.catalog.require("migan")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        self._migan = ort.InferenceSession(
            str(root / "migan_pipeline_v2.onnx"),
            sess_options=options, providers=["CPUExecutionProvider"])
        return self._migan

    def _ensure_flux(self, ctx: Context):
        if self._flux is not None:
            return self._flux
        import mlx.core as mx
        from mflux.models.common.config import ModelConfig
        from mflux.models.flux2.variants import Flux2KleinEdit

        root = self.catalog.require("flux2-klein-4b-q4")
        if MLX_CACHE_GB > 0:
            mx.set_cache_limit(int(MLX_CACHE_GB * 1e9))
        if MLX_WIRED_GB > 0:
            mx.set_wired_limit(int(min(MLX_WIRED_GB, MEMORY_BUDGET_GB) * 1e9))
        ctx.emit("load", model="flux2-klein-4b-q4")
        self._flux = Flux2KleinEdit(model_config=ModelConfig.flux2_klein_4b(),
                                    model_path=str(root))
        self._flux.callbacks.register(_ProgressBridge(self))
        return self._flux


class _ProgressBridge:
    """mflux keeps callbacks for the life of the model, so this is registered
    once and forwards to whichever job is currently active."""

    def __init__(self, engine: Engine) -> None:
        self.engine = engine
        self.steps = 0

    def call_before_loop(self, **_: object) -> None:
        self.steps = 0
        if self.engine._active:
            self.engine._active.emit("denoise", step=0)

    def call_in_loop(self, **_: object) -> None:
        self.steps += 1
        ctx = self.engine._active
        if ctx is None:
            return
        ctx.emit("denoise", step=self.steps)
        ctx.check_cancel()
