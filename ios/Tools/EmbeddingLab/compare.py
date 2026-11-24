#!/usr/bin/env python3
"""Compare vectors JSONs against a reference, photo by photo (same SHA-256 keys).

    python compare.py REFERENCE.json OTHER.json [OTHER.json ...]

For each OTHER: photos in common, cosine similarity to the reference (min / 5th percentile /
median), and how often the nearest other photo is the same one as with the reference vectors
(ranking kept, which is what matching furniture depends on). Prints numbers only, no keys.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import fail, read_vectors  # noqa: E402


def unit(rows: np.ndarray) -> np.ndarray:
    return rows / np.linalg.norm(rows, axis=1, keepdims=True)


def nearest(rows: np.ndarray) -> np.ndarray:
    similarity = rows @ rows.T
    np.fill_diagonal(similarity, -np.inf)
    return similarity.argmax(axis=1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reference", type=Path)
    parser.add_argument("others", type=Path, nargs="+")
    args = parser.parse_args()

    ref_name, ref = read_vectors(args.reference)
    print(f"reference {ref_name}: {len(ref)} vectors")
    for path in args.others:
        _, other = read_vectors(path)
        name = path.stem
        keys = sorted(set(ref) & set(other))
        if len(keys) < 2:
            fail(f"{path}: fewer than 2 photos in common with the reference")
        a = unit(np.array([ref[k] for k in keys], dtype=np.float64))
        b = unit(np.array([other[k] for k in keys], dtype=np.float64))
        if a.shape[1] != b.shape[1]:
            fail(f"{path}: dimension {b.shape[1]}, reference {a.shape[1]}")
        cos = np.sort((a * b).sum(axis=1))
        same_nn = float((nearest(a) == nearest(b)).mean())
        print(f"{name}: {len(keys)} photos; cosine to reference min {cos[0]:.5f}, "
              f"p5 {np.percentile(cos, 5):.5f}, median {np.median(cos):.5f} (1 - median {1 - np.median(cos):.1e}); "
              f"same nearest photo {same_nn:.1%}")


if __name__ == "__main__":
    main()
