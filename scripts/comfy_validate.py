#!/usr/bin/env python3
"""Validate a ComfyUI API workflow against /object_info.

PowerShell 5.1's ConvertFrom-Json rejects the duplicate case-insensitive keys
in ComfyUI's object_info (e.g. dynamicThresholdingFull / DynamicThresholdingFull),
so the check runs in ComfyUI's own Python and returns a small ASCII JSON result.
"""
import json
import sys
import urllib.request


def main() -> int:
    workflow_path = sys.argv[1]
    base = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8188"

    with open(workflow_path, "r", encoding="utf-8") as handle:
        workflow = json.load(handle)

    with urllib.request.urlopen(base + "/object_info", timeout=180) as response:
        info = json.load(response)

    issues = []
    for node_id, node in workflow.items():
        if node_id == "_meta" or not isinstance(node, dict):
            continue
        class_type = node.get("class_type")
        if class_type not in info:
            issues.append("Node %s: unknown class_type '%s'" % (node_id, class_type))
            continue
        spec = info[class_type].get("input", {})
        required = spec.get("required", {}) or {}
        optional = spec.get("optional", {}) or {}
        for name, value in (node.get("inputs", {}) or {}).items():
            if name == "_meta":
                continue
            if isinstance(value, list):
                continue
            if name not in required and name not in optional:
                issues.append("Node %s (%s): unknown input '%s'" % (node_id, class_type, name))

    print(json.dumps({"ok": not issues, "issues": issues}, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
