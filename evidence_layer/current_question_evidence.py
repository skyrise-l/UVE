"""Evidence path for answering the currently selected analysis question.

This path is intentionally narrow:
- inputs are the current Question Evidence Profile, stage result and Trace-grounded
  visual plans;
- no unexecuted schema or Join opportunity is allowed;
- Join probes are exploration-only and are never passed into this organizer.

Question Evidence Profile alignment is an auxiliary ranking preference in the shared
scoring layer.  It never filters a plan.  The organizer only packages computed evidence
for the Insight interpreter.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, Mapping, Sequence

from chart_extract.plan_selection import select_visual_plan_set
from chart_extract.visual_fact_extractor import build_visual_card_text
from evidence_layer.evidence_contracts import CURRENT_QUESTION_ROLE, TRACE_RESULT_PROVENANCE
from evidence_layer.route_gate import answer_route_decision, summarize_route_decisions

Plan = Mapping[str, Any]


class CurrentQuestionEvidenceOrganizer:
    """Select and package evidence that directly answers the current question."""

    def __init__(self, owner: Any) -> None:
        self.owner = owner
        self.last_route_gate_audit: Dict[str, Any] = {}

    def select_plans(
        self,
        *,
        scored_trace_plans: Sequence[Plan],
        analysis_tendency: Sequence[Mapping[str, Any]],
    ) -> tuple[list[Dict[str, Any]], str]:
        """Select Answer plans only from the current execution Trace.

        The explicit ``scored_trace_plans`` argument is an architectural boundary:
        callers cannot accidentally pass computed Join probes or schema opportunities
        into the current Insight evidence path.
        """
        decisions = []
        eligible = []
        for plan in list(scored_trace_plans or []):
            item = dict(plan)
            decision = answer_route_decision(item)
            decisions.append(decision)
            if decision.get("allowed"):
                eligible.append(item)
        self.last_route_gate_audit = summarize_route_decisions(decisions)
        selected = select_visual_plan_set(
            eligible,
            max_charts=self.owner.max_charts,
            analysis_tendency=analysis_tendency,
        )
        status = "selected"
        if not selected:
            selected = self.owner._recall_visual_plans(
                scored_plans=eligible,
                analysis_tendency=analysis_tendency,
            )
            status = "selected_by_recall" if selected else "no_answer_visual_plan"

        for plan in selected:
            plan["evidence_role"] = CURRENT_QUESTION_ROLE
            plan["provenance"] = TRACE_RESULT_PROVENANCE
        return selected, status

    def build(
        self,
        *,
        code_result: Dict[str, Any],
        evidence_profile: Mapping[str, Any] | None,
        selected_answer_plans: Sequence[Plan],
        materialize_df: Callable[[Plan], Any] | None,
    ) -> Dict[str, str]:
        """Return the compact result and visual cards consumed by the Insight model."""
        result_cards = self.owner._build_result_evidence_cards(
            code_result=code_result,
            evidence_profile=evidence_profile,
        )
        chart_cards = ""
        if materialize_df is not None:
            chart_cards = build_visual_card_text(
                selected_plans=selected_answer_plans,
                materialize_df=materialize_df,
                card_prefix="Answer Chart",
            )
        return {
            "answer_evidence_cards": self.owner._join_card_blocks(chart_cards, result_cards),
        }
