#!/usr/bin/env python3
"""Embed every photo in a folder and write a vectors JSON for `recognition-eval --prints`.

    python embed.py PHOTOS --model MODEL.mlpackage --out "$TMPDIR/v.json" [--compute-units all cpuOnly]
    python embed.py PHOTOS --model small --out "$TMPDIR/v-torch.json"     # PyTorch reference

MODEL is a .mlpackage / .mlmodelc from convert.py, or a key of common.MODELS (small, base-reg)
for the PyTorch reference (CPU, float32, eager), which is what the Core ML models are checked
against. Keys of the JSON are the SHA-256 of each file's bytes, as recognition-eval expects.

Photos are read in place. Nothing is printed about them except counts; the output file is 0600
and must be outside any Git checkout. With several --compute-units, one file per unit is written
(<out stem>-<unit>.json) and the time per prediction is printed for each.
"""

from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (IMAGENET_MEAN, IMAGENET_STD, INPUT_SIZE, MODELS, fail, load_square, photo_files,  # noqa: E402
                    refuse_inside_repository, sha256_file, write_private_json)

UNITS = ("all", "cpuAndGPU", "cpuOnly", "cpuAndNE")


def load_photos(root: Path, size: int):
    keys, images, unreadable, duplicates = [], [], 0, 0
    seen = set()
    for path in photo_files(root):
        try:
            image = load_square(path, size)
        except Exception:  # not a picture PIL can read; counted, never named
            unreadable += 1
            continue
        key = sha256_file(path)
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        keys.append(key)
        images.append(image)
    return keys, images, unreadable, duplicates


def torch_vectors(key: str, images, threads: int | None):
    import numpy as np
    import torch
    from transformers import AutoModel

    if threads:
        torch.set_num_threads(threads)
    spec = MODELS[key]
    model = AutoModel.from_pretrained(spec["id"], revision=spec["revision"]).eval()
    skip = 1 + int(getattr(model.config, "num_register_tokens", 0) or 0)
    mean = np.array(IMAGENET_MEAN, dtype=np.float32)
    std = np.array(IMAGENET_STD, dtype=np.float32)
    vectors, times = [], []
    with torch.no_grad():
        for image in images:
            x = torch.from_numpy(((np.asarray(image, dtype=np.float32) / 255 - mean) / std).transpose(2, 0, 1))
            t0 = time.perf_counter()
            hidden = model(pixel_values=x[None]).last_hidden_state
            vectors.append(hidden[0, skip:].mean(0).numpy())
            times.append(time.perf_counter() - t0)
    return f"{spec['id'].split('/')[-1]}-{INPUT_SIZE}-mean-torch", vectors, times, 0.0


def coreml_vectors(path: Path, unit: str, images):
    import coremltools as ct
    import numpy as np

    units = {"all": ct.ComputeUnit.ALL, "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
             "cpuOnly": ct.ComputeUnit.CPU_ONLY, "cpuAndNE": ct.ComputeUnit.CPU_AND_NE}[unit]
    t0 = time.perf_counter()
    if path.suffix == ".mlmodelc":
        model = ct.models.CompiledMLModel(str(path), compute_units=units)
    else:
        model = ct.models.MLModel(str(path), compute_units=units)
    load = time.perf_counter() - t0
    model.predict({"image": images[0]})  # first prediction warms the device; not timed
    vectors, times = [], []
    for image in images:
        t0 = time.perf_counter()
        out = model.predict({"image": image})["embedding"]
        times.append(time.perf_counter() - t0)
        vectors.append(np.asarray(out, dtype=np.float32).reshape(-1))
    name = path.name.removesuffix(path.suffix)
    return name, vectors, times, load


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("photos", type=Path)
    parser.add_argument("--model", required=True, help=".mlpackage/.mlmodelc, or " + ", ".join(sorted(MODELS)))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--compute-units", nargs="+", choices=UNITS, default=["all"])
    parser.add_argument("--threads", type=int, help="PyTorch CPU threads (reference only)")
    args = parser.parse_args()

    out = args.out.expanduser()
    refuse_inside_repository(out)
    if not args.photos.is_dir():
        fail(f"{args.photos}: not a folder")
    model_path = Path(args.model).expanduser()
    is_coreml = model_path.suffix in (".mlpackage", ".mlmodelc")
    if not is_coreml and args.model not in MODELS:
        fail(f"--model: a .mlpackage/.mlmodelc or one of {', '.join(sorted(MODELS))}")
    if is_coreml and not model_path.exists():
        fail(f"{model_path}: not found")

    t0 = time.perf_counter()
    keys, images, unreadable, duplicates = load_photos(args.photos, INPUT_SIZE)
    print(f"photos: {len(keys)} embedded, {unreadable} unreadable, {duplicates} duplicate bytes "
          f"(decode and resize {time.perf_counter() - t0:.1f} s)", flush=True)
    if not keys:
        fail("no readable photos")

    runs = args.compute_units if is_coreml else ["torch-cpu"]
    for unit in runs:
        if is_coreml:
            name, vectors, times, load = coreml_vectors(model_path, unit, images)
        else:
            name, vectors, times, load = torch_vectors(args.model, images, args.threads)
        target = out if len(runs) == 1 else out.with_name(f"{out.stem}-{unit}{out.suffix}")
        write_private_json({"model": name, "dimension": int(vectors[0].shape[0]),
                            "vectors": {k: [float(x) for x in v] for k, v in zip(keys, vectors)}}, target)
        ms = sorted(t * 1000 for t in times)
        print(f"{name} [{unit}] {len(vectors)} vectors of {vectors[0].shape[0]} -> {target}\n"
              f"  per prediction: median {statistics.median(ms):.1f} ms, mean {statistics.fmean(ms):.1f} ms, "
              f"p90 {ms[int(0.9 * (len(ms) - 1))]:.1f} ms; model load {load:.2f} s", flush=True)


if __name__ == "__main__":
    main()
