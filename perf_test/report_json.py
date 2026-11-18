#!/usr/bin/env python3
"""根据 perf_test/result* 目录中的 summary.txt / 日志生成 result.json。

用法:
    python3 perf_test/report_json.py perf_test/result1

web 服务只读取 result.json，避免直接解析人类可读的 summary.txt。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SIZE_TO_MIB = {
    "": 1.0 / (1024.0 * 1024.0),
    "K": 1.0 / 1024.0,
    "M": 1.0,
    "G": 1024.0,
    "T": 1024.0 * 1024.0,
}

PHASE_NAMES = ("cpuwork", "memwork")


def size_to_mib(text: str | None) -> float | None:
    if not text:
        return None
    match = re.match(r"\s*([0-9.]+)\s*([KMGT]?)", text)
    if not match:
        return None
    return round(float(match.group(1)) * SIZE_TO_MIB[match.group(2)], 3)


def parse_phase_row(line: str) -> dict | None:
    parts = line.split()
    if len(parts) != 6 or parts[0] not in PHASE_NAMES:
        return None
    try:
        return {
            "name": parts[0],
            "units": int(parts[1]),
            "seconds": round(float(parts[2]), 3),
            "rate_mops": round(float(parts[3]), 2),
            "rss_mib": round(float(parts[4]), 1),
            "peak_rss_mib": round(float(parts[5]), 1),
        }
    except ValueError:
        return None


def read_dso_share(result_dir: Path) -> list[dict]:
    """读 perf_dso_share.txt，格式: ' 50.71%  10018  10028028018  libcpuwork.so'。"""
    share_path = result_dir / "perf_dso_share.txt"
    share: list[dict] = []
    if not share_path.is_file():
        return share

    for line in share_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(
            r"\s*([0-9.]+)%\s+(\d+)\s+(\d+)\s+(.+?)\s*$", line
        )
        if match:
            share.append(
                {
                    "dso": match.group(4),
                    "percent": round(float(match.group(1)), 2),
                    "samples": int(match.group(2)),
                    "period": int(match.group(3)),
                }
            )
    return share


def read_heaptrack(result_dir: Path) -> dict:
    path = result_dir / "heaptrack_summary.txt"
    if not path.is_file():
        return {}

    text = path.read_text(encoding="utf-8", errors="replace")
    result: dict = {}

    match = re.search(r"total runtime:\s*([0-9.]+)s", text)
    if match:
        result["total_runtime_s"] = round(float(match.group(1)), 3)

    match = re.search(r"calls to allocation functions:\s*(\d+)", text)
    if match:
        result["allocations"] = int(match.group(1))

    match = re.search(r"temporary memory allocations:\s*(\d+)", text)
    if match:
        result["temporary_allocations"] = int(match.group(1))

    match = re.search(r"peak heap memory consumption:\s*([0-9.]+[KMGT]?)", text)
    if match:
        result["peak_heap_mib"] = size_to_mib(match.group(1))

    match = re.search(
        r"peak RSS \(including heaptrack overhead\):\s*([0-9.]+[KMGT]?)", text
    )
    if match:
        result["peak_rss_mib"] = size_to_mib(match.group(1))

    match = re.search(r"total memory leaked:\s*([0-9.]+[KMGT]?)", text)
    if match:
        result["leaked_mib"] = size_to_mib(match.group(1))

    return result


def build_result(result_dir: str | Path) -> dict:
    result_dir = Path(result_dir)
    summary_file = result_dir / "summary.txt"
    if not summary_file.is_file():
        raise FileNotFoundError(f"{summary_file} 不存在")

    text = summary_file.read_text(encoding="utf-8", errors="replace")

    def grab(label: str) -> str | None:
        match = re.search(rf"^{re.escape(label)}\s+:\s*(.*)$", text, re.M)
        return match.group(1).strip() if match else None

    data: dict = {
        "name": result_dir.name,
        "generated": grab("generated"),
        "bench": grab("bench"),
        "bench_args": grab("bench args"),
        "heaptrack_args": grab("heaptrack args"),
        "perf_event": grab("perf event"),
        "runtime": {
            "perf_span_s": None,
            "perf_wall_s": None,
            "bench_self_s": None,
            "heaptrack_s": None,
        },
        "phases": [],
        "share": [],
        "memory": {
            "program_perf": {},
            "program_heaptrack": {},
            "heaptrack": {},
        },
        "files": {
            "peak_svg": (result_dir / "peak.svg").is_file(),
            "leaked_svg": (result_dir / "leaked.svg").is_file(),
        },
    }

    runtime_patterns = {
        "perf_span_s": r"perf sample span\s+:\s*([0-9.]+)",
        "perf_wall_s": r"perf round wall\s+:\s*([0-9.]+)",
        "bench_self_s": r"bench self-timed\s+:\s*([0-9.]+)",
        "heaptrack_s": r"heaptrack runtime\s+:\s*([0-9.]+)",
    }
    for key, pattern in runtime_patterns.items():
        match = re.search(pattern, text)
        if match:
            data["runtime"][key] = round(float(match.group(1)), 3)

    summary_share: list[dict] = []
    section = None
    mem_target = None

    for raw in text.splitlines():
        line = raw.strip()
        section_match = re.match(r"-+\s*\[(\d)\]", line)
        if section_match:
            section = int(section_match.group(1))
            if section == 3:
                mem_target = None
            continue

        if section == 1:
            phase = parse_phase_row(line)
            if phase:
                data["phases"].append(phase)
                continue

        if section == 2 and not data["share"]:
            match = re.match(
                r"([0-9.]+)%\s+([0-9.]+)\s*s\s+(\d+)\s+(\d+)\s+(.+?)\s*$",
                line,
            )
            if match:
                summary_share.append(
                    {
                        "dso": match.group(5),
                        "percent": round(float(match.group(1)), 2),
                        "samples": int(match.group(3)),
                        "period": int(match.group(4)),
                        "est_seconds": round(float(match.group(2)), 3),
                    }
                )
                continue

        if section == 3:
            if line.startswith("program (perf"):
                mem_target = "program_perf"
                continue
            if line.startswith("program (heaptrack"):
                mem_target = "program_heaptrack"
                continue
            if line.startswith("heaptrack ("):
                mem_target = None
                continue
            if mem_target:
                match = re.match(r"rss after init:\s*([0-9.]+)\s*MB", line)
                if match:
                    data["memory"][mem_target]["rss_after_init_mib"] = round(
                        float(match.group(1)), 1
                    )
                    continue
                match = re.match(r"peak rss\s+:\s*([0-9.]+)\s*MB", line)
                if match:
                    data["memory"][mem_target]["peak_rss_mib"] = round(
                        float(match.group(1)), 1
                    )
                    continue
                match = re.match(r"intentional leak\s+:\s*(\d+)\s*MB", line)
                if match:
                    data["memory"][mem_target]["intentional_leak_mib"] = int(
                        match.group(1)
                    )
                    continue

    data["share"] = read_dso_share(result_dir) or summary_share
    data["memory"]["heaptrack"] = read_heaptrack(result_dir)

    return data


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <result_dir>", file=sys.stderr)
        return 2

    result_dir = Path(argv[1])
    try:
        data = build_result(result_dir)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    output = result_dir / "result.json"
    output.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
