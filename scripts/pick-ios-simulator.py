#!/usr/bin/env python3
"""Prints `udid=<id>` for the newest available iPhone simulator (CI)."""
import json
import subprocess

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
ios = sorted(
    (r for r in devices if "SimRuntime.iOS" in r),
    key=lambda r: [int(p) for p in r.rsplit("iOS-", 1)[1].split("-")],
)
phones = [d["udid"] for r in reversed(ios) for d in devices[r] if d["name"].startswith("iPhone")]
print(f"udid={phones[0]}")
