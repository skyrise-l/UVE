"""slot_binding.py
-----------------

运行时槽位绑定工具。

本模块在图计划生成阶段实时读取真实 DataFrame，对列的值分布、类型、
缺失、基数、可解析时间等信息进行分析，并为固定模板的槽位生成候选列。

注意：这里不做 query keyword 检索。少量列名提示只用于识别 id/time/count
等弱语义，主判断尽量来自列值本身。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from itertools import combinations, product
from typing import Any, Dict, List, Mapping, Optional, Sequence

import pandas as pd
from pandas.api.types import is_bool_dtype, is_datetime64_any_dtype, is_numeric_dtype

from vis_project_utils.utils import clip01, safe_to_datetime, safe_to_numeric
from vis_project_utils.dataframe_safety import safe_hashable_series, safe_nunique
from .template_registry import ViewTemplate


ID_HINTS = {"id", "uuid", "guid", "key", "编号", "编码"}
CATEGORY_CODE_HINTS = {"code", "ward", "postal", "postcode", "zip", "zipcode", "fips", "naics", "sic", "level", "grade"}
STRONG_IDENTIFIER_NAMES = {
    "unitid", "projectid", "schoolid", "inspectionid", "licenseid",
    "licenseno", "accountno", "recordid", "rowid", "objectid",
}
TIME_HINTS = {"date", "time", "year", "month", "day", "period", "opened", "closed", "created", "updated", "日期", "时间", "年", "月"}
COUNT_HINTS = {"count", "cnt", "num", "number", "total", "frequency", "freq", "数量", "次数", "总数"}
RATE_HINTS = {"rate", "ratio", "percent", "percentage", "proportion", "占比", "比例", "率"}

MAX_SLOT_CANDIDATES = 5
MIN_GROUP_SCORE = 0.42
MIN_METRIC_SCORE = 0.42
MIN_TIME_SCORE = 0.55


@dataclass
class ColumnRuntimeProfile:
    """面向槽位绑定的运行时列画像。"""

    name: str
    dtype: str
    rows: int
    non_null_count: int
    missing_ratio: float
    unique_count: int
    unique_ratio: float
    examples: List[str] = field(default_factory=list)
    is_bool: bool = False
    is_numeric: bool = False
    numeric_ratio: float = 0.0
    is_datetime: bool = False
    datetime_parse_ratio: float = 0.0
    is_constant: bool = False
    is_identifier_like: bool = False
    is_categorical_like: bool = False
    is_count_like_name: bool = False
    is_rate_like_name: bool = False
    is_time_name_like: bool = False
    declared_data_format: str = ""
    semantic_declared: bool = False
    is_primary_key: bool = False
    is_foreign_key: bool = False
    measure_kind: str = "unknown"
    is_additive: Optional[bool] = None
    min_value: Optional[float] = None
    max_value: Optional[float] = None
    mean_value: Optional[float] = None
    std_value: Optional[float] = None


@dataclass
class SlotCandidate:
    """某列作为某个槽位的候选。"""

    slot: str
    column: str
    score: float
    reasons: List[str] = field(default_factory=list)


@dataclass
class TableSlotIndex:
    """一张表的运行时槽位索引。"""

    tid: str
    rows: int
    cols: int
    profiles: Dict[str, ColumnRuntimeProfile]
    slot_candidates: Dict[str, List[SlotCandidate]]


@dataclass
class TemplateBinding:
    """一个模板绑定到具体列后的结果。"""

    template_id: str
    view_family: str
    chart_type: str
    pattern: str
    slots: Dict[str, str]
    score: float
    slot_scores: Dict[str, float]
    reasons: List[str]
    supported_tendencies: List[str]
    template_prior: float


# ---------------------------------------------------------------------------
# 运行时列画像
# ---------------------------------------------------------------------------


def build_table_slot_index(
    df: pd.DataFrame,
    tid: str = "",
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> TableSlotIndex:
    """根据真实 DataFrame 构建槽位绑定索引。"""

    if df is None:
        df = pd.DataFrame()
    profiles: Dict[str, ColumnRuntimeProfile] = {}
    for column in list(df.columns):
        name = str(column)
        profiles[name] = profile_column_runtime(
            df[column],
            name,
            int(len(df)),
            semantic_hint=dict((column_semantics or {}).get(name) or {}),
        )

    slot_candidates = {
        "group": _score_group_candidates(profiles),
        "metric": _score_metric_candidates(profiles),
        "time": _score_time_candidates(profiles),
    }
    # x_metric / y_metric 复用 metric 候选，但在绑定 relation_scatter 时会要求两列不同。
    slot_candidates["x_metric"] = [SlotCandidate("x_metric", c.column, c.score, list(c.reasons)) for c in slot_candidates["metric"]]
    slot_candidates["y_metric"] = [SlotCandidate("y_metric", c.column, c.score, list(c.reasons)) for c in slot_candidates["metric"]]

    return TableSlotIndex(
        tid=str(tid or ""),
        rows=int(df.shape[0]),
        cols=int(df.shape[1]),
        profiles=profiles,
        slot_candidates=slot_candidates,
    )


def profile_column_runtime(
    series: pd.Series,
    name: str,
    row_count: int,
    semantic_hint: Optional[Mapping[str, Any]] = None,
) -> ColumnRuntimeProfile:
    """为单列构建运行时画像。"""

    col = str(name)
    lowered = col.lower()
    hint = dict(semantic_hint or {})
    declared_format = str(hint.get("data_format") or "").lower()
    semantic_declared = bool(hint.get("declared", False))
    is_primary_key = bool(hint.get("is_primary_key", False))
    is_foreign_key = bool(hint.get("is_foreign_key", False))
    measure_kind = str(hint.get("kind") or "unknown")
    is_additive = hint.get("additive") if "additive" in hint else None
    if measure_kind == "unknown" and _has_any_hint(lowered, CATEGORY_CODE_HINTS):
        measure_kind = "category_code"
        is_additive = False

    non_null = series.dropna()
    non_null_count = int(len(non_null))
    missing_ratio = float(series.isna().mean()) if row_count else 0.0
    unique_count = safe_nunique(non_null, dropna=True) if row_count else 0
    unique_ratio = float(unique_count / max(1, non_null_count)) if non_null_count else 0.0
    dtype = str(series.dtype)

    declared_bool = declared_format == "boolean"
    declared_numeric = declared_format in {"integer", "real"}
    declared_temporal = declared_format in {"date", "datetime"}
    declared_text = declared_format == "text"

    is_bool = declared_bool or bool(is_bool_dtype(series)) or _looks_bool_like(non_null)
    numeric = safe_to_numeric(series)
    numeric_ratio = float(numeric.notna().mean()) if row_count else 0.0
    is_numeric = bool(declared_numeric or is_numeric_dtype(series) or (not declared_text and numeric_ratio >= 0.85))

    dt_parse_ratio = 0.0
    is_datetime = bool(declared_temporal or is_datetime64_any_dtype(series))
    if is_datetime:
        dt_parse_ratio = 1.0
    elif semantic_declared:
        # BIRD declarations are authoritative: declared text/integer/real columns do not
        # become temporal merely because pandas can coerce their values.
        dt_parse_ratio = 0.0
    elif _has_time_hint(lowered) or (not is_numeric and _looks_textual(non_null)):
        # Numeric identifiers/codes (ward, license_no, postal code, unitid, …)
        # can be coerced by pandas into nanosecond timestamps.  Only infer time
        # from numeric values when the column name itself carries a time hint.
        sample = series.head(min(120, len(series)))
        parsed = safe_to_datetime(sample)
        dt_parse_ratio = float(parsed.notna().mean()) if len(sample) else 0.0
        is_datetime = bool(dt_parse_ratio >= 0.80)

    min_value = max_value = mean_value = std_value = None
    numeric_non_null = pd.to_numeric(series, errors="coerce").dropna()
    if len(numeric_non_null):
        min_value = float(numeric_non_null.min())
        max_value = float(numeric_non_null.max())
        mean_value = float(numeric_non_null.mean())
        std_value = float(numeric_non_null.std(ddof=0)) if len(numeric_non_null) > 1 else 0.0

    is_constant = bool(unique_count <= 1)
    is_time_name_like = bool(declared_temporal or _has_time_hint(lowered))
    if is_primary_key or is_foreign_key or bool(hint.get("identifier", False)):
        is_identifier_like = True
    elif semantic_declared and declared_numeric:
        # A declared numeric BIRD measure should not be rejected solely because it is
        # high-cardinality. Strong id-name hints still apply when key metadata is absent.
        is_identifier_like = _has_strong_identifier_name(lowered)
    else:
        is_identifier_like = _is_identifier_like(lowered, unique_ratio, unique_count, row_count, is_numeric, is_datetime)
    is_categorical_like = _is_categorical_like(series, is_bool, is_numeric, is_datetime, unique_count, unique_ratio, row_count)
    if measure_kind in {"text", "boolean", "category_code"} and unique_count <= max(40, int(max(1, row_count) * 0.50)):
        is_categorical_like = True

    examples = [str(item) for item in list(non_null.astype(str).head(5))]
    return ColumnRuntimeProfile(
        name=col,
        dtype=dtype,
        rows=int(row_count),
        non_null_count=non_null_count,
        missing_ratio=missing_ratio,
        unique_count=unique_count,
        unique_ratio=unique_ratio,
        examples=examples,
        is_bool=is_bool,
        is_numeric=is_numeric,
        numeric_ratio=numeric_ratio,
        is_datetime=is_datetime,
        datetime_parse_ratio=dt_parse_ratio,
        is_constant=is_constant,
        is_identifier_like=is_identifier_like,
        is_categorical_like=is_categorical_like,
        is_count_like_name=_has_any_hint(lowered, COUNT_HINTS),
        is_rate_like_name=_has_any_hint(lowered, RATE_HINTS),
        is_time_name_like=is_time_name_like,
        declared_data_format=declared_format,
        semantic_declared=semantic_declared,
        is_primary_key=is_primary_key,
        is_foreign_key=is_foreign_key,
        measure_kind=measure_kind,
        is_additive=is_additive,
        min_value=min_value,
        max_value=max_value,
        mean_value=mean_value,
        std_value=std_value,
    )


# ---------------------------------------------------------------------------
# 槽位候选评分
# ---------------------------------------------------------------------------


def _score_group_candidates(profiles: Mapping[str, ColumnRuntimeProfile]) -> List[SlotCandidate]:
    out: List[SlotCandidate] = []
    for name, profile in profiles.items():
        score, reasons = _score_group(profile)
        if score >= MIN_GROUP_SCORE:
            out.append(SlotCandidate("group", name, score, reasons))
    out.sort(key=lambda item: (-item.score, item.column))
    return out[:MAX_SLOT_CANDIDATES]


def _score_metric_candidates(profiles: Mapping[str, ColumnRuntimeProfile]) -> List[SlotCandidate]:
    out: List[SlotCandidate] = []
    for name, profile in profiles.items():
        score, reasons = _score_metric(profile)
        if score >= MIN_METRIC_SCORE:
            out.append(SlotCandidate("metric", name, score, reasons))
    out.sort(key=lambda item: (-item.score, item.column))
    return out[:MAX_SLOT_CANDIDATES]


def _score_time_candidates(profiles: Mapping[str, ColumnRuntimeProfile]) -> List[SlotCandidate]:
    out: List[SlotCandidate] = []
    for name, profile in profiles.items():
        score, reasons = _score_time(profile)
        if score >= MIN_TIME_SCORE:
            out.append(SlotCandidate("time", name, score, reasons))
    out.sort(key=lambda item: (-item.score, item.column))
    return out[:MAX_SLOT_CANDIDATES]


def _score_group(profile: ColumnRuntimeProfile) -> tuple[float, List[str]]:
    """判断列是否适合作为类别/分组槽位。"""

    score = 0.0
    reasons: List[str] = []
    if profile.is_datetime:
        return 0.0, ["datetime_like_column"]
    if profile.is_primary_key:
        return 0.0, ["primary_key_column"]
    if profile.is_identifier_like and not profile.is_foreign_key:
        return 0.0, ["identifier_like_column"]
    if profile.unique_count < 1:
        return 0.0, ["no_distinct_values"]

    if profile.is_categorical_like:
        score += 0.45
        reasons.append("categorical_like_values")
    if profile.is_bool:
        score += 0.20
        reasons.append("boolean_like_values")

    if 2 <= profile.unique_count <= 20:
        score += 0.25
        reasons.append(f"good_cardinality={profile.unique_count}")
    elif 21 <= profile.unique_count <= 40:
        score += 0.12
        reasons.append(f"moderate_cardinality={profile.unique_count}")
    elif profile.unique_count == 1:
        score -= 0.25
        reasons.append("constant_group")
    else:
        score -= 0.25
        reasons.append(f"too_many_categories={profile.unique_count}")

    if profile.missing_ratio <= 0.20:
        score += 0.15
        reasons.append("low_missing_ratio")
    else:
        score -= 0.15
        reasons.append(f"high_missing_ratio={profile.missing_ratio:.2f}")

    if profile.is_numeric and not profile.is_bool and profile.unique_count > 12:
        score -= 0.15
        reasons.append("numeric_high_cardinality_penalty")

    return clip01(score), reasons


def _score_metric(profile: ColumnRuntimeProfile) -> tuple[float, List[str]]:
    """判断列是否适合作为数值指标槽位。"""

    score = 0.0
    reasons: List[str] = []
    if profile.is_datetime:
        return 0.0, ["datetime_like_column"]
    if profile.is_primary_key or profile.is_foreign_key:
        return 0.0, ["key_column"]
    if profile.is_identifier_like:
        return 0.0, ["identifier_like_column"]
    if profile.measure_kind in {"text", "boolean", "category_code", "coordinate"}:
        return 0.0, [f"non_measure_semantics:{profile.measure_kind}"]
    if profile.is_bool:
        return 0.0, ["boolean_like_column"]

    if profile.is_numeric:
        score += 0.50
        reasons.append(f"numeric_values={profile.numeric_ratio:.2f}")
    else:
        return 0.0, ["not_numeric"]

    if not profile.is_constant:
        score += 0.20
        reasons.append("non_constant")
    else:
        score -= 0.30
        reasons.append("constant_metric")

    if profile.missing_ratio <= 0.20:
        score += 0.15
        reasons.append("low_missing_ratio")
    else:
        score -= 0.15
        reasons.append(f"high_missing_ratio={profile.missing_ratio:.2f}")

    if profile.is_count_like_name or profile.is_rate_like_name:
        score += 0.08
        reasons.append("metric_name_hint")
    if profile.unique_count <= 2 and profile.rows > 20:
        score -= 0.10
        reasons.append("very_low_numeric_cardinality")

    return clip01(score), reasons


def _score_time(profile: ColumnRuntimeProfile) -> tuple[float, List[str]]:
    """判断列是否适合作为时间/顺序槽位。"""

    score = 0.0
    reasons: List[str] = []
    if profile.is_identifier_like:
        return 0.0, ["identifier_like_column"]

    if profile.is_datetime:
        score += 0.60
        reasons.append(f"datetime_parse_ratio={profile.datetime_parse_ratio:.2f}")
    elif _looks_like_year_values(profile):
        score += 0.55
        reasons.append("year_like_values")
    else:
        return 0.0, ["not_a_verified_time_column"]

    if profile.is_time_name_like:
        score += 0.15
        reasons.append("time_name_hint")

    if profile.unique_count >= 3:
        score += 0.15
        reasons.append(f"enough_time_points={profile.unique_count}")
    else:
        score -= 0.15
        reasons.append("too_few_time_points")

    if profile.missing_ratio <= 0.30:
        score += 0.10
    else:
        score -= 0.10
        reasons.append(f"high_missing_ratio={profile.missing_ratio:.2f}")

    return clip01(score), reasons


# ---------------------------------------------------------------------------
# 模板绑定
# ---------------------------------------------------------------------------


def bind_templates_to_table(index: TableSlotIndex, templates: Sequence[ViewTemplate]) -> List[TemplateBinding]:
    """把模板绑定到当前表，返回结构可行的候选绑定。"""

    bindings: List[TemplateBinding] = []
    for template in list(templates or []):
        if template.template_id == "count_by_group":
            bindings.extend(_bind_count_by_group(index, template))
        elif template.template_id == "comparison_bar":
            bindings.extend(_bind_group_metric(index, template))
        elif template.template_id == "trend_line":
            bindings.extend(_bind_time_metric(index, template))
        elif template.template_id == "relation_scatter":
            bindings.extend(_bind_relation(index, template))
        elif template.template_id == "distribution_box":
            bindings.extend(_bind_distribution(index, template))
    bindings.sort(key=lambda item: (-item.score, item.template_id, str(item.slots)))
    return bindings


def _bind_count_by_group(index: TableSlotIndex, template: ViewTemplate) -> List[TemplateBinding]:
    out: List[TemplateBinding] = []
    for cand in index.slot_candidates.get("group", [])[:4]:
        profile = index.profiles.get(cand.column)
        if profile and index.rows > 0 and profile.unique_count >= max(2, int(index.rows * 0.80)):
            # 如果一张表已经是一行一个类别，直接再 value_counts 只会得到全 1，
            # 通常不是有效证据。此时应由 comparison_bar 使用已有 metric。
            continue
        score = clip01(0.90 * cand.score + 0.10 * template.prior)
        out.append(_make_binding(template, {"group": cand.column}, {"group": cand.score}, score, cand.reasons))
    return out[:3]


def _bind_group_metric(index: TableSlotIndex, template: ViewTemplate) -> List[TemplateBinding]:
    out: List[TemplateBinding] = []
    groups = index.slot_candidates.get("group", [])[:4]
    metrics = index.slot_candidates.get("metric", [])[:5]
    for group, metric in product(groups, metrics):
        if group.column == metric.column:
            continue
        score = clip01(0.45 * group.score + 0.45 * metric.score + 0.10 * template.prior)
        reasons = [f"group:{r}" for r in group.reasons[:3]] + [f"metric:{r}" for r in metric.reasons[:3]]
        out.append(_make_binding(template, {"group": group.column, "metric": metric.column}, {"group": group.score, "metric": metric.score}, score, reasons))
    out.sort(key=lambda item: (-item.score, item.slots.get("group", ""), item.slots.get("metric", "")))
    return out[:4]


def _bind_time_metric(index: TableSlotIndex, template: ViewTemplate) -> List[TemplateBinding]:
    out: List[TemplateBinding] = []
    times = index.slot_candidates.get("time", [])[:3]
    metrics = index.slot_candidates.get("metric", [])[:4]
    for time_col, metric in product(times, metrics):
        if time_col.column == metric.column:
            continue
        score = clip01(0.50 * time_col.score + 0.40 * metric.score + 0.10 * template.prior)
        reasons = [f"time:{r}" for r in time_col.reasons[:3]] + [f"metric:{r}" for r in metric.reasons[:3]]
        out.append(_make_binding(template, {"time": time_col.column, "metric": metric.column}, {"time": time_col.score, "metric": metric.score}, score, reasons))
    out.sort(key=lambda item: (-item.score, item.slots.get("time", ""), item.slots.get("metric", "")))
    return out[:4]


def _bind_relation(index: TableSlotIndex, template: ViewTemplate) -> List[TemplateBinding]:
    out: List[TemplateBinding] = []
    metrics = index.slot_candidates.get("metric", [])[:5]
    for left, right in combinations(metrics, 2):
        left_profile = index.profiles.get(left.column)
        right_profile = index.profiles.get(right.column)
        if not left_profile or not right_profile:
            continue
        if left_profile.unique_count < 3 or right_profile.unique_count < 3:
            continue
        if left_profile.measure_kind == "category_code" or right_profile.measure_kind == "category_code":
            continue
        if _ambiguous_join_suffix_pair(left.column, right.column):
            continue
        score = clip01(0.45 * left.score + 0.45 * right.score + 0.10 * template.prior)
        reasons = [f"x_metric:{r}" for r in left.reasons[:2]] + [f"y_metric:{r}" for r in right.reasons[:2]]
        out.append(_make_binding(template, {"x_metric": left.column, "y_metric": right.column}, {"x_metric": left.score, "y_metric": right.score}, score, reasons))
    out.sort(key=lambda item: (-item.score, item.slots.get("x_metric", ""), item.slots.get("y_metric", "")))
    return out[:3]


def _bind_distribution(index: TableSlotIndex, template: ViewTemplate) -> List[TemplateBinding]:
    """绑定分组分布模板。

    boxplot 需要每个 group 至少有一定重复观测，否则只有一行一个组时，
    它与普通 comparison_bar 重复且没有分布意义。这里先用 profile 的 rows
    和 group unique_count 做轻量判断，真正执行后 filter/L2 还会再检查。
    """

    out: List[TemplateBinding] = []
    groups = index.slot_candidates.get("group", [])[:4]
    metrics = index.slot_candidates.get("metric", [])[:4]
    for group, metric in product(groups, metrics):
        if group.column == metric.column:
            continue
        group_profile = index.profiles.get(group.column)
        metric_profile = index.profiles.get(metric.column)
        if not group_profile or group_profile.unique_count <= 0 or not metric_profile:
            continue
        if metric_profile.measure_kind in {"category_code", "identifier", "boolean", "coordinate"}:
            continue
        if metric_profile.unique_count < 4:
            continue
        avg_rows_per_group = index.rows / max(1, group_profile.unique_count)
        if avg_rows_per_group < 2.0:
            continue
        score = clip01(0.40 * group.score + 0.45 * metric.score + 0.10 * min(avg_rows_per_group / 8.0, 1.0) + 0.05 * template.prior)
        reasons = [f"avg_rows_per_group={avg_rows_per_group:.1f}"] + [f"group:{r}" for r in group.reasons[:2]] + [f"metric:{r}" for r in metric.reasons[:2]]
        out.append(_make_binding(template, {"group": group.column, "metric": metric.column}, {"group": group.score, "metric": metric.score}, score, reasons))
    out.sort(key=lambda item: (-item.score, item.slots.get("group", ""), item.slots.get("metric", "")))
    return out[:3]


def _make_binding(
    template: ViewTemplate,
    slots: Dict[str, str],
    slot_scores: Dict[str, float],
    score: float,
    reasons: List[str],
) -> TemplateBinding:
    return TemplateBinding(
        template_id=template.template_id,
        view_family=template.view_family,
        chart_type=template.chart_type,
        pattern=template.pattern,
        slots=dict(slots),
        score=float(clip01(score)),
        slot_scores={k: float(clip01(v)) for k, v in dict(slot_scores).items()},
        reasons=list(reasons or []),
        supported_tendencies=list(template.supported_tendencies),
        template_prior=float(template.prior),
    )


# ---------------------------------------------------------------------------
# 辅助判断
# ---------------------------------------------------------------------------


def _has_any_hint(lowered_name: str, hints: set[str]) -> bool:
    tokens = _name_tokens(lowered_name)
    return bool(tokens & hints or any(h in lowered_name for h in hints if len(h) >= 3))


def _has_time_hint(lowered_name: str) -> bool:
    return _has_any_hint(lowered_name, TIME_HINTS)


def _name_tokens(lowered_name: str) -> set[str]:
    raw = lowered_name.replace("-", "_").replace(".", "_").replace("/", "_")
    return {part for part in raw.split("_") if part}


def _looks_textual(non_null: pd.Series) -> bool:
    if len(non_null) == 0:
        return False
    return bool(non_null.astype(str).map(len).mean() >= 2)


def _looks_bool_like(non_null: pd.Series) -> bool:
    if len(non_null) == 0:
        return False
    safe_values = safe_hashable_series(non_null)
    values = {str(v).strip().lower() for v in safe_values.unique().tolist()}
    return len(values) <= 2 and values <= {"0", "1", "true", "false", "yes", "no", "y", "n"}



def _has_strong_identifier_name(lowered_name: str) -> bool:
    tokens = _name_tokens(lowered_name)
    normalized = "".join(ch for ch in lowered_name if ch.isalnum())
    return bool(
        tokens & {"id", "uuid", "guid", "key"}
        or lowered_name.endswith("_id")
        or lowered_name.endswith("_key")
        or normalized in STRONG_IDENTIFIER_NAMES
        or ("license" in tokens and bool(tokens & {"no", "number", "id"}))
    )

def _is_identifier_like(
    lowered_name: str,
    unique_ratio: float,
    unique_count: int,
    row_count: int,
    is_numeric: bool,
    is_datetime: bool,
) -> bool:
    if is_datetime or row_count <= 0:
        return False
    tokens = _name_tokens(lowered_name)
    if _has_strong_identifier_name(lowered_name):
        return True
    if tokens & ID_HINTS:
        return True
    if unique_count >= max(20, int(row_count * 0.90)) and unique_ratio >= 0.90:
        return True
    # 高基数数值列经常是编号或索引，不直接当 metric。
    if is_numeric and row_count >= 20 and unique_ratio >= 0.98:
        return True
    return False


def _is_categorical_like(
    series: pd.Series,
    is_bool: bool,
    is_numeric: bool,
    is_datetime: bool,
    unique_count: int,
    unique_ratio: float,
    row_count: int,
) -> bool:
    if is_datetime or row_count <= 0:
        return False
    if is_bool:
        return True
    if unique_count <= 0:
        return False
    if not is_numeric:
        return unique_count <= max(40, int(row_count * 0.50))
    return 2 <= unique_count <= min(20, max(2, int(row_count * 0.20))) and unique_ratio <= 0.35


def _ambiguous_join_suffix_pair(left: str, right: str) -> bool:
    """Reject correlation between duplicate join columns such as fine_x/fine_y."""
    def base(value: str) -> str:
        text = str(value or "").lower()
        return text[:-2] if text.endswith(("_x", "_y")) else text

    left_text = str(left or "").lower()
    right_text = str(right or "").lower()
    return bool(
        left_text != right_text
        and left_text.endswith(("_x", "_y"))
        and right_text.endswith(("_x", "_y"))
        and base(left_text) == base(right_text)
    )


def _looks_like_year_values(profile: ColumnRuntimeProfile) -> bool:
    if not profile.is_numeric or profile.min_value is None or profile.max_value is None:
        return False
    if not profile.is_time_name_like:
        return False
    if profile.unique_count < 3:
        return False
    return bool(1800 <= profile.min_value <= 2200 and 1800 <= profile.max_value <= 2200)
