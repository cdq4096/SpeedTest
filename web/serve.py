#!/usr/bin/env python3
"""p1bench 结果查看器：静态页面 + result.json API，仅用 Python 标准库。

用法:
    python3 web/serve.py [--host 127.0.0.1] [--port 8000] [--results perf_test]

  - GET /                 页面
  - GET /api/results      所有 result*/result.json 的 JSON
  - GET /files/<name>/<f> 只允许 peak.svg / leaked.svg
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

WEB_DIR = Path(__file__).resolve().parent
STATIC_DIR = WEB_DIR / "static"
DEFAULT_RESULTS_DIR = WEB_DIR.parent / "perf_test"

ALLOWED_SVG = {"peak.svg", "leaked.svg"}
RESULT_NAME_RE = re.compile(r"result[^/\\]*")

MIME_OVERRIDES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
}


def natural_key(name: str) -> list:
    return [int(part) if part.isdigit() else part.lower()
            for part in re.split(r"(\d+)", name)]


class ResultStore:
    def __init__(self, results_dir: Path):
        self.results_dir = results_dir.resolve()

    def dirs(self) -> list[Path]:
        if not self.results_dir.is_dir():
            return []
        return sorted(
            (p for p in self.results_dir.iterdir()
             if p.is_dir() and p.name.startswith("result")),
            key=lambda p: natural_key(p.name),
        )

    def names(self) -> set[str]:
        return {p.name for p in self.dirs()}

    def load_all(self) -> list[dict]:
        results = []
        for directory in self.dirs():
            entry: dict = {"name": directory.name}
            json_file = directory / "result.json"
            if not json_file.is_file():
                entry["error"] = (
                    "缺少 result.json。请用最新 perf_test/run.sh 重新生成结果，"
                    "或执行: python3 perf_test/report_json.py <result_dir>"
                )
                results.append(entry)
                continue
            try:
                data = json.loads(json_file.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                entry["error"] = f"result.json 读取失败: {exc}"
                results.append(entry)
                continue

            data["name"] = directory.name
            files = {}
            for key, filename in (("peak_svg", "peak.svg"),
                                  ("leaked_svg", "leaked.svg")):
                if (directory / filename).is_file():
                    files[key] = f"/files/{directory.name}/{filename}"
            data["files"] = files
            results.append(data)
        return results

    def svg_path(self, name: str, filename: str) -> Path | None:
        if not RESULT_NAME_RE.fullmatch(name) or filename not in ALLOWED_SVG:
            return None
        if name not in self.names():
            return None
        path = (self.results_dir / name / filename).resolve()
        if not path.is_file() or self.results_dir not in path.parents:
            return None
        return path


class Handler(BaseHTTPRequestHandler):
    server_version = "p1bench-web/1.0"

    @property
    def store(self) -> ResultStore:
        return self.server.store  # type: ignore[attr-defined]

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(urlsplit(self.path).path)

        if path == "/api/results":
            payload = json.dumps(
                {"results": self.store.load_all()},
                ensure_ascii=False,
            ).encode("utf-8")
            self._send(payload, "application/json; charset=utf-8", cache="no-store")
            return

        if path.startswith("/files/"):
            parts = path[len("/files/"):].split("/")
            if len(parts) != 2:
                self._not_found()
                return
            file_path = self.store.svg_path(parts[0], parts[1])
            if file_path is None:
                self._not_found()
                return
            self._send(file_path.read_bytes(), "image/svg+xml", cache="no-cache")
            return

        self._serve_static(path)

    def _serve_static(self, path: str) -> None:
        relative = "index.html" if path in ("", "/") else path.lstrip("/")
        target = (STATIC_DIR / relative).resolve()
        if target != STATIC_DIR and STATIC_DIR not in target.parents:
            self._not_found()
            return
        if target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            self._not_found()
            return

        suffix = target.suffix.lower()
        content_type = MIME_OVERRIDES.get(
            suffix, mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        )
        self._send(target.read_bytes(), content_type, cache="no-cache")

    def _send(self, payload: bytes, content_type: str, cache: str = "no-store") -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(payload)

    def _not_found(self) -> None:
        payload = b"404 not found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(f"[web] {self.address_string()} {fmt % args}\n")


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    parser = argparse.ArgumentParser(description="p1bench 结果查看器")
    parser.add_argument("--host", default="127.0.0.1",
                        help="监听地址，默认 127.0.0.1")
    parser.add_argument("--port", type=int, default=8000,
                        help="监听端口，默认 8000")
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS_DIR,
                        help=f"结果目录，默认 {DEFAULT_RESULTS_DIR}")
    args = parser.parse_args()

    results_dir = args.results.resolve()
    store = ResultStore(results_dir)

    server = Server((args.host, args.port), Handler)
    server.store = store  # type: ignore[attr-defined]

    print(f"p1bench 结果查看器: http://{args.host}:{args.port}/", flush=True)
    print(f"结果目录: {results_dir}", flush=True)
    print(f"发现结果: {len(store.dirs())} 个"
          + (f" ({', '.join(p.name for p in store.dirs())})" if store.dirs() else ""),
          flush=True)
    print("按 Ctrl+C 停止", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
