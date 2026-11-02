"""Collect PYNQ software information without programming PL or accessing MMIO."""
import argparse
import importlib
import json
import platform
import sys
from pathlib import Path


def collect():
    report = {
        "system": platform.system(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "python_executable": sys.executable,
        "board_model": None,
        "pynq_version": None,
        "api_imports": {},
        "errors": {},
        "hardware_tested": False,
    }
    model = Path("/proc/device-tree/model")
    try:
        if model.exists():
            report["board_model"] = model.read_bytes().rstrip(b"\0").decode(errors="replace")
    except OSError as error:
        report["errors"]["board_model"] = "{}: {}".format(type(error).__name__, error)
    try:
        pynq = importlib.import_module("pynq")
        report["pynq_version"] = getattr(pynq, "__version__", "unknown")
    except Exception as error:
        pynq = None
        report["errors"]["pynq"] = "{}: {}".format(type(error).__name__, error)
    for module_name, attribute in (
        ("pynq", "Overlay"),
        ("pynq", "MMIO"),
        ("pynq", "allocate"),
        ("pynq.ps", "Clocks"),
    ):
        key = module_name + "." + attribute
        report["api_imports"][key] = False
        if pynq is None:
            continue
        try:
            getattr(importlib.import_module(module_name), attribute)
            report["api_imports"][key] = True
        except Exception as error:
            report["errors"][key] = "{}: {}".format(type(error).__name__, error)
    report["core_apis_importable"] = all(
        report["api_imports"][key] for key in ("pynq.Overlay", "pynq.MMIO")
    )
    machine = report["machine"].lower()
    report["embedded_arm_linux_candidate"] = (
        report["system"] == "Linux"
        and (machine.startswith("arm") or machine in ("aarch64", "aarch64_be"))
    )
    report["interpretation"] = (
        "Software import check only; board compatibility, permissions, clocks and PL operation are untested."
    )
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write JSON to a new file; refuses overwrite")
    args = parser.parse_args(argv)
    report = collect()
    payload = json.dumps(report, indent=2, ensure_ascii=True)
    if args.output is not None:
        try:
            with args.output.open("x", encoding="utf-8") as handle:
                handle.write(payload + "\n")
        except OSError as error:
            parser.exit(2, "Cannot write report: {}\n".format(error))
    print(payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
