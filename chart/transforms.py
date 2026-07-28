"""chart/transforms.py
---------------------
执行 VisualPlan 中显式声明的数据变换，生成 support table。
"""

from __future__ import annotations

from typing import Any, Dict, List

import pandas as pd

from vis_project_utils.utils import safe_to_datetime, preview_records, sanitize_filename
from vis_project_utils.dataframe_safety import safe_hashable_dataframe, safe_value_counts


def apply_transform_ops(df: pd.DataFrame, ops: List[Dict[str, Any]]) -> pd.DataFrame:
    """按顺序执行 VisualPlan 中的 transform ops。"""
    if df is None:
        raise ValueError("source dataframe is None")
    out = df.copy()
    for op in list(ops or []):
        name = str(op.get("op") or "")
        if name == "use_columns":
            cols = [str(col) for col in list(op.get("columns") or [])]
            _require_columns(out, cols)
            out = out.loc[:, cols].copy()
        elif name == "rename_columns":
            out = out.rename(columns={str(k): str(v) for k, v in dict(op.get("mapping") or {}).items()})
        elif name == "groupby_count":
            by = [str(col) for col in list(op.get("by") or [])]
            output = str(op.get("output") or "count")
            _require_columns(out, by)
            group_df = safe_hashable_dataframe(out, by)
            out = group_df.groupby(by, dropna=False).size().reset_index(name=output)
        elif name == "value_counts":
            column = str(op.get("column") or "")
            output = str(op.get("output") or "count")
            _require_columns(out, [column])
            counts = safe_value_counts(out[column], dropna=False)
            out = counts.rename_axis(column).reset_index(name=output)
        elif name == "groupby_agg":
            by = [str(col) for col in list(op.get("by") or [])]
            value = str(op.get("value") or "")
            agg = str(op.get("agg") or "mean")
            output = str(op.get("output") or value)
            _require_columns(out, by + [value])
            group_df = safe_hashable_dataframe(out, by)
            out = group_df.groupby(by, dropna=False)[value].agg(agg).reset_index(name=output)
        elif name == "sort_by":
            column = str(op.get("column") or "")
            if column in out.columns:
                out = out.sort_values(by=column, ascending=bool(op.get("ascending", True))).reset_index(drop=True)
        elif name == "top_k":
            out = out.head(max(1, int(op.get("k") or 12))).copy()
        elif name == "filter_in":
            column = str(op.get("column") or "")
            values = {str(v) for v in list(op.get("values") or [])}
            _require_columns(out, [column])
            out = out[out[column].astype(str).isin(values)].copy()
        elif name == "time_floor":
            column = str(op.get("column") or "")
            freq = str(op.get("freq") or "M")
            output = str(op.get("output") or column)
            _require_columns(out, [column])
            dt = safe_to_datetime(out[column])
            try:
                dt_for_period = dt.dt.tz_convert(None)
            except Exception:
                dt_for_period = dt

            if freq.upper().startswith("Q"):
                out[output] = dt_for_period.dt.to_period("Q").astype(str)
            elif freq.upper().startswith("Y"):
                out[output] = dt_for_period.dt.year
            else:
                out[output] = dt_for_period.dt.to_period("M").astype(str)
        elif name == "pivot_table":
            index = str(op.get("index") or "")
            columns = str(op.get("columns") or "")
            values = str(op.get("values") or "")
            aggfunc = str(op.get("aggfunc") or "mean")
            _require_columns(out, [index, columns, values])
            pivot_df = safe_hashable_dataframe(out, [index, columns])
            out = pivot_df.pivot_table(index=index, columns=columns, values=values, aggfunc=aggfunc).reset_index()
        elif not name:
            continue
        else:
            raise ValueError(f"unsupported transform op: {name}")
    return out.reset_index(drop=True)


def _require_columns(df: pd.DataFrame, columns: List[str]) -> None:
    missing = [col for col in columns if col and col not in df.columns]
    if missing:
        raise KeyError(f"missing columns for transform: {missing}")
