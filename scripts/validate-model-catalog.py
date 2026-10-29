#!/usr/bin/env python3
"""Validate the repository catalog used as a CUMOB server publishing reference."""
import json
import re
import sys
from pathlib import Path


def validate(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    models = data.get("models") if isinstance(data, dict) else None
    if not isinstance(models, list) or not models:
        raise ValueError("models must be a nonempty array")
    slugs = set()
    priorities = set()
    eligible = []
    for index, model in enumerate(models):
        if not isinstance(model, dict):
            raise ValueError(f"models[{index}] must be an object")
        slug = model.get("slug")
        priority = model.get("priority")
        if not isinstance(slug, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", slug):
            raise ValueError(f"models[{index}].slug must be a nonempty safe model ID")
        if slug in slugs:
            raise ValueError(f"duplicate slug: {slug}")
        slugs.add(slug)
        if isinstance(priority, bool) or not isinstance(priority, int):
            raise ValueError(f"{slug}: priority must be an integer")
        if priority in priorities:
            raise ValueError(f"duplicate priority: {priority}")
        priorities.add(priority)
        if not isinstance(model.get("display_name"), str) or not model["display_name"].strip():
            raise ValueError(f"{slug}: display_name is required")
        if model.get("supported_in_api") is not True or model.get("visibility") != "list":
            continue
        effort = model.get("default_reasoning_level")
        levels = model.get("supported_reasoning_levels")
        if not isinstance(effort, str) or not re.fullmatch(r"[a-z]+", effort):
            raise ValueError(f"{slug}: invalid default_reasoning_level")
        if not isinstance(levels, list) or effort not in [level.get("effort") for level in levels if isinstance(level, dict)]:
            raise ValueError(f"{slug}: default_reasoning_level is not supported")
        eligible.append(model)
    if not eligible:
        raise ValueError("no visible API-supported default model")
    return min(eligible, key=lambda model: model["priority"])


if __name__ == "__main__":
    try:
        selected = validate(sys.argv[1])
        print(f"Default model: {selected['slug']} ({selected['default_reasoning_level']})")
    except (ValueError, OSError, json.JSONDecodeError, IndexError) as exc:
        print(f"Invalid model catalog: {exc}", file=sys.stderr)
        sys.exit(1)
