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

from . import __version__, provenance
from .capabilities import current_platform, job_capability
from .catalog import Catalog, ModelEntry
from .protocol import (BUDGET_EXCEEDED, CONTRACT_VERSION, INTERNAL_ERROR,
                       INVALID_PARAMS, UNSUPPORTED, WorkerError)
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
    # The capability the host named in the envelope; §3.6 records it in provenance.
    capability_id: str | None = None
    # The capability the host asks the record to name without putting the job
    # through the verdict gate (the approved A1). It is metadata only: nothing
    # here refuses a job because of it.
    requested_capability: str | None = None

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
        self._providers: list[str] = []
        self._active: Context | None = None
        self._work: queue.Queue = queue.Queue()
        self._runner = threading.Thread(target=self._loop, name="engine", daemon=True)
        self._runner.start()

    def _note_provider(self, provider: str) -> None:
        if provider not in self._providers:
            self._providers.append(provider)

    def execution_providers(self) -> tuple[list[str], str | None]:
        """The providers this process has really run a model on, or the reason.

        Probing torch to answer `provider.list` earlier would put an import of
        seconds and hundreds of megabytes into every launch, on a machine that
        may never run a job. The protocol rule is that a provider is reported only
        after it initialised, so an unstarted worker reports none.
        """
        if self._providers:
            return list(self._providers), None
        return [], "no model has been loaded, so no execution provider has initialised"

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

        model, identity = self._ensure_flux(ctx)
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
        alpha_path = ctx.workdir / "alpha.png"
        patch_pixels = full[ey0:ey1, ex0:ex1]
        alpha_pixels = np.round(alpha[ey0:ey1, ex0:ex1] * 255).astype(np.uint8)
        # The app adopts this pair, so this is where §3.6 lands: each file
        # arrives with the sidecar that names its bytes. A job submitted by
        # kind alone publishes nothing rather than a record that would have to
        # guess which of the four patch_edit capabilities ran.
        published: dict[str, str] = {}
        capability = self._recorded_capability(ctx)
        if capability:
            rect = {"x": ex0 / width, "y": ey0 / height,
                    "width": (ex1 - ex0) / width, "height": (ey1 - ey0) / height}
            edit_parameters = {"prompt": prompt, "engine": "patch",
                               "steps": int(params.get("steps", 4)),
                               "patch": patch_long,
                               "context": float(params.get("context", 0.25)),
                               "dilate": dilate, "feather": feather,
                               "guidance": float(params.get("guidance", 1.0))}
            published["patch_provenance"] = str(self._publish_provenanced(
                ctx, patch_path, patch_pixels, capability=capability,
                identity=identity, parameters=edit_parameters,
                seed=int(params.get("seed", 42)), source=source, rect=rect,
                outside=outside_identical, seconds=generate_s))
            # The alpha plane is not a promise about picture pixels, so its
            # record keeps the field null; the patch record carries the
            # measured one for the pair.
            published["alpha_provenance"] = str(self._publish_provenanced(
                ctx, alpha_path, alpha_pixels, capability=capability,
                identity=identity, parameters=edit_parameters,
                seed=int(params.get("seed", 42)), source=source, rect=rect,
                outside=None, seconds=generate_s))
        else:
            Image.fromarray(patch_pixels).save(patch_path)
            Image.fromarray(alpha_pixels).save(alpha_path)
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
            **published,
            **ctx.publish(out),
        }

    # ------------------------------------------------------------------
    # §3.6 provenance for adopted edit artifacts (the approved A1).
    def _recorded_capability(self, ctx: Context) -> tuple[str, str | None] | None:
        """The capability name this job may record, and where the name came from.

        A gated name needs no label: the worker's own verdict is what made it
        true. `requested_capability` is the A1 route — the host names the edit
        it ran and the worker records that name without putting the job through
        the verdict gate — so its sidecars say `host-asserted`. A job that was
        submitted by kind alone has no honest name, because four capabilities
        share the kind and only the host knows which tool ran; its artifacts
        carry no provenance rather than a guessed one.
        """
        if ctx.capability_id:
            return ctx.capability_id, None
        if ctx.requested_capability:
            return ctx.requested_capability, "host-asserted"
        return None

    def _entry_identity(self, entry: ModelEntry, root: Path, provider: str) -> dict:
        """The model half of a record, built the way the load path sees it.

        The digests come from the catalog entry, which the load already
        trusted; re-hashing gigabytes per job would prove nothing the load did
        not already prove, and `version` is absent exactly when the running
        bytes are the legacy flat install rather than a versioned one.
        """
        flat = self.catalog.root / entry.id
        return {"id": entry.id,
                "version": None if root == flat else root.name,
                "format": entry.files[0].path.rsplit(".", 1)[-1] if entry.files else None,
                "provider": provider,
                "files": [{"path": spec.path, "sha256": spec.sha256}
                          for spec in entry.files if spec.sha256]}

    def _publish_provenanced(self, ctx: Context, target: Path, pixels: np.ndarray,
                             *, capability: tuple[str, str | None], identity: dict,
                             parameters: dict, seed: int | None,
                             source: np.ndarray, rect: dict,
                             outside: bool | None, seconds: float) -> Path:
        """Write `pixels` as `target` and land its §3.6 sidecar with it.

        The same publication boundary as the upscale path: a cancel that
        arrives while the bytes are being written stops the job here with
        nothing published, and nothing is checked once the two renames start,
        because that is the point a pair cannot be torn at.
        """
        staged = target.with_name(target.name + ".tmp")
        try:
            Image.fromarray(pixels).save(staged, format="PNG")
            ctx.check_cancel()
            capability_id, capability_source = capability
            record = provenance.document(
                capability_id=capability_id, job_id=ctx.job_id,
                contract_version=CONTRACT_VERSION, model=identity,
                adapter={"platform": current_platform(),
                         "version": __version__},
                parameters=parameters, seed=seed,
                input=provenance.pixels(source),
                output=provenance.artifact(staged),
                authorized_rect=rect, outside_pixels_identical=outside,
                elapsed_seconds=round(seconds, 2), state="succeeded",
                capability_source=capability_source)
            return provenance.publish(staged, target, record)
        except provenance.ProvenanceError as exc:
            staged.unlink(missing_ok=True)
            raise WorkerError(INTERNAL_ERROR,
                              "the edit artifact could not be published "
                              f"with provenance: {exc}",
                              {"job": ctx.job_id}) from exc
        except BaseException:
            staged.unlink(missing_ok=True)
            raise

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

        session, identity = self._ensure_migan()
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
        alpha_path = ctx.workdir / "alpha.png"
        patch_pixels = generated[ey0:ey1, ex0:ex1]
        alpha_pixels = np.round(alpha[ey0:ey1, ex0:ex1] * 255).astype(np.uint8)
        # The same adopted-pair rule as the generative path: provenance when
        # the host named the capability, nothing when it would have to guess.
        # MI-GAN takes no seed — the seed the host sent did not shape these
        # bytes, so the record says null rather than repeating a number that
        # only the generative model honours.
        published: dict[str, str] = {}
        capability = self._recorded_capability(ctx)
        if capability:
            rect = {"x": ex0 / width, "y": ey0 / height,
                    "width": (ex1 - ex0) / width, "height": (ey1 - ey0) / height}
            edit_parameters = {"engine": "inpaint", "dilate": dilate,
                               "feather": feather,
                               "steps": int(params.get("steps", 4))}
            published["patch_provenance"] = str(self._publish_provenanced(
                ctx, patch_path, patch_pixels, capability=capability,
                identity=identity, parameters=edit_parameters, seed=None,
                source=source, rect=rect, outside=outside_identical,
                seconds=generate_s))
            published["alpha_provenance"] = str(self._publish_provenanced(
                ctx, alpha_path, alpha_pixels, capability=capability,
                identity=identity, parameters=edit_parameters, seed=None,
                source=source, rect=rect, outside=None, seconds=generate_s))
        else:
            Image.fromarray(patch_pixels).save(patch_path)
            Image.fromarray(alpha_pixels).save(alpha_path)
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
            **published,
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

        model, identity = self._ensure_flux(ctx)
        ctx.check_cancel()
        started = time.perf_counter()
        generated = self._generate(model, prompt, reference, render_w, render_h, params, ctx)
        generate_s = time.perf_counter() - started
        out = np.array(generated.convert("RGB").resize((width, height), Image.LANCZOS))
        result_path = ctx.workdir / "result.png"
        alpha_path = ctx.workdir / "alpha.png"
        # A whole-frame render covers every pixel, so its alpha is the opaque
        # frame itself. It used to be drawn by the host, which left the pair
        # half-signed; the worker writes it now so both adopted files arrive
        # from the same hand and the same digest rule covers both.
        opaque = np.full((height, width), 255, dtype=np.uint8)
        full_rect = {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0}
        published: dict[str, str] = {}
        capability = self._recorded_capability(ctx)
        edit_parameters = {"prompt": prompt, "engine": "patch",
                           "full_frame": True,
                           "steps": int(params.get("steps", 4)),
                           "max_side": max_side,
                           "guidance": float(params.get("guidance", 1.0))}
        if capability:
            published["provenance"] = str(self._publish_provenanced(
                ctx, result_path, out, capability=capability,
                identity=identity, parameters=edit_parameters,
                seed=int(params.get("seed", 42)), source=source,
                rect=full_rect,
                outside=False,  # the whole frame was redrawn, on purpose
                seconds=generate_s))
            published["alpha_provenance"] = str(self._publish_provenanced(
                ctx, alpha_path, opaque, capability=capability,
                identity=identity, parameters=edit_parameters,
                seed=int(params.get("seed", 42)), source=source,
                rect=full_rect, outside=None, seconds=generate_s))
        else:
            Image.fromarray(out).save(result_path)
            Image.fromarray(opaque).save(alpha_path)
        return {
            "output": str(result_path),
            "mode": "full-frame",
            "alpha": str(alpha_path),
            "render_size": [render_w, render_h],
            "mask_fraction": round(fraction, 4),
            "generate_s": round(generate_s, 2),
            **published,
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

        # The weights are read before the first tile, so a cancel that arrives
        # during the load is seen as soon as it returns; the reader itself cannot
        # be interrupted.
        ctx.check_cancel()
        model, device, identity = self._ensure_swin()
        ctx.check_cancel()

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
        pixels = (output * 255).round().astype(np.uint8)
        result = ctx.workdir / "upscaled.png"
        # Nothing is visible at `result` until the last rename. The rendered
        # bytes land in a sibling temp, the sidecar is built from those bytes,
        # and `publish` lands the sidecar first and the artifact second: no
        # filesystem makes two renames atomic, so the invariant is carried by
        # the order. An artifact the host can adopt therefore always has its
        # provenance; the state between the two renames is a sidecar with no
        # artifact, which nothing adopts and startup `reconcile` clears.
        ctx.check_cancel()
        staging = ctx.workdir / (result.name + ".tmp")
        capability = ctx.capability_id or job_capability("upscale")[0].id
        seconds = round(time.perf_counter() - started, 2)
        try:
            Image.fromarray(pixels).save(staging, format="PNG")
            # A cancel that lands while the bytes are being written stops the
            # job here, with nothing published. Nothing is checked once the
            # publication starts: that is the boundary the pair cannot be torn
            # at, so the two renames run uninterrupted.
            ctx.check_cancel()
            record = provenance.document(
                capability_id=capability, job_id=ctx.job_id,
                contract_version=CONTRACT_VERSION, model=identity,
                adapter={"platform": current_platform(),
                         "version": __version__},
                parameters={"scale": scale, "tile": tile, "overlap": overlap},
                seed=params.get("seed"), input=provenance.pixels(source),
                output=provenance.artifact(staging),
                authorized_rect={"x": 0.0, "y": 0.0, "width": 1.0,
                                 "height": 1.0},
                outside_pixels_identical=None, elapsed_seconds=seconds,
                state="succeeded",
                # A host that named the capability had it approved by the
                # verdict first, which needs no label; a kind-only submit got
                # this name from the worker itself, and the record says so.
                capability_source=None if ctx.capability_id
                else "worker-derived")
            sidecar = provenance.publish(staging, result, record)
        except provenance.ProvenanceError as exc:
            staging.unlink(missing_ok=True)
            raise WorkerError(INTERNAL_ERROR,
                              "the upscaled artifact could not be published "
                              f"with provenance: {exc}",
                              {"job": ctx.job_id}) from exc
        except BaseException:
            staging.unlink(missing_ok=True)
            raise
        return {"output": str(result), "scale": scale, "device": device,
                "provider": device, "model": identity,
                "provenance": str(sidecar),
                "tile": tile, "overlap": overlap, "tiles": total,
                "image_size": [width, height],
                "output_size": [width * scale, height * scale],
                "seconds": seconds,
                **ctx.publish(pixels)}

    # ------------------------------------------------------------------
    def _ensure_swin(self):
        """The Swin2SR weights and the identity the sidecar records for them.

        The load path is where the catalog's SHA-256 is enforced: it runs once
        per process, is 0.036 s for this checkpoint's 48 MB weights on the
        reference Mac, and means the bytes a job trusts are the bytes the
        catalog describes. `require` keeps its size-only check so launch and
        capability reporting stay cheap.
        """
        if self._swin is not None:
            return self._swin
        entry = self.catalog.get("swin2sr-x4")
        root = self.catalog.require_verified("swin2sr-x4")
        try:
            import torch
            from transformers import Swin2SRForImageSuperResolution
        except ImportError as exc:
            self.catalog.release("swin2sr-x4", root)
            raise WorkerError(INTERNAL_ERROR,
                              f"the upscaler runtime is unavailable: {exc}",
                              {"model": entry.id}) from exc

        device = "mps" if torch.backends.mps.is_available() else "cpu"
        try:
            model = Swin2SRForImageSuperResolution.from_pretrained(
                str(root), local_files_only=True).to(device).eval()
        except BaseException:
            # A failed load is not a reason to keep the model leased: the owner
            # must be able to reinstall or delete it.
            self.catalog.release("swin2sr-x4", root)
            raise
        self._note_provider(device)
        flat = self.catalog.root / entry.id
        identity = {"id": entry.id,
                    "version": None if root == flat else root.name,
                    "format": "pytorch", "provider": device,
                    "files": [{"path": spec.path, "sha256": spec.sha256}
                              for spec in entry.files if spec.sha256]}
        self._swin = (model, device, identity)
        return self._swin

    # ------------------------------------------------------------------
    def _ensure_sam(self) -> None:
        if self._sam is not None:
            return
        # Asked before the model, and before `require` takes its lease: the
        # weights can be perfectly installable and still have nothing that
        # reads them. `sam2` is not in `requirements.lock`, so this is the
        # ordinary answer for a lock-reproducible runtime, not a damaged one.
        try:
            from sam2.build_sam import build_sam2
            from sam2.sam2_image_predictor import SAM2ImagePredictor
        except ImportError as error:
            raise WorkerError(
                UNSUPPORTED,
                "this worker cannot import sam2, so SAM 2.1 tiny has nothing "
                "to run on",
                {"capabilityId": "mask.click", "package": "sam2"}) from error
        root = self.catalog.require("sam2.1-hiera-tiny")

        checkpoint = str(root / "sam2.1_hiera_tiny.pt")
        sam2 = build_sam2("configs/sam2.1/sam2.1_hiera_t.yaml", checkpoint, device="mps")
        self._sam = SAM2ImagePredictor(sam2)
        self._sam_source = None
        self._note_provider("mps")

    def _ensure_migan(self):
        if self._migan is not None:
            return self._migan
        import onnxruntime as ort

        root = self.catalog.require("migan")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        session = ort.InferenceSession(
            str(root / "migan_pipeline_v2.onnx"),
            sess_options=options, providers=["CPUExecutionProvider"])
        self._note_provider("cpu")
        # The provider is not a guess here: the session was pinned to the CPU
        # execution provider above, and the record says what the session is.
        self._migan = (session, self._entry_identity(
            self.catalog.get("migan"), root, "cpu"))
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
        model = Flux2KleinEdit(model_config=ModelConfig.flux2_klein_4b(),
                               model_path=str(root))
        model.callbacks.register(_ProgressBridge(self))
        # mflux offers no device handle, but MLX answers for itself: the
        # default device is what the weights actually ran on. "metal" is the
        # GPU name MLX gives for its unified-memory device on Apple silicon.
        device_type = getattr(mx.default_device(), "device_type", None)
        provider = {"gpu": "metal", "cpu": "cpu"}.get(device_type,
                                                      device_type or "unknown")
        self._flux = (model, self._entry_identity(
            self.catalog.get("flux2-klein-4b-q4"), root, provider))
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
