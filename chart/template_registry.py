"""template_registry.py
----------------------

运行时视觉计划模板注册表。

这里复用旧版 chart 目录里“固定模板 + 槽位绑定”的思想，但不迁移
离线 bank、query keyword 检索或复杂 warm-start 逻辑。

模板只描述一类候选图计划需要哪些槽位、对应什么图型、默认执行哪些
数据变换，以及它通常能服务哪些查询分析方向。真正的列绑定发生在
slot_binding.py 中，查询相关性由效用 L1 处理。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List


@dataclass(frozen=True)
class ViewTemplate:
    """一个受控的候选图计划模板。

    字段说明
    ----
    template_id:
        模板唯一标识。
    view_family:
        更抽象的候选视图族，用于和 analysis_tendency 对齐。
    chart_type:
        渲染层支持的图类型。
    pattern:
        暂时保留的旧字段，供现有 L2/L3/日志阅读使用。
    required_slots:
        必须绑定成功的槽位，例如 group/metric/time/x_metric/y_metric。
    supported_tendencies:
        这个模板通常能支持的查询分析方向。它不是 query keyword，
        而是供 L1 使用的固定映射。
    op_template:
        抽象 transform 模板，里面用 $slot 占位，真正生成计划时再替换成列名。
    prior:
        模板本身的弱先验，用于槽位绑定排序，不替代效用评分。
    """

    template_id: str
    view_family: str
    chart_type: str
    pattern: str
    required_slots: List[str]
    supported_tendencies: List[str]
    op_template: List[Dict[str, Any]] = field(default_factory=list)
    prior: float = 0.5
    summary: str = ""


def build_default_templates() -> List[ViewTemplate]:
    """返回当前运行时启用的核心模板。

    第一版只启用渲染和效用层已经能稳定处理的模板。高级的 heatmap、
    pair gap、wide trend 暂时不迁入，避免一次重构面过大。
    """

    return [
        ViewTemplate(
            template_id="count_by_group",
            view_family="group_difference",
            chart_type="bar",
            pattern="category_count_distribution",
            required_slots=["group"],
            supported_tendencies=[
                "overview",
                "group_difference",
                "ranking_or_extreme",
                "composition_or_proportion",
            ],
            op_template=[
                {"op": "value_counts", "column": "$group", "output": "count"},
                {"op": "sort_by", "column": "count", "ascending": False},
                {"op": "top_k", "k": 20},
            ],
            prior=0.82,
            summary="统计单个类别列的频数分布。",
        ),
        ViewTemplate(
            template_id="comparison_bar",
            view_family="group_difference",
            chart_type="bar",
            pattern="category_metric_comparison",
            required_slots=["group", "metric"],
            supported_tendencies=[
                "overview",
                "group_difference",
                "ranking_or_extreme",
                "factor_explanation",
            ],
            # comparison_bar 的最终 ops 由 generator 根据表是否已经聚合来决定，
            # 因此这里不写死 groupby_agg。
            op_template=[],
            prior=0.78,
            summary="比较不同类别上的数值指标。",
        ),
        ViewTemplate(
            template_id="trend_line",
            view_family="trend_or_change",
            chart_type="line",
            pattern="time_trend",
            required_slots=["time", "metric"],
            supported_tendencies=[
                "trend_or_change",
                "anomaly_or_outlier",
                "overview",
            ],
            op_template=[
                {"op": "groupby_agg", "by": ["$time"], "value": "$metric", "agg": "mean", "output": "$metric"},
                {"op": "sort_by", "column": "$time", "ascending": True},
            ],
            prior=0.80,
            summary="沿时间或阶段顺序观察数值指标变化。",
        ),
        ViewTemplate(
            template_id="relation_scatter",
            view_family="relationship_or_association",
            chart_type="scatter",
            pattern="relationship",
            required_slots=["x_metric", "y_metric"],
            supported_tendencies=[
                "relationship_or_association",
                "factor_explanation",
            ],
            op_template=[
                {"op": "use_columns", "columns": ["$x_metric", "$y_metric"]},
            ],
            prior=0.76,
            summary="观察两个数值变量之间的关系。",
        ),
        ViewTemplate(
            template_id="distribution_box",
            view_family="distribution_shape",
            chart_type="boxplot",
            pattern="distribution_spread",
            required_slots=["group", "metric"],
            supported_tendencies=[
                "distribution_shape",
                "group_difference",
                "anomaly_or_outlier",
            ],
            op_template=[
                {"op": "use_columns", "columns": ["$group", "$metric"]},
            ],
            prior=0.62,
            summary="比较不同类别下数值变量的分布差异。",
        ),
    ]
