"""Shared helpers for the embedding lab: models, preprocessing, private output files.

Everything this lab writes (models, vectors, reports) holds either large binaries or facts about
private photos, so every output path is checked by `refuse_inside_repository` first.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

# Hugging Face checkpoints, pinned to the commit the measurements were taken with.
# Both are Apache-2.0 (model cards and the LICENSE in facebookresearch/dinov2).
MODELS = {
    "small": {"id": "facebook/dinov2-small", "revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056"},
    "base-reg": {"id": "facebook/dinov2-with-registers-base", "revision": "a1d738ccfa7ae170945f210395d99dde8adb1805"},
}
LICENCE = "Apache-2.0"
INPUT_SIZE = 224
# The app's thumbnail is 512 px; the measurements squashed the whole picture to 512 x 512 first,
# then to the model size. Both steps are PIL bicubic.
THUMBNAIL_SIZE = 512
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def _repository_of_this_lab() -> Path | None:
    folder = Path(__file__).resolve().parent
    while folder != folder.parent:
        if (folder / ".git").exists():
            return folder
        folder = folder.parent
    return None


def refuse_inside_repository(target: Path, shown: Path | None = None) -> None:
    """Exit when `target` would land inside this repository or any Git checkout.

    Same rule as recognition-eval: the parent folder must exist; case is ignored (APFS).
    `shown` is the path named in the error when it differs from `target`.
    """
    shown = shown or target
    parent = Path(os.path.abspath(target)).parent
    if not parent.is_dir():
        fail(f"{shown}: the folder {parent} does not exist")
    parent = parent.resolve()
    repo = _repository_of_this_lab()
    if repo is not None:
        repo_path = str(repo.resolve()).lower()
        here = str(parent).lower()
        if here == repo_path or here.startswith(repo_path + "/"):
            fail(f"{shown} is inside the repository; write it outside, for example under $TMPDIR")
    folder = parent
    while True:
        if (folder / ".git").exists():
            fail(f"{shown} is inside a Git checkout ({folder}); write it outside, for example under $TMPDIR")
        if folder == folder.parent:
            break
        folder = folder.parent


def write_private_json(obj, target: Path) -> None:
    """Write JSON readable only by this user (0600), via a temporary file in the same folder."""
    refuse_inside_repository(target)
    tmp = target.with_name(target.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(obj, handle)
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def photo_files(root: Path) -> list[Path]:
    """Every file under `root`, skipping dot files and dot folders, sorted by full path."""
    found = []
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        found.extend(Path(folder) / f for f in files if not f.startswith("."))
    return sorted(found, key=str)


def load_square(path: Path, size: int = INPUT_SIZE):
    """EXIF-upright RGB, whole picture squashed to a 512 square, then to `size` (both bicubic)."""
    from PIL import Image, ImageOps
    import pillow_heif

    pillow_heif.register_heif_opener()
    with Image.open(path) as image:
        upright = ImageOps.exif_transpose(image).convert("RGB")
    square = upright.resize((THUMBNAIL_SIZE, THUMBNAIL_SIZE), Image.BICUBIC)
    return square.resize((size, size), Image.BICUBIC)


def folder_bytes(path: Path) -> int:
    """Sum of file sizes under a folder (or one file)."""
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def read_vectors(path: Path) -> tuple[str, dict]:
    with open(path) as handle:
        data = json.load(handle)
    return data.get("model", path.stem), data["vectors"]
