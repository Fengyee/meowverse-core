#!/usr/bin/env python3
"""Talk to Bella in a built app: absent from the default build, present with MEOWVERSE_TALK_TO_BELLA=YES.

    python3 ios/check-voice-build.py <Meowverse.app> absent    # the default build, what ships
    python3 ios/check-voice-build.py <Meowverse.app> present   # a MEOWVERSE_TALK_TO_BELLA=YES build

Reads the product only: the app's binaries and its extensions' (`otool -L` for the Speech and
Foundation Models frameworks, `nm -u` for the symbols that listen, recognise speech or ask the
on-device model), Info.plist for the microphone and speech recognition usage descriptions
(ITMS-90683 asks for one for every API App Review finds), and every lproj's InfoPlist.strings.
The translations stay in InfoPlist.strings in both builds (one InfoPlist.xcstrings per target;
iOS reads a translation only for a key Info.plist has), so they are listed as notes, not
findings. The head itself is checked by `VoiceOffUITests`.

Before any of that the product must be whole (audit 2026-11-24, E24-02): every bundle's
executable present and a Mach-O file, and each expected extension there. A product with a hole
fails in both modes instead of passing "absent" on nothing read.
"""
import pathlib
import plistlib
import subprocess
import sys

FRAMEWORKS = ("Speech.framework", "FoundationModels.framework")
SYMBOLS = ("SFSpeech", "16FoundationModels", "AVAudioEngine", "recordPermission", "requestRecordPermission")
KEYS = ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription")
# The extensions every Meowverse product embeds (PlugIns/ or Extensions/).
EXTENSIONS = ("PocketCatWidget.appex", "MeowverseAssets.appex")
MACHO_MAGICS = {bytes.fromhex(m) for m in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def binaries(app: pathlib.Path):
    """Mach-O files of the app and its extensions (a Debug build keeps its code in *.debug.dylib)."""
    bundles = [app] + sorted(p for p in app.glob("**/*.appex"))
    for bundle in bundles:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        yield bundle / info["CFBundleExecutable"]
        yield from bundle.glob("*.debug.dylib")


def incomplete(app: pathlib.Path) -> list[str]:
    """What is missing from the product; empty when every binary the checks read is there."""
    problems = []
    if not (app / "Info.plist").is_file():
        return [f"missing: {app.name}/Info.plist"]
    present = {p.name for p in app.glob("**/*.appex")}
    problems += [f"missing: extension {e}" for e in EXTENSIONS if e not in present]
    for bundle in [app] + sorted(app.glob("**/*.appex")):
        plist = bundle / "Info.plist"
        info = plistlib.loads(plist.read_bytes()) if plist.is_file() else {}
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name:
            problems.append(f"missing: CFBundleExecutable in {bundle.relative_to(app.parent)}/Info.plist")
            continue
        exe = bundle / name
        rel = exe.relative_to(app.parent)
        if not exe.is_file():
            problems.append(f"missing: {rel}")
        elif exe.read_bytes()[:4] not in MACHO_MAGICS:
            problems.append(f"not a Mach-O file: {rel}")
    return problems


def run(*cmd) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120).stdout


def findings(app: pathlib.Path) -> list[str]:
    found = []
    for binary in binaries(app):
        name = binary.relative_to(app.parent)
        for line in run("otool", "-L", str(binary)).splitlines()[1:]:
            if any(f in line for f in FRAMEWORKS):
                found.append(f"{name} links {line.split()[0]}")
        undefined = run("nm", "-u", str(binary)).splitlines()
        for symbol in SYMBOLS:
            hits = [s for s in undefined if symbol in s]
            if hits:
                found.append(f"{name} uses {len(hits)} symbol(s) with {symbol}, e.g. {hits[0]}")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    found += [f"Info.plist has {k}" for k in KEYS if k in info]
    return found


def notes(app: pathlib.Path) -> list[str]:
    lines = []
    for strings in sorted(app.glob("*.lproj/InfoPlist.strings")):
        table = plistlib.loads(strings.read_bytes())
        lines += [f"{strings.relative_to(app.parent)} has {k}" for k in KEYS if k in table]
    return lines


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in ("absent", "present"):
        print(__doc__.strip().split("\n\n")[1])
        return 2
    app, want = pathlib.Path(sys.argv[1]), sys.argv[2]
    holes = incomplete(app)
    if holes:
        for line in holes:
            print(line)
        print(f"FAIL voice {want}: the product is incomplete ({len(holes)} problem(s)), nothing checked")
        return 1
    found, translated = findings(app), notes(app)
    for line in found:
        print(line)
    for line in translated:
        print(f"note: {line}")
    if want == "absent":
        print(f"{'FAIL' if found else 'PASS'} voice absent: {len(found)} finding(s) in {app.name}")
        return 1 if found else 0
    # Present: both frameworks linked, both keys in Info.plist and in each language's strings.
    need = ["links /System/Library/Frameworks/Speech.framework", "links /System/Library/Frameworks/FoundationModels.framework"]
    missing = [n for n in need if not any(n in f for f in found)]
    missing += [f"Info.plist has {k}" for k in KEYS if f"Info.plist has {k}" not in found]
    for lang in ("en", "zh-Hans"):
        missing += [f"{lang}.lproj {k}" for k in KEYS if not any(f"{lang}.lproj/InfoPlist.strings has {k}" in n for n in translated)]
    for line in missing:
        print(f"missing: {line}")
    print(f"{'FAIL' if missing else 'PASS'} voice present: {len(missing)} missing in {app.name}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
