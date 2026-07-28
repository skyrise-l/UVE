"""Internal column semantics for visualization correctness.

BIRD provides declared column formats plus optional primary/foreign-key constraints.
Those declarations are treated as authoritative.  InsightBench does not provide the
same metadata, so it continues to rely on the existing runtime inference path.
"""

from __future__ import annotations

import re
from typing import Any, Dict, Mapping


RATE_HINTS = {
    "rate", "ratio", "percent", "percentage", "proportion", "share", "margin",
    "correlation", "corr", "coefficient", "rank", "percentile", "average", "avg",
    "mean", "median", "std", "stdev", "variance", "score", "index",
}
COUNT_HINTS = {"count", "cnt", "frequency", "freq", "nunique", "number_of", "num_of"}
ADDITIVE_HINTS = {
    "amount", "revenue", "sales", "cost", "expense", "donation", "fine",
    "quantity", "qty", "volume", "total", "sum", "spend", "budget", "profit",
    "income", "students_reached",
}
TIME_HINTS = {
    "date", "time", "timestamp", "datetime", "year", "month", "day", "period",
    "opened", "closed", "created", "updated", "posted", "start", "end",
}
CODE_HINTS = {"code", "level", "grade", "ward", "status", "type_id", "category_id", "postal", "postcode", "zip", "zipcode", "fips", "naics", "sic"}
STRONG_IDENTIFIER_NAMES = {
    "unitid", "projectid", "schoolid", "inspectionid", "licenseid",
    "licenseno", "accountno", "recordid", "rowid", "objectid",
}
COORDINATE_HINTS = {"latitude", "longitude", "lat", "lon", "lng"}


def normalize_name(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def name_tokens(value: Any) -> set[str]:
    text = str(value or "").lower().replace("-", "_").replace(".", "_").replace("/", "_")
    return {part for part in text.split("_") if part}


def task_table_metadata(task: Any) -> Dict[str, Dict[str, Any]]:
    """Return runtime table name -> metadata without changing prompt payloads."""
    result: Dict[str, Dict[str, Any]] = {}
    for table in list(getattr(task, "all_tables", lambda: [])() or []):
        name = str(getattr(table, "name", "") or "")
        if name:
            result[name] = dict(getattr(table, "metadata", {}) or {})
    return result




def build_table_column_semantics(metadata: Mapping[str, Any] | None) -> Dict[str, Dict[str, Any]]:
    """Return source-column semantics for one table metadata object."""
    return _source_column_semantics(dict(metadata or {}))

def build_task_column_semantics(task: Any) -> Dict[str, Dict[str, Any]]:
    """Return unambiguous column-name semantics across the task's source tables."""
    candidates: Dict[str, list[Dict[str, Any]]] = {}
    for metadata in task_table_metadata(task).values():
        for name, semantic in _source_column_semantics(metadata).items():
            candidates.setdefault(name, []).append(dict(semantic or {}))
    result: Dict[str, Dict[str, Any]] = {}
    for name, items in candidates.items():
        signatures = {
            (
                str(item.get("data_format") or ""),
                bool(item.get("identifier", False)),
                str(item.get("kind") or "unknown"),
                item.get("additive"),
            )
            for item in items
        }
        if len(signatures) == 1:
            result[name] = items[0]
    return result

def build_veg_column_semantics(
    veg: Mapping[str, Any],
    source_table_metadata: Mapping[str, Mapping[str, Any]] | None,
) -> Dict[str, Dict[str, Dict[str, Any]]]:
    """Build tid -> column -> compact semantic metadata.

    Source-table declarations are authoritative for BIRD.  Derived tables inherit
    semantics through simple lineage rules and aggregation metadata.  Unknown columns
    remain conservative and can still be profiled by the existing runtime heuristics.
    """
    tables = dict((dict(veg or {}).get("tables") or {}))
    transforms = list((dict(veg or {}).get("transforms") or []))
    metadata_map = {str(k): dict(v or {}) for k, v in dict(source_table_metadata or {}).items()}

    by_normalized_name: Dict[str, list[tuple[str, Dict[str, Any]]]] = {}
    for table_name, metadata in metadata_map.items():
        by_normalized_name.setdefault(normalize_name(table_name), []).append((table_name, metadata))

    result: Dict[str, Dict[str, Dict[str, Any]]] = {}
    for tid, raw_table in tables.items():
        table = dict(raw_table or {})
        table_name = str(table.get("name") or "")
        candidates = by_normalized_name.get(normalize_name(table_name), [])
        if len(candidates) == 1:
            result[str(tid)] = _source_column_semantics(candidates[0][1])

    # Transform order follows the execution trace and is normally topological.
    for raw_transform in transforms:
        transform = dict(raw_transform or {})
        output_tid = str(transform.get("output") or "")
        if not output_tid or output_tid not in tables:
            continue
        output_columns = [str(c) for c in list((dict(tables[output_tid] or {})).get("columns") or [])]
        input_tids = [str(t) for t in list(transform.get("inputs") or []) if str(t)]
        input_maps = [result.get(tid, {}) for tid in input_tids]
        derived = _inherit_output_columns(output_columns, input_maps)
        _apply_transform_semantics(derived, output_columns, transform)
        if derived:
            existing = dict(result.get(output_tid) or {})
            existing.update(derived)
            result[output_tid] = existing

    return result


def _source_column_semantics(metadata: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    columns = [dict(item or {}) for item in list((dict(metadata or {}).get("columns") or []))]
    constraints = dict((dict(metadata or {}).get("constraints") or {}))
    primary_columns = {
        str(column)
        for key in list(constraints.get("primary_keys") or [])
        for column in list(key or [])
    }
    foreign_columns = {
        str(column)
        for fk in list(constraints.get("foreign_keys") or [])
        for column in list((dict(fk or {})).get("columns") or [])
    }
    is_bird = str((dict(metadata or {}).get("source") or "")).lower() in {"bird", "bird_join_probe"}
    result: Dict[str, Dict[str, Any]] = {}
    for column in columns:
        name = str(column.get("name") or "")
        if not name:
            continue
        data_format = str(column.get("data_format") or "").lower()
        description = " ".join(
            str(column.get(key) or "") for key in ("description", "value_description")
        ).strip()
        result[name] = infer_column_semantics(
            name,
            data_format=data_format,
            description=description,
            is_primary_key=name in primary_columns,
            is_foreign_key=name in foreign_columns,
            declared=is_bird and bool(data_format),
        )
    return result


def infer_column_semantics(
    name: str,
    *,
    data_format: str = "",
    description: str = "",
    is_primary_key: bool = False,
    is_foreign_key: bool = False,
    declared: bool = False,
) -> Dict[str, Any]:
    text = f"{name} {description}".lower()
    tokens = name_tokens(name) | name_tokens(description)
    normalized = normalize_name(name)

    identifier = bool(is_primary_key or is_foreign_key)
    temporal = data_format in {"date", "datetime"}
    raw_name = str(name or "").lower()
    if not identifier and (
        raw_name in {"id", "key", "uuid", "guid"}
        or raw_name.endswith("_id")
        or raw_name.endswith("_key")
        or normalized in STRONG_IDENTIFIER_NAMES
        or ("license" in tokens and bool(tokens & {"no", "number", "id"}))
    ):
        identifier = True

    kind = "unknown"
    additive: bool | None = None
    if identifier:
        kind = "identifier"
        additive = False
    elif temporal:
        kind = "temporal"
        additive = False
    elif data_format == "boolean":
        kind = "boolean"
        additive = False
    elif data_format == "text":
        kind = "text"
        additive = False
    elif tokens & COORDINATE_HINTS:
        kind = "coordinate"
        additive = False
    elif _contains_hint(text, RATE_HINTS):
        kind = "nonadditive_statistic"
        additive = False
    elif _contains_hint(text, COUNT_HINTS):
        kind = "count"
        additive = True
    elif _contains_hint(text, ADDITIVE_HINTS):
        kind = "additive_measure"
        additive = True
    elif data_format in {"integer", "real"}:
        if tokens & CODE_HINTS:
            kind = "category_code"
            additive = False
        else:
            kind = "numeric_measure"
            additive = None

    return {
        "data_format": data_format,
        "declared": bool(declared),
        "is_primary_key": bool(is_primary_key),
        "is_foreign_key": bool(is_foreign_key),
        "identifier": identifier,
        "temporal": temporal,
        "kind": kind,
        "additive": additive,
        "description": description,
    }


def _contains_hint(text: str, hints: set[str]) -> bool:
    tokens = name_tokens(text)
    return bool(tokens & hints or any(hint in text for hint in hints if len(hint) >= 4))


def _inherit_output_columns(
    output_columns: list[str],
    input_maps: list[Mapping[str, Mapping[str, Any]]],
) -> Dict[str, Dict[str, Any]]:
    result: Dict[str, Dict[str, Any]] = {}
    for column in output_columns:
        candidates: list[Dict[str, Any]] = []
        for mapping in input_maps:
            if column in mapping:
                candidates.append(dict(mapping[column] or {}))
                continue
            for suffix in ("_x", "_y"):
                if column.endswith(suffix) and column[: -len(suffix)] in mapping:
                    candidates.append(dict(mapping[column[: -len(suffix)]] or {}))
        if candidates:
            # Prefer a declared source when joins expose the same column from both sides.
            candidates.sort(key=lambda item: bool(item.get("declared")), reverse=True)
            result[column] = candidates[0]
        else:
            result[column] = infer_column_semantics(column)
    return result


def _apply_transform_semantics(
    semantics: Dict[str, Dict[str, Any]],
    output_columns: list[str],
    transform: Mapping[str, Any],
) -> None:
    family = str(transform.get("family") or "")
    op = str(transform.get("op") or "")
    args = dict(transform.get("args") or {})
    write_columns = [str(c) for c in list(transform.get("write") or []) if str(c)]

    if family == "aggregate" or op in {"group_agg", "value_counts", "crosstab"}:
        groupby = dict(args.get("groupby") or {})
        group_columns = {str(c) for c in list(groupby.get("by") or []) if str(c)}
        agg = dict(args.get("agg") or {})
        method = str(agg.get("method") or args.get("method") or "").lower()
        for column in output_columns:
            if column in group_columns:
                continue
            if method in {"size", "count", "nunique", "value_counts"}:
                semantics[column] = _derived_numeric("count", additive=True)
            elif method == "sum":
                inherited = dict(semantics.get(column) or {})
                inherited.update({"kind": "additive_measure", "additive": True, "identifier": False})
                semantics[column] = inherited
            elif method in {"mean", "median", "std", "var", "corr"}:
                semantics[column] = _derived_numeric("nonadditive_statistic", additive=False)

    if family == "derive" or op in {"derive", "series_expr", "pct_change"}:
        method = str(args.get("method") or op).lower()
        for column in write_columns:
            if method in {"eq", "ne", "gt", "ge", "lt", "le", "isin", "between"}:
                semantics[column] = {
                    **infer_column_semantics(column),
                    "kind": "boolean",
                    "additive": False,
                    "identifier": False,
                }
            elif method in {"truediv", "pct_change", "div"}:
                semantics[column] = _derived_numeric("nonadditive_statistic", additive=False)
            else:
                semantics[column] = infer_column_semantics(column)


def _derived_numeric(kind: str, *, additive: bool) -> Dict[str, Any]:
    return {
        "data_format": "real",
        "declared": False,
        "is_primary_key": False,
        "is_foreign_key": False,
        "identifier": False,
        "temporal": False,
        "kind": kind,
        "additive": additive,
        "description": "",
    }


def compact_profile_semantics(profile: Any) -> Dict[str, Any]:
    """Return only fields needed by transforms/fact extraction."""
    return {
        "data_format": str(getattr(profile, "declared_data_format", "") or ""),
        "declared": bool(getattr(profile, "semantic_declared", False)),
        "is_primary_key": bool(getattr(profile, "is_primary_key", False)),
        "is_foreign_key": bool(getattr(profile, "is_foreign_key", False)),
        "identifier": bool(getattr(profile, "is_identifier_like", False)),
        "temporal": bool(getattr(profile, "is_datetime", False)),
        "kind": str(getattr(profile, "measure_kind", "unknown") or "unknown"),
        "additive": getattr(profile, "is_additive", None),
    }
