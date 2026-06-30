#!/usr/bin/env python3
"""Validate modes/gaming/compat-db/apps.json against its required-key schema.

The compat DB is a curated, hand-grown file (the README documents adding
entries), and distro-gaming-compat keys off specific fields. A hand-added
entry missing a required key, or with an unknown status, is a realistic
regression — this catches it in CI before it ships. Exits non-zero with a
clear per-error message on any violation.

Usage: validate-compat-db.py [path-to-apps.json]
"""
import json
import os
import sys

VALID_STATUS = {"workaround", "broken", "native-alternative-recommended"}
REQUIRED = ("id", "name", "category", "status")


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, "..", "modes", "gaming", "compat-db", "apps.json")
    path = sys.argv[1] if len(sys.argv) > 1 else default

    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        print(f"FAIL: cannot load {path}: {e}", file=sys.stderr)
        return 1

    errors = []
    if not isinstance(data.get("apps"), list):
        print("FAIL: top-level 'apps' must be a list", file=sys.stderr)
        return 1

    seen_ids = set()
    for i, app in enumerate(data["apps"]):
        tag = app.get("id", f"#{i}")
        for key in REQUIRED:
            if key not in app or app[key] in (None, ""):
                errors.append(f"{tag}: missing required key '{key}'")
        status = app.get("status")
        if status is not None and status not in VALID_STATUS:
            errors.append(f"{tag}: unknown status '{status}' (allowed: {sorted(VALID_STATUS)})")
        if app.get("id") in seen_ids:
            errors.append(f"{tag}: duplicate id")
        seen_ids.add(app.get("id"))

        # status-specific contracts the loader relies on:
        if status == "workaround":
            if not isinstance(app.get("winetricks_verbs"), list):
                errors.append(f"{tag}: status 'workaround' requires a winetricks_verbs LIST (may be empty)")
        if status == "native-alternative-recommended":
            na = app.get("native_alternative")
            if not isinstance(na, dict):
                errors.append(f"{tag}: status 'native-alternative-recommended' requires a native_alternative object")
            else:
                if not na.get("apt_package") and not na.get("flatpak_id"):
                    errors.append(f"{tag}: native_alternative needs at least one of apt_package / flatpak_id")

    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        return 1

    print(f"OK: {len(data['apps'])} compat-db entries valid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
