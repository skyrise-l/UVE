"""chart/specs.py
----------------
图表渲染层支持的最小图型规范。
"""

SUPPORTED_CHARTS = {
    "bar": {"required_slots": ["x", "y"], "optional_slots": [], "suitable_patterns": ["category_count_distribution", "category_metric_comparison", "topk_ranking"]},
    "line": {"required_slots": ["x", "y"], "optional_slots": ["group"], "suitable_patterns": ["time_trend", "grouped_time_trend"]},
    "scatter": {"required_slots": ["x", "y"], "optional_slots": ["group"], "suitable_patterns": ["relationship"]},
    "boxplot": {"required_slots": ["x", "y"], "optional_slots": [], "suitable_patterns": ["distribution_spread"]},
    "heatmap": {"required_slots": ["x", "y", "value"], "optional_slots": [], "suitable_patterns": ["interaction_pattern"]},
}


def is_supported_chart(chart_type: str) -> bool:
    return str(chart_type or "") in SUPPORTED_CHARTS


def required_slots(chart_type: str):
    return list(SUPPORTED_CHARTS.get(str(chart_type or ""), {}).get("required_slots") or [])
