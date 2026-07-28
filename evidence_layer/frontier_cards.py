"""frontier_cards.py
-------------------
任务锚定的探索前沿卡片生成器。

本模块不调用 LLM，也不生成图表。它只根据真实表结构、少量列画像和当前
evidence_profile，给 frontier planner 提供下一轮可以审核的候选方向。

设计边界：
1. 只输出短文本卡片，不维护复杂状态；
2. 只使用真实表名/列名，避免 LLM 后续计划落到不存在字段；
3. 允许从 raw/schema 视角提出方向，但必须绑定任务目标、当前问题或真实列；
4. 对文本列做轻量值画像，解决 LLM 只看趋势/数值、忽略文本业务词的问题。
"""

from __future__ import annotations

import re
import warnings
from collections import Counter
from contextlib import contextmanager
from typing import Any, Iterable, List, Mapping, Sequence, Set

import pandas as pd
from pandas.api.types import is_datetime64_any_dtype, is_numeric_dtype

from vis_project_utils.dataframe_safety import compact_value_text, safe_nunique
from evidence_layer.visual_semantics import build_table_column_semantics, infer_column_semantics


TEXT_HINTS = (
    "description", "desc", "comment", "comments", "reason", "cause", "root",
    "rca", "resolution", "method", "summary", "details", "title", "task",
)
TIME_HINTS = (
    "date", "time", "year", "month", "day", "opened", "closed", "created",
    "updated", "processed", "start", "end", "resolved", "purchased", "due",
)
LOCATION_HINTS = (
    "location", "country", "city", "region", "site", "province", "area",
)
ENTITY_HINTS = (
    "id", "number", "no", "user", "assigned", "assignee", "closed_by", "manager",
    "owner", "group", "department", "model", "category", "vendor", "asset", "printer",
)

TEXT_STOPWORDS = {
    "the", "and", "for", "with", "from", "that", "this", "there", "was", "were",
    "are", "has", "have", "had", "not", "but", "you", "your", "our", "their",
    "issue", "issues", "problem", "problems", "error", "unknown", "none", "null",
    "nan", "missing", "please", "need", "needs", "using", "into", "about", "after",
    "before", "been", "will", "would", "could", "should", "when", "where",
}


class FrontierColumnIndex:
    """保存一张表上可用于前沿提示的列分组。"""

    def __init__(
        self,
        table_name: str,
        dataframe: pd.DataFrame,
        anchor_terms: Set[str],
        column_semantics: Mapping[str, Mapping[str, Any]] | None = None,
    ) -> None:
        self.table_name = str(table_name)
        self.dataframe = dataframe if isinstance(dataframe, pd.DataFrame) else pd.DataFrame()
        self.columns = [str(c) for c in self.dataframe.columns]
        self.anchor_terms = set(anchor_terms or set())
        self.column_semantics = {
            str(key): dict(value or {})
            for key, value in dict(column_semantics or {}).items()
        }

        self.text = _prioritize_columns(
            _columns_by_hint(self.columns, TEXT_HINTS),
            ["short_description", "description", "rca", "resolution", "reason", "cause"],
            self.anchor_terms,
        )
        self.time = _prioritize_columns(
            _detect_time_columns(self.dataframe, self.column_semantics),
            ["opened_at", "created", "start", "processed", "updated", "closed", "date", "time"],
            self.anchor_terms,
        )
        self.location = _prioritize_columns(
            _columns_by_hint(self.columns, LOCATION_HINTS),
            ["location", "country", "city", "region", "site"],
            self.anchor_terms,
        )
        self.entity = _prioritize_columns(
            [
                column for column in _columns_by_hint(self.columns, ENTITY_HINTS)
                if _is_useful_entity_column(self.dataframe, column, self.column_semantics)
            ],
            ["number", "id", "user", "assigned", "manager", "group", "department", "model", "vendor", "category"],
            self.anchor_terms,
        )
        self.numeric = _prioritize_columns(
            [
                str(c)
                for c in self.dataframe.columns
                if is_numeric_dtype(self.dataframe[c])
                and _is_valid_frontier_metric(str(c), self.column_semantics)
                and not _is_identifier_like(self.dataframe, str(c), self.column_semantics)
            ],
            ["count", "total", "amount", "score", "duration", "cost", "rate", "ratio"],
            self.anchor_terms,
        )
        self.group = _prioritize_columns(
            _detect_group_columns(self.dataframe, self.column_semantics),
            ["category", "department", "model", "priority", "assignment_group", "group", "state"],
            self.anchor_terms,
        )


def build_frontier_cards(
    *,
    task: Any,
    evidence_profile: Mapping[str, Any] | None,
    max_cards: int = 3,
) -> str:
    """生成给下一轮 planner 使用的 frontier cards。

    输入：当前 task 和当前问题证据画像。
    输出：多张短文本卡片拼成的字符串；没有可用方向时返回空字符串。
    """
    anchor_terms = _task_anchor_terms(task, evidence_profile)

    cards: List[str] = []
    for table in task.all_tables():
        index = FrontierColumnIndex(
            table.name,
            table.dataframe,
            anchor_terms,
            build_table_column_semantics(getattr(table, "metadata", {}) or {}),
        )
        cards.extend(_cards_for_table(index=index))
        if len(cards) >= max_cards:
            break

    return "\n\n".join(cards[:max_cards])


def _cards_for_table(index: FrontierColumnIndex) -> List[str]:
    """按固定优先级为单表生成候选卡片。"""
    cards: List[str] = []
    table = index.table_name
    group_col = _best_group_column(index.group, index.anchor_terms)

    text_col = _first_column(index.text)
    if text_col:
        card = _text_value_card(index=index, text_col=text_col, group_col=group_col)
        if card:
            cards.append(card)

    time_col = _first_column(index.time)
    if time_col:
        group_for_time = _best_group_column(index.group, index.anchor_terms)
        columns = _compact_columns([time_col, group_for_time])
        cards.append(
            _format_card(
                title="Time trend follow-up",
                table=table,
                columns=columns,
                why_it_may_matter=(
                    "An overall difference may be temporary, seasonal, or concentrated in a short period; "
                    "a time view can distinguish a persistent pattern from a one-off spike."
                ),
                concrete_analysis=(
                    f"Aggregate counts or the key metric over {time_col} to check for increase, decrease, peaks, or stable/no-trend patterns; "
                    f"when useful, segment the trend by {group_for_time or 'the main categorical column'}."
                ),
            )
        )

    location_col = _first_column(index.location)
    if location_col:
        columns = _compact_columns([location_col, group_col])
        cards.append(
            _format_card(
                title="Location concentration follow-up",
                table=table,
                columns=columns,
                why_it_may_matter=(
                    "A dataset-level pattern may be driven by one region or site, so geographic segmentation can reveal where the effect is concentrated."
                ),
                concrete_analysis=(
                    f"Compare the distribution across {location_col} and inspect which {group_col or 'categories'} are over-represented in the leading locations."
                ),
            )
        )

    entity_col = _first_column(index.entity)
    if entity_col:
        columns = _compact_columns([entity_col, group_col])
        cards.append(
            _format_card(
                title="Entity concentration follow-up",
                table=table,
                columns=columns,
                why_it_may_matter=(
                    "Aggregate results may be driven by a small number of repeated people, devices, teams, or business entities."
                ),
                concrete_analysis=(
                    f"Identify repeated values of {entity_col}, then compare their category or group composition rather than only reporting another top-k gap."
                ),
            )
        )

    metric_col = _first_column(index.numeric)
    if metric_col and group_col:
        columns = _compact_columns([group_col, metric_col])
        semantic = _column_semantic(metric_col, index.column_semantics)
        if semantic.get("additive") is True:
            method_text = "totals, top-k values, gaps, and shares"
        else:
            method_text = "means or medians, ranges, and group gaps; do not sum the values or interpret them as shares"
        cards.append(
            _format_card(
                title="Metric comparison follow-up",
                table=table,
                columns=columns,
                why_it_may_matter=(
                    "Frequency alone may hide meaningful differences in magnitude, duration, cost, or another business measure across groups."
                ),
                concrete_analysis=f"Compare {metric_col} by {group_col} using {method_text}; do not rely only on statistical outlier thresholds.",
            )
        )

    return cards


def _text_value_card(index: FrontierColumnIndex, text_col: str, group_col: str) -> str:
    """生成带轻量文本值画像的文本前沿卡片。"""
    df = index.dataframe
    if text_col not in df.columns:
        return ""
    profile = _profile_text_values(df[text_col], index.anchor_terms)
    kind = _text_column_kind(text_col, df[text_col])
    title = {
        "free_text": "Free-text keyword follow-up",
        "categorical_reason": "Categorical reason follow-up",
        "resolution_action": "Resolution/action follow-up",
    }.get(kind, "Text/root-cause follow-up")

    terms = profile["terms"]
    sample_values = profile["sample_values"]
    term_text = ", ".join(terms) if terms else "meaningful domain tokens"
    sample_text = "; ".join(sample_values[:2]) if sample_values else ""
    columns = _compact_columns([group_col, text_col])

    if kind == "free_text":
        suggestion = (
            f"Ignore template words such as there/was/issue in {text_col}, extract business terms, device/entity names, or failure words; "
            f"prefer checking whether these terms concentrate within {group_col or 'the main grouping column'}. Candidate terms: {term_text}."
        )
    elif kind == "resolution_action":
        suggestion = (
            f"Check the top-k distribution of methods, actions, or resolution types in {text_col}; "
            f"if {group_col or 'a grouping column'} is available, compare resolution patterns across groups. Candidate values/terms: {term_text}."
        )
    else:
        suggestion = (
            f"Treat {text_col} as a reason/category field and inspect its top-k values, shares, and group differences; "
            f"do not treat it as a continuous numeric column. Candidate values/terms: {term_text}."
        )
    if sample_text:
        suggestion += f" Sample values: {sample_text}."

    return _format_card(
        title=title,
        table=index.table_name,
        columns=columns,
        why_it_may_matter=(
            "The current numerical or categorical summary may identify where a pattern exists without revealing the operational terms, reasons, devices, or actions behind it."
        ),
        concrete_analysis=suggestion,
    )


def _profile_text_values(series: pd.Series, anchor_terms: Set[str], max_values: int = 120) -> dict[str, List[str]]:
    """对文本列做轻量画像，只返回后续 prompt 真正会使用的字段。"""
    non_null = series.dropna().astype(str)
    samples = [compact_value_text(value, 90) for value in non_null.head(4).tolist()]
    token_counter: Counter[str] = Counter()
    phrase_counter: Counter[str] = Counter()
    present_anchor_terms: Counter[str] = Counter()

    for text in non_null.head(max_values).tolist():
        tokens = _meaningful_tokens(text)
        token_counter.update(tokens)
        phrase_counter.update(" ".join(pair) for pair in zip(tokens, tokens[1:]) if pair[0] != pair[1])
        lowered = text.lower()
        for term in anchor_terms:
            if len(term) >= 3 and term in lowered:
                present_anchor_terms[term] += 1

    terms: List[str] = []
    for term, _ in present_anchor_terms.most_common(3):
        if term not in terms:
            terms.append(term)
    for term, _ in token_counter.most_common(8):
        if term not in terms:
            terms.append(term)
        if len(terms) >= 5:
            break
    for phrase, _ in phrase_counter.most_common(4):
        if len(terms) >= 5:
            break
        if phrase and phrase not in terms:
            terms.append(phrase)

    return {"terms": terms[:5], "sample_values": samples[:3]}


def _meaningful_tokens(text: str) -> List[str]:
    """从一段文本中抽取简单业务词，过滤模板词和纯数字。"""
    tokens = re.findall(r"[A-Za-z][A-Za-z0-9_\-]{2,}|[\u4e00-\u9fff]{2,}", str(text).lower())
    out: List[str] = []
    for token in tokens:
        token = token.strip("_- ")
        if not token or token in TEXT_STOPWORDS or token.isdigit():
            continue
        if len(token) < 3 and not re.search(r"[\u4e00-\u9fff]", token):
            continue
        out.append(token)
    return out


def _text_column_kind(name: str, series: pd.Series) -> str:
    """区分自由文本、原因类别和处理方式字段，避免下一轮用错分析方法。"""
    lowered = str(name).lower()
    if any(hint in lowered for hint in ["resolution", "method", "action", "处理", "解决"]):
        return "resolution_action"

    non_null = series.dropna()
    unique_count = safe_nunique(non_null, dropna=True) if len(non_null) else 0
    unique_ratio = unique_count / max(1, len(non_null))
    sample_text = " ".join(non_null.astype(str).head(20).tolist())
    avg_tokens = len(re.findall(r"\w+", sample_text)) / max(1, len(non_null.head(20)))

    if unique_count <= 40 and unique_ratio <= 0.65 and any(hint in lowered for hint in ["reason", "cause", "rca", "category", "type"]):
        return "categorical_reason"
    if avg_tokens >= 4 or unique_ratio > 0.65:
        return "free_text"
    return "categorical_reason"


def _task_anchor_terms(task: Any, evidence_profile: Mapping[str, Any] | None) -> Set[str]:
    """从任务目标和问题证据画像中抽取短锚点词，约束 Schema frontier 不跑偏。"""
    metadata = dict(getattr(task, "metadata", {}) or {})
    profile = dict(evidence_profile or {})
    focus = profile.get("evidence_focus")
    if isinstance(focus, str):
        focus = [focus]
    parts = [
        metadata.get("goal"),
        metadata.get("role"),
        metadata.get("category"),
        metadata.get("dataset_description"),
        profile.get("round_question"),
        *list(focus or []),
    ]
    text = " ".join(str(part or "") for part in parts).lower()
    tokens = re.findall(r"[a-z][a-z0-9_\-]{2,}|[一-鿿]{2,}", text)
    return {token for token in tokens if token not in TEXT_STOPWORDS and len(token) >= 3}


def _is_identifier_like(
    dataframe: pd.DataFrame,
    column: str,
    column_semantics: Mapping[str, Mapping[str, Any]] | None = None,
) -> bool:
    """判断列是否更像技术标识符而非可解释分析维度。"""
    if column not in dataframe.columns:
        return False
    semantic = _column_semantic(column, column_semantics)
    if semantic.get("identifier"):
        return True
    lowered = str(column).lower()
    explicit_id = bool(re.search(r"(^|[_\s])(id|uuid|row id|record id|number|no)([_\s]|$)", lowered))
    non_null = dataframe[column].dropna()
    if len(non_null) == 0:
        return explicit_id
    unique_ratio = safe_nunique(non_null, dropna=True) / max(1, len(non_null))
    return bool(explicit_id and unique_ratio >= 0.80)


def _is_useful_entity_column(
    dataframe: pd.DataFrame,
    column: str,
    column_semantics: Mapping[str, Mapping[str, Any]] | None = None,
) -> bool:
    """保留可能形成重复实体或业务分组的列，排除主键和近乎全唯一标识。"""
    semantic = _column_semantic(column, column_semantics)
    if semantic.get("is_primary_key"):
        return False
    return not _is_identifier_like(dataframe, column, column_semantics)


def _columns_by_hint(columns: Sequence[str], hints: Sequence[str]) -> List[str]:
    """根据列名关键词筛选列，保持原始顺序。"""
    out: List[str] = []
    for column in columns:
        lowered = column.lower()
        if any(hint in lowered for hint in hints):
            out.append(column)
    return out


def _detect_time_columns(
    dataframe: pd.DataFrame,
    column_semantics: Mapping[str, Mapping[str, Any]] | None = None,
) -> List[str]:
    """识别时间列；先看 dtype，再看列名和少量样本是否可解析。"""
    out: List[str] = []
    for column in dataframe.columns:
        name = str(column)
        series = dataframe[column]
        lowered = name.lower()
        semantic = _column_semantic(name, column_semantics)
        declared_format = str(semantic.get("data_format") or "")
        if semantic.get("temporal") or is_datetime64_any_dtype(series):
            sample = series.dropna().head(30)
            if len(sample) and safe_nunique(sample, dropna=True) >= 2:
                out.append(name)
            continue
        if semantic.get("declared") and declared_format not in {"date", "datetime"}:
            continue
        if not any(hint in lowered for hint in TIME_HINTS):
            continue
        if is_numeric_dtype(series):
            # Only a plausible year column is accepted in the fallback path.
            numeric = pd.to_numeric(series, errors="coerce").dropna()
            if ("year" in lowered or "年" in lowered) and len(numeric) and numeric.between(1800, 2200).mean() >= 0.90:
                out.append(name)
            continue
        sample = series.dropna().head(30)
        if len(sample) == 0:
            continue
        with _ignore_datetime_warnings():
            parsed = pd.to_datetime(sample, errors="coerce")
        if float(parsed.notna().mean()) >= 0.60:
            out.append(name)
    return out


def _detect_group_columns(
    dataframe: pd.DataFrame,
    column_semantics: Mapping[str, Mapping[str, Any]] | None = None,
) -> List[str]:
    """识别适合作为分组的低/中基数列，排除明显时间列和纯数值连续列。"""
    out: List[str] = []
    rows = max(1, int(len(dataframe)))
    for column in dataframe.columns:
        name = str(column)
        lowered = name.lower()
        semantic = _column_semantic(name, column_semantics)
        if semantic.get("is_primary_key") or semantic.get("temporal"):
            continue
        if any(hint in lowered for hint in TIME_HINTS):
            continue
        series = dataframe[column]
        non_null = series.dropna()
        if len(non_null) == 0:
            continue
        unique_count = safe_nunique(non_null, dropna=True)
        unique_ratio = unique_count / rows
        if 2 <= unique_count <= 30 and unique_ratio <= 0.45:
            out.append(name)
    return out



def _column_semantic(
    column: str,
    column_semantics: Mapping[str, Mapping[str, Any]] | None,
) -> dict[str, Any]:
    if column_semantics and column in column_semantics:
        return dict(column_semantics[column] or {})
    return infer_column_semantics(column)


def _is_valid_frontier_metric(
    column: str,
    column_semantics: Mapping[str, Mapping[str, Any]] | None,
) -> bool:
    semantic = _column_semantic(column, column_semantics)
    if semantic.get("identifier"):
        return False
    return str(semantic.get("kind") or "") not in {
        "category_code", "coordinate", "text", "boolean", "temporal"
    }

def _prioritize_columns(columns: Sequence[str], priorities: Sequence[str], anchor_terms: Set[str] | None = None) -> List[str]:
    """按业务关键词和任务锚点调整列优先级。"""
    anchors = set(anchor_terms or set())

    def score(column: str) -> tuple[int, int, str]:
        lowered = column.lower()
        anchor_hit = 0 if any(term and term in lowered for term in anchors) else 1
        for index, hint in enumerate(priorities):
            if hint in lowered:
                return (anchor_hit, index, column)
        return (anchor_hit, len(priorities), column)

    return sorted(list(columns), key=score)


def _best_group_column(columns: Sequence[str], anchor_terms: Set[str] | None = None) -> str:
    """选择最适合做上下文分组的列。"""
    return _first(_prioritize_columns(columns, ["category", "department", "model", "priority", "assignment_group", "group", "state"], set(anchor_terms or set())))


@contextmanager
def _ignore_datetime_warnings():
    """忽略 pandas 对混合日期格式的解析警告，frontier 这里只需要轻量判断。"""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        yield


def _first(values: Sequence[str]) -> str:
    """返回第一个非空字符串。"""
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def _first_column(values: Sequence[str]) -> str:
    """返回候选列表中的第一个非空列。"""
    for value in values:
        text = str(value or "").strip()
        if text:
            return text
    return ""


def _compact_columns(values: Iterable[str]) -> List[str]:
    """去空、去重，生成卡片中的列清单。"""
    out: List[str] = []
    seen: Set[str] = set()
    for value in values:
        text = str(value or "").strip()
        key = text.lower()
        if not text or key in seen:
            continue
        seen.add(key)
        out.append(text)
    return out


def _format_card(
    *,
    title: str,
    table: str,
    columns: Sequence[str],
    why_it_may_matter: str,
    concrete_analysis: str,
) -> str:
    """把一个探索方向格式化为 exploration card。

    Schema 卡不是已观察到的事实。它只说明一个仍可执行的新分析方向、这个方向
    为什么可能补充当前结果，以及应使用哪些真实字段。
    """
    column_text = ", ".join(columns) if columns else "available columns"
    return (
        f"[{title}]\n"
        f"Available direction: {title}.\n"
        f"Table: {table}\n"
        f"Use columns: {column_text}\n"
        f"Why it may matter: {why_it_may_matter}\n"
        f"Concrete analysis: {concrete_analysis}"
    )
