"""chart_extract/plan_selection.py
---------------------------------
组图选择层：在有限视觉预算下，从已通过 gate 的候选图中选择一组最值得渲染的图。

本层发生在渲染之前，只回答一个问题：
    哪一组图一起最能覆盖当前证据、减少重复、提高 answer 层理解？

它不负责：
- 生成候选图；
- 计算 L1/L2/L3；
- 渲染图像；
- 从图里抽取文字事实。

本文件当前包含两类 selector：
- ``select_visual_plan_set``：回答分支，优先选择最能支撑当前轮 insight 的图；
- ``select_frontier_plan_set``：探索分支，允许弱化对当前问题的直接对齐，优先选择更可能启发下一轮探索的问题方向的图。

和 score_visual_plans 的关系：
- score_visual_plans admits plans using hard structure/evidence/representation gates;
- 本文件只在 admitted 图中做组图级筛选；
- L3 不在这里重新定义，只读取 card utility margin 作为选择信号；
- 第一张图不追求多样性，只选单图价值最高、最贴近 stage_result 的候选；
- 后续图优先补充新的 insight_role，避免多张图只支持同一种结论。
"""

from __future__ import annotations

from collections import Counter
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from .common import (
    Plan,
    all_slots,
    chart_type_of,
    clip01,
    is_emit_chart,
    metric_key,
    plan_score,
    positive_gate_margin,
    representation_details,
    semantic_key,
    slot,
    source_tid,
    template_family,
)


def select_visual_plan_set(
    scored_plans: Iterable[Plan],
    *,
    max_charts: int = 4,
    analysis_tendency: Optional[Sequence[Mapping[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """从 scored_plans 中选择一组互补图表。

    参数说明：
    - ``scored_plans``：score_visual_plans 的完整输出；
    - ``max_charts``：最多允许渲染几张图；
    - ``analysis_tendency``：当前轮分析倾向，可为空。为空时只依赖 plan 自身信号。

    返回值：
    - selected plans 的浅拷贝；
    - 每个被选 plan 会附加一个很小的 ``selection`` 字段，便于审计；
    - 不返回未选候选，避免中间结果膨胀。
    """
    limit = max(1, int(max_charts or 1))
    tendency_types = _tendency_types(analysis_tendency)

    eligible = [dict(plan) for plan in list(scored_plans or []) if is_emit_chart(plan)]
    eligible = _merge_semantic_duplicates(eligible)
    if not eligible:
        return []

    selected: List[Dict[str, Any]] = []
    remaining: List[Dict[str, Any]] = sorted(
        eligible,
        key=lambda item: (_individual_value(item), plan_score(item)),
        reverse=True,
    )

    # 第一张图代表本轮最主要的视觉事实来源，只按单图价值选。
    # 多样性和 coverage 从第二张图开始再考虑。
    first = remaining.pop(0)
    first_value = _individual_value(first)
    first = dict(first)
    first["selection"] = {
        "rank": 1,
        "marginal_gain": round(float(first_value), 4),
        "individual_value": round(float(first_value), 4),
        "coverage_gain": 0.0,
        "redundancy_penalty": 0.0,
        "visual_cost": round(float(_visual_cost(first)), 4),
        "insight_role": _insight_role(first),
    }
    selected.append(first)

    while remaining and len(selected) < limit:
        best_index = -1
        best_gain = -10**9
        best_parts: Dict[str, float] = {}

        for index, plan in enumerate(remaining):
            if _violates_simple_caps(plan, selected):
                continue
            gain, parts = _marginal_gain(plan, selected, tendency_types)
            if gain > best_gain:
                best_index = index
                best_gain = gain
                best_parts = parts

        if best_index < 0:
            break

        # 后续图必须有正的新增价值；第一张已经在循环外确定。
        if best_gain <= 0.05:
            break

        chosen = dict(remaining.pop(best_index))
        chosen["selection"] = {
            "rank": len(selected) + 1,
            "marginal_gain": round(float(best_gain), 4),
            **{key: round(float(value), 4) for key, value in best_parts.items()},
            "insight_role": _insight_role(chosen),
        }
        selected.append(chosen)

    return selected


def select_frontier_plan_set(
    scored_plans: Iterable[Plan],
    *,
    answer_plans: Optional[Sequence[Plan]] = None,
    max_frontiers: int = 3,
) -> List[Dict[str, Any]]:
    """选择一小组探索型图表计划。

    设计目标：
    1. frontier 图不必直接服务当前 round question；
    2. 但它必须有真实数据支撑，并且图本身应能表达清楚的结构性信息；
    3. QEP analysis tendency is only a ranking preference; frontier still requires
       reliable sanity / evidence / representation signals.

    输入：
    - ``scored_plans``：score_visual_plans 的完整输出；
    - ``answer_plans``：回答分支已选图，作为软重复参照，不做硬排除；
    - ``max_frontiers``：最多保留几张 frontier 图；
    """
    limit = max(0, int(max_frontiers or 0))
    if limit <= 0:
        return []

    answer_plans = list(answer_plans or [])
    eligible: List[Dict[str, Any]] = []
    for plan in list(scored_plans or []):
        if not _is_frontier_candidate(plan):
            continue
        # Answer 和 Exploration 是两个用途不同的选择头。同一视觉证据既可能
        # 支撑当前 Insight，也可能暴露值得继续追问的差异，因此不在这里硬排除。
        # 与 Answer 已选计划的重复度由后面的 reference redundancy 软惩罚处理。
        eligible.append(dict(plan))

    eligible = _merge_semantic_duplicates(eligible)
    if not eligible:
        return []

    selected: List[Dict[str, Any]] = []
    remaining: List[Dict[str, Any]] = sorted(
        eligible,
        key=lambda item: (_frontier_individual_value(item), plan_score(item, purpose="exploration")),
        reverse=True,
    )

    reference = list(answer_plans)
    while remaining and len(selected) < limit:
        best_index = -1
        best_gain = -10**9
        best_parts: Dict[str, float] = {}

        for index, plan in enumerate(remaining):
            if _violates_simple_caps(plan, selected):
                continue
            gain, parts = _frontier_marginal_gain(plan, selected, reference)
            if gain > best_gain:
                best_index = index
                best_gain = gain
                best_parts = parts

        if best_index < 0:
            break
        if selected and best_gain <= 0.05:
            break

        chosen = dict(remaining.pop(best_index))
        chosen["selection"] = {
            "rank": len(selected) + 1,
            "marginal_gain": round(float(best_gain), 4),
            **{key: round(float(value), 4) for key, value in best_parts.items()},
            "insight_role": _insight_role(chosen),
        }
        selected.append(chosen)

    return selected


def _is_frontier_candidate(plan: Plan) -> bool:
    """判断一个候选图是否适合进入 frontier 分支。

    frontier plans may have low QEP preference because QEP never gates admission.
    To avoid unsupported divergence, frontier still requires:
    - sanity 通过；
    - frontier_evidence 通过；
    - representation 通过。

    frontier_evidence 是比 answer L2 更宽的门：它允许 raw/source table，
    但要求任务锚点、真实列绑定和数据信号能共同支撑下一轮探索。
    """
    gates = dict((plan or {}).get("gates") or {})
    sanity_gate = dict(gates.get("sanity") or {})
    frontier_gate = dict(gates.get("frontier_evidence") or {})
    representation_gate = dict(gates.get("representation") or {})
    return bool(
        sanity_gate.get("passed")
        and frontier_gate.get("passed")
        and representation_gate.get("passed")
    )


def _frontier_marginal_gain(
    plan: Plan,
    selected: Sequence[Plan],
    reference: Sequence[Plan],
) -> Tuple[float, Dict[str, float]]:
    """计算 frontier 图加入当前集合后的边际收益。"""
    individual = _frontier_individual_value(plan)
    coverage = _frontier_coverage_gain(plan, selected, reference)
    redundancy = _frontier_redundancy_penalty(plan, selected, reference)
    cost = _visual_cost(plan)
    gain = individual + coverage - redundancy - 0.10 * cost
    return gain, {
        "individual_value": individual,
        "coverage_gain": coverage,
        "redundancy_penalty": redundancy,
        "visual_cost": cost,
    }


def _frontier_individual_value(plan: Plan) -> float:
    """估计单张 frontier 图的探索价值。

    和回答分支不同，这里弱化 analysis alignment，
    强调 evidence support、representation utility 和图本身的可读性。
    """
    ranking = plan_score(plan, purpose="exploration")
    evidence_margin = positive_gate_margin(plan, "frontier_evidence")
    representation_margin = positive_gate_margin(plan, "representation")
    simplicity = 1.0 - _visual_cost(plan)
    return clip01(
        0.28 * ranking
        + 0.42 * evidence_margin
        + 0.22 * representation_margin
        + 0.08 * simplicity
    )




def _plan_slot_columns(plan: Plan) -> List[str]:
    """提取 plan 里代表分析轴的列名，用于历史重复惩罚。"""
    slots = all_slots(plan)
    out: List[str] = []
    for name in [
        slot(slots, "x", "category", "group", "time", "date", "x_metric"),
        slot(slots, "y", "value", "metric", "count", "y_metric"),
        slot(slots, "series", "facet", "hue"),
        slot(slots, "value"),
    ]:
        text = str(name or "").strip()
        if text and text not in out:
            out.append(text)
    return out


def _frontier_coverage_gain(
    plan: Plan,
    selected: Sequence[Plan],
    reference: Sequence[Plan],
) -> float:
    """奖励 frontier 图相对已有 answer 图和已选 frontier 图带来的新角度。"""
    compared = list(reference) + list(selected)
    if not compared:
        return 0.0

    family = template_family(plan)
    chart_type = chart_type_of(plan)
    metric = metric_key(plan)
    source = source_tid(plan)
    compared_families = {template_family(item) for item in compared}
    compared_chart_types = {chart_type_of(item) for item in compared}
    compared_metrics = {metric_key(item) for item in compared}
    compared_sources = {source_tid(item) for item in compared}
    compared_roles = {_insight_role(item) for item in compared}
    role = _insight_role(plan)

    gain = 0.0
    if role and role not in compared_roles:
        gain += 0.20
    if family and family not in compared_families:
        gain += 0.12
    if chart_type and chart_type not in compared_chart_types:
        gain += 0.10
    if metric not in compared_metrics:
        gain += 0.08
    if source and source not in compared_sources:
        gain += 0.04
    return gain


def _frontier_redundancy_penalty(
    plan: Plan,
    selected: Sequence[Plan],
    reference: Sequence[Plan],
) -> float:
    """惩罚 frontier 图与 answer 图/已选 frontier 图表达重复。"""
    compared = list(reference) + list(selected)
    if not compared:
        return 0.0

    penalty = 0.0
    family = template_family(plan)
    chart_type = chart_type_of(plan)
    metric = metric_key(plan)
    source = source_tid(plan)
    slots = all_slots(plan)
    y = slot(slots, "y", "metric", "value", "count", "y_metric")

    for item in compared:
        item_slots = all_slots(item)
        item_y = slot(item_slots, "y", "metric", "value", "count", "y_metric")
        if semantic_key(plan) == semantic_key(item):
            penalty += 1.00
        if metric == metric_key(item):
            penalty += 0.30
        if source and source == source_tid(item) and y and y == item_y:
            penalty += 0.22
        if family and family == template_family(item):
            penalty += 0.10
        if chart_type and chart_type == chart_type_of(item):
            penalty += 0.06
        if _insight_role(plan) == _insight_role(item):
            penalty += 0.12

    return penalty


def _merge_semantic_duplicates(plans: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """合并表达同一数据关系的图，只保留组图价值最高的一张。"""
    best: Dict[Tuple[Any, ...], Dict[str, Any]] = {}
    for plan in plans:
        key = semantic_key(plan)
        if key not in best or _individual_value(plan) > _individual_value(best[key]):
            best[key] = plan
    return list(best.values())


def _marginal_gain(
    plan: Plan,
    selected: Sequence[Plan],
    tendency_types: Sequence[str],
) -> Tuple[float, Dict[str, float]]:
    """计算把 plan 加入当前组图后的边际收益。"""
    individual = _individual_value(plan)
    coverage = _coverage_gain(plan, selected, tendency_types)
    redundancy = _redundancy_penalty(plan, selected)
    cost = _visual_cost(plan)
    gain = individual + coverage - redundancy - 0.15 * cost
    return gain, {
        "individual_value": individual,
        "coverage_gain": coverage,
        "redundancy_penalty": redundancy,
        "visual_cost": cost,
    }


def _individual_value(plan: Plan) -> float:
    """单图基础价值。

    ranking 已经以严格 answer L2 为主；这里再次提高 evidence margin，
    让第一张图优先选择最贴近当前 stage_result 的结果视图。
    """
    ranking = plan_score(plan)
    evidence_margin = positive_gate_margin(plan, "evidence")
    representation_margin = positive_gate_margin(plan, "representation")
    simplicity = 1.0 - _visual_cost(plan)
    return clip01(
        0.40 * ranking
        + 0.36 * evidence_margin
        + 0.20 * representation_margin
        + 0.04 * simplicity
    )


def _coverage_gain(plan: Plan, selected: Sequence[Plan], tendency_types: Sequence[str]) -> float:
    """奖励新图带来的覆盖增量。"""
    if not selected:
        return 0.0

    family = template_family(plan)
    chart_type = chart_type_of(plan)
    metric = metric_key(plan)
    source = source_tid(plan)
    selected_families = {template_family(item) for item in selected}
    selected_chart_types = {chart_type_of(item) for item in selected}
    selected_metrics = {metric_key(item) for item in selected}
    selected_roles = {_insight_role(item) for item in selected}
    role = _insight_role(plan)

    gain = 0.0
    if role and role not in selected_roles:
        gain += 0.22
    if family and family not in selected_families:
        gain += 0.12
    if chart_type and chart_type not in selected_chart_types:
        gain += 0.10
    if metric not in selected_metrics:
        gain += 0.06
    # 不奖励换 source。text-only 信息卡更重视同一 stage_result 上的补充事实，
    # 避免为了多样性把远离结果的原始表拉进来。

    # 当前轮分析倾向只作为轻量加分，不让 selector 变成复杂 planner。
    if tendency_types and _plan_hits_uncovered_tendency(plan, selected, tendency_types):
        gain += 0.03

    return gain


def _redundancy_penalty(plan: Plan, selected: Sequence[Plan]) -> float:
    """惩罚与已选图表达重复的候选图。"""
    if not selected:
        return 0.0

    penalty = 0.0
    family = template_family(plan)
    chart_type = chart_type_of(plan)
    metric = metric_key(plan)
    source = source_tid(plan)
    slots = all_slots(plan)
    y = slot(slots, "y", "metric", "value", "count", "y_metric")

    for item in selected:
        item_slots = all_slots(item)
        item_y = slot(item_slots, "y", "metric", "value", "count", "y_metric")

        if semantic_key(plan) == semantic_key(item):
            penalty += 1.00
        if metric == metric_key(item):
            penalty += 0.28
        if source and source == source_tid(item) and y and y == item_y:
            penalty += 0.25
        if family and family == template_family(item):
            penalty += 0.10
        if chart_type and chart_type == chart_type_of(item):
            penalty += 0.06
        if _insight_role(plan) == _insight_role(item):
            penalty += 0.12

    return penalty



def _insight_role(plan: Plan) -> str:
    """把候选图映射成它最可能支持的结论类型。

    这个角色只用于组图互补选择，不进入复杂任务规划。目标是让同一轮多张图
    覆盖不同结论维度，而不是只在图型或字段层面看起来多样。

    这里优先看字段语义，再看图表族：location、condition、entity drilldown 这类
    benchmark 常见 gold facet 如果只按 chart_type 会被合并成普通 bar，因此单独识别。
    """
    family = template_family(plan)
    chart_type = chart_type_of(plan)
    columns = " ".join(_plan_slot_columns(plan)).lower()

    if _has_any(columns, ["location", "country", "city", "region", "site", "area"]):
        return "location_breakdown"
    if _has_any(columns, ["leave", "pto", "during", "before", "after", "state", "status", "priority", "open", "closed"]):
        return "condition_comparison"
    if _has_any(columns, ["description", "comment", "reason", "cause", "resolution", "keyword", "term"]):
        return "text_reason"
    if family == "time_trend" or chart_type == "line":
        return "trend_or_stability"
    if family == "relationship" or chart_type == "scatter":
        return "relationship"
    if family == "matrix_contrast" or chart_type == "heatmap":
        return "matrix_contrast"
    if family == "group_distribution":
        return "distribution_shape"
    if family == "ranked_group_value":
        return "topk_concentration"
    return family or chart_type or "general"


def _has_any(text: str, hints: Sequence[str]) -> bool:
    """判断字段串是否包含任一语义提示词。"""
    return any(hint in text for hint in hints)

def _visual_cost(plan: Plan) -> float:
    """估计信息卡风险。字段名沿用 visual_cost，实际含义来自 L3 card_risk。"""
    details = representation_details(plan)
    if "visual_cost" in details:
        return clip01(details.get("visual_cost"))

    costs = [
        details.get("clutter_risk"),
        details.get("transform_cost"),
        details.get("distortion_risk"),
    ]
    valid = [clip01(item) for item in costs if item is not None]
    return sum(valid) / len(valid) if valid else 0.20


def _violates_simple_caps(plan: Plan, selected: Sequence[Plan]) -> bool:
    """硬性上限：同一分析族、同一指标、同一图型最多各出现两次。

    这个限制很简单，但能有效避免一轮里全是 boxplot 或全是 line。
    如果某轮只有一种图型被 admitted，那么 selector 仍会选择最多 2 张，
    防止后续辅助观察被同质图淹没。
    """
    family_counts = Counter(template_family(item) for item in selected)
    metric_counts = Counter(metric_key(item) for item in selected)
    chart_type_counts = Counter(chart_type_of(item) for item in selected)
    role_counts = Counter(_insight_role(item) for item in selected)
    family = template_family(plan)
    metric = metric_key(plan)
    chart_type = chart_type_of(plan)
    role = _insight_role(plan)
    return bool(
        (family and family_counts[family] >= 2)
        or metric_counts[metric] >= 2
        or (chart_type and chart_type_counts[chart_type] >= 2)
        or (role and role_counts[role] >= 2)
    )


def _tendency_types(analysis_tendency: Optional[Sequence[Mapping[str, Any]]]) -> List[str]:
    """提取当前轮分析倾向类型。"""
    out: List[str] = []
    for item in list(analysis_tendency or []):
        if isinstance(item, Mapping):
            name = str(item.get("type") or "").strip()
            if name:
                out.append(name)
    return out


def _plan_hits_uncovered_tendency(
    plan: Plan,
    selected: Sequence[Plan],
    tendency_types: Sequence[str],
) -> bool:
    """判断候选图是否命中当前组图尚未覆盖的分析倾向。"""
    supported = {str(item) for item in list((plan or {}).get("supported_tendencies") or [])}
    if not supported:
        return False

    covered = set()
    for item in selected:
        covered.update(str(x) for x in list((item or {}).get("supported_tendencies") or []))

    target = set(tendency_types)
    return bool((supported & target) - covered)
