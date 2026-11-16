"""Image transport between the app and the worker.

Three ways in, in order of preference:

- `shm`: the app allocates POSIX shared memory and passes name + geometry. No
  path is involved, nothing is copied to disk, and the worker cannot open any
  other file.
- `data`: a base64 payload for small images and tests.
- `path`: a filesystem path, only accepted when the server was started with an
  explicit allow-list root. Refused otherwise.

Results are written as PNG files inside the job directory; the app may also ask
for a shared-memory copy, which the worker keeps alive until `buffer.release`.
"""
from __future__ import annotations

import base64
import hashlib
from pathlib import Path

import numpy as np
from PIL import Image

from .protocol import INVALID_PARAMS, PATH_DENIED, WorkerError

CHANNELS = {1: "L", 3: "RGB", 4: "RGBA"}


def _shared_memory(name: str):
    from multiprocessing import shared_memory

    return shared_memory.SharedMemory(name=name)


def read_image(spec: dict, allow_roots: tuple[Path, ...], workdir: Path) -> np.ndarray:
    if not isinstance(spec, dict):
        raise WorkerError(INVALID_PARAMS, "image must be an object")
    if "shm" in spec:
        handle = _shared_memory(spec["shm"])
        try:
            width, height = int(spec["width"]), int(spec["height"])
            channels = int(spec.get("channels", 3))
            if channels not in CHANNELS:
                raise WorkerError(INVALID_PARAMS, "channels must be 1, 3 or 4")
            expected = width * height * channels
            if spec.get("bytes") is not None and int(spec["bytes"]) != expected:
                raise WorkerError(INVALID_PARAMS, "shared memory size does not match geometry")
            if handle.size < expected:
                raise WorkerError(INVALID_PARAMS, "shared memory is smaller than the image")
            array = np.frombuffer(handle.buf[:expected], dtype=np.uint8)
            image = array.reshape(height, width, channels)
            if channels != 3:
                image = np.array(Image.fromarray(image.squeeze(), mode=CHANNELS[channels])
                                 .convert("RGB"))
            else:
                image = image.copy()
            return image
        finally:
            handle.close()

    if "data" in spec:
        payload = spec["data"]
        header, _, body = payload.partition(",")
        if not header.startswith("data:image") or "base64" not in header:
            raise WorkerError(INVALID_PARAMS, "data must be a base64 image data URL")
        raw = base64.b64decode(body)
        target = workdir / ("input-" + hashlib.sha256(raw).hexdigest()[:12] + ".png")
        target.write_bytes(raw)
        return _open(target)

    if "path" in spec:
        path = Path(str(spec["path"])).expanduser()
        if not path.is_absolute():
            raise WorkerError(INVALID_PARAMS, "path must be absolute")
        resolved = path.resolve()
        if not any(_is_within(resolved, root) for root in allow_roots):
            raise WorkerError(PATH_DENIED, "path is outside the allowed roots",
                              {"path": str(resolved)})
        if not resolved.exists():
            raise WorkerError(INVALID_PARAMS, "input file does not exist")
        return _open(resolved)

    raise WorkerError(INVALID_PARAMS, "image needs one of shm, data or path")


def _open(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        return np.array(image.convert("RGB"))


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root.resolve())
        return True
    except ValueError:
        return False


class BufferRegistry:
    """Shared-memory outputs the app still has to read."""

    def __init__(self) -> None:
        self._buffers: dict[str, object] = {}

    def publish(self, name: str | None, array: np.ndarray) -> dict:
        if not name:
            return {}
        handle = _shared_memory(name)
        payload = np.ascontiguousarray(array).tobytes()
        if handle.size < len(payload):
            handle.close()
            raise WorkerError(INVALID_PARAMS, "output shared memory is too small",
                              {"required": len(payload), "size": handle.size})
        handle.buf[:len(payload)] = payload
        self._buffers[name] = handle
        return {"shm": name, "bytes": len(payload),
                "width": array.shape[1], "height": array.shape[0],
                "channels": 1 if array.ndim == 2 else array.shape[2]}

    def release(self, name: str) -> None:
        # The app owns the segment and is responsible for shm_unlink; the worker
        # only detaches so a crashed app cannot leak it on our side.
        handle = self._buffers.pop(name, None)
        if handle is not None:
            handle.close()
