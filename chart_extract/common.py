"""chart_extract/common.py
-------------------------
图表抽取模块的公共小工具。

本文件只放当前代码链路中反复需要的轻量函数：
1. 读取 VisualPlan 的核心字段；
2. 判断图表所属的抽象分析族；
3. 生成组图选择时使用的语义去重键；
4. 读取 ranking / gate 分数。

设计原则：
- 只支持当前 evidence_layer 生成的 VisualPlan 结构；
- 不保留旧字段兼容分支；
- 不在这里实现选择算法或视觉事实提取算法。
"""

from __future__ import annotations

import math
from typing import Any, Dict, Mapping, Optional, Tuple

Plan = Mapping[str, Any]


def make_hashable(value: Any) -> Any:
    """把 list/dict 等嵌套值转成可哈希结构。

    图选择阶段会把语义 key 放进 set。如果槽位或 transform 中混入 list/dict，
    原来会触发 ``unhashable type`` 并中断视觉链路。这里统一转成稳定 tuple，
    不改变原始 plan，只保证去重 key 可用。
    """
    if isinstance(value, Mapping):
        return tuple(sorted((str(k), make_hashable(v)) for k, v in value.items()))
    if isinstance(value, (list, tuple, set)):
        return tuple(make_hashable(item) for item in value)
    return value


# 当前模板、pattern、chart_type 到抽象分析族的映射。
# selector 用它判断组图覆盖，extractor 用它选择事实提取函数。
TEMPLATE_FAMILY: Dict[str, str] = {
    "distribution_box": "group_distribution",
    "trend_line": "time_trend",
    "comparison_bar": "ranked_group_value",
    "count_by_group": "ranked_group_value",
    "relation_scatter": "relationship",
    "heatmap_pivot": "matrix_contrast",
}

PATTERN_FAMILY: Dict[str, str] = {
    "category_count_distribution": "ranked_group_value",
    "category_metric_comparison": "ranked_group_value",
    "ranking_or_extreme": "ranked_group_value",
    "time_trend": "time_trend",
    "trend_or_change": "time_trend",
    "grouped_time_trend": "time_trend",
    "relationship": "relationship",
    "relationship_or_association": "relationship",
    "distribution_spread": "group_distribution",
    "distribution_shape": "group_distribution",
    "group_difference": "group_distribution",
    "matrix_contrast": "matrix_contrast",
    "interaction_pattern": "matrix_contrast",
}

CHART_FAMILY: Dict[str, str] = {
    "bar": "ranked_group_value",
    "line": "time_trend",
    "scatter": "relationship",
    "boxplot": "group_distribution",
    "heatmap": "matrix_contrast",
}


def clip01(value: Any) -> float:
    """把数值压到 [0, 1]；非法值按 0 处理。"""
    number = safe_float(value)
    if number is None:
        return 0.0
    return max(0.0, min(1.0, number))


def safe_float(value: Any) -> Optional[float]:
    """安全转有限 float；缺失、NaN、inf 时返回 None。"""
    try:
        if value is None:
            return None
        # Avoid importing pandas here; ``value != value`` catches numpy NaN while
        # conversion below safely rejects ``pd.NA``.
        number = float(value)
    except Exception:
        return None
    if not math.isfinite(number):
        return None
    return number


def source_tid(plan: Plan) -> str:
    """读取当前 VisualPlan 的数据源表 id。"""
    return str((plan or {}).get("source_tid") or "")


def chart_type_of(plan: Plan) -> str:
    """读取当前 VisualPlan 的图形类型。"""
    encoding = dict((plan or {}).get("encoding") or {})
    return str(encoding.get("chart_type") or "")


def all_slots(plan: Plan) -> Dict[str, Any]:
    """读取当前 VisualPlan 的槽位，并补齐 extractor 常用别名。"""
    encoding = dict((plan or {}).get("encoding") or {})
    slots: Dict[str, Any] = dict(encoding.get("slots") or {})

    # template_slots 是 generator 当前输出的一部分，不是旧兼容字段。
    # 它能保留 group/metric/time 等原始模板语义，便于事实提取。
    template_slots = (plan or {}).get("template_slots")
    if isinstance(template_slots, Mapping):
        for key, value in dict(template_slots).items():
            slots.setdefault(key, value)

    alias_pairs = [
        ("group", "x"),
        ("category", "x"),
        ("time", "x"),
        ("date", "x"),
        ("metric", "y"),
        ("value", "y"),
        ("count", "y"),
        ("y_metric", "y"),
        ("x_metric", "x"),
    ]
    for src, dst in alias_pairs:
        if src in slots and dst not in slots:
            slots[dst] = slots[src]
    return slots


def slot(slots: Mapping[str, Any], *names: str) -> Optional[str]:
    """按候选名称顺序读取第一个非空槽位。"""
    for name in names:
        value = slots.get(name)
        if value is not None and value != "":
            return str(value)
    return None


def transform_key(plan: Plan) -> str:
    """生成当前 VisualPlan 的 transform 签名，用于去重。"""
    transform = dict((plan or {}).get("transform") or {})
    return repr(make_hashable(list(transform.get("ops") or [])))


def template_family(plan: Plan) -> str:
    """识别 plan 对应的抽象分析族。"""
    template_id = str((plan or {}).get("template_id") or "")
    if template_id in TEMPLATE_FAMILY:
        return TEMPLATE_FAMILY[template_id]

    pattern = str((plan or {}).get("pattern") or "")
    if pattern in PATTERN_FAMILY:
        return PATTERN_FAMILY[pattern]

    chart_type = chart_type_of(plan)
    if chart_type in CHART_FAMILY:
        return CHART_FAMILY[chart_type]

    return ""


def plan_score(plan: Plan, purpose: str = "answer") -> float:
    """读取视觉计划在指定用途下的 Utility 分数。

    `purpose="answer"` 用于当前 Insight 证据选择；
    `purpose="exploration"` 用于后续探索证据选择。
    """
    key = "exploration_utility" if str(purpose).lower() == "exploration" else "answer_utility"
    utility = dict((plan or {}).get(key) or {})
    return clip01(utility.get("score"))


def gate(plan: Plan, name: str) -> Dict[str, Any]:
    """读取指定 gate；不存在时返回空 dict。"""
    gates = dict((plan or {}).get("gates") or {})
    value = gates.get(name)
    return dict(value) if isinstance(value, Mapping) else {}


def gate_margin(plan: Plan, name: str) -> float:
    """读取 gate margin。"""
    return float(safe_float(gate(plan, name).get("margin")) or 0.0)


def positive_gate_margin(plan: Plan, name: str, scale: float = 0.30) -> float:
    """把正向 gate margin 映射到 [0, 1]。"""
    margin = max(0.0, gate_margin(plan, name))
    return clip01(margin / max(scale, 1e-9))


def representation_details(plan: Plan) -> Dict[str, Any]:
    """读取 L3 representation gate 的 details。"""
    details = gate(plan, "representation").get("details")
    return dict(details) if isinstance(details, Mapping) else {}


def is_emit_chart(plan: Plan) -> bool:
    """判断 plan 是否通过 score_visual_plans 的最终准入。"""
    admission = dict((plan or {}).get("admission") or {})
    return bool(admission.get("admitted")) and str(admission.get("decision") or "") == "emit_chart"


def semantic_key(plan: Plan) -> Tuple[Any, ...]:
    """生成语义去重键：同一数据关系只保留一张代表图。"""
    slots = all_slots(plan)
    return (
        source_tid(plan),
        transform_key(plan),
        template_family(plan),
        make_hashable(slot(slots, "x", "category", "group", "time")),
        make_hashable(slot(slots, "y", "value", "metric", "count")),
        make_hashable(slot(slots, "series", "facet", "hue")),
    )


def metric_key(plan: Plan) -> Tuple[Any, ...]:
    """生成指标去重键：避免同一指标被多张近似图反复表达。"""
    slots = all_slots(plan)
    return (
        source_tid(plan),
        make_hashable(slot(slots, "y", "value", "metric", "count", "y_metric")),
    )
