#!/usr/bin/env python3
"""Fails when the app's localisation is incomplete.

    python3 check-localization.py                     # catalog checks only
    python3 check-localization.py --stringsdata DIR   # also audit the Swift sources

Catalog checks (no build needed):
  * every entry of every Meowverse/*.xcstrings has an English translation in state "translated",
    nothing is stale or awaiting review, and the English text keeps the key's placeholders;
  * every count phrase in English has plural variations;
  * every furniture and resting-place name in the catalog JSON files and in
    `FurnitureCatalog.builtInModels` has an entry in CatalogNames.xcstrings.

Source audit (needs the .stringsdata files of a build, e.g.
build/DerivedData/Build/Intermediates.noindex/Meowverse.build/Debug-iphonesimulator/Meowverse.build/Objects-normal/arm64):
  * every string literal with Chinese text in Meowverse/**/*.swift is either extracted by the
    compiler as a localisable string, or on a line marked `// not-localized: <reason>`;
  * every extracted key is in its table's catalog (Localizable.xcstrings, or e.g. RoomAR.xcstrings
    for `Text("…", tableName: "RoomAR")`).
Code under `#if MEOWVERSE_TALK_TO_BELLA` (Talk to Bella, off by default) is audited only when the
build compiled it: run once more on a `MEOWVERSE_TALK_TO_BELLA=YES` build for those lines.
"""
import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "Meowverse")
CORE = os.path.join(ROOT, "MeowverseCore", "Sources", "MeowverseCore")
# Chinese characters, CJK punctuation (「」、。) and full-width forms (，：（）).
HAN = re.compile(r"[㐀-鿿\u3000-\u303f\uff00-\uffef]")
# Entries whose English stays in Info.plist: the English display name is MEOWVERSE_DISPLAY_NAME
# (Config.xcconfig), so a worktree's Local.xcconfig name still shows; only 喵空间 is translated.
ENGLISH_FROM_INFO_PLIST = {("InfoPlist.xcstrings", "CFBundleDisplayName")}
# Compile conditions off in the default build: their code yields no .stringsdata there.
OPTIONAL_CONDITIONS = ("MEOWVERSE_TALK_TO_BELLA",)
SPEC = re.compile(r"%(?:(\d+)\$)?(#@\w+@|l{0,2}[dufsx@])")
OPT_OUT = "not-localized:"


def placeholders(text):
    """Placeholders as (position, type); unnumbered ones are numbered in order."""
    found, position = [], 0
    for match in SPEC.finditer(text.replace("%%", "")):
        position = int(match.group(1)) if match.group(1) else position + 1
        found.append((position, match.group(2)))
    return sorted(found)


def unit_problems(key, unit, where):
    problems = []
    if unit.get("state") != "translated":
        problems.append(f"{where}: state is {unit.get('state')!r}, not 'translated'")
    value = unit.get("value", "")
    if not value.strip() and key.strip():
        problems.append(f"{where}: empty English text")
    if HAN.search(value):
        problems.append(f"{where}: English text contains Chinese characters: {value!r}")
    return problems


def english_units(localization):
    """All (label, stringUnit) of one localisation, through plural variations and substitutions."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"]
    for kind, cases in localization.get("variations", {}).items():
        for case, inner in cases.items():
            for label, unit in english_units(inner):
                yield f"{kind}.{case}{label and '.' + label}", unit
    for name, substitution in localization.get("substitutions", {}).items():
        for label, unit in english_units(substitution):
            yield f"{name}.{label}", unit


def check_catalog(path, count_keys_need_plurals=True):
    problems = []
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    name = os.path.basename(path)
    if catalog.get("sourceLanguage") != "zh-Hans":
        problems.append(f"{name}: sourceLanguage is not zh-Hans")
    for key, entry in catalog["strings"].items():
        where = f"{name}: {key!r}"
        if entry.get("extractionState") == "stale":
            problems.append(f"{where}: stale (no longer in the source)")
        if not key.strip() or entry.get("shouldTranslate") is False or (name, key) in ENGLISH_FROM_INFO_PLIST:
            continue
        english = entry.get("localizations", {}).get("en")
        if english is None:
            problems.append(f"{where}: no English translation")
            continue
        # An entry with an explicit key carries its Chinese text as a value; otherwise the key is the text.
        chinese = entry.get("localizations", {}).get("zh-Hans", {})
        source = chinese.get("stringUnit", {}).get("value", key)
        # A plural entry without its own Chinese string falls back to the development region
        # (English) in the Chinese UI, so "1 changes are waiting" shows up among Chinese text.
        if "substitutions" in english and not chinese:
            problems.append(f"{where}: English plural without a zh-Hans string (Chinese UI would show English)")
        for label, unit in english_units(chinese):
            if unit.get("state") != "translated":
                problems.append(f"{where}: Chinese text is in state {unit.get('state')!r}")
        units = list(english_units(english))
        if not units:
            problems.append(f"{where}: no English translation")
        for label, unit in units:
            problems += unit_problems(key, unit, f"{where} [{label}]" if label else where)
        # Placeholders: the top-level English text must take the same arguments as the key.
        top = english.get("stringUnit", {}).get("value")
        if top is not None:
            substitutions = english.get("substitutions", {})
            got = [(p, t) for p, t in placeholders(top) if not t.startswith("#@")]
            for match in SPEC.finditer(top):
                if match.group(2).startswith("#@"):
                    sub = substitutions.get(match.group(2)[2:-1])
                    if sub is None:
                        problems.append(f"{where}: substitution {match.group(2)} is not defined")
                    else:
                        got.append((sub["argNum"], "ll" + sub["formatSpecifier"].lstrip("l")))
            want = [(p, "ll" + t.lstrip("l") if t.endswith(("d", "u")) else t) for p, t in placeholders(source)]
            got = [(p, "ll" + t.lstrip("l") if t.endswith(("d", "u")) else t) for p, t in got]
            if sorted(set(got)) != sorted(set(want)) and not set(got) < set(want):
                problems.append(f"{where}: placeholders differ: key {want}, English {sorted(got)}")
        elif "variations" in english:
            for label, unit in units:
                extra = set(placeholders(unit.get("value", ""))) - set(placeholders(source))
                if extra:
                    problems.append(f"{where} [{label}]: placeholders not in the key: {sorted(extra)}")
        # Count phrases: an integer placeholder next to an English noun needs plural forms.
        if count_keys_need_plurals and "%lld" in key and entry.get("comment", "").find("no-plural") < 0:
            if "variations" not in english and "substitutions" not in english:
                problems.append(f"{where}: has a count but no English plural variations "
                                "(add them, or put 'no-plural: <reason>' in the comment)")
    return catalog, problems


def catalog_names():
    names = set()
    for path in glob.glob(os.path.join(CORE, "Resources", "*.catalog.json")):
        with open(path, encoding="utf-8") as handle:
            for model in json.load(handle)["models"]:
                names.add(model["label"])
                names.update(site["label"] for site in model.get("sites") or [])
    with open(os.path.join(CORE, "Catalog.swift"), encoding="utf-8") as handle:
        names.update(re.findall(r'label: "([^"]+)"', handle.read()))
    return names


def han_literals(source):
    """(line, column, text) of every string literal with Chinese text, comments skipped.
    Line and column are 1-based and point at the opening quote, as in .stringsdata."""
    found = []
    i, line, column = 0, 1, 1
    length = len(source)

    def advance(count=1):
        nonlocal i, line, column
        for _ in range(count):
            if source[i] == "\n":
                line, column = line + 1, 1
            else:
                column += len(source[i].encode("utf-8"))  # .stringsdata counts UTF-8 bytes
            i += 1

    def literal():
        start = (line, column)
        triple = source.startswith('"""', i)
        advance(3 if triple else 1)
        begin = i
        while i < length:
            if source[i] == "\\" and i + 1 < length:
                if source[i + 1] == "(":
                    advance(2)
                    code(")")
                else:
                    advance(2)
                continue
            if triple and source.startswith('"""', i):
                text = source[begin:i]
                advance(3)
                break
            if not triple and source[i] == '"':
                text = source[begin:i]
                advance()
                break
            advance()
        else:
            text = source[begin:]
        outer = re.sub(r"\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)", "", text)
        if HAN.search(outer):
            found.append((start[0], start[1], text))

    def code(until=None):
        depth = 0
        while i < length:
            char = source[i]
            if source.startswith("//", i):
                while i < length and source[i] != "\n":
                    advance()
            elif source.startswith("/*", i):
                while i < length and not source.startswith("*/", i):
                    advance()
                advance(min(2, length - i))
            elif char == '"':
                literal()
            elif char == "(":
                depth += 1
                advance()
            elif char == ")":
                if until == ")" and depth == 0:
                    advance()
                    return
                depth -= 1
                advance()
            else:
                advance()

    code()
    return found


def optional_lines(source):
    """Line numbers (1-based) inside `#if <condition>` blocks for OPTIONAL_CONDITIONS, `#else` excluded."""
    inside, found = [], set()
    for number, text in enumerate(source.split("\n"), start=1):
        stripped = text.strip()
        if stripped.startswith("#if "):
            inside.append(stripped[4:].strip() in OPTIONAL_CONDITIONS)
        elif stripped.startswith(("#else", "#elseif")) and inside:
            inside[-1] = False
        elif stripped.startswith("#endif") and inside:
            inside.pop()
        elif any(inside):
            found.add(number)
    return found


def audit_sources(stringsdata_dir, catalogs):
    problems = []
    extracted = {}
    keys = {}
    files = glob.glob(os.path.join(stringsdata_dir, "*.stringsdata"))
    if not files:
        return [f"no .stringsdata files in {stringsdata_dir}"]
    for path in files:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                location = entry.get("location", {})
                extracted.setdefault(os.path.realpath(data["source"]), set()).add(
                    (location.get("startingLine"), location.get("startingColumn")))
                keys.setdefault(table, set()).add(entry["key"])
    sources = {}
    for path in sorted(glob.glob(os.path.join(APP, "**", "*.swift"), recursive=True)):
        with open(path, encoding="utf-8") as handle:
            sources[path] = handle.read()
    # A condition counts as off when nothing inside it was extracted anywhere.
    regions = {path: optional_lines(source) for path, source in sources.items()}
    compiled = {line for path in sources for line, _ in extracted.get(os.path.realpath(path), set()) if line in regions[path]}
    skip_optional = not compiled
    for path, source in sources.items():
        lines = source.split("\n")
        seen = extracted.get(os.path.realpath(path), set())
        for line, column, text in han_literals(source):
            if skip_optional and line in regions[path]:
                continue
            before = lines[line - 1].encode("utf-8")[:column - 1].decode("utf-8").rstrip()
            # `defaultValue:` is the Chinese text of an entry with an explicit key; `comment:` is for translators.
            if (line, column) in seen or OPT_OUT in lines[line - 1] or before.endswith(("defaultValue:", "comment:")):
                continue
            problems.append(f"{os.path.relpath(path, ROOT)}:{line}:{column}: Chinese text is not localised: {text!r}")
    for table in sorted(keys):
        catalog = catalogs.get(table)
        if catalog is None:
            problems.append(f"{table}.xcstrings: no such catalog, but the source uses the table")
            continue
        for key in sorted(keys[table] - set(catalog["strings"])):
            problems.append(f"{table}.xcstrings: missing key used in the source: {key!r}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stringsdata", help="directory with the .stringsdata files of an app build")
    arguments = parser.parse_args()

    problems = []
    main_catalog, found = check_catalog(os.path.join(APP, "Localizable.xcstrings"))
    problems += found
    names_catalog, found = check_catalog(os.path.join(APP, "CatalogNames.xcstrings"), count_keys_need_plurals=False)
    problems += found
    for name in sorted(catalog_names() - set(names_catalog["strings"])):
        problems.append(f"CatalogNames.xcstrings: no entry for the catalog name {name!r}")
    catalogs = {"Localizable": main_catalog, "CatalogNames": names_catalog}
    # The other string tables (RoomAR, RoomSounds, PocketCat shared with the widget, ...): the
    # same checks, no plural rule.
    tables = glob.glob(os.path.join(APP, "*.xcstrings")) + glob.glob(os.path.join(ROOT, "PocketCatShared", "*.xcstrings"))
    for path in sorted(tables):
        table = os.path.splitext(os.path.basename(path))[0]
        if table not in catalogs:
            catalogs[table], found = check_catalog(path, count_keys_need_plurals=False)
            problems += found
    if arguments.stringsdata:
        problems += audit_sources(arguments.stringsdata, catalogs)

    for problem in problems:
        print(problem)
    total = sum(len(catalog["strings"]) for catalog in catalogs.values())
    print(f"{total} catalog entries checked, {len(problems)} problem(s)"
          + ("" if arguments.stringsdata else " (sources not audited: pass --stringsdata)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
