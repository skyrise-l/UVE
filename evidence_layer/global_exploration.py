"""跨分支全局探索候选选择。

该模块把当前批次各问题分支产生的已计算信号，与任务级 retrieval frontier 产生的
未执行方向合并后做小预算选择。全局选择只区分“已计算信号”和“未执行方向”的
证据状态，不再根据 Join、表级方向或 retrieval subtype 设置固定名额。
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set

from evidence_layer.benchmark_exploration import DefaultExplorationPolicy
from evidence_layer.evidence_contracts import (
    GOAL_RETRIEVAL_PROVENANCE,
    JOIN_OPPORTUNITY_PROVENANCE,
)
from vis_project_utils.utils import clip01, truncate_text

class GlobalExplorationSelector:
    """在小预算内选择互补的已计算信号和未执行方向。"""

    def __init__(self, *, max_candidates: int = 4, policy: Optional[Any] = None) -> None:
        self.max_candidates = max(0, int(1 if max_candidates is None else max_candidates))
        self.policy = policy or DefaultExplorationPolicy()
        # 只有真正成功执行的普通方向才视为已消费。Retrieval direction 是否完成
        # 由成功 trace 中的实际列使用决定，不在这里维护第二套状态。
        self._seen_direction_signatures: Set[str] = set()

    def select(
        self,
        branch_records: Sequence[Mapping[str, Any]],
        *,
        extra_candidates: Sequence[Mapping[str, Any]] = (),
    ) -> List[Dict[str, Any]]:
        """合并分支候选和任务级候选，然后执行全局边际选择。

        ``extra_candidates`` 用于批次级 retrieval frontier。它们不绑定某个 sibling
        question，因此不会被伪装成分支记录，也不会写入 round_history。
        """
        if self.max_candidates <= 0:
            return []

        pool = self._build_pool(branch_records, extra_candidates=extra_candidates)
        if not pool:
            return []

        policy_selected = self.policy.select_global(
            pool,
            max_candidates=self.max_candidates,
            select_pool=self._select_pool,
        )
        if policy_selected is not None:
            return list(policy_selected)[: self.max_candidates]

        # 容量是上限，不是类型配额。已计算信号、未执行方向和恢复候选在同一个
        # 边际效用过程中竞争；证据状态仍保留在 candidate_group 中供提示格式化。
        return self._select_pool(
            pool,
            limit=self.max_candidates,
            min_gain_after_first=0.08,
        )

    def mark_successful_directions(self, used_candidates: Sequence[Mapping[str, Any]]) -> None:
        """只记录已经成功执行的普通未执行方向。

        Retrieval direction 不在这里退休：它必须等到真实 trace 使用了相应业务列，
        才会由 RetrievalFrontierBuilder 的 explored_columns 自然停止生成。
        """
        for item in list(used_candidates or []):
            if str(item.get("candidate_group") or "") != "new_direction":
                continue
            provenance = str(item.get("provenance") or "")
            if provenance in {GOAL_RETRIEVAL_PROVENANCE, JOIN_OPPORTUNITY_PROVENANCE}:
                # Join Opportunity 是否真正消费由 EvidenceOrganizer 对照成功 trace 的
                # 实际源表判断，不能只因问题引用了该卡片就退休路径。
                continue
            signature = str(item.get("exploration_signature") or "").strip()
            if signature:
                self._seen_direction_signatures.add(signature)

    def _build_pool(
        self,
        branch_records: Sequence[Mapping[str, Any]],
        *,
        extra_candidates: Sequence[Mapping[str, Any]],
    ) -> List[Dict[str, Any]]:
        """把两种来源规范成同一个最小候选池，并按签名去重。"""
        pool: List[Dict[str, Any]] = []
        used_ids: Set[str] = set()
        signature_positions: Dict[str, int] = {}

        # 同一路径已经由 retrieval 表列组合成具体分析时，通用 Join Opportunity
        # 不再重复进入全局池；不同路径的局部连接可能仍可与 retrieval 候选共同竞争。
        retrieval_join_signatures = {
            str(item.get("signature") or "").strip()
            for item in list(extra_candidates or [])
            if str(item.get("provenance") or "") == GOAL_RETRIEVAL_PROVENANCE
            and str(item.get("signature") or "").strip()
        }

        sources: List[tuple[str, str, Mapping[str, Any]]] = []
        for branch_index, record in enumerate(list(branch_records or []), start=1):
            question = str((record or {}).get("question") or "").strip()
            round_index = str((record or {}).get("round_index") or "").strip()
            prefix = f"r{round_index}" if round_index else f"b{branch_index}"
            for raw in list((record or {}).get("exploration_candidates") or []):
                if isinstance(raw, Mapping):
                    sources.append((prefix, question, raw))
        for raw in list(extra_candidates or []):
            if isinstance(raw, Mapping):
                sources.append(("task", "Original task goal", raw))

        for local_index, (prefix, source_question, raw) in enumerate(sources, start=1):
            candidate = dict(self.policy.enrich_candidate(raw))
            base_id = str(candidate.get("id") or f"candidate_{local_index}")
            candidate_id = f"{prefix}:{base_id}"
            if candidate_id in used_ids:
                continue
            used_ids.add(candidate_id)

            candidate_group = str(candidate.get("candidate_group") or "").strip()
            if not candidate_group:
                kind = str(candidate.get("kind") or "visual")
                candidate_group = (
                    "new_direction"
                    if kind in {"schema", "join_opportunity", "retrieval"}
                    else "computed_signal"
                )

            exploration_signature = str(candidate.get("exploration_signature") or "").strip()
            join_signature = str(candidate.get("signature") or "").strip()
            if (
                str(candidate.get("provenance") or "") == JOIN_OPPORTUNITY_PROVENANCE
                and join_signature in retrieval_join_signatures
            ):
                continue
            dedupe_signature = exploration_signature or join_signature
            if (
                candidate_group == "new_direction"
                and exploration_signature
                and exploration_signature in self._seen_direction_signatures
            ):
                continue

            item = {
                "id": candidate_id,
                "kind": str(candidate.get("kind") or "visual"),
                "candidate_group": candidate_group,
                "title": str(candidate.get("title") or "Exploration signal"),
                "evidence": truncate_text(str(candidate.get("evidence") or ""), 1000),
                "observed_pattern": str(candidate.get("observed_pattern") or ""),
                "unresolved_part": str(candidate.get("unresolved_part") or ""),
                "support_summary": str(candidate.get("support_summary") or ""),
                "available_direction": str(candidate.get("available_direction") or ""),
                "why_it_may_matter": str(candidate.get("why_it_may_matter") or ""),
                "concrete_analysis": str(candidate.get("concrete_analysis") or ""),
                "columns": [
                    str(value)
                    for value in list(candidate.get("columns") or [])
                    if str(value).strip()
                ][:6],
                "utility": clip01(candidate.get("utility", 0.0)),
                "source_question": source_question,
                "evidence_role": str(candidate.get("evidence_role") or "exploration"),
                "provenance": str(candidate.get("provenance") or "unknown"),
                "candidate_subtype": str(candidate.get("candidate_subtype") or ""),
                "join_context": dict(candidate.get("join_context") or {}),
                **({"signature": join_signature} if join_signature else {}),
                **({"exploration_signature": exploration_signature} if exploration_signature else {}),
            }
            if dedupe_signature and dedupe_signature in signature_positions:
                existing_index = signature_positions[dedupe_signature]
                if float(item.get("utility") or 0.0) > float(pool[existing_index].get("utility") or 0.0):
                    pool[existing_index] = item
                continue
            if dedupe_signature:
                signature_positions[dedupe_signature] = len(pool)
            pool.append(item)
        return pool

    def _select_pool(
        self,
        candidates: Sequence[Mapping[str, Any]],
        *,
        limit: int,
        reference: Sequence[Mapping[str, Any]] | None = None,
        min_gain_after_first: float = 0.0,
    ) -> List[Dict[str, Any]]:
        """使用局部效用和集合冗余做贪心选择。"""
        if limit <= 0:
            return []
        selected: List[Dict[str, Any]] = []
        reference_items = list(reference or [])
        remaining = sorted(
            [dict(item) for item in list(candidates or [])],
            key=lambda item: float(item.get("utility") or 0.0),
            reverse=True,
        )
        while remaining and len(selected) < limit:
            best_index = -1
            best_gain = -10**9
            for index, candidate in enumerate(remaining):
                gain = self._marginal_gain(candidate, [*reference_items, *selected])
                if gain > best_gain:
                    best_gain = gain
                    best_index = index
            if best_index < 0:
                break
            if selected and best_gain < float(min_gain_after_first):
                break
            chosen = dict(remaining.pop(best_index))
            chosen["global_utility"] = round(float(best_gain), 6)
            if chosen.get("candidate_group") == "new_direction":
                chosen["selection_reason"] = "high-utility unexecuted analytical direction"
            else:
                chosen["selection_reason"] = "high-utility computed pattern with unresolved explanation"
            selected.append(chosen)
        return selected

    def _marginal_gain(
        self,
        candidate: Mapping[str, Any],
        selected: Sequence[Mapping[str, Any]],
    ) -> float:
        """计算集合边际收益；未探索列不在这里加分。"""
        base = float(candidate.get("utility") or 0.0)
        if not selected:
            return base

        source_question = str(candidate.get("source_question") or "")
        source_bonus = 0.10 if source_question and source_question not in {
            str(item.get("source_question") or "") for item in selected
        } else 0.0
        max_similarity = max(self._similarity(candidate, item) for item in selected)
        return base + source_bonus - 0.42 * max_similarity

    def _similarity(self, left: Mapping[str, Any], right: Mapping[str, Any]) -> float:
        """同时比较方向文本和实际分析列，避免选择近重复卡片。"""
        left_terms = _terms(
            f"{left.get('title', '')} {left.get('observed_pattern', '')} "
            f"{left.get('unresolved_part', '')} {left.get('available_direction', '')} "
            f"{left.get('concrete_analysis', '')}"
        )
        right_terms = _terms(
            f"{right.get('title', '')} {right.get('observed_pattern', '')} "
            f"{right.get('unresolved_part', '')} {right.get('available_direction', '')} "
            f"{right.get('concrete_analysis', '')}"
        )
        text_similarity = _jaccard(left_terms, right_terms)
        left_columns = {
            str(item).lower() for item in list(left.get("columns") or []) if str(item).strip()
        }
        right_columns = {
            str(item).lower() for item in list(right.get("columns") or []) if str(item).strip()
        }
        column_similarity = _jaccard(left_columns, right_columns)
        return 0.65 * text_similarity + 0.35 * column_similarity


def format_global_exploration_evidence(
    candidates: Sequence[Mapping[str, Any]],
    *,
    policy: Optional[Any] = None,
) -> str:
    """按证据状态格式化为中央管理器可读的两类探索信息。"""
    computed_blocks: List[str] = []
    direction_blocks: List[str] = []
    recovery_blocks: List[str] = []

    items = list(candidates or [])
    resolved_policy = policy or DefaultExplorationPolicy()
    contextual_columns = _direction_context_columns(items)

    for item in items:
        columns = ", ".join(str(value) for value in list(item.get("columns") or [])) or "not specified"
        common = [
            f"[{item.get('id')}] {item.get('title')}",
            f"Provenance: {item.get('provenance')}",
            f"Source question: {truncate_text(str(item.get('source_question') or ''), 180)}",
            f"Columns: {columns}",
        ]
        group = str(item.get("candidate_group") or "")
        if group == "computed_signal":
            block = [
                *common,
                f"Observed pattern: {item.get('observed_pattern') or _field_from_evidence(item, 'Observed pattern')}",
                f"Unresolved part: {item.get('unresolved_part') or _field_from_evidence(item, 'Unresolved part')}",
            ]
            support = str(item.get("support_summary") or "").strip()
            if support:
                block.append(f"Support: {support}")
            own_columns = {
                str(value).strip().lower()
                for value in list(item.get("columns") or [])
                if str(value).strip()
            }
            drilldown_columns = [
                column for column in contextual_columns
                if column.lower() not in own_columns
            ][:4]
            if drilldown_columns:
                block.append(
                    "Available contextual columns: "
                    + ", ".join(drilldown_columns)
                    + " (schema-level options, not yet observed drivers)"
                )
            block.extend(resolved_policy.format_extra_lines(item))
            computed_blocks.append("\n".join(block))
        elif group == "new_direction":
            direction_block = [
                *common,
                f"Available direction: {item.get('available_direction') or item.get('title')}",
                f"Why it may matter: {item.get('why_it_may_matter') or _field_from_evidence(item, 'Why it may matter')}",
                f"Concrete analysis: {item.get('concrete_analysis') or _field_from_evidence(item, 'Concrete analysis')}",
            ]
            direction_block.extend(resolved_policy.format_extra_lines(item))
            direction_blocks.append("\n".join(direction_block))
        else:
            recovery_blocks.append(
                "\n".join([*common, f"Evidence: {truncate_text(str(item.get('evidence') or ''), 500)}"])
            )

    sections: List[str] = []
    if computed_blocks:
        sections.append("Computed visual signals for deeper analysis:\n" + "\n\n".join(computed_blocks))
    if direction_blocks:
        sections.append("Available different analytical directions:\n" + "\n\n".join(direction_blocks))
    if recovery_blocks:
        sections.append("Execution recovery evidence:\n" + "\n\n".join(recovery_blocks))
    guidance = str(resolved_policy.prompt_guidance(items) or "").strip()
    if guidance:
        sections.append(guidance)
    return "\n\n".join(sections)


def _field_from_evidence(item: Mapping[str, Any], label: str) -> str:
    match = re.search(
        rf"^{re.escape(label)}:\s*(.+)$",
        str(item.get("evidence") or ""),
        flags=re.MULTILINE,
    )
    return str(match.group(1) or "").strip() if match else "not specified"


def _direction_context_columns(candidates: Sequence[Mapping[str, Any]]) -> List[str]:
    """收集已选择未执行方向中的少量真实列，供 computed signal 作为上下文。"""
    out: List[str] = []
    seen: Set[str] = set()
    for item in list(candidates or []):
        if str(item.get("candidate_group") or "") != "new_direction":
            continue
        for value in list(item.get("columns") or []):
            text = str(value or "").strip()
            key = text.lower()
            if not text or key in seen:
                continue
            seen.add(key)
            out.append(text)
    return out[:8]


def _terms(text: str) -> Set[str]:
    expanded = str(text or "").replace("_", " ").replace("-", " ").lower()
    return set(re.findall(r"[a-z][a-z0-9]{2,}|[\u4e00-\u9fff]{2,}", expanded))


def _jaccard(left: Set[str], right: Set[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / max(1, len(left | right))
