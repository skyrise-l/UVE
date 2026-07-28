"""evidence_brief.py
--------------------
把代码执行结果、结果证据卡和图表证据卡压缩成一份统一的证据摘要。

这个模块位于 code execution 和 insight extraction 之间。它不生成最终 insight，
只负责回答两个问题：
1. 已经计算出的关键证据或运行时诊断是什么；
2. 这些证据更像分组对比、趋势、相关性、文本关键词，还是运行时诊断。

Interpret LLM 不应该直接从 raw DataFrame、图卡文本和 stage_result 里自由猜重点，
而应该看到一份紧凑、结构清晰、以 gold-like finding 为目标的证据摘要。
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Mapping, Sequence

import pandas as pd


MAX_KEY_FACTS = 8
MAX_IMPORTANT_NUMBERS = 8
MAX_COMPACT_ROWS = 8
MAX_COMPACT_COLS = 8


def build_evidence_brief(
    *,
    question: str,
    goal: str,
    answer_evidence: Mapping[str, Any],
    answer_evidence_cards: str = "",
) -> Dict[str, Any]:
    """生成 interpret 阶段优先读取的证据摘要。

    输入：
    - question：当前被回答的问题；
    - goal：当前数据集的分析目标；
    - answer_evidence：EvidenceOrganizer 从 stage_result 生成的结果证据；
    - answer_evidence_cards：结果卡和 answer 图卡拼接后的短文本。

    输出只保留下游真正会使用的字段：
    - evidence_type：证据类型，帮助 LLM 把事实写成正确类型的 insight；
    - key_facts：最重要的事实句；
    - important_numbers：从事实中抽取的关键数字；
    - compact_table：如果 stat.value 是小表，给出少量行列预览；
    - goal_alignment：该证据和目标中哪些需求相关；
    - caveats：执行失败、运行时诊断或截断等注意事项。
    """
    evidence = dict(answer_evidence or {})
    stage_result = dict(evidence.get("stage_result") or {})
    card_facts = _facts_from_card_text(answer_evidence_cards)
    stat_facts = _facts_from_stat(stage_result)
    key_facts = _dedupe_texts(stat_facts + card_facts)[:MAX_KEY_FACTS]
    compact_table = _compact_table_from_stat(stage_result)
    caveats = _build_caveats(answer_evidence=evidence, key_facts=key_facts)
    evidence_type = _classify_evidence_type(
        question=question,
        goal=goal,
        stage_result=stage_result,
        key_facts=key_facts,
        cards=answer_evidence_cards,
    )

    return {
        "evidence_type": evidence_type,
        "key_facts": key_facts,
        "important_numbers": _important_numbers_from_texts(key_facts)[:MAX_IMPORTANT_NUMBERS],
        "compact_table": compact_table,
        "goal_alignment": _goal_alignment(goal=goal, question=question, evidence_type=evidence_type),
        "caveats": caveats,
    }


def _facts_from_stat(stage_result: Mapping[str, Any]) -> List[str]:
    """从 stage_result.stat 的 name/description/value 里抽取短事实。"""
    facts: List[str] = []
    stat_items = stage_result.get("stat")
    if not isinstance(stat_items, list):
        return facts

    for item in stat_items:
        if not isinstance(item, Mapping):
            continue
        name = _clean_text(item.get("name"))
        description = _clean_text(item.get("description"))
        value = item.get("value")
        if name and description:
            facts.append(f"{name}: {description}")
        elif name:
            facts.append(name)
        elif description:
            facts.append(description)

        value_fact = _brief_value_fact(value)
        if value_fact:
            facts.append(value_fact)
    return facts


def _facts_from_card_text(cards: str) -> List[str]:
    """从结果卡/图卡文本中抽取 Key facts 和 Candidate local finding。"""
    facts: List[str] = []
    for raw_line in str(cards or "").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        lowered = line.lower()
        if line.startswith("- "):
            facts.append(_clean_text(line[2:]))
        elif lowered.startswith("candidate local finding:"):
            facts.append(_clean_text(line.split(":", 1)[1]))
    return [fact for fact in facts if fact]


def _brief_value_fact(value: Any) -> str:
    """把 value 的形态压成一句短事实，不在这里解释业务含义。"""
    if isinstance(value, list):
        if value and all(isinstance(row, Mapping) for row in value):
            return f"The evidence table contains {len(value)} rows and {len(value[0]) if value else 0} columns."
        return f"The evidence list contains {len(value)} items."
    if isinstance(value, dict):
        return f"The evidence object contains {len(value)} named field(s): {', '.join(list(map(str, value.keys()))[:5])}."
    if isinstance(value, (int, float, str)) and str(value).strip():
        return f"The computed evidence value is {str(value).strip()}."
    return ""


def _compact_table_from_stat(stage_result: Mapping[str, Any]) -> List[Dict[str, Any]]:
    """从第一个表状 stat.value 中取少量行列，供 interpret LLM 精确引用。"""
    stat_items = stage_result.get("stat")
    if not isinstance(stat_items, list):
        return []
    for item in stat_items:
        if not isinstance(item, Mapping):
            continue
        df = _coerce_table(item.get("value"))
        if df is None or df.empty:
            continue
        return _preview_dataframe(df)
    return []


def _coerce_table(value: Any) -> pd.DataFrame | None:
    """把常见表状对象转成 DataFrame。"""
    if isinstance(value, pd.DataFrame):
        return value.copy()
    if isinstance(value, pd.Series):
        name = value.name if value.name is not None else "value"
        return value.to_frame(name=str(name)).reset_index()
    if isinstance(value, list) and value and all(isinstance(row, Mapping) for row in value):
        try:
            return pd.DataFrame(value)
        except Exception:
            return None
    if isinstance(value, dict) and value:
        # dict of arrays -> table
        try:
            df = pd.DataFrame(value)
            if not df.empty:
                return df
        except Exception:
            pass
        # dict of scalars -> two-column table
        if all(not isinstance(v, (list, tuple, dict, pd.Series, pd.DataFrame)) for v in value.values()):
            return pd.DataFrame([{"name": str(k), "value": v} for k, v in value.items()])
    return None


def _preview_dataframe(df: pd.DataFrame) -> List[Dict[str, Any]]:
    """生成稳定、短小、可 JSON 序列化的小表预览。"""
    small = df.iloc[:MAX_COMPACT_ROWS, :MAX_COMPACT_COLS].copy()
    out: List[Dict[str, Any]] = []
    for row in small.to_dict(orient="records"):
        clean_row: Dict[str, Any] = {}
        for key, value in row.items():
            clean_row[str(key)] = _json_safe_preview_value(value)
        out.append(clean_row)
    return out


def _json_safe_preview_value(value: Any) -> Any:
    """Convert a dataframe cell without evaluating array-like null masks as booleans."""
    if isinstance(value, pd.DataFrame):
        return f"<DataFrame {value.shape[0]}x{value.shape[1]}>"
    if isinstance(value, pd.Series):
        return f"<Series length={len(value)}>"
    if isinstance(value, Mapping):
        return f"<mapping keys={len(value)}>"
    if isinstance(value, (list, tuple, set)):
        return f"<{type(value).__name__} length={len(value)}>"
    try:
        missing = pd.isna(value)
        if isinstance(missing, bool) and missing:
            return None
    except Exception:
        pass
    if isinstance(value, float):
        try:
            return round(float(value), 6)
        except (TypeError, ValueError):
            return str(value)
    return str(value) if not isinstance(value, (int, bool)) else value


def _classify_evidence_type(
    *,
    question: str,
    goal: str,
    stage_result: Mapping[str, Any],
    key_facts: Sequence[str],
    cards: str,
) -> str:
    """用简单规则判断证据类型，避免 interpret 阶段把证据写偏。"""
    evidence_text = " ".join([cards, " ".join(key_facts)]).lower()

    goal_text = " ".join([question, goal]).lower()

    # 先看已经算出来的证据，再看 goal/question。否则 goal 里的 trend 等宽泛词
    # 会把明显的 top-k/count 结果误判为趋势证据。
    if any(word in evidence_text for word in ["correlation", "relationship", "regression", "pearson", "linear", "association"]):
        return "relationship"
    if any(word in evidence_text for word in ["highest", "lowest", "top", "dominant", "share", "gap", "distribution", "count", "total"]):
        return "group_comparison"
    if any(word in evidence_text for word in ["trend", "over time", "date", "month", "year", "increase", "decrease", "stable", "peak"]):
        return "trend"
    if any(word in evidence_text for word in ["keyword", "term", "text", "description", "comment", "resolution", "root cause"]):
        return "text_keyword"

    if any(word in goal_text for word in ["correlation", "relationship", "regression", "pearson", "linear", "association"]):
        return "relationship"
    if any(word in goal_text for word in ["trend", "over time", "date", "month", "year", "increase", "decrease", "stable", "peak"]):
        return "trend"
    if any(word in goal_text for word in ["keyword", "term", "text", "description", "comment", "resolution", "root cause"]):
        return "text_keyword"
    return "general_evidence"


def _goal_alignment(*, goal: str, question: str, evidence_type: str) -> List[str]:
    """给出短目标对齐标签，帮助后续 prompt 聚焦 gold-like 需求。"""
    text = f"{goal} {question}".lower()
    labels: List[str] = []
    if evidence_type != "general_evidence":
        labels.append(evidence_type)
    if any(word in text for word in ["cost", "expense", "amount", "budget"]):
        labels.append("cost_or_expense")
    if any(word in text for word in ["incident", "ticket", "request", "case"]):
        labels.append("incident_or_request")
    if any(word in text for word in ["department", "location", "category", "priority", "group", "agent", "user"]):
        labels.append("entity_or_segment")
    return _dedupe_texts(labels)[:5]


def _important_numbers_from_texts(texts: Sequence[str]) -> List[Dict[str, Any]]:
    """从事实句中抽取数字，给 interpret 阶段一个显式数字锚点。"""
    numbers: List[Dict[str, Any]] = []
    pattern = re.compile(r"(?<![A-Za-z0-9_])[-+]?\d[\d,]*(?:\.\d+)?%?")
    for text in texts:
        for match in pattern.findall(str(text)):
            numbers.append({"value": match, "source": _clean_text(text)[:180]})
            if len(numbers) >= MAX_IMPORTANT_NUMBERS:
                return numbers
    return numbers


def _build_caveats(*, answer_evidence: Mapping[str, Any], key_facts: Sequence[str]) -> List[str]:
    """收集执行失败、运行时诊断和截断等注意事项。"""
    caveats: List[str] = []
    note = _clean_text(answer_evidence.get("note"))
    if note:
        caveats.append(note)
    return _dedupe_texts(caveats)[:3]


def _dedupe_texts(values: Sequence[str]) -> List[str]:
    """保持顺序去重。"""
    out: List[str] = []
    seen = set()
    for value in values:
        text = _clean_text(value)
        key = re.sub(r"\W+", " ", text.lower()).strip()
        if not text or key in seen:
            continue
        seen.add(key)
        out.append(text)
    return out


def _clean_text(value: Any) -> str:
    """清理多余空白和句末重复标点。"""
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    text = text.rstrip("。.")
    return text + "." if text else ""
