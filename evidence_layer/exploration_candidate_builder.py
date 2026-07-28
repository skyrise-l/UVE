"""Candidate construction for the *next-question* exploration system.

This module does not support the current Insight.  It turns computed frontier plans and,
when necessary, unexecuted schema opportunities into compact candidates for the central
manager.

Benchmark policies are intentionally different:
- InsightBench / single-table tasks keep the original single-table schema fallback.
- BIRD treats PK/FK Join expansion as the primary schema-driven mechanism.  A standalone
  single-table schema card is used only as a last fallback when neither computed evidence
  nor a Join opportunity is available.
"""

from __future__ import annotations

import re
from typing import Any, Callable, Dict, List, Mapping, Sequence

from chart_extract.common import all_slots, plan_score
from chart_extract.plan_selection import select_frontier_plan_set
from chart_extract.visual_fact_extractor import build_visual_card_text
from evidence_layer.exploration_quality import (
    evaluate_materialized_exploration,
    precheck_exploration_plan,
)
from evidence_layer.evidence_contracts import (
    EXECUTION_RECOVERY_PROVENANCE,
    EXPLORATION_ROLE,
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
    SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE,
    TRACE_FRONTIER_PROVENANCE,
    is_bird_task,
)
from evidence_layer.route_gate import (
    canonical_exploration_provenance,
    exploration_route_decision,
    summarize_route_decisions,
)
from vis_project_utils.utils import truncate_text

Plan = Mapping[str, Any]


class ExplorationCandidateBuilder:
    """Select and package candidates used only to generate later questions."""

    def __init__(self, owner: Any) -> None:
        self.owner = owner
        self.last_route_gate_audit: Dict[str, Any] = {}
        self.last_quality_audit: Dict[str, Any] = {
            "precheck_rejections": [],
            "materialized_rejections": [],
        }

    def select_plans(
        self,
        *,
        scored_trace_plans: Sequence[Plan],
        scored_join_plans: Sequence[Plan],
        answer_plans: Sequence[Plan],
    ) -> List[Dict[str, Any]]:
        """Select computed exploration plans from Trace and Join expansion sources."""
        decisions = []
        candidates = []
        precheck_rejections: List[Dict[str, Any]] = []
        channel_items = [
            *((plan, TRACE_FRONTIER_PROVENANCE) for plan in list(scored_trace_plans or [])),
            *((plan, JOIN_PROBE_PROVENANCE) for plan in list(scored_join_plans or [])),
        ]
        for plan, expected_provenance in channel_items:
            item = dict(plan)
            item["evidence_role"] = EXPLORATION_ROLE
            canonical = canonical_exploration_provenance(item)
            # Attach missing provenance from the explicit architectural channel, not from
            # generic plan fields.  Contradictory provenance is left intact so the gate
            # can reject the channel mismatch.
            if not canonical:
                item["provenance"] = expected_provenance
            else:
                item["provenance"] = canonical
            decision = exploration_route_decision(
                item, expected_provenance=expected_provenance
            )
            decisions.append(decision)
            if decision.get("allowed"):
                item["provenance"] = expected_provenance
                quality = precheck_exploration_plan(item)
                if quality.allowed:
                    candidates.append(item)
                else:
                    precheck_rejections.append({
                        "plan_id": str(item.get("plan_id") or ""),
                        "title": str(item.get("title") or item.get("pattern") or ""),
                        **quality.to_dict(),
                    })
        self.last_route_gate_audit = summarize_route_decisions(decisions)
        self.last_quality_audit = {
            "precheck_rejections": precheck_rejections,
            "materialized_rejections": [],
        }
        selected = select_frontier_plan_set(
            candidates,
            answer_plans=answer_plans,
            # Materialized quality checks happen after selection because they need the
            # support dataframe.  Select a small reserve so one bad materialized plan
            # does not consume the entire local frontier budget.
            max_frontiers=max(
                self.owner.max_frontiers,
                min(self.owner.max_frontiers * 2, self.owner.max_frontiers + 3),
            ),
        )
        for plan in selected:
            join_probe = bool(plan.get("join_probe"))
            plan["evidence_role"] = EXPLORATION_ROLE
            plan["provenance"] = JOIN_PROBE_PROVENANCE if join_probe else TRACE_FRONTIER_PROVENANCE
        return selected

    def build(
        self,
        *,
        evidence_profile: Mapping[str, Any] | None,
        frontier_plans: Sequence[Plan],
        materialize_df: Callable[[Plan], Any] | None,
    ) -> List[Dict[str, Any]]:
        """Build local candidates under the benchmark-specific exploration policy."""
        computed = self._computed_visual_candidates(frontier_plans, materialize_df)
        if is_bird_task(self.owner.task):
            return self._build_bird_candidates(evidence_profile, computed)
        return self._build_single_table_candidates(evidence_profile, computed)

    def build_error(
        self,
        *,
        evidence_profile: Mapping[str, Any] | None,
        error_card: str,
    ) -> List[Dict[str, Any]]:
        """Build recovery candidates without turning execution failure into a finding."""
        candidates = [{
            "id": "execution_recovery",
            "kind": "recovery",
            "candidate_group": "recovery",
            "title": "Execution recovery",
            "evidence": truncate_text(error_card, 1000),
            "unresolved_part": "The failed computation must be repaired or reformulated before it can support a new analytical conclusion.",
            "columns": [],
            "utility": 0.50,
            "evidence_role": EXPLORATION_ROLE,
            "provenance": EXECUTION_RECOVERY_PROVENANCE,
        }]

        if is_bird_task(self.owner.task):
            join_candidates = self._join_opportunity_candidates(evidence_profile, has_join_visual=False)
            candidates.extend(join_candidates)
            if not join_candidates:
                candidates.extend(self._schema_fallback_candidates(evidence_profile, utility=0.34))
            return candidates

        candidates.extend(self._schema_fallback_candidates(evidence_profile, utility=0.38))
        return candidates

    def _build_bird_candidates(
        self,
        evidence_profile: Mapping[str, Any] | None,
        computed: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """BIRD：同时暴露已计算信号和当前 trace 附近的连接可能。

        Join Opportunity 不再拥有固定名额，也不与任务级 retrieval 构成层级关系。
        它只是当前局部位置可用的连接能力：这里生成少量候选，批次级全局选择器会在
        同一路径已经形成更具体 retrieval card 时删除通用 Join 卡，再统一比较效用。
        """
        candidates = list(computed)
        has_join_visual = any(
            item.get("provenance") == JOIN_PROBE_PROVENANCE
            for item in candidates
        )
        current_join_signatures = {
            str(item.get("signature") or "").strip()
            for item in candidates
            if item.get("provenance") == JOIN_PROBE_PROVENANCE
            and str(item.get("signature") or "").strip()
        }
        candidates.extend(
            self._join_opportunity_candidates(
                evidence_profile,
                has_join_visual=has_join_visual,
                exclude_signatures=current_join_signatures,
            )
        )
        if candidates:
            return candidates
        return self._schema_fallback_candidates(evidence_profile, utility=0.34)

    def _build_single_table_candidates(
        self,
        evidence_profile: Mapping[str, Any] | None,
        computed: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """InsightBench: preserve the original visual + schema exploration behavior."""
        candidates = list(computed)
        candidates.extend(self._schema_fallback_candidates(evidence_profile, utility=0.42))
        return candidates

    def _computed_visual_candidates(
        self,
        frontier_plans: Sequence[Plan],
        materialize_df: Callable[[Plan], Any] | None,
    ) -> List[Dict[str, Any]]:
        candidates: List[Dict[str, Any]] = []
        if materialize_df is None:
            return candidates

        materialized_rejections: List[Dict[str, Any]] = []
        for plan in list(frontier_plans or []):
            support_df = materialize_df(plan)
            quality = evaluate_materialized_exploration(plan, support_df)
            if not quality.allowed:
                materialized_rejections.append({
                    "plan_id": str(plan.get("plan_id") or ""),
                    "title": str(plan.get("title") or plan.get("pattern") or ""),
                    **quality.to_dict(),
                })
                continue
            card = build_visual_card_text(
                selected_plans=[plan],
                materialize_df=lambda _plan, cached=support_df: cached,
                card_prefix="Exploration Frontier",
            )
            if not card:
                continue
            join_probe = dict(plan.get("join_probe") or {})
            join_note = str(join_probe.get("note") or "").strip()
            evidence_text = card if not join_note else f"{join_note}\n{card}"
            provenance = JOIN_PROBE_PROVENANCE if join_probe else TRACE_FRONTIER_PROVENANCE
            columns = self._plan_columns(plan)
            join_context = dict(join_probe.get("context") or {})
            observed_pattern = self._card_field(card, "Observed pattern")
            unresolved_part = self._card_field(card, "Unresolved part")
            candidate = {
                "id": str(plan.get("plan_id") or f"visual_{len(candidates) + 1}"),
                "kind": "join_visual" if join_probe else "visual",
                "candidate_group": "computed_signal",
                "title": str(plan.get("title") or plan.get("pattern") or "Visual exploration signal"),
                "evidence": truncate_text(evidence_text, 1100),
                "observed_pattern": observed_pattern,
                "unresolved_part": unresolved_part,
                "support_summary": str(quality.details.get("support_summary") or ""),
                "columns": columns,
                "utility": round(plan_score(plan, purpose="exploration"), 6),
                "evidence_role": EXPLORATION_ROLE,
                "provenance": provenance,
                "exploration_signature": self._candidate_signature(
                    group="computed_signal",
                    title=str(plan.get("pattern") or plan.get("title") or "visual"),
                    columns=columns,
                ),
                **({"signature": str(join_probe.get("signature") or "")} if join_probe else {}),
                **({"join_context": join_context} if join_probe else {}),
            }
            candidates.append(self._enrich_candidate(candidate))
            if len(candidates) >= int(self.owner.max_frontiers):
                break
        self.last_quality_audit = {
            **dict(self.last_quality_audit or {}),
            "materialized_rejections": materialized_rejections,
            "selected_plan_reserve": int(len(list(frontier_plans or []))),
            "accepted_computed_candidates": int(len(candidates)),
        }
        return candidates

    def _join_opportunity_candidates(
        self,
        evidence_profile: Mapping[str, Any] | None,
        *,
        has_join_visual: bool,
        exclude_signatures: Sequence[str] = (),
    ) -> List[Dict[str, Any]]:
        items = self.owner._join_frontier_candidates(
            evidence_profile,
            has_join_visual=has_join_visual,
            exclude_signatures=exclude_signatures,
        )
        out: List[Dict[str, Any]] = []
        for raw in list(items or []):
            item = dict(raw or {})
            item["candidate_group"] = "new_direction"
            item["evidence_role"] = EXPLORATION_ROLE
            item["provenance"] = JOIN_OPPORTUNITY_PROVENANCE
            columns = [str(value) for value in list(item.get("columns") or []) if str(value).strip()][:6]
            item["columns"] = columns
            item.setdefault("available_direction", str(item.get("title") or "Join expansion"))
            item.setdefault(
                "why_it_may_matter",
                "The relationship may expose a relevant analytical dimension that is absent from the current table-level result.",
            )
            item.setdefault(
                "concrete_analysis",
                "Materialize the declared join safely, report join coverage, preserve the seed-table grain, and then compare the newly available non-key attributes.",
            )
            join_signature = str(item.get("signature") or "").strip()
            item["exploration_signature"] = (
                f"new_direction|join|{join_signature}"
                if join_signature
                else self._candidate_signature(
                    group="new_direction",
                    title=str(item.get("available_direction") or item.get("title") or "join opportunity"),
                    columns=columns,
                )
            )
            out.append(self._enrich_candidate(item))
        return out

    def _schema_fallback_candidates(
        self,
        evidence_profile: Mapping[str, Any] | None,
        *,
        utility: float,
    ) -> List[Dict[str, Any]]:
        cards = self.owner._schema_frontier_cards(evidence_profile)
        candidates: List[Dict[str, Any]] = []
        for index, block in enumerate(self._split_cards(cards), start=1):
            title = self._card_title(block)
            columns = self._card_columns(block)
            candidate = {
                "id": f"schema_frontier_{index}",
                "kind": "schema",
                "candidate_group": "new_direction",
                "title": title,
                "evidence": truncate_text(block, 900),
                "available_direction": self._card_field(block, "Available direction") or title,
                "why_it_may_matter": self._card_field(block, "Why it may matter"),
                "concrete_analysis": self._card_field(block, "Concrete analysis"),
                "columns": columns,
                "utility": float(utility),
                "evidence_role": EXPLORATION_ROLE,
                "provenance": SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE,
                "exploration_signature": self._candidate_signature(
                    group="new_direction",
                    title=title,
                    columns=columns,
                ),
            }
            candidates.append(self._enrich_candidate(candidate))
        return candidates

    def _enrich_candidate(self, candidate: Mapping[str, Any]) -> Dict[str, Any]:
        """Apply the benchmark plug-in without coupling generic construction to BIRD."""
        policy = getattr(self.owner, "exploration_policy", None)
        if policy is None or not hasattr(policy, "enrich_candidate"):
            return dict(candidate or {})
        return dict(policy.enrich_candidate(candidate))

    def _plan_columns(self, plan: Plan) -> List[str]:
        out: List[str] = []
        seen = set()
        for value in all_slots(plan).values():
            text = str(value or "").strip()
            key = text.lower()
            if text and key not in seen:
                seen.add(key)
                out.append(text)
        return out[:6]

    def _split_cards(self, cards: str) -> List[str]:
        return [block.strip() for block in str(cards or "").split("\n\n") if block.strip()]

    def _card_title(self, card: str) -> str:
        first = str(card or "").splitlines()[0].strip() if str(card or "").strip() else "Schema exploration signal"
        return first.strip("[] ") or "Schema exploration signal"

    def _card_columns(self, card: str) -> List[str]:
        match = re.search(r"^Use columns:\s*(.+)$", str(card or ""), flags=re.MULTILINE)
        if not match:
            return []
        return [
            item.strip()
            for item in match.group(1).split(",")
            if item.strip() and item.strip() != "available columns"
        ][:6]

    def _card_field(self, card: str, label: str) -> str:
        match = re.search(
            rf"^{re.escape(str(label))}:\s*(.+)$",
            str(card or ""),
            flags=re.MULTILINE,
        )
        return str(match.group(1) or "").strip() if match else ""

    def _candidate_signature(self, *, group: str, title: str, columns: Sequence[str]) -> str:
        if group == "computed_signal":
            normalized_columns = sorted({
                self._canonical_computed_column(value)
                for value in columns
                if str(value).strip()
            })
        else:
            normalized_columns = sorted({str(value).strip().lower() for value in columns if str(value).strip()})
        normalized_title = re.sub(r"[^a-z0-9]+", "_", str(title or "").lower()).strip("_")
        return f"{group}|{normalized_title}|{'|'.join(normalized_columns)}"

    def _canonical_computed_column(self, value: Any) -> str:
        text = str(value or "").strip().lower()
        tokens = {token for token in re.split(r"[^a-z0-9]+", text) if token}
        if tokens & {"count", "cnt", "frequency", "freq"}:
            return "<count>"
        if tokens & {"proportion", "share", "percentage", "percent", "pct", "ratio", "rate"}:
            return "<rate>"
        if tokens & {"date", "time", "timestamp", "week", "month", "quarter", "year"}:
            return "<time>"
        return text
