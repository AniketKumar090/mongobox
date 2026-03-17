#!/usr/bin/env python3
"""
start.py
========
One-command launcher for the MongoBox voice backend.
Checks dependencies, installs anything missing, then starts uvicorn.

Usage
-----
    python start.py                     # default: port 8000
    python start.py --port 9000         # custom port
    python start.py --host 0.0.0.0      # expose on LAN (for physical device)
    python start.py --reload            # dev mode: auto-restart on code change
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys


BOLD = "\033[1m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
RESET = "\033[0m"


def banner() -> None:
    print(
        f"""
{BOLD}╔══════════════════════════════════════════╗
║   MongoBox  •  Voice Cloning Backend     ║
║   Coqui XTTS-v2  •  Free / Local         ║
╚══════════════════════════════════════════╝{RESET}
"""
    )


def check_python() -> None:
    major, minor = sys.version_info[:2]
    if (major, minor) < (3, 10):
        print(f"{RED}✗  Python 3.10+ required (found {major}.{minor}){RESET}")
        sys.exit(1)
    print(f"{GREEN}✓  Python {major}.{minor}{RESET}")


def check_ffmpeg() -> None:
    if shutil.which("ffmpeg"):
        print(f"{GREEN}✓  ffmpeg found{RESET}")
        return

    print(f"{YELLOW}⚠  ffmpeg not found — required for .m4a → WAV conversion.{RESET}")
    print("   macOS:   brew install ffmpeg")
    print("   Ubuntu:  sudo apt install ffmpeg")
    print("   Windows: https://ffmpeg.org/download.html")
    answer = input("\n   Continue anyway? [y/N] ").strip().lower()
    if answer != "y":
        sys.exit(1)


def install_requirements() -> None:
    req_file = os.path.join(os.path.dirname(__file__), "requirements.txt")
    if not os.path.exists(req_file):
        print(f"{RED}✗  requirements.txt not found next to start.py{RESET}")
        sys.exit(1)

    print(f"\n{BOLD}Checking Python packages …{RESET}")
    result = subprocess.run([sys.executable, "-m", "pip", "install", "-r", req_file, "--quiet"])
    if result.returncode != 0:
        print(f"{RED}✗  pip install failed — check the error above.{RESET}")
        sys.exit(1)
    print(f"{GREEN}✓  All packages installed{RESET}")


def check_cuda() -> None:
    try:
        import torch

        if torch.cuda.is_available():
            name = torch.cuda.get_device_name(0)
            print(f"{GREEN}✓  CUDA GPU detected: {name} — inference will be fast{RESET}")
        else:
            print(f"{YELLOW}ℹ  No CUDA GPU — running on CPU.{RESET}")
            print("   CPU inference can take ~30–120 s depending on lyrics length.")
    except ImportError:
        pass


def start_server(host: str, port: int, reload: bool) -> None:
    print(f"\n{BOLD}Starting FastAPI server …{RESET}")
    print(f"  URL:    {GREEN}http://{host}:{port}{RESET}")
    print(f"  Health: {GREEN}http://{host}:{port}/health{RESET}")
    print(f"\n  Flutter VOICE_BACKEND_URL = http://<your-machine-ip>:{port}")
    print("  (For iOS Simulator use 127.0.0.1; for Android emulator use 10.0.2.2)")
    print("\n  XTTS-v2 model (~2 GB) downloads on first run.\n")

    cmd = [
        sys.executable,
        "-m",
        "uvicorn",
        "main:app",
        "--host",
        host,
        "--port",
        str(port),
    ]
    if reload:
        cmd.append("--reload")

    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    os.execvp(cmd[0], cmd)


def main() -> None:
    parser = argparse.ArgumentParser(description="Start the MongoBox voice backend.")
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Bind host (default 127.0.0.1; use 0.0.0.0 for LAN)",
    )
    parser.add_argument("--port", type=int, default=8000, help="Port number (default 8000)")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload (dev mode)")
    parser.add_argument(
        "--skip-install", action="store_true", help="Skip pip install step (faster start)"
    )
    args = parser.parse_args()

    banner()
    print(f"{BOLD}Pre-flight checks{RESET}")
    print("─" * 44)
    check_python()
    check_ffmpeg()

    if not args.skip_install:
        install_requirements()

    check_cuda()
    start_server(args.host, args.port, args.reload)


if __name__ == "__main__":
    main()

