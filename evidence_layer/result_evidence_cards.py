"""result_evidence_cards.py
--------------------------
把 ``stage_result`` 中的表格/文本结果压缩成少量英文证据卡。

设计原则：
1. 只生成能直接帮助当前 answer/insight 的短卡，不保存复杂中间结构；
2. 先识别结果模式，再生成卡片，避免把 grouped distribution 错压成 trend；
3. 进入 LLM prompt 的卡片统一使用英文，避免和英文 InsightBench gold/evaluator 混杂。
"""

from __future__ import annotations

import math
import re
import warnings
from collections import Counter
from typing import Any, Iterable, List, Mapping, Optional, Sequence, Tuple

import pandas as pd
from pandas.api.types import is_bool_dtype, is_datetime64_any_dtype, is_numeric_dtype

from evidence_layer.visual_semantics import build_task_column_semantics, infer_column_semantics
from vis_project_utils.utils import safe_to_numeric

MAX_RESULT_CARDS = 2
MAX_FACTS_PER_CARD = 3

TEXT_COLUMN_HINTS = (
    "description", "desc", "comment", "comments", "reason", "cause", "root",
    "summary", "detail", "details", "resolution", "action", "title", "keyword", "term",
)
TIME_COLUMN_HINTS = (
    "date", "time", "opened", "closed", "created", "updated", "resolved", "start", "end", "month", "year",
)
GROUP_COLUMN_HINTS = (
    "category", "type", "state", "status", "priority", "location", "country", "city",
    "department", "group", "agent", "assigned", "user", "manager", "model", "vendor", "asset", "printer",
)
INTERNAL_RESULT_COLUMNS = {
    "_section", "stat_name", "result_type", "summary_type", "record_type",
}

STOPWORDS = {
    "the", "and", "for", "with", "from", "that", "this", "there", "was", "were", "are",
    "has", "have", "had", "not", "but", "issue", "issues", "problem", "problems", "error",
    "none", "null", "nan", "unknown", "please", "need", "needs", "using", "into", "about",
    "before", "after", "would", "could", "should", "when", "where", "what", "which", "while",
}


def build_result_evidence_cards(
    value: Any,
    *,
    evidence_profile: Optional[Mapping[str, Any]] = None,
    task: Any = None,
    max_cards: int = MAX_RESULT_CARDS,
) -> str:
    """从结果值生成短证据卡；不同 section 永不拼接后再聚合。"""
    limit = max(0, int(max_cards or 0))
    if limit <= 0:
        return ""

    sections = _coerce_to_sections(value)
    if not sections:
        return ""

    question = str((evidence_profile or {}).get("round_question") or "").strip()
    anchor_text = _anchor_text(task, evidence_profile)
    column_semantics = build_task_column_semantics(task)

    # BIRD evaluation rewards concrete quantitative findings.  Preserve the original
    # InsightBench ordering, but let BIRD consume grouped/numeric evidence before a text
    # keyword card can occupy the small card budget.
    if _is_bird_task(task):
        builders = [
            _build_grouped_distribution_card,
            _build_group_metric_card,
            _build_trend_card,
            _build_text_keyword_card,
        ]
    else:
        builders = [
            _build_text_keyword_card,
            _build_grouped_distribution_card,
            _build_group_metric_card,
            _build_trend_card,
        ]
    cards: List[str] = []
    seen = set()
    # Preserve the existing builder priority, while keeping each section independent.
    for builder in builders:
        for section_name, dataframe in sections:
            try:
                card = builder(
                    dataframe,
                    question=question,
                    anchor_text=anchor_text,
                    column_semantics=column_semantics,
                )
            except Exception:
                card = ""
            if card and section_name:
                card = _label_section_card(card, section_name)
            key = _dedupe_key(card)
            if card and key and key not in seen:
                cards.append(card)
                seen.add(key)
            if len(cards) >= limit:
                return "\n\n".join(cards[:limit])
    return "\n\n".join(cards[:limit])


def _build_text_keyword_card(
    dataframe: pd.DataFrame, *, question: str, anchor_text: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    """从文本列抽取高频业务词。"""
    text_col = _best_text_column(dataframe, anchor_text, column_semantics=column_semantics)
    if not text_col:
        return ""
    tokens = _top_text_tokens(dataframe[text_col])
    if not tokens:
        return ""

    group_col = _best_group_column(
        dataframe, exclude={text_col}, anchor_text=anchor_text,
        column_semantics=column_semantics,
    )
    token_text = ", ".join(f"{token}({count})" for token, count in tokens[:5])
    facts = [f"The most frequent terms or values in {text_col} are {token_text}."]
    if group_col and group_col in dataframe.columns:
        dominant = _top_group_value(dataframe, group_col)
        if dominant:
            facts.append(f"These text signals can be interpreted together with the dominant {group_col} value: {dominant}.")
    candidate_terms = ", ".join(token for token, _ in tokens[:3])
    candidate = f"The result text is concentrated around recurring terms or entities such as {candidate_terms}."
    return _format_card(
        title="Result Text Evidence",
        setup=f"analyze text column {text_col}" + (f" with group {group_col}" if group_col else ""),
        facts=facts,
        candidate=candidate,
    )


def _build_grouped_distribution_card(
    dataframe: pd.DataFrame, *, question: str, anchor_text: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    """为二级分组表生成 grouped distribution 卡片。

    典型输入是 category × priority × count/share 之类的表。该卡避免把结果压成
    全局 priority count，也避免把 share 误当成 trend。
    """
    metric_col = _best_numeric_column(
        dataframe, prefer_count=True, column_semantics=column_semantics,
    )
    if not metric_col:
        return ""
    group_cols = _candidate_group_columns(
        dataframe, anchor_text=anchor_text, exclude={metric_col},
        column_semantics=column_semantics,
    )
    if len(group_cols) < 2:
        return ""

    outer_col, inner_col = group_cols[0], group_cols[1]
    if dataframe[outer_col].nunique(dropna=True) < 2 or dataframe[inner_col].nunique(dropna=True) < 2:
        return ""
    work = dataframe[[outer_col, inner_col, metric_col]].copy()
    work[metric_col] = safe_to_numeric(work[metric_col])
    work = work.dropna(subset=[outer_col, inner_col, metric_col])
    if work.empty:
        return ""

    aggregation = "sum" if _is_additive_metric(metric_col, column_semantics) else "mean"
    work = (
        work.groupby([outer_col, inner_col], dropna=False, as_index=False)[metric_col]
        .agg(aggregation)
    )
    if work.empty:
        return ""

    top_rows = work.sort_values(metric_col, ascending=False).head(3)
    facts = [
        f"The largest {outer_col} × {inner_col} cell is {fmt(row[outer_col])} / {fmt(row[inner_col])} with {metric_col}={fmt_num(row[metric_col])}."
        for _, row in top_rows.iterrows()
    ]
    # 如果表里每个 outer group 都有内部 top 类别，补一个 within-group 事实。
    within_parts: List[str] = []
    for outer_value, group in work.groupby(outer_col, dropna=False):
        ordered = group.sort_values(metric_col, ascending=False).reset_index(drop=True)
        top = ordered.iloc[0]
        tied = ordered[metric_col].sub(float(top[metric_col])).abs().le(1e-9)
        tied_names = [fmt(value) for value in ordered.loc[tied, inner_col].tolist()]
        if len(tied_names) > 1:
            within_parts.append(
                f"{fmt(outer_value)}→tie({', '.join(tied_names[:3])}; {fmt_num(top[metric_col])})"
            )
        else:
            within_parts.append(f"{fmt(outer_value)}→{fmt(top[inner_col])}({fmt_num(top[metric_col])})")
        if len(within_parts) >= 4:
            break
    if within_parts:
        facts.append("Within-group leaders: " + ", ".join(within_parts) + ".")

    numeric_values = safe_to_numeric(work[metric_col]).dropna()
    if not numeric_values.empty and float(numeric_values.max() - numeric_values.min()) <= 1e-9:
        candidate = (
            f"The {metric_col} values are uniform across the observed {outer_col} × {inner_col} cells."
        )
    else:
        candidate = (
            f"The result is a grouped distribution: {metric_col} differs across both {outer_col} and {inner_col}, "
            f"so the key evidence should be interpreted within each {outer_col} group rather than collapsed globally."
        )
    return _format_card(
        title="Grouped Distribution Evidence",
        setup=f"compare {metric_col} across {outer_col} and {inner_col}",
        facts=facts,
        candidate=candidate,
    )


def _build_group_metric_card(
    dataframe: pd.DataFrame, *, question: str, anchor_text: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    """生成单维分组/指标对比卡。"""
    group_col = _best_group_column(
        dataframe, exclude=set(), anchor_text=anchor_text,
        column_semantics=column_semantics,
    )
    metric_col = _best_numeric_column(
        dataframe, prefer_count=True, column_semantics=column_semantics,
    )
    if not group_col or not metric_col or group_col == metric_col:
        return ""

    work = dataframe[[group_col, metric_col]].copy()
    work[metric_col] = safe_to_numeric(work[metric_col])
    work = work.dropna(subset=[group_col, metric_col])
    if work.empty:
        return ""

    additive = _is_additive_metric(metric_col, column_semantics)
    aggregation = "sum" if additive else "mean"
    work = work.groupby(group_col, dropna=False, as_index=False)[metric_col].agg(aggregation)
    work = work.sort_values(metric_col, ascending=False).reset_index(drop=True)
    if len(work) < 2:
        return ""

    top = work.iloc[0]
    bottom = work.iloc[-1]
    values = [safe_number(v) for v in work[metric_col]]
    if any(v is None for v in values):
        return ""
    numeric_values = [float(v) for v in values if v is not None]
    gap = float(top[metric_col]) - float(bottom[metric_col])
    facts: List[str] = []

    if abs(gap) <= 1e-9:
        facts.append(f"All {len(work)} {group_col} groups have the same {metric_col}, so the distribution is uniform.")
        candidate = f"The {metric_col} values are balanced across {group_col}, with no dominant group."
    else:
        facts.append(f"{fmt(top[group_col])} has the highest {metric_col}: {fmt_num(top[metric_col])}.")
        second = work.iloc[1]
        facts.append(f"The second-highest group is {fmt(second[group_col])} with {metric_col}={fmt_num(second[metric_col])}.")
        dominant_share = _dominant_share(numeric_values) if additive else None
        if dominant_share is not None:
            candidate = (
                f"{fmt(top[group_col])} is the dominant {group_col} group, with "
                f"{metric_col}={fmt_num(top[metric_col])} "
                f"({fmt_num(dominant_share * 100.0)}% of the shown total)."
            )
        else:
            candidate = (
                f"{fmt(top[group_col])} has the highest {metric_col}: "
                f"{fmt_num(top[metric_col])}, compared with "
                f"{fmt_num(bottom[metric_col])} for {fmt(bottom[group_col])}."
            )

    return _format_card(
        title="Result Comparison Evidence",
        setup=f"compare {metric_col} by {group_col}",
        facts=facts,
        candidate=candidate,
    )


def _build_trend_card(
    dataframe: pd.DataFrame, *, question: str, anchor_text: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    """仅在结果包含真实时间列时生成趋势卡。"""
    time_col = _best_time_column(dataframe, column_semantics=column_semantics)
    metric_col = _best_numeric_column(
        dataframe, prefer_count=True, column_semantics=column_semantics,
    )
    if not time_col or not metric_col or time_col == metric_col:
        return ""

    work = dataframe[[time_col, metric_col]].copy()
    work[metric_col] = safe_to_numeric(work[metric_col])
    parsed_time = _safe_parse_datetime(work[time_col])
    # 没有可解析时间时，不生成 trend；避免把 share/rank 等普通数值误判为趋势轴。
    if not parsed_time.notna().any():
        return ""
    work = work.assign(_sort_time=parsed_time).dropna(subset=[metric_col, "_sort_time"])
    aggregation = "sum" if _is_additive_metric(metric_col, column_semantics) else "mean"
    work = (
        work.groupby("_sort_time", as_index=False)[metric_col]
        .agg(aggregation)
        .sort_values("_sort_time")
    )
    if len(work) < 2:
        return ""

    start = float(work.iloc[0][metric_col])
    end = float(work.iloc[-1][metric_col])
    delta = end - start
    pct = _relative_change(start, end)
    values = [float(value) for value in work[metric_col].tolist()]
    direction_changes = _direction_changes(values)
    spread = max(values) - min(values) if values else 0.0
    if abs(delta) <= 1e-9 or (pct is not None and abs(pct) <= 0.05):
        if direction_changes > 0 and spread > max(1e-9, abs(start) * 0.10):
            candidate = (
                f"{metric_col} ends near its starting level over {time_col}, "
                f"but fluctuates within the period rather than remaining stable."
            )
        else:
            candidate = f"{metric_col} is stable over {time_col}, with no clear net change."
        facts = [f"The first value is {fmt_num(start)} and the last value is {fmt_num(end)}."]
    else:
        direction = "higher" if delta > 0 else "lower"
        if direction_changes > 0:
            candidate = (
                f"{metric_col} ends {direction} over {time_col}, moving from "
                f"{fmt_num(start)} to {fmt_num(end)}, with fluctuations along the way."
            )
        else:
            verb = "increases" if delta > 0 else "decreases"
            candidate = f"{metric_col} {verb} over {time_col}, moving from {fmt_num(start)} to {fmt_num(end)}."
        facts = [f"The first value is {fmt_num(start)} and the last value is {fmt_num(end)}."]
        if pct is not None:
            facts.append(f"The relative change is about {fmt_num(abs(pct) * 100.0)}%.")

    return _format_card(
        title="Result Trend Evidence",
        setup=f"track {metric_col} over {time_col}",
        facts=facts,
        candidate=candidate,
    )


def _format_card(*, title: str, setup: str, facts: Sequence[str], candidate: str) -> str:
    """把三段式信息组织为短卡片。"""
    lines = [f"[{title}]", f"Setup: {setup}."]
    clean_facts = [_clean_sentence(fact) for fact in list(facts or []) if _clean_sentence(fact)]
    if clean_facts:
        lines.append("Key facts:")
        lines.extend(f"- {fact}" for fact in clean_facts[:MAX_FACTS_PER_CARD])
    if candidate:
        lines.append(f"Candidate local finding: {_clean_sentence(candidate)}")
    return "\n".join(lines)


def _is_bird_task(task: Any) -> bool:
    metadata = dict(getattr(task, "metadata", {}) or {}) if task is not None else {}
    return str(metadata.get("benchmark") or "").lower() == "bird"


def _direction_changes(values: Sequence[float]) -> int:
    signs: List[int] = []
    for left, right in zip(values, values[1:]):
        diff = float(right) - float(left)
        if abs(diff) <= 1e-12:
            continue
        signs.append(1 if diff > 0 else -1)
    return sum(1 for left, right in zip(signs, signs[1:]) if left != right)


def _coerce_to_sections(value: Any, section_name: str = "") -> List[Tuple[str, pd.DataFrame]]:
    """Convert stage_result values into independent dataframes without cross-section concat."""
    if isinstance(value, pd.DataFrame):
        return [(section_name, value.copy())] if not value.empty else []
    if isinstance(value, pd.Series):
        name = value.name if value.name is not None else "value"
        frame = value.to_frame(name=str(name)).reset_index()
        return [(section_name, frame)] if not frame.empty else []
    if isinstance(value, list) and value and all(isinstance(item, dict) for item in value):
        nested: List[Tuple[str, pd.DataFrame]] = []
        for index, item in enumerate(value):
            label = str(item.get("name") or item.get("section") or f"item_{index + 1}")
            child_value = item.get("value") if "value" in item else None
            if isinstance(child_value, (pd.DataFrame, pd.Series, dict, list, tuple)):
                nested.extend(_coerce_to_sections(child_value, label))
        if nested:
            return nested
        try:
            df = pd.DataFrame(value)
        except Exception:
            return []
        return [(section_name, df)] if not df.empty and not _contains_nested_cells(df) else []
    if isinstance(value, dict) and value:
        rows = _dict_list_like_to_dataframe(value)
        if rows is not None and not _contains_nested_cells(rows):
            return [(section_name, rows)]
        sections: List[Tuple[str, pd.DataFrame]] = []
        for key, item in value.items():
            sections.extend(_coerce_to_sections(item, str(key)))
        return sections
    return []


def _coerce_to_dataframe(value: Any) -> Optional[pd.DataFrame]:
    """Return a dataframe only when ``value`` contains one result section."""
    sections = _coerce_to_sections(value)
    return sections[0][1] if len(sections) == 1 else None


def _contains_nested_cells(dataframe: pd.DataFrame) -> bool:
    for column in dataframe.columns:
        for value in dataframe[column].head(50).tolist():
            if isinstance(value, (pd.DataFrame, pd.Series, dict, list, tuple, set)):
                return True
    return False


def _dict_list_like_to_dataframe(value: Mapping[str, Any]) -> Optional[pd.DataFrame]:
    sequence_values = []
    for item in value.values():
        if isinstance(item, (list, tuple, pd.Series)):
            sequence_values.append(item)
        else:
            return None
    lengths = {len(item) for item in sequence_values}
    if len(lengths) != 1 or not lengths or next(iter(lengths)) == 0:
        return None
    try:
        df = pd.DataFrame(value)
    except Exception:
        return None
    return df if not df.empty else None


def _contains_unhashable(series: pd.Series) -> bool:
    for value in series.dropna().head(100).tolist():
        if isinstance(value, (dict, list, set, tuple)):
            return True
        try:
            hash(value)
        except Exception:
            return True
    return False


def _best_text_column(
    dataframe: pd.DataFrame, anchor_text: str, *,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    candidates: List[Tuple[float, str]] = []
    anchors = _tokens(anchor_text)
    for col in dataframe.columns:
        name = str(col)
        series = dataframe[col]
        semantic = _column_semantic(name, column_semantics)
        if name.strip().lower() in INTERNAL_RESULT_COLUMNS or semantic.get("identifier"):
            continue
        if is_numeric_dtype(series):
            continue
        values = [str(v).strip() for v in series.dropna().head(80).tolist() if str(v).strip()]
        if not values:
            continue
        avg_len = sum(len(v) for v in values) / max(1, len(values))
        name_l = name.lower()
        hint = 1.0 if any(h in name_l for h in TEXT_COLUMN_HINTS) else 0.0
        anchor = 0.35 if any(tok in name_l for tok in anchors) else 0.0
        length = 0.35 if avg_len >= 12 else 0.10
        candidates.append((hint + anchor + length, name))
    candidates.sort(reverse=True)
    return candidates[0][1] if candidates and candidates[0][0] >= 0.45 else ""


def _candidate_group_columns(
    dataframe: pd.DataFrame, *, anchor_text: str, exclude: Iterable[str],
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> List[str]:
    excluded = {str(c) for c in exclude}
    anchors = _tokens(anchor_text)
    rows = max(1, len(dataframe))
    candidates: List[Tuple[float, str]] = []
    for col in dataframe.columns:
        name = str(col)
        series = dataframe[col]
        semantic = _column_semantic(name, column_semantics)
        if name in excluded or name.strip().lower() in INTERNAL_RESULT_COLUMNS:
            continue
        name_l = name.lower()
        if any(hint in name_l for hint in TEXT_COLUMN_HINTS):
            # Free-form descriptions/comments are evidence content, not stable grouping
            # dimensions.  Treating them as categories creates one group per sentence
            # and can crowd out the actual business comparison.
            continue
        if semantic.get("is_primary_key"):
            continue
        if is_numeric_dtype(series) and not semantic.get("is_foreign_key"):
            continue
        if _contains_unhashable(series):
            continue
        try:
            nunique = int(series.nunique(dropna=True))
        except Exception:
            continue
        if nunique <= 0 or nunique > max(30, rows * 0.85):
            continue
        hint = 0.6 if any(h in name_l for h in GROUP_COLUMN_HINTS) else 0.25
        anchor = 0.25 if any(tok in name_l for tok in anchors) else 0.0
        cardinality = 0.25 if 2 <= nunique <= 20 else 0.05
        candidates.append((hint + anchor + cardinality, name))
    candidates.sort(reverse=True)
    return [name for _, name in candidates]


def _best_group_column(
    dataframe: pd.DataFrame, *, exclude: Iterable[str], anchor_text: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    cols = _candidate_group_columns(
        dataframe, anchor_text=anchor_text, exclude=exclude,
        column_semantics=column_semantics,
    )
    return cols[0] if cols else ""


def _best_numeric_column(
    dataframe: pd.DataFrame, *, prefer_count: bool,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    candidates: List[Tuple[float, str]] = []
    for col in dataframe.columns:
        name = str(col)
        series = dataframe[col]
        semantic = _column_semantic(name, column_semantics)
        if semantic.get("identifier") or semantic.get("kind") in {"category_code", "coordinate", "text", "boolean"}:
            continue
        if is_bool_dtype(series):
            continue
        numeric = safe_to_numeric(series)
        if is_bool_dtype(numeric):
            continue
        valid = int(numeric.notna().sum())
        if valid == 0:
            continue
        name_l = name.lower()
        hint = 0.0
        if prefer_count and any(k in name_l for k in ["count", "cnt", "number", "total", "frequency", "freq"]):
            hint += 0.45
        if any(k in name_l for k in ["rate", "ratio", "share", "percent", "percentage"]):
            hint += 0.35
        try:
            variation = float(numeric.max() - numeric.min()) if valid else 0.0
        except Exception:
            continue
        candidates.append((hint + (0.25 if variation > 0 else 0.0) + valid / max(1, len(dataframe)) * 0.30, name))
    candidates.sort(reverse=True)
    return candidates[0][1] if candidates else ""


def _best_time_column(
    dataframe: pd.DataFrame, *,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> str:
    candidates: List[Tuple[float, str]] = []
    for col in dataframe.columns:
        name = str(col)
        name_l = name.lower()
        semantic = _column_semantic(name, column_semantics)
        if semantic.get("identifier"):
            continue
        declared_format = str(semantic.get("data_format") or "")
        if semantic.get("declared") and declared_format not in {"date", "datetime"}:
            continue
        if semantic.get("temporal") or is_datetime64_any_dtype(dataframe[col]):
            parsed = _safe_parse_datetime(dataframe[col])
            parse_ratio = float(parsed.notna().mean()) if len(dataframe) else 0.0
            if parse_ratio > 0 and int(parsed.nunique(dropna=True)) >= 2:
                candidates.append((1.0 + parse_ratio, name))
            continue
        name_hint = 0.6 if any(h in name_l for h in TIME_COLUMN_HINTS) else 0.0
        if not name_hint or is_numeric_dtype(dataframe[col]):
            continue
        parsed = _safe_parse_datetime(dataframe[col])
        parse_ratio = float(parsed.notna().mean()) if len(dataframe) else 0.0
        if parse_ratio >= 0.80 and int(parsed.nunique(dropna=True)) >= 2:
            candidates.append((name_hint + parse_ratio, name))
    candidates.sort(reverse=True)
    return candidates[0][1] if candidates else ""


def _safe_parse_datetime(series: pd.Series) -> pd.Series:
    if series is None:
        return pd.Series(dtype="datetime64[ns]")
    try:
        if is_datetime64_any_dtype(series):
            return pd.to_datetime(series, errors="coerce")
        if is_numeric_dtype(series):
            name = str(getattr(series, "name", "") or "").lower()
            if not any(hint in name for hint in TIME_COLUMN_HINTS):
                return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
            values = safe_to_numeric(series)
            valid = values.dropna()
            if valid.empty or valid.between(1800, 2200).mean() < 0.8:
                return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
            return pd.to_datetime(values.astype("Int64").astype(str), errors="coerce", format="%Y")
    except Exception:
        return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Could not infer format.*", category=UserWarning)
        try:
            return pd.to_datetime(series, errors="coerce", format="mixed")
        except TypeError:
            return pd.to_datetime(series, errors="coerce")
        except Exception:
            return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None))


def _top_text_tokens(series: pd.Series) -> List[Tuple[str, int]]:
    counter: Counter[str] = Counter()
    for value in series.dropna().head(160).tolist():
        for token in _tokens(str(value)):
            if token in STOPWORDS or len(token) <= 2:
                continue
            counter[token] += 1
    return counter.most_common(6)


def _top_group_value(dataframe: pd.DataFrame, column: str) -> str:
    if column not in dataframe.columns:
        return ""
    counts = dataframe[column].dropna().astype(str).value_counts()
    if counts.empty:
        return ""
    return f"{counts.index[0]}({int(counts.iloc[0])})"



def _column_semantic(
    name: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]],
) -> Dict[str, Any]:
    if column_semantics and name in column_semantics:
        return dict(column_semantics[name] or {})
    return infer_column_semantics(str(name))


def _is_additive_metric(
    name: str,
    column_semantics: Optional[Mapping[str, Mapping[str, Any]]],
) -> bool:
    return _column_semantic(name, column_semantics).get("additive") is True


def safe_number(value: Any) -> Optional[float]:
    try:
        if value is None or pd.isna(value):
            return None
    except Exception:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _dominant_share(values: Sequence[float]) -> Optional[float]:
    if len(values) < 2 or any(value < 0 for value in values):
        return None
    total = float(sum(values))
    if total <= 0:
        return None
    ordered = sorted(values, reverse=True)
    if abs(ordered[0] - ordered[1]) <= 1e-9:
        return None
    share = ordered[0] / total
    uniform = 1.0 / len(ordered)
    threshold = max(0.35, uniform + 0.10)
    return share if share >= threshold else None


def _label_section_card(card: str, section_name: str) -> str:
    lines = str(card or "").splitlines()
    if not lines:
        return card
    label = fmt(section_name)
    if lines[0].startswith("[") and lines[0].endswith("]"):
        lines[0] = lines[0][:-1] + f" — {label}]"
    else:
        lines.insert(0, f"[Result section — {label}]")
    return "\n".join(lines)

def _anchor_text(task: Any, evidence_profile: Optional[Mapping[str, Any]]) -> str:
    """构造结果卡与当前问题证据需求的语义锚点。"""
    metadata = dict(getattr(task, "metadata", {}) or {})
    profile = dict(evidence_profile or {})
    focus = profile.get("evidence_focus")
    if isinstance(focus, str):
        focus = [focus]
    parts = [
        metadata.get("goal"),
        metadata.get("role"),
        metadata.get("category"),
        profile.get("round_question"),
        *list(focus or []),
    ]
    return " ".join(str(part or "") for part in parts if str(part or "").strip())


def _tokens(text: str) -> List[str]:
    return [tok.lower() for tok in re.findall(r"[A-Za-z][A-Za-z0-9_\-]{2,}|\d{3,}", str(text or ""))]


def _relative_change(start: float, end: float) -> Optional[float]:
    if abs(start) <= 1e-12:
        return None
    return (end - start) / abs(start)


def _clean_sentence(text: str) -> str:
    cleaned = re.sub(r"\s+", " ", str(text or "")).strip()
    if cleaned and cleaned[-1] not in ".!?":
        cleaned += "."
    return cleaned


def _dedupe_key(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(text or "").lower()).strip()[:220]


def fmt(value: Any) -> str:
    text = str(value)
    return text if len(text) <= 60 else text[:57] + "..."


def fmt_num(value: Any) -> str:
    number = safe_number(value)
    if number is None:
        return fmt(value)
    if math.isfinite(number) and abs(number - round(number)) <= 1e-9:
        return str(int(round(number)))
    return f"{number:.2f}".rstrip("0").rstrip(".")
