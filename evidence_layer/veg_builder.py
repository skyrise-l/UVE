"""Build a compact Visual Evidence Graph (VEG) from one execution trace.

The VEG remains an in-memory intermediate used by visual-plan generation.  It keeps
only nodes reachable from stage-result/live artifacts, so pandas implementation
temporaries and abandoned loop objects do not enter the candidate graph.
"""

from __future__ import annotations

from collections import defaultdict, deque
from typing import Any, Dict, Iterable, List, Mapping, Set

import pandas as pd

from vis_project_utils.utils import _safe_int


class VEGBuilder:
    """Build and prune a lightweight data-flow graph."""

    def build(self, *, trace_bundle: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Dict[str, Any]:
        trace = dict(trace_bundle or {})
        artifacts = dict(artifact_store or {})

        stage_result = _build_stage_result(trace.get("stage_result") or {})
        all_transforms = _build_transforms(trace.get("events") or [])
        all_tables = _build_tables(trace.get("tables") or {}, artifacts)
        tables, transforms = _prune_reachable_graph(
            tables=all_tables,
            transforms=all_transforms,
            stage_result=stage_result,
            artifact_store=artifacts,
        )

        return {
            "round_index": trace.get("round_index"),
            "tables": tables,
            "transforms": transforms,
            "stage_result": stage_result,
            "trace_stats": dict(trace.get("trace_stats") or {}),
        }


def build_veg(trace_bundle: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Dict[str, Any]:
    return VEGBuilder().build(trace_bundle=trace_bundle, artifact_store=artifact_store)


def _prune_reachable_graph(
    *,
    tables: Mapping[str, Dict[str, Any]],
    transforms: List[Dict[str, Any]],
    stage_result: Mapping[str, Any],
    artifact_store: Mapping[str, Any],
) -> tuple[Dict[str, Dict[str, Any]], List[Dict[str, Any]]]:
    """Reverse-traverse from real sinks and remove orphan implementation objects.

    Seeds are stage_result references plus still-live artifacts.  Generated code keeps
    user-named intermediates alive in its namespace, while pandas UDF/internal
    temporaries normally disappear; this distinction gives a practical and stable
    pruning boundary even when stage_result contains only scalar values.
    """

    producer_by_output: Dict[str, List[int]] = defaultdict(list)
    for index, transform in enumerate(transforms):
        output = str(transform.get("output") or "")
        if output:
            producer_by_output[output].append(index)

    seeds: Set[str] = {
        str(ref.get("tid") or "")
        for ref in list(dict(stage_result or {}).get("refs") or [])
        if str(ref.get("tid") or "")
    }
    transform_outputs = {
        str(transform.get("output") or "")
        for transform in transforms
        if str(transform.get("output") or "")
    }
    # Keep live derived artifacts, but do not seed every raw input table merely because
    # it was loaded into the execution namespace.
    seeds.update(
        str(tid)
        for tid in artifact_store
        if str(tid) in tables and str(tid) in transform_outputs
    )

    # Defensive fallback for traces without live pandas artifacts: retain terminal
    # outputs, rather than reverting to every object ever observed.
    if not seeds:
        input_tids = {
            str(tid)
            for transform in transforms
            for tid in list(transform.get("inputs") or [])
            if str(tid)
        }
        terminal_outputs = [
            str(transform.get("output") or "")
            for transform in transforms
            if str(transform.get("output") or "") and str(transform.get("output") or "") not in input_tids
        ]
        seeds.update(terminal_outputs[-50:])

    reachable_tids: Set[str] = set()
    reachable_transform_indexes: Set[int] = set()
    queue = deque(tid for tid in seeds if tid)

    while queue:
        tid = queue.popleft()
        if tid in reachable_tids:
            continue
        reachable_tids.add(tid)
        for index in producer_by_output.get(tid, []):
            if index in reachable_transform_indexes:
                continue
            reachable_transform_indexes.add(index)
            transform = transforms[index]
            upstream = [str(v) for v in list(transform.get("inputs") or []) if str(v)]
            upstream.extend(str(v) for v in dict(transform.get("read") or {}) if str(v))
            for upstream_tid in upstream:
                if upstream_tid not in reachable_tids:
                    queue.append(upstream_tid)

    kept_transforms = [
        transform for index, transform in enumerate(transforms)
        if index in reachable_transform_indexes
    ]

    # Ensure every id referenced by a retained edge/ref has a table manifest when one
    # exists in the original trace.
    for transform in kept_transforms:
        reachable_tids.update(str(v) for v in list(transform.get("inputs") or []) if str(v))
        output = str(transform.get("output") or "")
        if output:
            reachable_tids.add(output)
        reachable_tids.update(str(v) for v in dict(transform.get("read") or {}) if str(v))
    reachable_tids.update(seeds)

    kept_tables = {
        tid: dict(info)
        for tid, info in dict(tables or {}).items()
        if str(tid) in reachable_tids
    }
    return kept_tables, kept_transforms


def _build_tables(raw_tables: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Dict[str, Dict[str, Any]]:
    tables: Dict[str, Dict[str, Any]] = {}
    for raw_tid, raw_info in dict(raw_tables or {}).items():
        tid = str(raw_tid or "")
        if not tid:
            continue
        info = dict(raw_info or {})
        artifact = artifact_store.get(tid)
        columns = _normalize_columns(info.get("columns"))
        column_count = _safe_int(info.get("column_count")) or 0
        if column_count <= 0:
            shape = _shape_list(info.get("shape"))
            column_count = shape[1] if len(shape) > 1 else len(columns)
        tables[tid] = {
            "name": str(info.get("name") or tid),
            "kind": str(info.get("kind") or "dataframe"),
            "shape": _shape_list(info.get("shape")),
            "columns": columns,
            "column_count": column_count,
            "columns_truncated": bool(info.get("columns_truncated", column_count > len(columns))),
            "artifact_key": tid if _is_table_artifact(artifact) else None,
        }
    return tables


def _build_transforms(raw_events: Iterable[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    transforms: List[Dict[str, Any]] = []
    for raw_event in list(raw_events or []):
        event = dict(raw_event or {})
        output = str(event.get("output") or "")
        if not output or output == "__nested_untracked__":
            continue
        transforms.append(
            {
                "id": _safe_int(event.get("id")),
                "op": str(event.get("op") or ""),
                "family": str(event.get("event_family") or "unknown"),
                "inputs": [
                    str(tid) for tid in list(event.get("inputs") or [])
                    if tid and str(tid) != "__nested_untracked__"
                ],
                "output": output,
                "read": _normalize_read_map(event.get("read") or {}),
                "write": [str(col) for col in list(event.get("write") or []) if col is not None],
                "args": dict(event.get("args") or {}),
            }
        )
    return transforms


def _build_stage_result(raw_stage_result: Mapping[str, Any]) -> Dict[str, Any]:
    raw = dict(raw_stage_result or {})
    refs: List[Dict[str, str]] = []
    for raw_ref in list(raw.get("refs") or []):
        ref = dict(raw_ref or {})
        tid = str(ref.get("tid") or "")
        if not tid or tid == "__nested_untracked__":
            continue
        refs.append({"path": str(ref.get("path") or "stage_result"), "tid": tid})
    return {"type": str(raw.get("type") or ""), "refs": refs}


def _normalize_columns(raw_columns: Any) -> List[str]:
    return [str(col) for col in list(raw_columns or []) if col is not None]


def _normalize_read_map(raw_read: Any) -> Dict[str, List[str]]:
    out: Dict[str, List[str]] = {}
    for raw_tid, raw_columns in dict(raw_read or {}).items():
        tid = str(raw_tid or "")
        if not tid or tid == "__nested_untracked__":
            continue
        columns = [str(col) for col in list(raw_columns or []) if col is not None]
        if columns:
            out[tid] = columns
    return out


def _shape_list(raw_shape: Any) -> List[int]:
    if isinstance(raw_shape, tuple):
        raw_shape = list(raw_shape)
    if not isinstance(raw_shape, list):
        return []
    shape: List[int] = []
    for value in raw_shape:
        try:
            shape.append(int(value))
        except Exception:
            continue
    return shape


def _is_table_artifact(value: Any) -> bool:
    return isinstance(value, (pd.DataFrame, pd.Series))
