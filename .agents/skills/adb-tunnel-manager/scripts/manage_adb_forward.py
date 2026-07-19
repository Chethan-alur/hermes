#!/usr/bin/env python3
"""
ADB Port Forwarding Manager for Project Hermes
Manages ADB socket tunnel setup and status checking.
"""

import argparse
import subprocess
import sys


def run_adb_command(cmd_args: list):
    full_cmd = ["adb"] + cmd_args
    try:
        res = subprocess.run(full_cmd, capture_output=True, text=True)
        return res.returncode == 0, res.stdout.strip(), res.stderr.strip()
    except FileNotFoundError:
        return False, "", "ADB executable not found in PATH."


def setup_forward(port: int):
    print(f"🔌 Setting up ADB port forward: tcp:{port} -> tcp:{port}...")
    success, stdout, stderr = run_adb_command(["forward", f"tcp:{port}", f"tcp:{port}"])
    if success:
        print(f"✅ ADB port forwarding established on tcp:{port}")
    else:
        print(f"⚠️ ADB setup failed or device not connected: {stderr or stdout}")
    return success


def check_status():
    print("🔍 Checking active ADB forward rules...")
    success, stdout, stderr = run_adb_command(["forward", "--list"])
    if success:
        if stdout:
            print("Active forward rules:\n" + stdout)
        else:
            print("No active ADB forward rules.")
    else:
        print(f"⚠️ Failed to list ADB forward rules: {stderr or stdout}")


def remove_forward(port: int):
    print(f"🧹 Removing ADB port forward for tcp:{port}...")
    success, stdout, stderr = run_adb_command(["forward", "--remove", f"tcp:{port}"])
    if success:
        print(f"✅ ADB port forward tcp:{port} removed.")
    else:
        print(f"⚠️ Failed to remove ADB forward: {stderr or stdout}")


def main():
    parser = argparse.ArgumentParser(description="Hermes ADB Tunnel Manager")
    parser.add_argument("--setup", action="store_true", help="Set up ADB port forwarding")
    parser.add_argument("--status", action="store_true", help="List active ADB forward rules")
    parser.add_argument("--remove", action="store_true", help="Remove ADB port forwarding")
    parser.add_argument("--port", type=int, default=9999, help="TCP port (default: 9999)")

    args = parser.parse_args()

    if args.setup:
        setup_forward(args.port)
    elif args.remove:
        remove_forward(args.port)
    else:
        check_status()


if __name__ == "__main__":
    main()
