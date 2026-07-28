"""chart/profile.py
------------------
DataFrame 列画像工具。只判断最基础的列角色，不做旧版复杂模板绑定。
"""

from __future__ import annotations

from typing import Any, Dict, List
import re

import pandas as pd
from pandas.api.types import is_bool_dtype, is_datetime64_any_dtype, is_numeric_dtype

from vis_project_utils.utils import preview_records, safe_to_datetime, safe_to_numeric
from vis_project_utils.dataframe_safety import make_unique_column_names, safe_nunique

_TIME_NAME_HINTS = {"date", "time", "opened", "closed", "created", "updated", "month", "quarter", "year", "period"}
_ID_NAME_HINTS = {"id", "uuid", "guid", "key"}
_CATEGORY_CODE_HINTS = {"code", "ward", "postal", "postcode", "zip", "zipcode", "fips", "naics", "sic"}
_STRONG_IDENTIFIER_NAMES = {"unitid", "projectid", "schoolid", "inspectionid", "licenseid", "licenseno", "accountno", "recordid", "rowid", "objectid"}


def build_table_profile(df: pd.DataFrame, table_name: str = "") -> Dict[str, Any]:
    """为 DataFrame 构建轻量画像。"""
    if df is None:
        df = pd.DataFrame()
    columns: Dict[str, Any] = {}
    unique_names = make_unique_column_names(list(df.columns))
    for index, name in enumerate(unique_names):
        columns[name] = profile_column(df.iloc[:, index], name, int(len(df)))
    return {"table_name": table_name, "rows": int(df.shape[0]), "cols": int(df.shape[1]), "columns": columns}


def profile_column(series: pd.Series, column_name: str, row_count: int) -> Dict[str, Any]:
    """为单列构建轻量画像。"""
    name = str(column_name)
    lowered = name.lower()
    non_null = series.dropna()
    unique_count = safe_nunique(non_null, dropna=True) if row_count else 0
    missing_ratio = float(series.isna().mean()) if row_count else 0.0
    unique_ratio = float(unique_count / max(1, len(non_null))) if len(non_null) else 0.0
    dtype = str(series.dtype)

    is_bool = bool(is_bool_dtype(series))
    numeric_series = safe_to_numeric(series)
    numeric_ratio = float(numeric_series.notna().mean()) if row_count else 0.0
    is_numeric = bool(is_numeric_dtype(series) or numeric_ratio >= 0.8)

    tokens = {part for part in re.split(r"[^a-z0-9]+", lowered) if part}
    normalized = "".join(ch for ch in lowered if ch.isalnum())
    is_identifier = bool(
        tokens & _ID_NAME_HINTS
        or lowered.endswith("_id")
        or lowered.endswith("_key")
        or normalized in _STRONG_IDENTIFIER_NAMES
        or ("license" in tokens and bool(tokens & {"no", "number", "id"}))
    )
    is_category_code = bool(tokens & _CATEGORY_CODE_HINTS)

    is_datetime = bool(is_datetime64_any_dtype(series))
    if not is_datetime and any(hint in lowered for hint in _TIME_NAME_HINTS):
        sample = series.head(min(80, len(series)))
        if is_numeric:
            valid = safe_to_numeric(sample).dropna()
            is_datetime = bool(not valid.empty and valid.between(1800, 2200).mean() >= 0.8)
        else:
            parsed = safe_to_datetime(sample)
            is_datetime = bool(parsed.notna().mean() >= 0.6) if len(parsed) else False

    roles: List[str] = []
    if is_bool:
        roles.append("boolean")
    if is_datetime:
        roles.append("time")
    if is_identifier:
        roles.append("identifier")
    if is_category_code:
        roles.append("dimension")
    if is_numeric and not is_bool and not is_datetime and not is_identifier and not is_category_code:
        roles.append("metric")
    if _is_dimension_candidate(name, unique_count, row_count, is_numeric, is_bool, is_datetime):
        roles.append("dimension")

    examples = [str(item) for item in list(non_null.astype(str).head(5))]
    return {
        "name": name,
        "dtype": dtype,
        "rows": int(row_count),
        "unique_count": unique_count,
        "unique_ratio": unique_ratio,
        "missing_ratio": missing_ratio,
        "roles": sorted(set(roles)),
        "examples": examples,
    }


def _is_dimension_candidate(name: str, unique_count: int, row_count: int, is_numeric: bool, is_bool: bool, is_datetime: bool) -> bool:
    if row_count <= 0 or is_datetime:
        return False
    if is_bool:
        return True
    lowered = name.lower()
    if any(hint in lowered for hint in ["category", "type", "status", "priority", "department", "group", "country", "region", "user"]):
        return True
    if not is_numeric:
        return 1 <= unique_count <= max(30, int(row_count * 0.6))
    return 2 <= unique_count <= min(12, max(2, int(row_count * 0.2)))
