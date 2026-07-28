"""utility_encoding_advantage.py
--------------------------------

L3：Textual Visual-Fact Utility。

本项目当前明确不把图像传给 answer LLM，而是把图转成文字信息卡。因此 L3
不再把“图是否比表格/文本更值得看”作为主问题，而是判断：

    候选图对应的 support table，能否稳定抽出对回答有帮助的文字化模式事实？

设计取舍：
- 保留图表编码适配、模式强弱、拥挤风险等创新因素，但它们只作为辅助信号；
- 小表不再因为“表格也能看懂”被系统性压制，反而会因事实可抽取性获得加分；
- 输出只保留后续 gate、selector 和审计真正会用到的字段。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, List, Mapping

import numpy as np
import pandas as pd

from chart.transforms import apply_transform_ops
from evidence_layer.pattern_signal import compute_pattern_signal
from vis_project_utils.utils import clip01, safe_to_numeric


_PATTERN_CHART_FIT = {
    "category_count_distribution": {"bar": 0.96},
    "category_metric_comparison": {"bar": 0.94},
    "topk_ranking": {"bar": 0.97},
    "time_trend": {"line": 0.97},
    "grouped_time_trend": {"line": 0.92},
    "relationship": {"scatter": 0.90},
    "distribution_spread": {"boxplot": 0.84},
    "interaction_pattern": {"heatmap": 0.84},
}

_LIGHT_TRANSFORMS = {"use_columns", "rename_columns", "sort_by", "filter_in"}
_MODERATE_TRANSFORMS = {"value_counts", "groupby_count", "groupby_agg", "time_floor", "top_k"}
_HEAVY_TRANSFORMS = {"pivot_table"}


def _safe_nunique(series: pd.Series) -> int:
    """安全计算唯一值数量，避免 list/dict 等不可哈希对象导致打分中断。"""
    try:
        return int(series.nunique(dropna=False))
    except TypeError:
        return int(series.map(lambda value: repr(value)).nunique(dropna=False))


@dataclass
class CardProfile:
    """候选图生成文字信息卡时需要的最小数据画像。"""

    pattern: str
    chart_type: str
    template_id: str
    rows: int
    cols: int
    source_rows: int
    x: str
    y: str
    value: str
    x_cardinality: int
    group_cardinality: int
    numeric_y_count: int
    numeric_x_count: int
    transform_steps: int
    transform_cost: float
    has_aggregation: bool
    avg_label_len: float
    missing_ratio: float


class VisualEncodingAdvantageScorer:
    """L3：评估候选图是否值得转成文字化 Visual Evidence Card。"""

    def score(self, plan: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Dict[str, Any]:
        """返回 L3 分数、简洁原因和 selector 需要的少量 details。"""

        source_tid = str(plan.get("source_tid") or "")
        source_df = artifact_store.get(source_tid)
        if not isinstance(source_df, pd.DataFrame) or source_df.empty:
            return self._failed_score("source dataframe missing or empty")

        ops = list((dict(plan.get("transform") or {}).get("ops")) or [])
        try:
            support_df = apply_transform_ops(source_df, ops)
        except Exception as exc:
            return self._failed_score(f"transform failed while encoding scoring: {exc}")
        if not isinstance(support_df, pd.DataFrame) or support_df.empty:
            return self._failed_score("support dataframe missing or empty")

        profile = self._build_profile(plan, source_df, support_df, ops)
        details = self._score_card_utility(plan, support_df, profile)
        reasons = self._format_reasons(details)
        return {
            "score": float(details["visual_encoding_advantage"]),
            "reasons": reasons,
            "details": details,
        }

    def _failed_score(self, reason: str) -> Dict[str, Any]:
        return {
            "score": 0.0,
            "reasons": [reason],
            "details": {"error": reason, "visual_encoding_advantage": 0.0},
        }

    def _build_profile(
        self,
        plan: Mapping[str, Any],
        source_df: pd.DataFrame,
        support_df: pd.DataFrame,
        ops: List[Mapping[str, Any]],
    ) -> CardProfile:
        """把 plan/support_df 压缩成 L3 会用到的轻量画像。"""

        encoding = dict(plan.get("encoding") or {})
        slots = dict(encoding.get("slots") or {})
        chart_type = str(encoding.get("chart_type") or "")
        pattern = str(plan.get("pattern") or "")
        template_id = str(plan.get("template_id") or "")
        x = str(slots.get("x") or "")
        y = str(slots.get("y") or "")
        value = str(slots.get("value") or "")

        numeric_y = safe_to_numeric(support_df[y]) if y in support_df.columns else pd.Series(dtype=float)
        numeric_x = safe_to_numeric(support_df[x]) if x in support_df.columns else pd.Series(dtype=float)
        labels = support_df[x].dropna().astype(str) if x in support_df.columns else pd.Series(dtype=str)
        transform_names = {str(op.get("op") or "") for op in list(ops or [])}

        return CardProfile(
            pattern=pattern,
            chart_type=chart_type,
            template_id=template_id,
            rows=int(support_df.shape[0]),
            cols=int(support_df.shape[1]),
            source_rows=int(source_df.shape[0]),
            x=x,
            y=y,
            value=value,
            x_cardinality=_safe_nunique(support_df[x]) if x in support_df.columns else int(support_df.shape[0]),
            group_cardinality=_safe_nunique(support_df[x]) if x in support_df.columns and chart_type == "boxplot" else 0,
            numeric_y_count=int(numeric_y.notna().sum()) if len(numeric_y) else 0,
            numeric_x_count=int(numeric_x.notna().sum()) if len(numeric_x) else 0,
            transform_steps=len(list(ops or [])),
            transform_cost=self._estimate_transform_cost(ops),
            has_aggregation=bool(transform_names & {"value_counts", "groupby_count", "groupby_agg", "pivot_table"}),
            avg_label_len=float(labels.str.len().mean()) if len(labels) else 0.0,
            missing_ratio=float(support_df.isna().mean().mean()) if support_df.size else 0.0,
        )

    def _score_card_utility(self, plan: Mapping[str, Any], df: pd.DataFrame, profile: CardProfile) -> Dict[str, Any]:
        """计算文字信息卡价值。核心是 fact_extractability，而不是图像本身。"""

        pattern_signal = compute_pattern_signal(df, plan)
        signal = clip01(pattern_signal.score)
        pattern_fit = self._pattern_encoding_fit(profile.pattern, profile.chart_type)
        fact_extractability = self._fact_extractability(profile, signal)
        compression_gain = self._compression_gain(profile)
        readability = self._readability(profile)
        structural = self._structural_visibility(profile, signal)
        non_visual = self._non_visual_baseline(profile, signal, fact_extractability)
        weak_signal = self._weak_signal_penalty(profile, signal, fact_extractability)
        visual_cost = self._card_risk(profile, weak_signal)

        card_value = clip01(
            0.30 * fact_extractability
            + 0.22 * signal
            + 0.18 * pattern_fit
            + 0.14 * compression_gain
            + 0.10 * readability
            + 0.06 * structural
        )

        # 非视觉基线和成本保留，但降为弱约束。
        # 这样“小表也容易读”不会直接压掉可产生明确文字事实的候选图。
        raw = card_value - 0.25 * non_visual - 0.30 * visual_cost
        l3 = clip01(0.43 + 0.72 * raw)
        dominant = "card" if l3 >= 0.50 else "table_or_text"

        return {
            "visual_encoding_advantage": float(l3),
            "chart_information_value": float(card_value),
            "fact_extractability": float(fact_extractability),
            "table_baseline_value": float(non_visual),
            "text_baseline_value": float(non_visual),
            "non_visual_baseline": float(non_visual),
            "visual_cost": float(visual_cost),
            "weak_signal_penalty": float(weak_signal),
            "pattern_encoding_fit": float(pattern_fit),
            "perceptual_signal_gain": float(signal),
            "compression_gain": float(compression_gain),
            "structural_visibility": float(structural),
            "readability": float(readability),
            "clutter_risk": float(self._clutter_risk(profile)),
            "transform_cost": float(profile.transform_cost),
            "distortion_risk": float(self._distortion_risk(profile)),
            "dominant_representation": dominant,
            "pattern_signal_metrics": dict(pattern_signal.metrics or {}),
            "profile": {
                "pattern": profile.pattern,
                "chart_type": profile.chart_type,
                "template_id": profile.template_id,
                "rows": profile.rows,
                "cols": profile.cols,
                "source_rows": profile.source_rows,
                "x": profile.x,
                "y": profile.y,
                "x_cardinality": profile.x_cardinality,
                "transform_cost": profile.transform_cost,
            },
        }

    def _estimate_transform_cost(self, ops: List[Mapping[str, Any]]) -> float:
        """估计从源表到 support table 的解释成本。"""
        if not ops:
            return 0.02
        cost = 0.0
        for op in list(ops or []):
            name = str(op.get("op") or "")
            if name in _LIGHT_TRANSFORMS:
                cost += 0.04
            elif name in _MODERATE_TRANSFORMS:
                cost += 0.08
            elif name in _HEAVY_TRANSFORMS:
                cost += 0.18
            elif name:
                cost += 0.12
        return clip01(cost + max(0, len(ops) - 2) * 0.02)

    def _pattern_encoding_fit(self, pattern: str, chart_type: str) -> float:
        """模板/图型是否适合承载该类模式。"""
        if not pattern or not chart_type:
            return 0.25
        direct = _PATTERN_CHART_FIT.get(pattern, {}).get(chart_type)
        if direct is not None:
            return float(direct)
        if chart_type == "bar" and "category" in pattern:
            return 0.70
        if chart_type == "line" and "trend" in pattern:
            return 0.70
        return 0.30

    def _fact_extractability(self, profile: CardProfile, signal: float) -> float:
        """评估 support table 是否容易转成可靠文字事实。"""
        rows = profile.rows
        if rows <= 1:
            return 0.18

        if profile.chart_type == "bar":
            # 小到中等规模的 group-count / group-metric 结果最适合抽 top、占比、差距。
            if 2 <= rows <= 12:
                return clip01(0.72 + 0.24 * signal)
            if 13 <= rows <= 30:
                return clip01(0.58 + 0.24 * signal)
            return clip01(0.35 + 0.25 * signal)

        if profile.chart_type == "line":
            if 3 <= rows <= 80:
                return clip01(0.62 + 0.30 * signal)
            return clip01(0.32 + 0.25 * signal)

        if profile.chart_type == "scatter":
            if rows >= 8:
                return clip01(0.35 + 0.52 * signal)
            return 0.22

        if profile.chart_type == "boxplot":
            if profile.source_rows >= 12 and 2 <= profile.x_cardinality <= 12:
                return clip01(0.40 + 0.45 * signal)
            return clip01(0.22 + 0.35 * signal)

        if profile.chart_type == "heatmap":
            return clip01(0.35 + 0.40 * signal)

        return clip01(0.35 + 0.35 * signal)

    def _compression_gain(self, profile: CardProfile) -> float:
        """评估信息卡相对原 support table 的压缩收益。"""
        rows = profile.rows
        if rows <= 1:
            return 0.10
        if profile.chart_type == "bar":
            if 2 <= rows <= 5:
                return 0.66
            if 6 <= rows <= 18:
                return 0.84
            if 19 <= rows <= 60:
                return 0.62
            return 0.34
        if profile.chart_type == "line":
            if 3 <= rows <= 80:
                return 0.82
            return 0.42
        if profile.chart_type == "scatter":
            return 0.72 if rows >= 20 else 0.38
        if profile.chart_type == "boxplot":
            return 0.70 if profile.source_rows >= 20 else 0.38
        return clip01(min(1.0, np.log1p(rows) / np.log1p(80.0)))

    def _readability(self, profile: CardProfile) -> float:
        """估计从图对应结构中抽取事实时的可读性。"""
        rows = profile.rows
        label_penalty = 0.18 if profile.avg_label_len > 28 else 0.08 if profile.avg_label_len > 18 else 0.0
        missing_penalty = min(0.18, profile.missing_ratio * 0.35)
        if profile.chart_type == "bar":
            base = 0.94 if 2 <= rows <= 12 else 0.72 if rows <= 24 else 0.42
        elif profile.chart_type == "line":
            base = 0.86 if 3 <= rows <= 80 else 0.50
        elif profile.chart_type == "scatter":
            base = 0.70 if rows >= 12 else 0.42
        elif profile.chart_type == "boxplot":
            base = 0.78 if 2 <= profile.x_cardinality <= 10 else 0.45
        else:
            base = 0.55
        return clip01(base - label_penalty - missing_penalty)

    def _structural_visibility(self, profile: CardProfile, signal: float) -> float:
        """模式结构是否清晰。这里是辅助信号，不再主导准入。"""
        rows = profile.rows
        if profile.chart_type == "bar":
            size_bonus = 0.95 if 2 <= rows <= 12 else 0.65 if rows <= 24 else 0.35
            return clip01(0.55 * signal + 0.45 * size_bonus)
        if profile.chart_type == "line":
            return clip01(0.68 * signal + 0.32 * (1.0 if rows >= 3 else 0.35))
        if profile.chart_type == "scatter":
            return clip01(0.72 * signal + 0.28 * min(1.0, rows / 80.0))
        if profile.chart_type == "boxplot":
            return clip01(0.62 * signal + 0.38 * (1.0 if profile.x_cardinality >= 2 else 0.25))
        return clip01(0.50 * signal + 0.25)

    def _non_visual_baseline(self, profile: CardProfile, signal: float, fact_extractability: float) -> float:
        """表格/文本基线只作为轻惩罚，避免压制小结果的信息卡。"""
        if profile.rows <= 3:
            base = 0.70
        elif profile.rows <= 6:
            base = 0.58
        elif profile.rows <= 12:
            base = 0.42
        else:
            base = 0.25
        # 如果事实很容易抽取，说明信息卡确实能省掉 answer 模型自行推理的成本。
        return clip01(base - 0.28 * fact_extractability + 0.12 * (1.0 - signal))

    def _weak_signal_penalty(self, profile: CardProfile, signal: float, fact_extractability: float) -> float:
        """弱信号惩罚：保留风险意识，但不让它一票否决小型结果卡。"""
        if signal < 0.20:
            penalty = 0.34
        elif signal < 0.35:
            penalty = 0.20
        else:
            penalty = 0.08
        if fact_extractability >= 0.70 and profile.rows <= 12:
            penalty *= 0.55
        if profile.chart_type in {"scatter", "line"} and signal < 0.30:
            penalty += 0.10
        return clip01(penalty)

    def _card_risk(self, profile: CardProfile, weak_signal: float) -> float:
        """综合信息卡风险：拥挤、变换成本、失真和弱信号。"""
        return clip01(
            0.35 * self._clutter_risk(profile)
            + 0.25 * profile.transform_cost
            + 0.25 * self._distortion_risk(profile)
            + 0.15 * weak_signal
        )

    def _clutter_risk(self, profile: CardProfile) -> float:
        """过多类别/点位会让图和信息卡都难以稳定总结。"""
        risk = 0.0
        if profile.chart_type == "bar":
            risk += 0.40 if profile.x_cardinality > 24 else 0.18 if profile.x_cardinality > 14 else 0.0
        elif profile.chart_type == "line":
            risk += 0.38 if profile.rows > 160 else 0.16 if profile.rows > 80 else 0.0
        elif profile.chart_type == "scatter":
            risk += 0.35 if profile.rows > 1000 else 0.18 if profile.rows > 500 else 0.0
        elif profile.chart_type == "boxplot" and profile.x_cardinality > 12:
            risk += 0.32
        risk += 0.16 if profile.avg_label_len > 28 else 0.06 if profile.avg_label_len > 18 else 0.0
        risk += min(0.18, profile.missing_ratio * 0.35)
        return clip01(risk)

    def _distortion_risk(self, profile: CardProfile) -> float:
        """估计从 support table 抽事实时可能产生的摘要失真。"""
        risk = 0.08 if profile.has_aggregation else 0.02
        if profile.transform_steps >= 4:
            risk += 0.12
        if profile.rows <= 2:
            risk += 0.08
        if profile.chart_type == "scatter" and profile.rows < 8:
            risk += 0.20
        return clip01(risk)

    def _format_reasons(self, details: Mapping[str, Any]) -> List[str]:
        """生成短审计原因，避免把所有中间项都塞进日志。"""
        return [
            f"card_value={float(details.get('chart_information_value') or 0.0):.2f}",
            f"fact_extractability={float(details.get('fact_extractability') or 0.0):.2f}",
            f"pattern_signal={float(details.get('perceptual_signal_gain') or 0.0):.2f}",
            f"non_visual_baseline={float(details.get('non_visual_baseline') or 0.0):.2f}",
            f"card_risk={float(details.get('visual_cost') or 0.0):.2f}",
            f"dominant_representation={str(details.get('dominant_representation') or '')}",
        ]
