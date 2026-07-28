"""pattern_signal.py
-------------------
L2 和 L3 共享的证据模式信号计算模块。

设计原则
========
- 这里只判断数据里有没有某类“可感知模式”：差异、趋势、相关、分布差别等；
- L2 把它当作 evidence grounding 的一部分；
- L3 把它当作 visual salience / perceptual gain 的基础；
- 因此这里不决定“是否画图”，也不关心表格/文本 baseline。
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Dict, List, Mapping

import numpy as np
import pandas as pd

from vis_project_utils.utils import clip01, safe_to_numeric
from vis_project_utils.dataframe_safety import safe_hashable_dataframe, safe_nunique


@dataclass
class PatternSignal:
    """某个 evidence pattern 在 support table 中的强弱。"""

    score: float
    reasons: List[str]
    metrics: Dict[str, float]

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def compute_pattern_signal(df: pd.DataFrame, plan: Mapping[str, Any]) -> PatternSignal:
    """根据 plan 的 pattern/slots 计算统一的数据模式信号。"""

    if not isinstance(df, pd.DataFrame) or df.empty:
        return PatternSignal(0.0, ["support dataframe missing or empty"], {})

    pattern = str(plan.get("pattern") or "")
    slots = dict((dict(plan.get("encoding") or {}).get("slots") or {}))
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    value = str(slots.get("value") or "")

    if pattern in {"category_count_distribution", "category_metric_comparison", "topk_ranking"}:
        return category_signal(df, x, y)
    if pattern in {"time_trend", "grouped_time_trend"}:
        return trend_signal(df, x, y)
    if pattern == "relationship":
        return relationship_signal(df, x, y)
    if pattern == "distribution_spread":
        return distribution_signal(df, x, y)
    if pattern == "interaction_pattern":
        return matrix_signal(df, value)
    return PatternSignal(0.35, ["no specialized pattern signal scorer"], {"fallback_signal": 0.35})


def category_signal(df: pd.DataFrame, x: str, y: str) -> PatternSignal:
    """类别比较/排序/频数分布的视觉信号。"""

    if y not in df.columns:
        return PatternSignal(0.10, ["missing y for category signal"], {})
    values = safe_to_numeric(df[y]).dropna().abs()
    if len(values) < 2:
        return PatternSignal(0.08, ["too few numeric values for category signal"], {})

    mean = float(values.mean())
    median = float(values.median())
    std = float(values.std(ddof=0)) if len(values) > 1 else 0.0
    cv = std / max(1e-9, mean) if mean else 0.0
    max_ratio = float(values.max() / max(1e-9, median if median else mean)) if (median or mean) else 0.0

    sorted_values = values.sort_values(ascending=False).to_numpy(dtype=float)
    top_gap = 0.0
    if len(sorted_values) >= 2 and sorted_values[0] != 0:
        top_gap = float((sorted_values[0] - sorted_values[1]) / max(1e-9, sorted_values[0]))

    if values.sum() > 0:
        probs = values / values.sum()
        entropy = float(-(probs * np.log(probs + 1e-12)).sum() / max(1e-9, np.log(len(probs)))) if len(probs) > 1 else 0.0
        concentration = 1.0 - entropy
    else:
        concentration = 0.0

    score = clip01(
        0.34 * min(cv / 1.20, 1.0)
        + 0.28 * min(max_ratio / 3.0, 1.0)
        + 0.24 * top_gap
        + 0.14 * concentration
    )
    metrics = {
        "coefficient_of_variation": cv,
        "max_to_median_ratio": max_ratio,
        "top1_top2_gap": top_gap,
        "concentration": concentration,
    }
    reasons = [f"{key}={value:.2f}" for key, value in metrics.items()]
    return PatternSignal(score, reasons, metrics)


def trend_signal(df: pd.DataFrame, x: str, y: str) -> PatternSignal:
    """趋势图的视觉信号：方向一致性、端点变化和线性相关。"""

    if y not in df.columns or len(df) < 3:
        return PatternSignal(0.08, ["too few points for trend signal"], {})
    values = safe_to_numeric(df[y]).dropna().to_numpy(dtype=float)
    if len(values) < 3:
        return PatternSignal(0.08, ["too few numeric points for trend signal"], {})

    idx = np.arange(len(values), dtype=float)
    corr = abs(float(np.corrcoef(idx, values)[0, 1])) if np.std(values) > 0 else 0.0
    baseline = abs(values[0]) if values[0] != 0 else float(np.mean(np.abs(values)) + 1e-9)
    change = abs(float(values[-1] - values[0]) / max(1e-9, baseline))
    diffs = np.diff(values)
    expected_up = values[-1] >= values[0]
    direction = float(np.mean(diffs >= 0) if expected_up else np.mean(diffs <= 0)) if len(diffs) else 0.0
    volatility = float(np.std(diffs) / max(1e-9, np.std(values))) if len(diffs) and np.std(values) else 0.0

    score = clip01(0.42 * corr + 0.28 * min(change, 1.0) + 0.20 * direction + 0.10 * min(volatility / 1.2, 1.0))
    metrics = {
        "trend_correlation": corr,
        "relative_change": change,
        "direction_consistency": direction,
        "volatility_shape": volatility,
    }
    reasons = [f"{key}={value:.2f}" for key, value in metrics.items()]
    return PatternSignal(score, reasons, metrics)


def relationship_signal(df: pd.DataFrame, x: str, y: str) -> PatternSignal:
    """散点关系图的视觉信号：相关性、样本充分性和异常点。"""

    if x not in df.columns or y not in df.columns:
        return PatternSignal(0.05, ["missing x/y for relationship signal"], {})
    xx = safe_to_numeric(df[x])
    yy = safe_to_numeric(df[y])
    valid = pd.DataFrame({"x": xx, "y": yy}).dropna()
    if len(valid) < 8:
        return PatternSignal(0.08, ["too few valid points for relationship signal"], {"valid_points": float(len(valid))})

    corr = abs(float(valid["x"].corr(valid["y"]))) if valid["x"].std() and valid["y"].std() else 0.0
    sample_bonus = min(1.0, np.log1p(len(valid)) / np.log1p(120.0))
    z_x = (valid["x"] - valid["x"].mean()) / max(1e-9, float(valid["x"].std(ddof=0)))
    z_y = (valid["y"] - valid["y"].mean()) / max(1e-9, float(valid["y"].std(ddof=0)))
    outlier_ratio = float(((z_x.abs() > 2.5) | (z_y.abs() > 2.5)).mean())
    outlier_signal = min(outlier_ratio / 0.08, 1.0)

    score = clip01(0.62 * corr + 0.23 * sample_bonus + 0.15 * outlier_signal)
    metrics = {
        "absolute_correlation": corr,
        "sample_adequacy": sample_bonus,
        "outlier_signal": outlier_signal,
        "valid_points": float(len(valid)),
    }
    reasons = [f"{key}={value:.2f}" for key, value in metrics.items()]
    return PatternSignal(score, reasons, metrics)


def distribution_signal(df: pd.DataFrame, x: str, y: str) -> PatternSignal:
    """分布差异图的视觉信号：组间位置差异、样本充分性和异常值。"""

    if x not in df.columns or y not in df.columns:
        return PatternSignal(0.05, ["missing x/y for distribution signal"], {})
    values = safe_to_numeric(df[y])
    valid = pd.DataFrame({"group": df[x], "value": values}).dropna()
    safe_valid = safe_hashable_dataframe(valid, ["group"])
    if len(safe_valid) < 8 or safe_nunique(safe_valid["group"], dropna=False) < 2:
        return PatternSignal(0.10, ["too few values or groups for distribution signal"], {"valid_points": float(len(valid))})

    group_count = safe_nunique(safe_valid["group"], dropna=False)
    overall_std = float(valid["value"].std(ddof=0)) if valid["value"].std(ddof=0) else 0.0
    if overall_std <= 0:
        return PatternSignal(0.10, ["zero spread distribution"], {"group_count": float(group_count)})

    medians = safe_valid.groupby("group", dropna=False)["value"].median()
    median_gap = float((medians.max() - medians.min()) / max(1e-9, overall_std)) if len(medians) else 0.0
    group_sizes = safe_valid.groupby("group", dropna=False).size()
    sample_adequacy = float((group_sizes >= 3).mean()) if len(group_sizes) else 0.0
    z = (valid["value"] - valid["value"].mean()) / max(1e-9, overall_std)
    outlier_signal = min(float((z.abs() > 2.5).mean()) / 0.08, 1.0)

    score = clip01(0.45 * min(median_gap / 2.0, 1.0) + 0.35 * sample_adequacy + 0.20 * outlier_signal + 0.04 * min(group_count / 8.0, 1.0))
    metrics = {
        "group_count": float(group_count),
        "median_gap_over_std": median_gap,
        "sample_adequacy": sample_adequacy,
        "outlier_signal": outlier_signal,
    }
    reasons = [f"{key}={value:.2f}" for key, value in metrics.items()]
    return PatternSignal(score, reasons, metrics)


def matrix_signal(df: pd.DataFrame, value: str) -> PatternSignal:
    """热力图/矩阵图的视觉信号。"""

    if value not in df.columns:
        return PatternSignal(0.20, ["missing value for matrix signal"], {})
    values = safe_to_numeric(df[value]).dropna()
    if len(values) < 4:
        return PatternSignal(0.15, ["too few values for matrix signal"], {})
    mean = float(values.mean())
    cv = float(values.std(ddof=0) / max(1e-9, abs(mean))) if mean else 0.0
    score = clip01(0.35 + 0.65 * min(cv / 1.2, 1.0))
    metrics = {"matrix_value_cv": cv}
    return PatternSignal(score, [f"matrix_value_cv={cv:.2f}"], metrics)
