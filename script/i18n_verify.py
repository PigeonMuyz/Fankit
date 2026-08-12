#!/usr/bin/env python3
"""Build and verify that every Fankit localization has the same complete key set."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "ja", "yue-Hant")
STRINGS_LINE = re.compile(
    r'^\s*"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";\s*$'
)
L10N_CALL = re.compile(
    r'L10n\.(?:string|format)\(\s*"((?:\\.|[^"\\])*)"', re.DOTALL
)
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|f)')


def decode(value: str) -> str:
    return json.loads(f'"{value}"')


def read_strings(path: pathlib.Path) -> tuple[dict[str, str], list[str]]:
    values: dict[str, str] = {}
    duplicates: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = STRINGS_LINE.match(line)
        if not match:
            continue
        key, value = map(decode, match.groups())
        if key in values:
            duplicates.append(key)
        values[key] = value
    return values, duplicates


def build(derived_data: pathlib.Path) -> None:
    result = subprocess.run(
        [
            "xcodebuild",
            "-project",
            "Fankit.xcodeproj",
            "-scheme",
            "Fankit",
            "-configuration",
            "Debug",
            "-derivedDataPath",
            str(derived_data),
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        print(result.stdout)
        raise SystemExit("The localization audit build failed.")


def compiler_keys(derived_data: pathlib.Path) -> set[str]:
    keys: set[str] = set()
    for path in derived_data.rglob("*.stringsdata"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        source = data.get("source", "")
        if "/Fankit/Fankit/" not in source:
            continue
        for table in data.get("tables", {}).values():
            keys.update(item["key"] for item in table)
    return keys


def dynamic_keys() -> set[str]:
    keys: set[str] = set()
    source_root = REPO / "Fankit"
    for path in source_root.rglob("*.swift"):
        source = path.read_text(encoding="utf-8")
        keys.update(decode(match) for match in L10N_CALL.findall(source))

    hardware = (source_root / "Services/HardwareMonitor.swift").read_text(encoding="utf-8")
    keys.update(re.findall(r'name: "([^"]+)"', hardware))
    keys.update(("Left Side", "Right Side", "System Fan"))

    curves = (source_root / "Models/ThermalCurve.swift").read_text(encoding="utf-8")
    keys.update(re.findall(r'(?:name|summary): "([^"]+)"', curves))
    keys.update(("Your editable temperature curve.", "Custom fan preset."))
    keys.update(("Processor", "Graphics", "Memory", "Battery", "Airflow", "System"))
    return keys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derived-data", type=pathlib.Path)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()

    temporary: tempfile.TemporaryDirectory[str] | None = None
    if args.derived_data:
        derived_data = args.derived_data.resolve()
    else:
        temporary = tempfile.TemporaryDirectory(prefix="fan-control-i18n-")
        derived_data = pathlib.Path(temporary.name)

    if not args.skip_build:
        build(derived_data)

    required = compiler_keys(derived_data) | dynamic_keys()
    localizations: dict[str, dict[str, str]] = {}
    problems: list[str] = []
    for language in LANGUAGES:
        path = REPO / "Fankit" / f"{language}.lproj" / "Localizable.strings"
        values, duplicates = read_strings(path)
        localizations[language] = values
        if duplicates:
            problems.append(f"{language}: duplicate keys: {', '.join(sorted(duplicates))}")
        if missing := required - values.keys():
            problems.append(f"{language}: missing keys: {', '.join(sorted(missing))}")
        if empty := sorted(key for key, value in values.items() if not value.strip()):
            problems.append(f"{language}: empty values: {', '.join(empty)}")

    base_keys = set(localizations["en"])
    for language in LANGUAGES[1:]:
        keys = set(localizations[language])
        if missing := base_keys - keys:
            problems.append(f"{language}: keys missing from English set: {', '.join(sorted(missing))}")
        if extra := keys - base_keys:
            problems.append(f"{language}: keys absent from English set: {', '.join(sorted(extra))}")

    for language, values in localizations.items():
        for key, value in values.items():
            expected = sorted(PLACEHOLDER.findall(key))
            actual = sorted(PLACEHOLDER.findall(value))
            if expected != actual:
                problems.append(
                    f"{language}: placeholder mismatch for {key!r}: {expected} != {actual}"
                )

    if problems:
        print("\n".join(problems))
        raise SystemExit(1)
    print(
        f"i18n verified: {len(required)} referenced keys, "
        f"{len(base_keys)} resource keys, {len(LANGUAGES)} languages"
    )

    if temporary is not None:
        temporary.cleanup()


if __name__ == "__main__":
    main()
