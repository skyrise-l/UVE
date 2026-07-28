"""evidence_layer/schemas.py
---------------------------
证据层最小 schema 构造函数。为避免过度工程化，内部对象使用普通 dict。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional


def make_visual_plan(
    *,
    plan_id: str,
    source_table_node: str,
    source_tid: str,
    pattern: str,
    transform_ops: List[Dict[str, Any]],
    chart_type: str,
    slots: Dict[str, str],
    title: str = "",
    generation_reason: Optional[List[str]] = None,
    source_event_ids: Optional[List[int]] = None,
) -> Dict[str, Any]:
    """构造视觉证据计划。"""
    return {
        "plan_id": plan_id,
        "source_table_node": source_table_node,
        "source_tid": source_tid,
        "pattern": pattern,
        "title": title,
        "transform": {"ops": list(transform_ops or [])},
        "encoding": {"chart_type": chart_type, "slots": dict(slots or {})},
        "faithfulness": {
            "source": "veg_table",
            "source_event_ids": [int(item) for item in list(source_event_ids or []) if item is not None],
            "derived_from_existing_result": True,
        },
        "generation_reason": list(generation_reason or []),
    }


def make_rejected_plan(plan: Dict[str, Any], reasons: List[str]) -> Dict[str, Any]:
    """给被拒绝的计划附上拒绝原因。"""
    item = dict(plan or {})
    item["accepted"] = False
    item["reject_reason"] = list(reasons or [])
    return item
