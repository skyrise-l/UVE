"""
data_loader/metadata_enricher.py
--------------------------------
生成给 LLM prompt 使用的轻量表 schema。

输出列格式：
- name: 列名；
- type: 简化类型，取 str/int/float/bool/datetime；
- top_values: 可选，帮助模型理解列语义的代表性取值；
- description: 可选，由数据集官方 metadata 在 loader 中合并。

设计原则：
- top_values 不仅是低基数类别列的高频值，也兼具 sample values 的作用；
- 低基数字符串列展示更多值，用于理解枚举空间；
- 高基数但语义强的实体列 / 文本列展示少量值，用于理解列含义和潜在关系；
- 近似唯一且缺少业务语义的 ID-like 列默认不展示，避免 prompt 噪声。

本模块不再生成 value_signal，也不再抽取重复 token、实体或短语。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import re
from typing import Any, Dict, List, Optional, Set

import pandas as pd
from pandas.api.types import (
    is_bool_dtype,
    is_datetime64_any_dtype,
    is_integer_dtype,
    is_numeric_dtype,
)


@dataclass
class MetadataEnrichmentConfig:
    """轻量 schema 配置。"""

    # 低基数字段阈值。注意：top_values 的语义不是纯类别频数，
    # 而是“列语义代表值”。因此低基数只是准入条件之一。
    top_values_max_unique_ratio: float = 0.2
    top_values_max_unique_count: int = 30
    top_values_min_non_null: int = 3

    # 不同列角色使用不同展示预算，避免所有列都无脑 top5。
    max_top_values_per_column: int = 5
    max_semantic_values_per_column: int = 3
    max_datetime_values_per_column: int = 3
    max_bool_values_per_column: int = 2
    max_value_string_len: int = 100

    def to_dict(self) -> Dict[str, Any]:
        """转成普通字典，供 metadata cache 计算缓存键。"""
        return asdict(self)


def _json_scalar(value: Any) -> Any:
    """把 pandas / numpy 标量转成 JSON 友好的普通 Python 值。"""
    try:
        if pd.isna(value):
            return None
    except Exception:
        pass

    if isinstance(value, pd.Timestamp):
        return value.isoformat()

    if hasattr(value, "item") and not isinstance(value, (str, bytes)):
        try:
            value = value.item()
        except Exception:
            pass

    if isinstance(value, (bool, int, float, str)) or value is None:
        return value
    return str(value)


def _simplified_type(series: pd.Series) -> str:
    """把 pandas dtype 压缩成 prompt 中使用的稳定类型。"""
    non_missing = series.dropna()
    if is_bool_dtype(series):
        return "bool"
    if not non_missing.empty and all(
        isinstance(value, (bool, type(True), type(False)))
        for value in non_missing.head(50)
    ):
        return "bool"
    if is_integer_dtype(series):
        return "int"
    if is_numeric_dtype(series):
        return "float"
    if is_datetime64_any_dtype(series):
        return "datetime"
    # Prompt type must describe the actual runtime dtype. Date-like strings that were
    # not normalized by the loader remain `str` instead of being mislabeled datetime.
    return "str"


_SEMANTIC_NAME_HINTS: Set[str] = {
    # 人 / 组织 / 业务实体
    "user", "name", "owner", "manager", "assigned", "assignee", "employee",
    "customer", "client", "vendor", "supplier", "person", "member", "agent",
    # 产品 / 资产 / 服务实体
    "product", "service", "asset", "device", "printer", "server", "application",
    "app", "software", "hardware", "ci", "item", "model", "brand",
    # 组织、地域、分组与类别
    "group", "team", "department", "dept", "location", "country", "city",
    "region", "site", "office", "state", "status", "category", "type",
    "class", "priority", "severity", "impact", "urgency", "reason", "cause",
}

_FREE_TEXT_NAME_HINTS: Set[str] = {
    "description", "desc", "comment", "message", "summary", "title", "text",
    "note", "notes", "detail", "details", "issue", "problem", "resolution",
    "feedback", "review", "remark", "content", "body", "subject",
}

_ID_NAME_HINTS: Set[str] = {
    "id", "uuid", "guid", "hash", "number", "ticket", "record", "transaction",
    "url", "email", "code", "key",
}


def _name_tokens(name: str) -> Set[str]:
    """把列名拆成稳定 token，避免 `id` 误命中 `valid` 这类子串。"""
    lowered = str(name or "").lower()
    return {token for token in re.split(r"[^a-z0-9]+", lowered) if token}


def _name_has_hint(name: str, hints: Set[str]) -> bool:
    tokens = _name_tokens(name)
    if tokens.intersection(hints):
        return True

    # 少数常见列名以复合词出现，例如 username / shortdescription。
    lowered = str(name or "").lower()
    semantic_compounds = {
        "username", "fullname", "firstname", "lastname", "assignedto",
        "assignedgroup", "openedby", "closedby",
    }
    free_text_compounds = {"shortdescription", "longdescription"}
    if hints is _SEMANTIC_NAME_HINTS:
        return lowered in semantic_compounds
    if hints is _FREE_TEXT_NAME_HINTS:
        return lowered in free_text_compounds
    if hints is _ID_NAME_HINTS:
        return lowered in {"sysid", "recordid", "transactionid", "ticketnumber"}
    return False


def _looks_free_text(values: pd.Series) -> bool:
    """基于样本长度粗略判断无明显列名提示的自由文本列。"""
    if values.empty:
        return False
    sample = values.dropna().astype(str).head(20)
    if sample.empty:
        return False
    avg_len = float(sample.str.len().mean())
    avg_words = float(sample.str.split().map(len).mean())
    return bool(avg_len >= 30 or avg_words >= 4)


def _looks_machine_identifier_values(values: pd.Series) -> bool:
    """判断样例值是否主要是 UUID/hash/长编号等机器标识。

    这类值即使列名带 user/customer 等实体语义，也通常不适合直接放入
    prompt 的 top_values：它们很难帮助模型理解业务含义，反而容易制造噪声。
    """
    if values.empty:
        return False
    sample = values.dropna().astype(str).str.strip().head(20)
    sample = sample.loc[sample != ""]
    if sample.empty:
        return False

    uuid_re = re.compile(
        r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    compact_hex_re = re.compile(r"^[0-9a-fA-F]{16,}$")
    long_numeric_re = re.compile(r"^[0-9]{10,}$")
    code_like_re = re.compile(r"^[A-Za-z]{0,4}[-_ ]?[0-9]{5,}$")

    def is_identifier(text: str) -> bool:
        compact = text.replace("-", "").replace("_", "").replace(" ", "")
        if uuid_re.match(text) or compact_hex_re.match(compact) or long_numeric_re.match(compact):
            return True
        if code_like_re.match(text):
            return True
        alpha_num = sum(ch.isalnum() for ch in text)
        if len(text) >= 18 and alpha_num / max(len(text), 1) >= 0.85 and " " not in text:
            return True
        return False

    matches = sum(1 for value in sample if is_identifier(str(value)))
    return matches / max(len(sample), 1) >= 0.8


def _clean_values_for_top_values(series: pd.Series, column_type: str) -> pd.Series:
    values = series.dropna()
    if column_type == "str" or values.dtype == object or pd.api.types.is_string_dtype(values):
        values = values.loc[values.astype(str).str.strip() != ""]
    return values


def _top_values_profile(
    series: pd.Series,
    column_type: str,
    config: MetadataEnrichmentConfig,
) -> Dict[str, Any]:
    """计算 top_values 是否展示以及展示预算所需的列画像。"""
    values = _clean_values_for_top_values(series, column_type)
    non_null_count = int(values.shape[0])
    unique_count = int(values.nunique(dropna=True)) if non_null_count else 0
    unique_ratio = unique_count / max(non_null_count, 1)

    name = str(series.name or "")
    semantic_name_hint = _name_has_hint(name, _SEMANTIC_NAME_HINTS)
    id_name_hint = _name_has_hint(name, _ID_NAME_HINTS)
    # 长 ID / hash 往往也满足“平均长度较长”，但它们不是自由文本。
    free_text_hint = _name_has_hint(name, _FREE_TEXT_NAME_HINTS) or (
        column_type == "str" and not id_name_hint and _looks_free_text(values)
    )
    id_like = id_name_hint and unique_ratio >= 0.9
    machine_identifier_values = column_type == "str" and unique_ratio >= 0.9 and _looks_machine_identifier_values(values)
    low_cardinality = (
        unique_count <= int(config.top_values_max_unique_count)
        or unique_ratio <= float(config.top_values_max_unique_ratio)
    )

    return {
        "values": values,
        "non_null_count": non_null_count,
        "unique_count": unique_count,
        "unique_ratio": unique_ratio,
        "semantic_name_hint": semantic_name_hint,
        "free_text_hint": free_text_hint,
        "id_like": id_like,
        "machine_identifier_values": machine_identifier_values,
        "low_cardinality": low_cardinality,
    }


def _should_include_top_values(
    series: pd.Series,
    column_type: str,
    config: MetadataEnrichmentConfig,
) -> bool:
    """判断是否展示列语义代表值 top_values。"""
    if column_type not in {"str", "bool", "datetime"}:
        return False

    profile = _top_values_profile(series, column_type, config)
    if int(profile["non_null_count"]) < int(config.top_values_min_non_null):
        return False
    if int(profile["unique_count"]) <= 0:
        return False

    if column_type == "bool":
        return True

    # 日期列的 type 已经足以说明格式语义；只有低基数日期/时间枚举才展示，
    # 避免给每个高唯一时间戳列都塞 3 个样例值。
    if column_type == "datetime":
        return bool(profile["low_cardinality"])

    # 近似唯一且缺少业务语义的 ID-like 列通常只制造 prompt 噪声。
    if bool(profile["id_like"]) and not bool(profile["semantic_name_hint"]) and not bool(profile["free_text_hint"]):
        return False

    # UUID/hash/长编号类值即使列名带实体语义，也通常不适合直接展示。
    if bool(profile["machine_identifier_values"]):
        return False

    return bool(
        profile["low_cardinality"]
        or profile["semantic_name_hint"]
        or profile["free_text_hint"]
    )


def _top_value_limit(
    series: pd.Series,
    column_type: str,
    config: MetadataEnrichmentConfig,
) -> int:
    """按列角色动态控制 top_values 数量。"""
    if column_type == "bool":
        return int(config.max_bool_values_per_column)
    if column_type == "datetime":
        return int(config.max_datetime_values_per_column)

    profile = _top_values_profile(series, column_type, config)
    if bool(profile["low_cardinality"]):
        return int(config.max_top_values_per_column)
    if bool(profile["semantic_name_hint"]) or bool(profile["free_text_hint"]):
        return int(config.max_semantic_values_per_column)
    return int(config.max_top_values_per_column)


def _top_values(
    series: pd.Series,
    *,
    limit: int,
    max_string_len: int,
) -> List[Any]:
    """返回前若干个代表性取值。

    排序规则：先按出现频率降序；频率相同则保留首次出现顺序。
    因此它既能表达低基数字段的高频值，也能在高基数字段中退化为
    数据顺序下的少量 sample values。
    """
    values = series.dropna()
    if values.empty:
        return []

    if values.dtype == object or pd.api.types.is_string_dtype(values):
        mask = values.astype(str).str.strip() != ""
        values = values.loc[mask]
    if values.empty:
        return []

    counts: Dict[str, Dict[str, Any]] = {}
    for position, value in enumerate(values.tolist()):
        safe = _json_scalar(value)
        if safe is None:
            continue
        if isinstance(safe, str):
            safe = safe.strip()
            if not safe:
                continue
            if len(safe) > max_string_len:
                safe = safe[:max_string_len]
        key = repr(safe)
        if key not in counts:
            counts[key] = {"value": safe, "count": 0, "first_position": position}
        counts[key]["count"] += 1

    ranked = sorted(
        counts.values(),
        key=lambda item: (-int(item["count"]), int(item["first_position"])),
    )
    return [item["value"] for item in ranked[: max(0, int(limit))]]


def _build_column_metadata(
    series: pd.Series,
    config: Optional[MetadataEnrichmentConfig] = None,
) -> Dict[str, Any]:
    """生成单列轻量 schema。"""
    resolved_config = config or MetadataEnrichmentConfig()
    column_type = _simplified_type(series)
    entry: Dict[str, Any] = {
        "name": str(series.name),
        "type": column_type,
    }

    if _should_include_top_values(series, column_type, resolved_config):
        values = _top_values(
            series,
            limit=_top_value_limit(series, column_type, resolved_config),
            max_string_len=resolved_config.max_value_string_len,
        )
        if values:
            entry["top_values"] = values

    return entry


def build_table_metadata(
    dataframe: pd.DataFrame,
    config: Optional[MetadataEnrichmentConfig] = None,
) -> Dict[str, Any]:
    """从 DataFrame 生成 prompt 使用的轻量 schema。"""
    resolved_config = config or MetadataEnrichmentConfig()
    return {
        "num_rows": int(dataframe.shape[0]),
        "num_columns": int(dataframe.shape[1]),
        "columns": [
            _build_column_metadata(dataframe[column_name], resolved_config)
            for column_name in dataframe.columns
        ],
    }
