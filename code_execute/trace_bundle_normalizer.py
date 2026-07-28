"""trace_bundle_normalizer.py
--------------------------------

Trace bundle 的轻量规范层。

这个文件现在只保留一个核心职责：

1. 统一 trace bundle 的外层字段命名；
2. 对 ``trace_pandas_patch.py`` 已经捕获好的 ``tables`` / ``events`` 做轻量清洗；
3. 为每个 event 补一个稳定的 ``event_family``，方便人读 trace，也方便后续模块按操作大类重建逻辑。


设计原则：

``trace_pandas_patch.py`` 负责捕获事实，保证 event 的基础结构稳定；
本文件只在事实之上补充最小、可读、稳定的操作族分类。
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional
from vis_project_utils.utils import _safe_int

# 统一维护 pandas trace op -> event family 的映射。
# 后续如果 patcher 新增 op，优先只改这里，而不是把分类逻辑分散到多个函数。
OP_FAMILY: Dict[str, str] = {
    # source / sink
    "source_read": "source",
    "sink_write": "sink",

    # selection / cleaning-like structural operations
    "copy": "select",
    "select": "select",
    "select_series": "select",
    "slice_rows": "select",
    "drop": "select",
    "dropna": "select",
    "fillna": "select",
    "replace": "select",
    "astype": "select",

    # row filtering / boolean masking
    "filter": "filter",
    "query": "filter",
    "where": "filter",
    "mask": "filter",
    "isin": "filter",

    # table combination
    "join": "join",
    "merge": "join",
    "concat": "join",

    # aggregation / summarization
    "group_agg": "aggregate",
    "group_apply": "aggregate",
    "group_transform": "aggregate",
    "value_counts": "aggregate",
    "crosstab": "aggregate",

    # sorting / ranking / truncation
    "sort": "sort_rank",
    "sort_index": "sort_rank",
    "nlargest": "sort_rank",
    "nsmallest": "sort_rank",
    "head": "sort_rank",
    "tail": "sort_rank",

    # derived columns / expressions
    "derive": "derive",
    "update_column": "derive",
    "update_values": "derive",
    "eval": "derive",
    "apply": "derive",
    "series_expr": "derive",
    "str_extract": "derive",
    "diff": "derive",
    "shift": "derive",
    "pct_change": "derive",
    "map": "derive",

    # scalar reductions from Series
    "series_reduce": "reduce",
    "unique": "reduce",
    "corr": "reduce",

    # schema / shape changes
    "rename": "rename",
    "reshape": "reshape",
    "explode": "reshape",
    "stack": "reshape",
    "unstack": "reshape",
    "pivot": "reshape",
    "pivot_table": "reshape",
    "melt": "reshape",
    "series_to_frame": "reshape",

    # index changes
    "set_index": "index",
    "reset_index": "index",

    # duplicate-related operations
    "drop_duplicates": "deduplicate",
    "duplicated": "deduplicate",
}


def normalize_trace_bundle(trace_bundle: Mapping[str, Any], round_index: Optional[int] = None) -> Dict[str, Any]:
    """Return a minimal, readable trace bundle.
    Returned schema::

        {
            "round_index": int | None,
            "tables": {
                "t1": {"name": str, "kind": str, "shape": list, "columns": list[str]},
                ...
            },
            "events": [
                {
                    "id": int,
                    "op": str,
                    "event_family": str,
                    "inputs": list[str],
                    "output": str,
                    "read": dict[str, list[str]],
                    "write": list[str],
                    "args": dict,
                },
                ...
            ],
            "stage_result": {
                "type": str,
                "refs": [{"path": str, "tid": str}, ...]
            }
        }
    """

    raw_bundle = dict(trace_bundle or {})
    resolved_round = _resolve_round_index(raw_bundle, round_index)

    return {
        "round_index": resolved_round,
        "tables": _normalize_tables(raw_bundle.get("tables") or {}),
        "events": [_normalize_event(item) for item in list(raw_bundle.get("events") or [])],
        "stage_result": _normalize_stage_result(raw_bundle),
        "trace_stats": _normalize_trace_stats(raw_bundle.get("trace_stats") or {}),
    }


def _normalize_tables(raw_tables: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Clean table manifest while avoiding duplicate data.

    The table id is already the dictionary key, so each value does not repeat
    ``tid``. Keeping the manifest small makes trace JSON easier to inspect.
    """

    tables: Dict[str, Dict[str, Any]] = {}
    for tid, raw_info in dict(raw_tables or {}).items():
        tid_str = str(tid or "")
        if not tid_str:
            continue

        info = dict(raw_info or {})
        shape = info.get("shape") or info.get("size") or []
        if isinstance(shape, tuple):
            shape = list(shape)
        if not isinstance(shape, list):
            shape = []

        tables[tid_str] = {
            "name": str(info.get("name") or tid_str),
            "kind": str(info.get("kind") or info.get("artifact_type") or "dataframe"),
            "shape": list(shape),
            "columns": [str(col) for col in list(info.get("columns") or []) if col is not None],
            "column_count": _safe_int(info.get("column_count")),
            "columns_truncated": bool(info.get("columns_truncated", False)),
        }
    return tables


def _normalize_trace_stats(raw_stats: Mapping[str, Any]) -> Dict[str, Any]:
    stats = dict(raw_stats or {})
    limits = dict(stats.get("limits") or {})
    return {
        "table_count": _safe_int(stats.get("table_count")) or 0,
        "event_count": _safe_int(stats.get("event_count")) or 0,
        "dropped_table_count": _safe_int(stats.get("dropped_table_count")) or 0,
        "dropped_event_count": _safe_int(stats.get("dropped_event_count")) or 0,
        "nested_suppressed_table_count": _safe_int(stats.get("nested_suppressed_table_count")) or 0,
        "columns_truncated_table_count": _safe_int(stats.get("columns_truncated_table_count")) or 0,
        "truncated": bool(stats.get("truncated", False)),
        "limits": {
            "max_tables": _safe_int(limits.get("max_tables")) or 0,
            "max_events": _safe_int(limits.get("max_events")) or 0,
            "max_columns": _safe_int(limits.get("max_columns")) or 0,
        },
    }


def _normalize_event(raw_event: Mapping[str, Any]) -> Dict[str, Any]:
    """Clean one trace event and attach only ``event_family`` as derived info."""

    event = dict(raw_event or {})
    event_id = _safe_int(event.get("id") if event.get("id") is not None else event.get("event_id"))
    op = str(event.get("op") or "")

    return {
        "id": event_id,
        "op": op,
        "event_family": _event_family(op),
        "inputs": [str(tid) for tid in list(event.get("inputs") or []) if tid],
        "output": str(event.get("output") or ""),
        "read": _normalize_read_map(event.get("read") or event.get("read_columns") or {}),
        "write": [str(col) for col in list(event.get("write") or event.get("write_columns") or []) if col is not None],
        "args": dict(event.get("args") or {}),
    }


def _normalize_stage_result(trace_bundle: Mapping[str, Any]) -> Dict[str, Any]:
    """Normalize the link between ``stage_result`` and traced table ids.

    ``code_executer.py`` is responsible for creating this part, because only it
    sees the actual runtime value of ``stage_result``. The normalized trace
    contract uses ``stage_result`` as the only sink key.
    """

    raw_stage_result = dict(trace_bundle.get("stage_result") or {})
    refs: List[Dict[str, str]] = []

    for raw_ref in list(raw_stage_result.get("refs") or []):
        ref = dict(raw_ref or {})
        tid = str(ref.get("tid") or "")
        if not tid:
            continue
        refs.append(
            {
                "path": str(ref.get("path") or "stage_result"),
                "tid": tid,
            }
        )

    return {
        "type": str(raw_stage_result.get("type") or ""),
        "refs": refs,
    }


def _resolve_round_index(trace_bundle: Mapping[str, Any], round_index: Optional[int]) -> Optional[int]:
    if round_index is not None:
        return _safe_int(round_index)
    value = trace_bundle.get("round_index")
    if value is not None:
        return _safe_int(value)
    return None


def _normalize_read_map(read_map: Any) -> Dict[str, List[str]]:
    """Normalize read lineage into ``{tid: [column, ...]}``."""

    if isinstance(read_map, list):
        values = _dedupe_str_list(read_map)
        return {"": values} if values else {}

    out: Dict[str, List[str]] = {}
    for tid, cols in dict(read_map or {}).items():
        tid_str = str(tid or "")
        values = _dedupe_str_list(cols or [])
        if tid_str and values:
            out[tid_str] = values
    return out


def _event_family(op: str) -> str:
    """Return the coarse operation family for one traced pandas op."""

    return OP_FAMILY.get(str(op or ""), "unknown")


def _dedupe_str_list(values: Any) -> List[str]:
    seen = set()
    out: List[str] = []
    for value in list(values or []):
        if value is None:
            continue
        item = str(value)
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out



