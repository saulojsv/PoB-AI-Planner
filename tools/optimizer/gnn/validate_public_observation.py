"""Validate observation-only discovery JSON against the checked-in schema.

This dependency-free validator implements the JSON Schema keywords used by
public_build_observation.schema.json. Discovery references are descriptive
text by contract; source URLs belong in the human review document.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any


def resolve_ref(root: dict[str, Any], ref: str) -> Any:
    if not ref.startswith("#/"):
        raise ValueError(f"unsupported schema reference: {ref}")
    node: Any = root
    for part in ref[2:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        node = node[part]
    return node


def matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    raise ValueError(f"unsupported schema type: {expected}")


def validate(value: Any, rule: dict[str, Any], root: dict[str, Any], path: str) -> list[str]:
    errors: list[str] = []
    if "$ref" in rule:
        return validate(value, resolve_ref(root, rule["$ref"]), root, path)

    if "oneOf" in rule:
        matches = sum(not validate(value, option, root, path) for option in rule["oneOf"])
        if matches != 1:
            errors.append(f"{path}: expected exactly one matching schema branch")
        return errors

    expected_type = rule.get("type")
    if expected_type and not matches_type(value, expected_type):
        return [f"{path}: expected {expected_type}"]

    if "const" in rule and value != rule["const"]:
        errors.append(f"{path}: expected constant {rule['const']!r}")
    if "enum" in rule and value not in rule["enum"]:
        errors.append(f"{path}: value is outside the allowed enum")

    if isinstance(value, str):
        if len(value) < rule.get("minLength", 0):
            errors.append(f"{path}: shorter than minLength")
        if len(value) > rule.get("maxLength", 1_000_000):
            errors.append(f"{path}: longer than maxLength")
        pattern = rule.get("pattern")
        if pattern and re.search(pattern, value) is None:
            errors.append(f"{path}: does not match pattern")
        if rule.get("format") == "date":
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value) is None:
                errors.append(f"{path}: expected ISO date YYYY-MM-DD")
            else:
                try:
                    date.fromisoformat(value)
                except ValueError:
                    errors.append(f"{path}: invalid calendar date")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if value < rule.get("minimum", value):
            errors.append(f"{path}: below minimum")
        if value > rule.get("maximum", value):
            errors.append(f"{path}: above maximum")

    if isinstance(value, list):
        if len(value) < rule.get("minItems", 0):
            errors.append(f"{path}: fewer than minItems")
        if len(value) > rule.get("maxItems", 1_000_000):
            errors.append(f"{path}: more than maxItems")
        if rule.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, ensure_ascii=False) for item in value]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{path}: contains duplicate items")
        item_rule = rule.get("items")
        if item_rule:
            for index, item in enumerate(value):
                errors.extend(validate(item, item_rule, root, f"{path}[{index}]"))

    if isinstance(value, dict):
        properties = rule.get("properties", {})
        for key in rule.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required property {key!r}")
        if rule.get("additionalProperties") is False:
            for key in value.keys() - properties.keys():
                errors.append(f"{path}: unexpected property {key!r}")
        for key, child in properties.items():
            if key in value:
                errors.extend(validate(value[key], child, root, f"{path}.{key}"))

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("documents", nargs="+", type=Path, help="observation JSON files to validate")
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path(__file__).with_name("schemas") / "public_build_observation.schema.json",
        help="JSON Schema path",
    )
    args = parser.parse_args()
    try:
        schema = json.loads(args.schema.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"SCHEMA ERROR: {exc}", file=sys.stderr)
        return 2

    failed = False
    for document in args.documents:
        try:
            value = json.loads(document.read_text(encoding="utf-8"))
            errors = validate(value, schema, schema, "$")
        except (OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
            errors = [str(exc)]
        if errors:
            failed = True
            print(f"FAIL {document}")
            for error in errors:
                print(f"  {error}")
        else:
            print(f"PASS {document}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
