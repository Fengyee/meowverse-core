#!/usr/bin/env python3
"""Convert DINOv2 to a Core ML image embedder: 224 x 224 RGB image in, mean of patch tokens out.

Preprocessing (0-255 -> 0-1 -> ImageNet mean/std) and the pooling are inside the model, so the
app hands Core ML (or Vision with .scaleFill) a 224 x 224 picture and gets one vector back.

    python convert.py --model small --out "$TMPDIR/embedding-lab/models"
    python convert.py --model base-reg --out ... --variants fp16 int8 pal8

Writes <out>/<name>-<variant>.mlpackage, compiles each to <name>-<variant>.mlmodelc with
`xcrun coremlcompiler`, and prints sizes. <out> must be outside any Git checkout.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (IMAGENET_MEAN, IMAGENET_STD, INPUT_SIZE, LICENCE, MODELS, fail, folder_bytes,  # noqa: E402
                    refuse_inside_repository, sha256_file, write_private_json)

VARIANTS = ("fp32", "fp16", "int8", "pal8", "pal6")
DEFAULT_VARIANTS = ("fp16", "int8", "pal8")


def build_wrapper(hf_model, size: int):
    import torch

    class MeanPatchEmbedder(torch.nn.Module):
        def __init__(self, backbone):
            super().__init__()
            self.backbone = backbone
            config = backbone.config
            self.skip = 1 + int(getattr(config, "num_register_tokens", 0) or 0)  # CLS, then registers
            embeddings = backbone.embeddings
            # The checkpoint's position table is for 518 px. Interpolate it once, outside tracing,
            # exactly as eager PyTorch does at this size, and bake the result in as a constant:
            # the converted model has no bicubic resize and matches the reference vectors.
            patches = (size // config.patch_size) ** 2
            with torch.no_grad():
                dummy = torch.zeros(1, 1 + patches, config.hidden_size)
                fixed = embeddings.interpolate_pos_encoding(dummy, size, size).detach().clone()
            embeddings.register_buffer("baked_position_embeddings", fixed, persistent=False)
            embeddings.interpolate_pos_encoding = lambda _e, _h, _w: embeddings.baked_position_embeddings
            self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))

        def forward(self, image):  # image: (1, 3, size, size) in 0-1 (Core ML applies scale 1/255)
            x = (image - self.mean) / self.std
            hidden = self.backbone(pixel_values=x).last_hidden_state
            return hidden[:, self.skip:].mean(dim=1)

    return MeanPatchEmbedder(hf_model).eval()


def convert(key: str, size: int, attention: str):
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoModel

    spec = MODELS[key]
    model = AutoModel.from_pretrained(spec["id"], revision=spec["revision"], attn_implementation=attention).eval()
    wrapper = build_wrapper(model, size)
    example = torch.rand(1, 3, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)
        dimension = int(traced(example).shape[-1])
    image = ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0, bias=[0, 0, 0],
                         color_layout=ct.colorlayout.RGB)
    output = ct.TensorType(name="embedding", dtype=np.float32)

    def to_coreml(precision):
        mlmodel = ct.convert(traced, inputs=[image], outputs=[output], convert_to="mlprogram",
                             minimum_deployment_target=ct.target.iOS18, compute_precision=precision)
        mlmodel.author = "Meta AI (DINOv2); converted by Meowverse EmbeddingLab"
        mlmodel.license = LICENCE
        mlmodel.short_description = (f"{spec['id']} mean of patch tokens (CLS and registers excluded), "
                                     f"{size} x {size} RGB, whole picture squashed to a square")
        mlmodel.input_description["image"] = f"{size} x {size} RGB, whole picture squashed (scaleFill)"
        mlmodel.output_description["embedding"] = f"{dimension} floats, not normalised"
        mlmodel.user_defined_metadata.update({
            "source": spec["id"], "revision": spec["revision"], "licence": LICENCE,
            "pooling": "mean of patch tokens", "inputSize": str(size), "dimension": str(dimension),
            "preprocessing": "x/255, ImageNet mean/std, inside the model",
        })
        return mlmodel

    return spec, dimension, to_coreml


def quantised(base, variant: str):
    import coremltools.optimize as cto

    if variant == "int8":
        op = cto.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
        return cto.coreml.linear_quantize_weights(base, cto.coreml.OptimizationConfig(global_config=op))
    # One look-up table per weight tensor. 6 bits already moves the vectors (cosine about 0.99);
    # 4 bits, even with per-group tables, gave vectors unrelated to the reference, so it is not offered.
    bits = {"pal8": 8, "pal6": 6}[variant]
    op = cto.coreml.OpPalettizerConfig(mode="kmeans", nbits=bits, granularity="per_tensor")
    return cto.coreml.palettize_weights(base, cto.coreml.OptimizationConfig(global_config=op))


def make_deterministic(package: Path) -> None:
    """Same inputs, same bytes: the weights already are; the spec and the manifest are made so.

    coremltools writes protobuf maps in arbitrary order (same model, different bytes on every run)
    and gives the manifest random item identifiers. Re-serialise the spec with sorted maps and
    derive the identifiers from the item paths, so a re-run reproduces registered hashes.
    """
    import uuid
    from coremltools.proto import Model_pb2

    spec_path = package / "Data" / "com.apple.CoreML" / "model.mlmodel"
    spec = Model_pb2.Model()
    spec.ParseFromString(spec_path.read_bytes())
    spec_path.write_bytes(spec.SerializeToString(deterministic=True))
    manifest_path = package / "Manifest.json"
    manifest = json.loads(manifest_path.read_text())
    ids = {old: str(uuid.uuid5(uuid.NAMESPACE_URL, "meowverse-embedding-lab/" + item["path"])).upper()
           for old, item in manifest["itemInfoEntries"].items()}
    manifest["itemInfoEntries"] = {ids[old]: item for old, item in manifest["itemInfoEntries"].items()}
    manifest["rootModelIdentifier"] = ids[manifest["rootModelIdentifier"]]
    manifest_path.write_text(json.dumps(manifest, indent=4, sort_keys=True) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", choices=sorted(MODELS), required=True)
    parser.add_argument("--out", type=Path, required=True, help="folder for the models, outside any Git checkout")
    parser.add_argument("--variants", nargs="+", choices=VARIANTS, default=list(DEFAULT_VARIANTS))
    parser.add_argument("--size", type=int, default=INPUT_SIZE)
    parser.add_argument("--attention", choices=("sdpa", "eager"), default="sdpa")
    args = parser.parse_args()

    import coremltools as ct

    out = Path(os.path.abspath(args.out.expanduser()))
    existing = out
    while not existing.exists():
        existing = existing.parent
    refuse_inside_repository(existing / "probe", shown=out)  # checks `existing` and everything above it
    out.mkdir(parents=True, exist_ok=True)
    if shutil.which("xcrun") is None:
        fail("xcrun not found: install Xcode to compile the models")

    started = time.time()
    spec, dimension, to_coreml = convert(args.model, args.size, args.attention)
    name = f"{spec['id'].split('/')[-1]}-{args.size}-mean"
    report = {"source": spec["id"], "revision": spec["revision"], "licence": LICENCE, "size": args.size,
              "dimension": dimension, "attention": args.attention, "coremltools": ct.__version__, "variants": {}}

    fp16 = None
    for variant in args.variants:
        t0 = time.time()
        if variant == "fp32":
            mlmodel = to_coreml(ct.precision.FLOAT32)
        else:
            if fp16 is None:
                fp16 = to_coreml(ct.precision.FLOAT16)
            mlmodel = fp16 if variant == "fp16" else quantised(fp16, variant)
        package = out / f"{name}-{variant}.mlpackage"
        compiled = out / f"{name}-{variant}.mlmodelc"
        for old in (package, compiled):
            if old.exists():
                shutil.rmtree(old)
        mlmodel.save(str(package))
        make_deterministic(package)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True,
                       stdout=subprocess.DEVNULL)
        entry = {"package": package.name, "packageBytes": folder_bytes(package),
                 "compiled": compiled.name, "compiledBytes": folder_bytes(compiled),
                 "sha256": {str(p.relative_to(package)): sha256_file(p)
                            for p in sorted(package.rglob("*")) if p.is_file() and p.name != "Manifest.json"},
                 "seconds": round(time.time() - t0, 1)}
        report["variants"][variant] = entry
        print(f"{name} {variant:5s} mlpackage {entry['packageBytes'] / 1e6:7.1f} MB  "
              f"compiled {entry['compiledBytes'] / 1e6:7.1f} MB  ({entry['seconds']} s)", flush=True)
        for rel, digest in entry["sha256"].items():
            print(f"    {digest}  {rel}")

    write_private_json(report, out / f"{name}-convert.json")
    print(f"done in {time.time() - started:.0f} s; report {out / (name + '-convert.json')}")


if __name__ == "__main__":
    main()
