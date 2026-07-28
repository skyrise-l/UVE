"""analysis_tendency.py
----------------------
Query-analysis tendency normalization.

``analysis_tendency`` is an auxiliary preference signal.  It may influence ranking
between otherwise valid visual plans, but it must never authorize or reject a plan,
change a hard gate threshold, or substitute for runtime evidence.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Mapping, Sequence

from vis_project_utils.utils import clip01


ANALYSIS_TENDENCY_TYPES = [
    "overview",
    "group_difference",
    "ranking_or_extreme",
    "trend_or_change",
    "distribution_shape",
    "relationship_or_association",
    "composition_or_proportion",
    "anomaly_or_outlier",
    "factor_explanation",
    "process_explanation",
    "data_quality_check",
]

_ALLOWED_TYPES = set(ANALYSIS_TENDENCY_TYPES)


ANALYSIS_TENDENCY_GUIDE = {
    "overview": "Overall overview, summary, or basic situation.",
    "group_difference": "Differences between groups, categories, cohorts, or conditions.",
    "ranking_or_extreme": "Highest, lowest, most, least, top-k, or extreme objects.",
    "trend_or_change": "Changes over time, stages, or an explicitly ordered sequence.",
    "distribution_shape": (
        "Shape, center, spread, skewness, quantiles, or dispersion of a numeric variable. "
        "Do not use this label merely because category counts are described as a distribution."
    ),
    "relationship_or_association": "Relationship, correlation, or association between variables.",
    "composition_or_proportion": "Composition, proportion, percentage, share, or part-to-whole structure.",
    "anomaly_or_outlier": "Anomalies, outliers, sudden spikes or drops, or unusual observations.",
    "factor_explanation": "Causes, influencing factors, drivers, or contributing factors.",
    "process_explanation": "Analysis process, calculation chain, or method steps.",
    "data_quality_check": "Missing values, duplicates, format anomalies, or data quality.",
}

_CATEGORICAL_CUES = (
    "by", "across", "between", "each", "different", "category", "categories",
    "group", "groups", "segment", "segments", "region", "regions", "type", "types",
    "status", "state", "states", "priority", "priorities", "department", "departments",
    "location", "locations", "assignee", "assignees", "personnel",
    "按", "各", "不同", "类别", "类型", "分组", "群组", "地区", "区域", "部门", "群体",
    "状态", "优先级", "人员", "负责人",
)
_COUNT_CUES = (
    "count", "counts", "number of", "frequency", "frequencies", "数量", "个数", "频数", "次数",
)
_COMPOSITION_CUES = (
    "share", "shares", "percentage contribution", "percent of", "percentage of",
    "proportion", "ratio", "composition",
    "占比", "比例", "百分比", "构成", "份额",
)
_RANKING_CUES = (
    "top", "bottom", "highest", "lowest", "most", "least", "rank", "ranking",
    "前", "最高", "最低", "最多", "最少", "排名", "排序",
)
_NUMERIC_DISTRIBUTION_CUES = (
    "histogram", "boxplot", "box plot", "quantile", "quartile", "median", "variance",
    "standard deviation", "spread", "dispersion", "skew",
    "直方图", "箱线图", "分位数", "四分位", "中位数", "方差", "标准差", "离散", "偏度",
)
_NUMERIC_MEASURE_CUES = (
    "percent", "percentage", "amount", "duration", "time", "times", "date", "dates",
    "processing time", "processing times", "resolution time", "resolution times",
    "response time", "response times", "time lag", "time lags", "time interval", "time intervals",
    "days", "hours", "rate", "score", "cost", "revenue", "completion", "target",
    "interval", "intervals", "lag", "lags", "age", "salary", "price", "quantity",
    "金额", "时长", "处理时间", "响应时间", "解决时间", "天数", "小时", "比率",
    "得分", "成本", "收入", "完成率", "目标值", "年龄", "价格",
)


def normalize_analysis_tendency(
    raw_items: Any,
    *,
    question_text: str = "",
) -> List[Dict[str, Any]]:
    """Normalize model output into a stable auxiliary preference list.

    The normalizer also repairs one common ambiguity: models often label categorical
    count/share comparisons as ``distribution_shape``.  When the question clearly
    concerns categories rather than the numeric distribution of a variable, that label
    is converted into the more precise comparison/composition/ranking preferences.

    No normalized item is ever a hard gate.  Empty or low-confidence output falls back
    to a weak ``overview`` preference.
    """

    if isinstance(raw_items, Mapping):
        raw_items = raw_items.get("items") or raw_items.get("analysis_tendency") or []
    if not isinstance(raw_items, list):
        raw_items = []

    normalized: List[Dict[str, Any]] = []
    seen = set()
    for raw in raw_items:
        if not isinstance(raw, Mapping):
            continue
        item_type = str(raw.get("type") or "").strip()
        if item_type not in _ALLOWED_TYPES or item_type in seen:
            continue
        strength = clip01(raw.get("strength", 0.0))
        if strength < 0.20:
            continue
        reason = str(raw.get("reason") or "").strip()
        normalized.append({"type": item_type, "strength": strength, "reason": reason})
        seen.add(item_type)
        if len(normalized) >= 3:
            break

    normalized = _repair_categorical_distribution_ambiguity(normalized, question_text)
    normalized = _dedupe_and_limit(normalized, limit=3)
    if normalized:
        return normalized

    return [{
        "type": "overview",
        "strength": 0.35,
        "reason": "No reliable analysis tendency was supplied; use only a weak overview preference.",
    }]


def tendency_strength_map(items: Sequence[Mapping[str, Any]]) -> Dict[str, float]:
    """Convert a tendency list into ``{type: strength}``."""

    out: Dict[str, float] = {}
    for item in list(items or []):
        item_type = str((item or {}).get("type") or "")
        if item_type not in _ALLOWED_TYPES:
            continue
        out[item_type] = max(out.get(item_type, 0.0), clip01((item or {}).get("strength", 0.0)))
    return out


def _repair_categorical_distribution_ambiguity(
    items: Sequence[Mapping[str, Any]],
    question_text: str,
) -> List[Dict[str, Any]]:
    text = _normalized_text(question_text)
    if not text or not any(str(item.get("type") or "") == "distribution_shape" for item in items):
        return [dict(item) for item in items]

    categorical = _contains_any(text, _CATEGORICAL_CUES)
    numeric_distribution = _contains_any(text, _NUMERIC_DISTRIBUTION_CUES)
    count_like = _contains_any(text, _COUNT_CUES)
    composition_like = _contains_any(text, _COMPOSITION_CUES)
    ranking_like = _contains_any(text, _RANKING_CUES)
    numeric_measure = _contains_any(text, _NUMERIC_MEASURE_CUES)
    explicit_categorical_summary = bool(
        count_like or composition_like or (ranking_like and not numeric_measure)
    )
    implicit_categorical_summary = bool(categorical and not numeric_measure)
    if (
        not categorical
        or numeric_distribution
        or not (explicit_categorical_summary or implicit_categorical_summary)
    ):
        return [dict(item) for item in items]

    output: List[Dict[str, Any]] = []
    distribution_strength = 0.0
    for item in items:
        if str(item.get("type") or "") == "distribution_shape":
            distribution_strength = max(distribution_strength, clip01(item.get("strength", 0.0)))
        else:
            output.append(dict(item))

    base = max(0.45, distribution_strength)
    if count_like or implicit_categorical_summary:
        output.append({
            "type": "group_difference",
            "strength": base,
            "reason": "Normalized from ambiguous categorical distribution wording.",
        })
    if composition_like:
        output.append({
            "type": "composition_or_proportion",
            "strength": base,
            "reason": "Normalized from categorical share/proportion wording.",
        })
    if ranking_like:
        output.append({
            "type": "ranking_or_extreme",
            "strength": base,
            "reason": "Normalized from top/bottom or extreme-category wording.",
        })
    return output


def _dedupe_and_limit(items: Sequence[Mapping[str, Any]], *, limit: int) -> List[Dict[str, Any]]:
    best: Dict[str, Dict[str, Any]] = {}
    order: List[str] = []
    for item in items:
        key = str(item.get("type") or "")
        if key not in _ALLOWED_TYPES:
            continue
        candidate = {
            "type": key,
            "strength": clip01(item.get("strength", 0.0)),
            "reason": str(item.get("reason") or "").strip(),
        }
        if key not in best:
            best[key] = candidate
            order.append(key)
        elif candidate["strength"] > best[key]["strength"]:
            best[key] = candidate
    ranked = sorted((best[key] for key in order), key=lambda item: -float(item["strength"]))
    return ranked[: max(1, int(limit))]


def _normalized_text(value: str) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def _contains_any(text: str, cues: Sequence[str]) -> bool:
    """Match semantic cues without accidental English substring hits.

    QEP tendency repair is intentionally conservative.  In particular, an English
    cue such as ``by`` must not match inside an unrelated token such as ``standby``.
    Chinese cues keep substring matching because word boundaries are not represented
    by spaces in the same way.
    """

    normalized = re.sub(r"[_-]+", " ", str(text or "").lower())
    for raw_cue in cues:
        cue = str(raw_cue or "").strip().lower()
        if not cue:
            continue
        if re.search(r"[\u4e00-\u9fff]", cue):
            if cue in normalized:
                return True
            continue
        pattern = rf"(?<![a-z0-9_]){re.escape(cue)}(?![a-z0-9_])"
        if re.search(pattern, normalized):
            return True
    return False
