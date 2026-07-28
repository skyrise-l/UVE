"""Deterministic quality checks for next-question visual exploration evidence.

The exploration selector is deliberately more permissive than the current-answer path,
but a visually valid chart can still be a poor next-step signal.  This module rejects a
small set of failure modes that were observed in real InsightBench runs:

- mechanical relationships between a count and a derived share/proportion;
- pseudo time axes such as durations or ages;
- correlations supported by too few points;
- rankings over technical row identifiers;
- charts with too little support to motivate a new analysis question.

No LLM call is added.  The checks use only the selected plan and its materialized support
view so rejected candidates remain auditable and reproducible.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import re
import warnings
from typing import Any, Dict, List, Mapping

import pandas as pd
from pandas.api.types import is_datetime64_any_dtype, is_numeric_dtype

from chart_extract.common import all_slots, gate, slot, template_family
from chart_extract.visual_fact_extractor import to_dataframe
from evidence_layer.visual_semantics import infer_column_semantics


_RATE_TOKENS = {
    "rate", "ratio", "share", "proportion", "percent", "percentage", "pct",
    "fraction", "normalized", "normalised",
}
_COUNT_TOKENS = {
    "count", "cnt", "frequency", "freq", "number", "total", "volume",
}
_DURATION_TOKENS = {
    "duration", "elapsed", "latency", "age", "tenure", "warranty", "days",
    "hours", "minutes", "seconds",
}
_PERIOD_TOKENS = {"week", "month", "quarter", "year", "day"}
_STRONG_IDENTIFIER_TOKENS = {
    "uuid", "guid", "rowid", "recordid", "sysid", "objectid", "primarykey",
}
_BUSINESS_IDENTIFIER_TOKENS = {"id", "tag", "number", "no", "key"}


@dataclass(frozen=True)
class ExplorationQualityDecision:
    """One deterministic exploration-quality decision."""

    allowed: bool
    reasons: List[str] = field(default_factory=list)
    details: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "allowed": bool(self.allowed),
            "reasons": list(self.reasons),
            "details": dict(self.details),
        }


def precheck_exploration_plan(plan: Mapping[str, Any]) -> ExplorationQualityDecision:
    """Reject obvious low-value plans before they consume the frontier budget."""
    family = template_family(plan)
    slots = all_slots(plan)
    x = str(slot(slots, "x", "group", "category", "time", "x_metric") or "").strip()
    y = str(slot(slots, "y", "value", "metric", "count", "y_metric") or "").strip()
    support_shape = list(gate(plan, "sanity").get("support_shape") or [])
    rows = int(support_shape[0]) if support_shape and _is_int_like(support_shape[0]) else 0

    reasons: List[str] = []
    if x and y and _normalize(x) == _normalize(y):
        reasons.append("same_column_on_both_axes")

    if family == "relationship":
        if rows and rows < 8:
            reasons.append("relationship_has_fewer_than_8_points")
        if _looks_like_derived_count_rate_pair(x, y) and _has_derived_lineage(plan):
            reasons.append("count_rate_relationship_is_derived_from_same_aggregation")
        if _looks_like_date_period_pair(x, y) and _has_derived_lineage(plan):
            reasons.append("date_period_relationship_is_mechanical")

    if family == "time_trend":
        if _looks_like_duration_axis(x):
            reasons.append("duration_or_age_used_as_time_axis")
        if rows and rows < 4:
            reasons.append("time_trend_has_fewer_than_4_points")

    if family in {"ranked_group_value", "group_distribution", "matrix_contrast"}:
        if rows and rows < 2:
            reasons.append("group_evidence_has_fewer_than_2_rows")
        if _looks_like_strong_identifier(x) and rows >= 10:
            reasons.append("technical_identifier_used_as_primary_group")

    return ExplorationQualityDecision(
        allowed=not reasons,
        reasons=reasons,
        details={"family": family, "x": x, "y": y, "support_rows": rows},
    )


def evaluate_materialized_exploration(
    plan: Mapping[str, Any],
    materialized: Any,
) -> ExplorationQualityDecision:
    """Validate the materialized support view before creating an evidence card."""
    precheck = precheck_exploration_plan(plan)
    if not precheck.allowed:
        return precheck

    dataframe = to_dataframe(materialized)
    if dataframe is None or dataframe.empty:
        return ExplorationQualityDecision(False, ["empty_materialized_support"], precheck.details)

    family = template_family(plan)
    slots = all_slots(plan)
    x = _resolve_column(dataframe, slot(slots, "x", "group", "category", "time", "x_metric"))
    y = _resolve_column(dataframe, slot(slots, "y", "value", "metric", "count", "y_metric"))
    details: Dict[str, Any] = {
        **precheck.details,
        "support_rows": int(dataframe.shape[0]),
        "support_columns": int(dataframe.shape[1]),
        "x": x or precheck.details.get("x", ""),
        "y": y or precheck.details.get("y", ""),
    }
    reasons: List[str] = []

    if family == "relationship":
        if not x or not y or x not in dataframe.columns or y not in dataframe.columns:
            reasons.append("relationship_axes_not_materialized")
        else:
            valid = pd.DataFrame({
                "x": pd.to_numeric(dataframe[x], errors="coerce"),
                "y": pd.to_numeric(dataframe[y], errors="coerce"),
            }).dropna()
            details["valid_points"] = int(len(valid))
            details["unique_x"] = int(valid["x"].nunique()) if not valid.empty else 0
            details["unique_y"] = int(valid["y"].nunique()) if not valid.empty else 0
            if len(valid) < 8:
                reasons.append("relationship_has_fewer_than_8_valid_points")
            if not valid.empty and (valid["x"].nunique() < 3 or valid["y"].nunique() < 3):
                reasons.append("relationship_has_insufficient_numeric_variation")
            if (
                len(valid) >= 8
                and _looks_like_derived_count_rate_pair(x, y)
                and _materialized_count_rate_is_mechanical(valid, x_name=x, y_name=y)
            ):
                reasons.append("count_rate_relationship_is_materially_mechanical")
                details["mechanical_count_rate"] = True

    elif family == "time_trend":
        if not x or x not in dataframe.columns:
            reasons.append("time_axis_not_materialized")
        elif not _is_real_time_axis(dataframe[x], x):
            reasons.append("time_axis_is_not_a_verified_date_or_period")
        else:
            details["time_points"] = int(dataframe[x].dropna().nunique())
            if details["time_points"] < 4:
                reasons.append("time_trend_has_fewer_than_4_unique_periods")

    elif family in {"ranked_group_value", "group_distribution"}:
        if not x or x not in dataframe.columns:
            reasons.append("group_axis_not_materialized")
        else:
            unique_groups = int(dataframe[x].dropna().nunique())
            details["unique_groups"] = unique_groups
            if unique_groups < 2:
                reasons.append("group_evidence_has_fewer_than_2_groups")
            if _is_runtime_identifier(dataframe[x], x):
                reasons.append("technical_identifier_has_near_unique_values")
            elif _is_sparse_business_identifier(dataframe[x], x):
                reasons.append("business_identifier_has_only_unique_individual_values")

    elif family == "matrix_contrast":
        if int(dataframe.shape[0]) < 4:
            reasons.append("matrix_evidence_has_fewer_than_4_cells")

    details["support_summary"] = _support_summary(family, details)
    return ExplorationQualityDecision(not reasons, reasons, details)


def _support_summary(family: str, details: Mapping[str, Any]) -> str:
    if family == "relationship":
        return f"{int(details.get('valid_points') or 0)} valid points"
    if family == "time_trend":
        return f"{int(details.get('time_points') or 0)} distinct time points"
    if family in {"ranked_group_value", "group_distribution"}:
        return f"{int(details.get('unique_groups') or 0)} groups"
    return f"{int(details.get('support_rows') or 0)} support rows"


def _has_derived_lineage(plan: Mapping[str, Any]) -> bool:
    transform = dict((plan or {}).get("transform") or {})
    ops_text = repr(list(transform.get("ops") or [])).lower()
    if any(token in ops_text for token in ("derive", "truediv", "div", "pct_change", "ratio", "share")):
        return True
    gates = dict((plan or {}).get("gates") or {})
    for gate_name in ("frontier_evidence", "evidence"):
        reasons = " ".join(str(value) for value in list((dict(gates.get(gate_name) or {})).get("reasons") or [])).lower()
        if "derive" in reasons or "truediv" in reasons or "pct_change" in reasons:
            return True
    return False


def _looks_like_derived_count_rate_pair(left: str, right: str) -> bool:
    left_tokens = _tokens(left)
    right_tokens = _tokens(right)
    return bool(
        (left_tokens & _COUNT_TOKENS and right_tokens & _RATE_TOKENS)
        or (right_tokens & _COUNT_TOKENS and left_tokens & _RATE_TOKENS)
    )


def _materialized_count_rate_is_mechanical(
    valid: pd.DataFrame,
    *,
    x_name: str,
    y_name: str,
) -> bool:
    """Detect a rate/share that is only a constant rescaling of the count.

    Some generated plans omit explicit derivation metadata.  In that case the support
    table itself still reveals the failure mode: rate/count is constant across groups.
    """
    x_is_count = bool(_tokens(x_name) & _COUNT_TOKENS)
    y_is_count = bool(_tokens(y_name) & _COUNT_TOKENS)
    x_is_rate = bool(_tokens(x_name) & _RATE_TOKENS)
    y_is_rate = bool(_tokens(y_name) & _RATE_TOKENS)
    if x_is_count and y_is_rate:
        count_values = valid["x"]
        rate_values = valid["y"]
    elif y_is_count and x_is_rate:
        count_values = valid["y"]
        rate_values = valid["x"]
    else:
        return False
    nonzero = count_values.abs() > 1e-12
    ratios = (rate_values[nonzero] / count_values[nonzero]).replace([float("inf"), float("-inf")], pd.NA).dropna()
    if len(ratios) < 4:
        return False
    scale = max(abs(float(ratios.mean())), 1e-12)
    relative_spread = float(ratios.std(ddof=0) / scale)
    return relative_spread <= 1e-6


def _looks_like_date_period_pair(left: str, right: str) -> bool:
    left_semantic = infer_column_semantics(left)
    right_semantic = infer_column_semantics(right)
    left_tokens = _tokens(left)
    right_tokens = _tokens(right)
    return bool(
        (left_semantic.get("temporal") or _looks_date_named(left)) and right_tokens & _PERIOD_TOKENS
        or (right_semantic.get("temporal") or _looks_date_named(right)) and left_tokens & _PERIOD_TOKENS
    )


def _looks_like_duration_axis(name: str) -> bool:
    tokens = _tokens(name)
    if not tokens:
        return False
    explicit_date_anchor = bool(
        tokens
        & {
            "date", "timestamp", "datetime", "created", "opened", "closed",
            "updated", "expiry", "expiration",
        }
    )
    # Duration/age/latency remain non-calendar measures even when their names contain
    # words such as start/end/year (for example age_at_start or tenure_years).
    if tokens & {"duration", "elapsed", "latency", "age", "tenure"}:
        return True
    if "warranty" in tokens:
        return not explicit_date_anchor and not (
            tokens & {"end", "expiry", "expiration"}
            and tokens & {"year", "month", "date", "time"}
        )
    process_time = "time" in tokens and bool(
        tokens & {"processing", "resolution", "response", "turnaround", "cycle", "handling"}
    )
    unit_duration = bool(tokens & {"days", "hours", "minutes", "seconds"})
    if explicit_date_anchor:
        return False
    return process_time or unit_duration


def _looks_like_strong_identifier(name: str) -> bool:
    normalized = _normalize(name)
    tokens = _tokens(name)
    return bool(
        normalized in _STRONG_IDENTIFIER_TOKENS
        or name.lower() in {"id", "uuid", "guid", "key"}
        or name.lower().endswith(("_uuid", "_guid", "_row_id", "_record_id", "_sys_id"))
        or {"row", "id"}.issubset(tokens)
        or {"record", "id"}.issubset(tokens)
    )


def _is_runtime_identifier(series: pd.Series, name: str) -> bool:
    if not _looks_like_strong_identifier(name):
        return False
    non_null = series.dropna()
    if len(non_null) < 10:
        return False
    return float(non_null.nunique() / max(1, len(non_null))) >= 0.90


def _is_sparse_business_identifier(series: pd.Series, name: str) -> bool:
    """Reject tiny rankings over individual IDs/tags without blocking binary groups.

    Round-one review found that requiring three groups would also remove valid two-way
    comparisons such as accepted vs declined.  The actual low-value case is narrower:
    every displayed value is a different identifier (for example two asset tags), so the
    chart compares individuals rather than revealing a repeatable group pattern.
    """
    tokens = _tokens(name)
    if not tokens & _BUSINESS_IDENTIFIER_TOKENS:
        return False
    non_null = series.dropna()
    if not 2 <= len(non_null) <= 8:
        return False
    return int(non_null.nunique()) == int(len(non_null))


def _is_real_time_axis(series: pd.Series, name: str) -> bool:
    if _looks_like_duration_axis(name):
        return False
    non_null = series.dropna()
    if len(non_null) < 4:
        return False
    if is_datetime64_any_dtype(non_null):
        return int(non_null.nunique()) >= 4
    if is_numeric_dtype(non_null):
        values = pd.to_numeric(non_null, errors="coerce").dropna()
        if len(values) < 4 or int(values.nunique()) < 4:
            return False
        lowered = str(name or "").lower()
        if "year" in lowered or "年" in lowered:
            return bool(float(values.between(1800, 2200).mean()) >= 0.90)
        # Derived calendar periods are valid ordered time axes even when materialized as
        # integers.  The previous check rejected ordinary month/week aggregations and
        # removed useful temporal directions together with pseudo-duration axes.
        if "month" in lowered or "月" in lowered:
            return bool(float(values.between(1, 12).mean()) >= 0.95)
        if "week" in lowered or "周" in lowered or "星期" in lowered:
            return bool(float(values.between(1, 53).mean()) >= 0.95)
        if "quarter" in lowered or "季度" in lowered:
            return bool(float(values.between(1, 4).mean()) >= 0.95)
        return False
    if _is_named_period_series(non_null, name):
        return True
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", category=UserWarning)
        parsed = pd.to_datetime(non_null.head(80), errors="coerce")
    return bool(float(parsed.notna().mean()) >= 0.70 and int(parsed.dropna().nunique()) >= 4)


def _is_named_period_series(series: pd.Series, name: str) -> bool:
    """Accept common materialized calendar labels such as 2024-W03 or 2024Q2."""
    lowered = str(name or "").lower()
    values = [str(value).strip() for value in series.dropna().head(80)]
    if len(set(values)) < 4:
        return False
    if "week" in lowered or "周" in lowered:
        return bool(values and sum(
            bool(re.fullmatch(r"\d{4}[-_/ ]?[wW]\d{1,2}", value))
            for value in values
        ) / len(values) >= 0.90)
    if "quarter" in lowered or "季度" in lowered:
        return bool(values and sum(
            bool(re.fullmatch(r"\d{4}[-_/ ]?[qQ][1-4]", value))
            for value in values
        ) / len(values) >= 0.90)
    if "month" in lowered or "月" in lowered:
        month_names = {
            "jan", "january", "feb", "february", "mar", "march", "apr", "april",
            "may", "jun", "june", "jul", "july", "aug", "august", "sep",
            "sept", "september", "oct", "october", "nov", "november", "dec",
            "december",
        }
        return bool(values and all(value.lower() in month_names for value in values))
    return False


def _looks_date_named(name: str) -> bool:
    lowered = str(name or "").lower()
    return any(token in lowered for token in ("date", "time", "opened", "closed", "created", "updated"))


def _resolve_column(dataframe: pd.DataFrame, value: Any) -> str:
    text = str(value or "").strip()
    if text in dataframe.columns:
        return text
    normalized = _normalize(text)
    for column in dataframe.columns:
        if _normalize(column) == normalized:
            return str(column)
    return ""


def _tokens(value: Any) -> set[str]:
    text = str(value or "").lower().replace("-", "_").replace(" ", "_")
    return {token for token in re.split(r"[^a-z0-9]+", text) if token}


def _normalize(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _is_int_like(value: Any) -> bool:
    try:
        int(value)
        return True
    except Exception:
        return False
