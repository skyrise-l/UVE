"""问题证据画像与视觉候选的语义对齐评分。

该评分器回答：一个候选图所表达的字段、比较关系和图表标题，是否贴近当前
Question Evidence Profile 中声明的 evidence_focus。
它只使用轻量词项匹配，不调用 LLM，也不替代 Trace/VEG 的真实性判断。
"""

from __future__ import annotations

import math
import re
from typing import Any, List, Mapping, Set, Tuple

from chart_extract.common import all_slots
from vis_project_utils.utils import clip01

_STOPWORDS = {
    "the", "and", "for", "with", "from", "that", "this", "into", "what", "which",
    "how", "whether", "should", "would", "could", "need", "needs", "use", "using",
    "evidence", "question", "analysis", "compare", "comparison", "result", "results",
    "current", "selected", "directly", "across", "between", "within", "later", "main",
    "data", "table", "tables", "value", "values", "metric", "metrics",
}


class EvidenceIntentAlignmentScorer:
    """计算视觉候选与问题证据画像的软对齐分。"""

    def score(
        self,
        plan: Mapping[str, Any],
        evidence_profile: Mapping[str, Any] | None,
    ) -> Tuple[float, List[str]]:
        """返回 0 到 1 的软对齐分和简短原因。"""
        profile_text = self._profile_text(evidence_profile)
        if not profile_text:
            return 0.50, ["no explicit evidence focus; use neutral intent prior"]

        plan_text = self._plan_text(plan)
        profile_terms = _terms(profile_text)
        plan_terms = _terms(plan_text)
        if not profile_terms or not plan_terms:
            return 0.35, ["insufficient lexical signal for evidence-intent alignment"]

        overlap = profile_terms.intersection(plan_terms)
        cosine_like = len(overlap) / max(1.0, math.sqrt(len(profile_terms) * len(plan_terms)))
        overlap_score = clip01(cosine_like * 3.0)

        slot_terms = _terms(" ".join(str(value or "") for value in all_slots(plan).values()))
        slot_coverage = len(slot_terms.intersection(profile_terms)) / max(1, len(slot_terms)) if slot_terms else 0.0

        phrase_bonus = _phrase_match_bonus(profile_text, plan_text)
        score = clip01(0.24 + 0.48 * overlap_score + 0.20 * slot_coverage + 0.08 * phrase_bonus)

        reasons = [
            f"intent_overlap={overlap_score:.2f}",
            f"slot_focus_coverage={slot_coverage:.2f}",
        ]
        if overlap:
            reasons.append("shared_terms=" + ", ".join(sorted(overlap)[:6]))
        return score, reasons

    def _profile_text(self, profile: Mapping[str, Any] | None) -> str:
        profile = dict(profile or {})
        focus = profile.get("evidence_focus")
        if isinstance(focus, str):
            focus = [focus]
        parts: List[str] = [
            str(profile.get("round_question") or ""),
        ]
        parts.extend(str(item or "") for item in list(focus or []))
        return " ".join(part for part in parts if part.strip())

    def _plan_text(self, plan: Mapping[str, Any]) -> str:
        plan = dict(plan or {})
        transform = dict(plan.get("transform") or {})
        parts = [
            str(plan.get("title") or ""),
            str(plan.get("pattern") or ""),
            str(plan.get("template_id") or ""),
            " ".join(str(value or "") for value in all_slots(plan).values()),
            str(transform.get("ops") or ""),
        ]
        return " ".join(part for part in parts if part.strip())


def _terms(text: str) -> Set[str]:
    """抽取英文、下划线字段和中文短词。"""
    expanded = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", str(text or ""))
    expanded = expanded.replace("_", " ").replace("-", " ").lower()
    raw = re.findall(r"[a-z][a-z0-9]{2,}|[\u4e00-\u9fff]{2,}", expanded)
    return {token for token in raw if token not in _STOPWORDS}


def _phrase_match_bonus(profile_text: str, plan_text: str) -> float:
    """字段名或短语直接出现时给少量奖励。"""
    profile = re.sub(r"\s+", " ", str(profile_text or "").lower())
    plan = re.sub(r"\s+", " ", str(plan_text or "").lower())
    hits = 0
    for phrase in re.findall(r"[a-z][a-z0-9_\-]{3,}", plan):
        normalized = phrase.replace("_", " ").replace("-", " ")
        if normalized in profile or phrase in profile:
            hits += 1
    return clip01(hits / 3.0)
