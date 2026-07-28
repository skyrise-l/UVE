"""BIRD 多表探索候选的轻量策略。

该策略不再为 Join probe、Join Opportunity 或 retrieval direction 预留固定名额。
所有候选进入同一个全局边际选择过程；Join Engine 只提供真实连接、粒度和安全边界。
候选仍保留“已计算信号”和“未执行方向”的证据状态区别，避免把方向误写成发现。
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence

from evidence_layer.evidence_contracts import (
    GOAL_RETRIEVAL_PROVENANCE,
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
)


class BirdExplorationPolicy:
    """为 BIRD 候选补充稳定 subtype 和 Join 展示信息。"""

    benchmark = "bird"

    def __init__(self, config: Optional[Mapping[str, Any]] = None) -> None:
        self.config = dict(config or {})

    def enrich_candidate(self, candidate: Mapping[str, Any]) -> Dict[str, Any]:
        """根据证据来源标记 subtype，不改变候选分组或效用。"""
        item = dict(candidate or {})
        provenance = str(item.get("provenance") or "")
        kind = str(item.get("kind") or "")
        if provenance == JOIN_PROBE_PROVENANCE or kind == "join_visual":
            subtype = "join_probe"
        elif provenance == GOAL_RETRIEVAL_PROVENANCE or kind == "retrieval":
            subtype = "retrieval_direction"
        elif provenance == JOIN_OPPORTUNITY_PROVENANCE or kind == "join_opportunity":
            subtype = "join_opportunity"
        elif str(item.get("candidate_group") or "") == "computed_signal":
            subtype = "table_signal"
        elif str(item.get("candidate_group") or "") == "new_direction":
            subtype = "table_direction"
        else:
            subtype = kind or "other"
        item["candidate_subtype"] = subtype
        return item

    def select_global(
        self,
        pool: Sequence[Mapping[str, Any]],
        *,
        max_candidates: int,
        select_pool: Callable[..., List[Dict[str, Any]]],
    ) -> Optional[List[Dict[str, Any]]]:
        """不做类型配额，让通用选择器统一比较候选的效用与冗余。"""
        return None

    def format_extra_lines(self, candidate: Mapping[str, Any]) -> List[str]:
        """展示未执行/已执行状态及真实 Join 路径，供中央管理器安全生成问题。"""
        item = dict(candidate or {})
        context = dict(item.get("join_context") or {})
        if not context:
            return []

        status = str(context.get("status") or "")
        lines: List[str] = []
        if status == "executed":
            lines.append("Join status: executed exploration probe")
            coverage = context.get("coverage")
            if coverage is not None:
                try:
                    lines.append(f"Matched coverage: {float(coverage):.1%}")
                except (TypeError, ValueError):
                    pass
        else:
            lines.append("Join status: unexecuted schema-grounded direction; it is not a finding")

        path_text = str(context.get("path_text") or "").strip()
        grain_table = str(context.get("grain_table") or "").strip()
        edge_summaries = [
            str(value) for value in list(context.get("edge_summaries") or []) if str(value).strip()
        ]
        safe_use = str(context.get("safe_use") or "").strip()
        if path_text:
            lines.append(f"Join path: {path_text}")
        if grain_table:
            lines.append(f"Safe analysis grain: {grain_table}")
        if edge_summaries:
            lines.append("Declared keys: " + "; ".join(edge_summaries[:2]))
        if safe_use:
            lines.append("Join-use boundary: " + safe_use)
        if status == "executed":
            lines.append(
                "Interpretation boundary: the observed pattern applies to matched grain records; "
                "coverage and unmatched records may affect generalization."
            )
        return lines

    def prompt_guidance(self, candidates: Sequence[Mapping[str, Any]]) -> str:
        """只有候选含 Join 上下文时才追加多表安全提示。"""
        if not any(dict(item.get("join_context") or {}) for item in list(candidates or [])):
            return ""
        return (
            "BIRD multi-table guidance:\n"
            "* Treat executed Join probes as observed evidence only for their reported path, grain, and coverage.\n"
            "* Treat retrieval or Join directions as unexecuted analyses; execute them before drawing conclusions.\n"
            "* Ask for the comparison unlocked by the connected columns, not merely for a Join operation.\n"
            "* Preserve the stated grain and declared key path; avoid raw many-to-many expansion."
        )
