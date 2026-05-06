#!/usr/bin/env python3
"""
start.py
========
One-command launcher for the MongoBox voice backend.
Checks dependencies, installs anything missing, then starts uvicorn.

Usage
-----
    python start.py                     # default: 0.0.0.0:8000 (phone + simulator)
    python start.py --port 9000         # custom port
    python start.py --host 127.0.0.1    # loopback only (stricter)
    python start.py --reload            # dev mode: auto-restart on code change
"""

from __future__ import annotations

import argparse
import importlib
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
║   Voicebox API  •  Remote synthesis      ║
╚══════════════════════════════════════════╝{RESET}
"""
    )


def check_python() -> None:
    major, minor = sys.version_info[:2]
    if (major, minor) < (3, 10):
        print(f"{RED}✗  Python 3.10+ required (found {major}.{minor}){RESET}")
        sys.exit(1)
    print(f"{GREEN}✓  Python {major}.{minor}{RESET}")


def check_ffmpeg(auto_continue: bool = False) -> None:
    if shutil.which("ffmpeg"):
        print(f"{GREEN}✓  ffmpeg found{RESET}")
        return

    print(f"{YELLOW}⚠  ffmpeg not found — required for .m4a → WAV conversion.{RESET}")
    print("   macOS:   brew install ffmpeg")
    print("   Ubuntu:  sudo apt install ffmpeg")
    print("   Windows: https://ffmpeg.org/download.html")
    if auto_continue:
        print(f"{YELLOW}ℹ  Continuing because auto-boot mode is enabled.{RESET}")
        return
    answer = input("\n   Continue anyway? [y/N] ").strip().lower()
    if answer != "y":
        sys.exit(1)


def _requirements_file() -> str:
    return os.path.join(os.path.dirname(__file__), "requirements.txt")


def install_requirements() -> None:
    req_file = _requirements_file()
    if not os.path.exists(req_file):
        print(f"{RED}✗  Dependency file not found: {req_file}{RESET}")
        sys.exit(1)

    print(f"\n{BOLD}Checking Python packages …{RESET}")
    print(f"  Requirements: {GREEN}{os.path.basename(req_file)}{RESET}")
    result = subprocess.run([sys.executable, "-m", "pip", "install", "-r", req_file])
    if result.returncode != 0:
        print(f"{RED}✗  pip install failed — check the error above.{RESET}")
        sys.exit(1)
    print(f"{GREEN}✓  All packages installed{RESET}")


def check_background_mix_stack(auto_continue: bool = False) -> None:
    missing: list[str] = []
    for module_name, label in (("demucs", "demucs"), ("torchcodec", "torchcodec")):
        try:
            importlib.import_module(module_name)
        except Exception:
            missing.append(label)

    if not missing:
        print(f"{GREEN}✓  Background music extraction stack ready{RESET}")
        return

    print(
        f"{YELLOW}⚠  Background music mixing may be unavailable — missing: {', '.join(missing)}{RESET}"
    )
    print("   Run: python -m pip install -r requirements.txt")
    if auto_continue:
        print(f"{YELLOW}ℹ  Continuing because auto-boot mode is enabled.{RESET}")
        return
    answer = input("\n   Continue anyway? [y/N] ").strip().lower()
    if answer != "y":
        sys.exit(1)


def _primary_lan_ipv4() -> str | None:
    """Best-effort LAN address for Flutter `VOICE_BACKEND_DEVICE_URL` hints."""
    import socket

    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("10.254.254.254", 1))
            ip = probe.getsockname()[0]
            if ip and not ip.startswith("127."):
                return ip
        finally:
            probe.close()
    except OSError:
        pass

    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if ip and not ip.startswith("127."):
                return ip
    except OSError:
        pass

    return None


def check_cuda() -> None:
    try:
        import torch

        if torch.cuda.is_available():
            name = torch.cuda.get_device_name(0)
            print(f"{GREEN}✓  CUDA GPU detected: {name} — inference will be fast{RESET}")
        else:
            print(f"{YELLOW}ℹ  No CUDA GPU — running on CPU.{RESET}")
            print("   CPU inference can take a while during first-run warmup.")
    except ImportError:
        pass


def start_server(host: str, port: int, reload: bool) -> None:
    # Disable numba JIT cache to avoid "no locator available" when disk is full
    # or cache dir is unwritable (e.g. read-only volume, sandbox).
    os.environ.setdefault("NUMBA_DISABLE_JIT_CACHE", "1")
    os.environ.setdefault("MONGOBOX_TTS_ENGINE", "voicebox")
    voicebox_url = (os.environ.get("VOICEBOX_API_URL", "http://127.0.0.1:17493") or "").strip()

    lan_ip = _primary_lan_ipv4()
    print(f"\n{BOLD}Starting FastAPI server …{RESET}")
    print(f"  Bind:   {GREEN}{host}:{port}{RESET}")
    print(f"  URL:    {GREEN}http://{host}:{port}{RESET}")
    print(f"  Health: {GREEN}http://{host}:{port}/health{RESET}")
    print(f"  Voicebox API:      {GREEN}{voicebox_url}{RESET}")
    if lan_ip:
        print(
            f"\n  {BOLD}Physical phone / tablet on Wi-Fi:{RESET} "
            f"set {GREEN}VOICE_BACKEND_DEVICE_URL=http://{lan_ip}:{port}{RESET}"
        )
        print(f"  Quick check from phone browser: http://{lan_ip}:{port}/health")
    print(
        f"\n  iOS Simulator may keep {GREEN}VOICE_BACKEND_URL=http://127.0.0.1:{port}{RESET}"
    )
    print("  Android emulator uses http://10.0.2.2:$PORT for the host machine.")
    print("\n  Demucs may download weights on first instrumental separation.\n")

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
        default="0.0.0.0",
        help="Bind host (default 0.0.0.0 for LAN + localhost; use 127.0.0.1 for loopback only)",
    )
    parser.add_argument("--port", type=int, default=8000, help="Port number (default 8000)")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload (dev mode)")
    parser.add_argument(
        "--auto",
        action="store_true",
        help="Non-interactive mode for app-triggered background startup",
    )
    parser.add_argument(
        "--skip-install", action="store_true", help="Skip pip install step (faster start)"
    )
    args = parser.parse_args()

    auto_boot = args.auto or os.environ.get("MONGOBOX_AUTO_BOOT") == "1"
    os.environ.setdefault("MONGOBOX_TTS_ENGINE", "voicebox")

    banner()
    print(f"{BOLD}Pre-flight checks{RESET}")
    print("─" * 44)
    check_python()
    check_ffmpeg(auto_continue=auto_boot)

    if not args.skip_install:
        install_requirements()

    check_background_mix_stack(auto_continue=auto_boot)
    check_cuda()
    start_server(args.host, args.port, args.reload)


if __name__ == "__main__":
    main()
