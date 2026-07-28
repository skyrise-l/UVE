"""chart_extract 包。

当前包分为两层：
- plan_selection：渲染前的组图选择；
- visual_fact_extractor：渲染后的辅助观察提取。
"""

from .plan_selection import select_visual_plan_set
from .visual_fact_extractor import Observation, build_auxiliary_observation_text

__all__ = [
    "Observation",
    "select_visual_plan_set",
    "build_auxiliary_observation_text",
]
