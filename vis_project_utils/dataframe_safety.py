"""dataframe_safety.py
---------------------
Pandas 安全工具。

本模块只解决一个具体问题：DataFrame 单元格里偶尔会出现 list/dict/set。
这些值在 nunique、value_counts、groupby、pivot_table 等哈希操作中会触发
``unhashable type``，导致整条视觉管线失败。这里把嵌套值转换成稳定、可哈希
的结构，保证画像、聚合和渲染可以继续执行。
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Sequence

import numpy as np
import pandas as pd


def make_hashable_value(value: Any) -> Any:
    """把单个值转换成 pandas 哈希操作可接受的值。

    输入可以是普通标量，也可以是 list/dict/set/ndarray 等嵌套对象；输出保持
    原始语义的简化表示。普通标量原样返回，嵌套对象转成 tuple，避免 groupby
    或 nunique 因不可哈希对象中断。
    """
    if isinstance(value, Mapping):
        return tuple(sorted((str(key), make_hashable_value(item)) for key, item in value.items()))
    if isinstance(value, (list, tuple, set, frozenset)):
        return tuple(make_hashable_value(item) for item in value)
    if isinstance(value, np.ndarray):
        return tuple(make_hashable_value(item) for item in value.tolist())
    return value


def has_unhashable_values(series: pd.Series, sample_size: int = 200) -> bool:
    """轻量判断一列是否包含会破坏哈希操作的嵌套值。"""
    if not isinstance(series, pd.Series) or series.empty:
        return False
    sample = series.dropna().head(max(1, int(sample_size)))
    for value in sample.tolist():
        if isinstance(value, (Mapping, list, tuple, set, frozenset, np.ndarray)):
            return True
    return False


def safe_hashable_series(series: pd.Series) -> pd.Series:
    """返回适合 nunique/value_counts/groupby 的 Series。

    只有在发现嵌套值时才复制并转换；普通列直接返回原 Series，减少不必要的数据
    处理，也避免改变数值、时间列的 dtype。
    """
    if not isinstance(series, pd.Series):
        return pd.Series(series)
    if not has_unhashable_values(series):
        return series
    return series.map(make_hashable_value)


def safe_nunique(series: pd.Series, *, dropna: bool = True) -> int:
    """安全计算唯一值数量。"""
    safe_series = safe_hashable_series(series)
    return int(safe_series.nunique(dropna=dropna))


def safe_value_counts(series: pd.Series, *, dropna: bool = False) -> pd.Series:
    """安全计算 value_counts。"""
    safe_series = safe_hashable_series(series)
    return safe_series.value_counts(dropna=dropna)


def safe_hashable_dataframe(df: pd.DataFrame, columns: Sequence[str] | None = None) -> pd.DataFrame:
    """返回指定列已做哈希安全转换的 DataFrame。

    输入：原始 DataFrame 与需要参与 groupby/pivot/value_counts 的列名。
    输出：如果没有嵌套值，直接返回原 DataFrame；否则返回浅复制后的 DataFrame。
    """
    if not isinstance(df, pd.DataFrame) or df.empty:
        return df
    target_columns = [str(col) for col in list(columns or []) if str(col) in df.columns]
    if not target_columns:
        return df

    out = df
    copied = False
    for column in target_columns:
        series = df[column]
        if not has_unhashable_values(series):
            continue
        if not copied:
            out = df.copy()
            copied = True
        out[column] = safe_hashable_series(series)
    return out


def compact_value_text(value: Any, max_chars: int = 80) -> str:
    """把任意值压成短文本，供卡片和标签展示使用。"""
    text = str(value)
    limit = max(10, int(max_chars))
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"



def make_unique_column_names(columns: Sequence[Any]) -> list[str]:
    """Return deterministic unique names for a possibly duplicated column index.

    Generated analysis code can legitimately create duplicate labels after merges or
    renames.  ``df["name"]`` then returns a DataFrame rather than a Series and breaks
    profiling/scoring code.  The visualization copy uses ``name``, ``name__2``, ...;
    the executed result itself is left untouched.
    """
    seen: dict[str, int] = {}
    output: list[str] = []
    for raw in list(columns or []):
        base = str(raw)
        count = seen.get(base, 0) + 1
        seen[base] = count
        output.append(base if count == 1 else f"{base}__{count}")
    return output

def normalize_analysis_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """Return a copy whose missing scalars are safe for numerical/visual analysis.

    The stage-result contract may legitimately retain pandas nullable dtypes.  The
    visualization stack, however, performs scalar formatting and statistics that
    expect ``numpy.nan``/``None`` rather than ``pd.NA``.  This function is applied
    only to the visual artifact store and never mutates the code-execution result.
    """
    if not isinstance(df, pd.DataFrame):
        return df
    out = df.copy()
    unique_columns = make_unique_column_names(list(out.columns))
    if list(map(str, out.columns)) != unique_columns:
        out.columns = unique_columns
    for column in list(out.columns):
        series = out[column]
        try:
            if pd.api.types.is_numeric_dtype(series) and not pd.api.types.is_bool_dtype(series):
                numeric = pd.to_numeric(series, errors="coerce").astype("float64")
                out[column] = numeric.replace([np.inf, -np.inf], np.nan)
                continue
            if pd.api.types.is_bool_dtype(series):
                # Nullable booleans cannot be converted directly to bool when NA is
                # present.  Keep true/false values and represent missing as None.
                out[column] = series.astype(object).where(pd.notna(series), None)
                continue
            if pd.api.types.is_object_dtype(series) or pd.api.types.is_string_dtype(series) or isinstance(series.dtype, pd.CategoricalDtype):
                out[column] = series.astype(object).where(pd.notna(series), None)
        except Exception:
            # A single exotic extension column must not make all visual evidence fail.
            try:
                out[column] = series.astype(object).where(pd.notna(series), None)
            except Exception:
                pass
    return out


def normalize_artifact_store(artifact_store: Mapping[str, Any] | None) -> dict[str, Any]:
    """Normalize every DataFrame in an artifact store without touching other values."""
    result: dict[str, Any] = {}
    for key, value in dict(artifact_store or {}).items():
        result[str(key)] = normalize_analysis_dataframe(value) if isinstance(value, pd.DataFrame) else value
    return result
