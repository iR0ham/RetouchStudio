# Third-party notices

The worker itself is MIT licensed; see `LICENSE`.

The runtime environment is built only from the SHA-256-pinned distributions in
`requirements.lock` (or the smaller `requirements-test.lock` used by tests).
Installing a wheel retains its `*.dist-info/METADATA` and any license file the
upstream project ships; those files are copied into the app bundle and are the
authoritative license text for each package.

Direct dependencies: numpy (BSD-3-Clause AND 0BSD AND MIT AND Zlib AND
CC0-1.0), Pillow (MIT-CMU), MLX (MIT), mflux (MIT),
torch (Apache-2.0 AND Apache-2.0 WITH LLVM-exception AND BSD-2-Clause AND
BSD-3-Clause AND BSL-1.0 AND ISC AND MIT AND Zlib), spandrel (MIT), onnxruntime
(MIT). Transitive packages pinned by the lock:
Jinja2, MarkupSafe, PyYAML, Pygments, annotated-doc, antlr4-python3-runtime,
anyio, certifi, charset-normalizer, click, contourpy, cycler, einops, filelock,
fire, flatbuffers, fonttools, fsspec, h11, hf-xet, hf_transfer, httpcore, httpx,
huggingface_hub, hydra-core, idna, iopath, kiwisolver, markdown-it-py,
matplotlib, mdurl, mlx-metal, mpmath, networkx, omegaconf, packaging,
piexif (MIT), platformdirs, portalocker, protobuf, pyparsing, python-dateutil,
regex, requests,
rich, safetensors, sentencepiece, setuptools, shellingham, sympy, termcolor,
tokenizers, toml, torchvision, tqdm, transformers, typer, typing_extensions,
tzdata, urllib3.

Model weights are not part of this repository or the app bundle. They are
downloaded separately under the consent rules in `Docs/W5_ROADMAP.md`, and each
model carries its own license and attribution requirements.
