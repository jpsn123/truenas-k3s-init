#!/usr/bin/env python3
"""Replace Ed25519 public key in Coder binary via binary search-and-replace."""
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
BINARY = sys.argv[1] if len(sys.argv) > 1 else "/opt/coder"
OLD_KEY = bytes.fromhex("67186ade9d222c21b1be112009b7c43676aab17f1b8796682f88c8636dceaf2f")
NEW_KEY = (SCRIPT_DIR / "public.key").read_bytes()

with open(BINARY, "rb") as f:
    data = f.read()

count = data.count(OLD_KEY)
if count == 0:
    if data.count(NEW_KEY) > 0:
        print("Old key not found in binary. Already patched.")
        sys.exit(0)
    print("Old key not found in binary. Different binary version.")
    sys.exit(1)

print(f"Found {count} occurrence(s) of the old key. Patching...")
data = data.replace(OLD_KEY, NEW_KEY, 1)

with open(BINARY, "wb") as f:
    f.write(data)

print("Patched successfully.")
