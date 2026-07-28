"""Strict contract handling for generated ``stage_result`` values.

Normalization is intentionally conservative: it may sanitize missing scalars and remove
*structurally valid* stat items whose values contain no usable evidence, but it must not
wrap arbitrary return values into a successful result. Malformed generated output remains
malformed so the repair loop can see and correct the real contract error.

Generated code must expose computed evidence through ``stage_result["stat"]``.
The contract has no answerability field or fallback path.
"""

from __future__ import annotations

import math
from typing import Any, Dict, List, Tuple

import numpy as np
import pandas as pd

from code_execute.error_classification import STAGE_RESULT_CONTRACT_ERROR


def normalize_stage_result_contract(raw: Any) -> Tuple[Any, Dict[str, Any]]:
    """Sanitize a generated ``stage_result`` without repairing its structure.

    The only structural cleanup performed is dropping a stat item when all of the
    following are true:
    1. it is a dict;
    2. it explicitly contains ``name``, ``description`` and ``value``;
    3. ``name`` and ``description`` are non-empty strings; and
    4. its value contains no usable evidence after missing-value sanitation.

    Any malformed item is preserved so :func:`validate_stage_result_contract` rejects it
    rather than silently turning a partially malformed payload into success.
    """
    diagnostics: Dict[str, Any] = {
        "contract": "stage_result_v4_stat_only",
        "status": "normalized",
        "raw_type": type(raw).__name__,
        "original_stat_count": 0,
        "dropped_empty_stat_count": 0,
        "malformed_stat_count": 0,
        "kept_stat_count": 0,
        "empty_after_cleanup": False,
    }

    if not isinstance(raw, dict):
        diagnostics["status"] = "invalid_top_level_type"
        return raw, diagnostics

    payload: Dict[str, Any] = dict(raw)
    raw_stat = payload.get("stat")
    if not isinstance(raw_stat, list):
        diagnostics["status"] = "invalid_stat_container"
        # Preserve the original invalid value for strict validation.
        return payload, diagnostics

    diagnostics["original_stat_count"] = len(raw_stat)
    cleaned_items: List[Any] = []
    for item in raw_stat:
        if not isinstance(item, dict):
            diagnostics["malformed_stat_count"] += 1
            cleaned_items.append(item)
            continue

        cleaned_item = dict(item)
        if "value" in cleaned_item:
            cleaned_item["value"] = sanitize_stage_result_value(cleaned_item.get("value"))

        structurally_valid = (
            "value" in cleaned_item
            and isinstance(cleaned_item.get("name"), str)
            and bool(cleaned_item.get("name", "").strip())
            and isinstance(cleaned_item.get("description"), str)
            and bool(cleaned_item.get("description", "").strip())
        )
        if not structurally_valid:
            diagnostics["malformed_stat_count"] += 1
            cleaned_items.append(cleaned_item)
            continue

        if is_empty_evidence_value(cleaned_item.get("value")):
            diagnostics["dropped_empty_stat_count"] += 1
            continue
        cleaned_items.append(cleaned_item)

    payload["stat"] = cleaned_items
    valid_items = [item for item in cleaned_items if isinstance(item, dict) and "value" in item]
    payload["value"] = _combine_stat_values(valid_items)
    payload["type"] = _infer_stage_result_type(payload.get("value"))

    if valid_items:
        payload["summary"] = " ".join(
            str(item.get("description") or item.get("name") or "").strip()
            for item in valid_items
            if str(item.get("description") or item.get("name") or "").strip()
        ).strip()
    else:
        payload["summary"] = str(payload.get("summary") or "").strip()


    diagnostics["kept_stat_count"] = len(cleaned_items)
    diagnostics["empty_after_cleanup"] = bool(not cleaned_items)
    if diagnostics["malformed_stat_count"]:
        diagnostics["status"] = "normalized_with_malformed_items"
    return payload, diagnostics


def validate_stage_result_contract(result_payload: Any) -> Tuple[bool, str, str]:
    """Validate the generated contract without applying permissive coercions."""
    if not isinstance(result_payload, dict):
        return False, "stage_result must be a dict.", STAGE_RESULT_CONTRACT_ERROR

    if "answerable" in result_payload:
        return False, "stage_result must not include an 'answerable' field.", STAGE_RESULT_CONTRACT_ERROR

    if "stat" not in result_payload:
        return False, "stage_result must explicitly include 'stat'.", STAGE_RESULT_CONTRACT_ERROR
    stat_items = result_payload.get("stat")
    if not isinstance(stat_items, list):
        return False, "stage_result['stat'] must be a list.", STAGE_RESULT_CONTRACT_ERROR

    if not stat_items:
        return False, "stage_result['stat'] must include at least one non-empty computed evidence item.", STAGE_RESULT_CONTRACT_ERROR

    return _validate_stat_items(stat_items, allow_empty_value=False)


def _validate_stat_items(stat_items: Any, *, allow_empty_value: bool) -> Tuple[bool, str, str]:
    """Validate the list of computed evidence stat objects."""
    for index, item in enumerate(stat_items):
        if not isinstance(item, dict):
            return False, f"stage_result['stat'][{index}] must be a dict.", STAGE_RESULT_CONTRACT_ERROR
        if "name" not in item or not isinstance(item.get("name"), str) or not item.get("name", "").strip():
            return False, f"stage_result['stat'][{index}]['name'] must be a non-empty string.", STAGE_RESULT_CONTRACT_ERROR
        if (
            "description" not in item
            or not isinstance(item.get("description"), str)
            or not item.get("description", "").strip()
        ):
            return False, f"stage_result['stat'][{index}]['description'] must be a non-empty string.", STAGE_RESULT_CONTRACT_ERROR
        if "value" not in item:
            return False, f"stage_result['stat'][{index}] must explicitly include 'value'.", STAGE_RESULT_CONTRACT_ERROR
        if not allow_empty_value and is_empty_evidence_value(item.get("value")):
            return False, f"stage_result['stat'][{index}]['value'] is empty.", STAGE_RESULT_CONTRACT_ERROR
    return True, "", ""


def sanitize_stage_result_value(value: Any) -> Any:
    """Recursively convert scalar missing/non-finite values to ``None``.

    DataFrames and Series retain their tabular type because downstream evidence modules
    need their structure. Their missing cells are handled by shared preview/visual safety
    utilities.
    """
    if value is None:
        return None
    if isinstance(value, (pd.DataFrame, pd.Series)):
        return value
    if isinstance(value, dict):
        return {str(key): sanitize_stage_result_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [sanitize_stage_result_value(item) for item in value]
    if isinstance(value, tuple):
        return tuple(sanitize_stage_result_value(item) for item in value)
    if isinstance(value, set):
        return [sanitize_stage_result_value(item) for item in value]
    if isinstance(value, np.ndarray):
        return [sanitize_stage_result_value(item) for item in value.tolist()]
    if isinstance(value, np.generic):
        return sanitize_stage_result_value(value.item())
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    try:
        if pd.isna(value):
            return None
    except Exception:
        pass
    return value


def is_empty_evidence_value(value: Any) -> bool:
    """Return whether a value contains no usable evidence, recursively."""
    if value is None:
        return True
    if isinstance(value, pd.DataFrame):
        if value.empty or value.shape[1] == 0:
            return True
        try:
            cleaned = value.replace([np.inf, -np.inf], np.nan)
            for column in cleaned.select_dtypes(include=["object", "string"]).columns:
                cleaned[column] = cleaned[column].map(
                    lambda item: None if isinstance(item, str) and not item.strip() else item
                )
            return not bool(cleaned.notna().to_numpy().any())
        except Exception:
            return False
    if isinstance(value, pd.Series):
        if value.empty:
            return True
        try:
            cleaned = value.replace([np.inf, -np.inf], np.nan)
            if str(cleaned.dtype) in {"object", "string"}:
                cleaned = cleaned.map(
                    lambda item: None if isinstance(item, str) and not item.strip() else item
                )
            return not bool(cleaned.notna().to_numpy().any())
        except Exception:
            return False
    if isinstance(value, np.ndarray):
        return value.size == 0 or all(is_empty_evidence_value(item) for item in value.tolist())
    if isinstance(value, dict):
        return not value or all(is_empty_evidence_value(item) for item in value.values())
    if isinstance(value, (list, tuple, set)):
        return not value or all(is_empty_evidence_value(item) for item in value)
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, np.generic):
        return is_empty_evidence_value(value.item())
    if isinstance(value, float):
        return not math.isfinite(value)
    try:
        missing = pd.isna(value)
        if isinstance(missing, (bool, np.bool_)):
            return bool(missing)
    except Exception:
        pass
    return False


def _infer_stage_result_type(value: Any) -> str:
    if isinstance(value, pd.DataFrame):
        return "table"
    if isinstance(value, dict):
        return "dict"
    if isinstance(value, list):
        return "list"
    if isinstance(value, str):
        return "text"
    return "scalar"


def _combine_stat_values(stat_items: List[Dict[str, Any]]) -> Any:
    if not stat_items:
        return None
    if len(stat_items) == 1:
        return stat_items[0].get("value")
    return {
        item.get("name") or f"evidence_{index + 1}": item.get("value")
        for index, item in enumerate(stat_items)
    }
