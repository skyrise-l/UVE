"""utility_analysis_tendency.py
-------------------------------

Auxiliary intent-method preference scorer.

The score helps order otherwise valid candidates.  It is never a hard gate, never
changes evidence/representation thresholds, and never authorizes a chart without
runtime grounding.
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Sequence, Tuple

from analysis_tendency import normalize_analysis_tendency, tendency_strength_map
from vis_project_utils.utils import clip01


# 模板到分析方向的精确权重。
# 这里保留“次要可用方向”，但让它们明显低于主方向，避免 boxplot/scatter
# 仅靠宽泛 group_difference 等方向拿到过高 L1。
_TEMPLATE_TENDENCY_WEIGHTS: Dict[str, Dict[str, float]] = {
    "count_by_group": {
        "group_difference": 1.00,
        "composition_or_proportion": 0.92,
        "ranking_or_extreme": 0.86,
        "overview": 0.62,
        # Kept as a weak compatibility preference only.  Categorical counts are not
        # treated as numeric distribution shape by the QEP normalizer.
        "distribution_shape": 0.28,
    },
    "comparison_bar": {
        "group_difference": 1.00,
        "ranking_or_extreme": 0.86,
        "composition_or_proportion": 0.74,
        "factor_explanation": 0.55,
        "overview": 0.54,
    },
    "trend_line": {
        "trend_or_change": 1.00,
        "anomaly_or_outlier": 0.54,
        "group_difference": 0.34,
        "overview": 0.38,
    },
    "relation_scatter": {
        "relationship_or_association": 1.00,
        "factor_explanation": 0.60,
        "anomaly_or_outlier": 0.32,
    },
    "distribution_box": {
        "distribution_shape": 1.00,
        "group_difference": 0.74,
        "anomaly_or_outlier": 0.68,
        "overview": 0.30,
    },
}

# pattern 兜底映射。正常情况下 generator 都会写 template_id。
_PATTERN_TO_TENDENCIES: Dict[str, Dict[str, float]] = {
    "category_count_distribution": _TEMPLATE_TENDENCY_WEIGHTS["count_by_group"],
    "category_metric_comparison": _TEMPLATE_TENDENCY_WEIGHTS["comparison_bar"],
    "topk_ranking": {
        "ranking_or_extreme": 1.00,
        "group_difference": 0.52,
        "anomaly_or_outlier": 0.45,
    },
    "time_trend": _TEMPLATE_TENDENCY_WEIGHTS["trend_line"],
    "grouped_time_trend": _TEMPLATE_TENDENCY_WEIGHTS["trend_line"],
    "relationship": _TEMPLATE_TENDENCY_WEIGHTS["relation_scatter"],
    "distribution_spread": _TEMPLATE_TENDENCY_WEIGHTS["distribution_box"],
}


class AnalysisTendencyAlignmentScorer:
    """Auxiliary ranking preference between a plan and the current tendency."""

    def score(self, plan: Mapping[str, Any], analysis_tendency: Sequence[Mapping[str, Any]]) -> Tuple[float, List[str]]:
        """返回 L1 分数和简洁原因。

        输入：单个 VisualPlan 和已规范化或未规范化的 analysis_tendency。
        输出：0 到 1 的匹配分，以及少量审计原因。
        """

        tendencies = normalize_analysis_tendency(list(analysis_tendency or []))
        strengths = tendency_strength_map(tendencies)
        weights = self._plan_tendency_weights(plan)
        if not weights:
            return 0.22, ["no_template_tendency_weights"]

        primary_type, primary_strength = _strongest_tendency(strengths)
        primary_match = float(weights.get(primary_type, 0.0)) * float(primary_strength)

        best_type = ""
        best_match = 0.0
        for tendency_type, strength in strengths.items():
            value = float(weights.get(tendency_type, 0.0)) * float(strength)
            if value > best_match:
                best_match = value
                best_type = tendency_type

        # Specificity rewards an exact primary-method match, but the result remains a
        # ranking preference only.  A mismatch must not reject an otherwise grounded plan.
        template_primary = max(weights.items(), key=lambda item: item[1])[0]
        specificity = 1.0 if template_primary == primary_type else 0.35 if primary_match > 0 else 0.0

        score = clip01(0.58 * primary_match + 0.30 * best_match + 0.12 * specificity)
        reasons = [
            f"analysis_tendency={_brief_tendency(strengths)}",
            f"template_id={str(plan.get('template_id') or '')}",
            f"primary_match={primary_type}:{primary_match:.2f}",
            f"best_match={best_type or 'none'}:{best_match:.2f}",
        ]
        return score, reasons

    def _plan_tendency_weights(self, plan: Mapping[str, Any]) -> Dict[str, float]:
        """读取当前 plan 的模板权重；缺失时用 pattern 兜底。"""
        template_id = str((plan or {}).get("template_id") or "")
        if template_id in _TEMPLATE_TENDENCY_WEIGHTS:
            return dict(_TEMPLATE_TENDENCY_WEIGHTS[template_id])

        pattern = str((plan or {}).get("pattern") or "")
        if pattern in _PATTERN_TO_TENDENCIES:
            return dict(_PATTERN_TO_TENDENCIES[pattern])

        # 最后兜底：supported_tendencies 仍可用，但统一给较弱权重。
        out: Dict[str, float] = {}
        for item in list((plan or {}).get("supported_tendencies") or []):
            key = str(item or "")
            if key:
                out[key] = max(out.get(key, 0.0), 0.58)
        return out


def _strongest_tendency(strengths: Mapping[str, float]) -> Tuple[str, float]:
    """返回 LLM 当前轮最强分析方向。"""
    if not strengths:
        return "overview", 0.40
    key, value = max(((str(k), float(v)) for k, v in strengths.items()), key=lambda item: item[1])
    return key, value


def _brief_tendency(strengths: Mapping[str, float]) -> str:
    """压缩显示前三个分析方向，避免审计日志过长。"""
    items = sorted(((k, float(v)) for k, v in dict(strengths or {}).items()), key=lambda x: -x[1])
    return ";".join(f"{key}:{value:.2f}" for key, value in items[:3]) or "none"
