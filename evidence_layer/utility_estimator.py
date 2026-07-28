"""utility_estimator.py
---------------------
Visual-plan scoring and admission.

Hard admission is intentionally limited to executable structure, runtime evidence,
and representation quality.  QEP ``analysis_tendency`` is a bounded ranking preference
only: it never rejects a plan or changes a hard-gate threshold.  QEP ``evidence_focus``
remains a substantive semantic evidence contract: it may guide evidence-intent ranking
and frontier task relevance, but it can never substitute for runtime grounding.
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Sequence, Tuple

import pandas as pd

from analysis_tendency import normalize_analysis_tendency
from evidence_layer.utility_analysis_tendency import AnalysisTendencyAlignmentScorer
from evidence_layer.utility_encoding_advantage import VisualEncodingAdvantageScorer
from evidence_layer.utility_evidence_support import EvidenceSupportScorer
from evidence_layer.utility_evidence_intent import EvidenceIntentAlignmentScorer
from chart.specs import is_supported_chart, required_slots
from chart.transforms import apply_transform_ops
from vis_project_utils.utils import clip01
from vis_project_utils.dataframe_safety import safe_nunique


# Explicit caps make the soft-prior boundary auditable.  These weights may influence
# ordering among grounded candidates but cannot participate in admission.
QEP_ANSWER_RANKING_WEIGHT = 0.06
QEP_EXPLORATION_RANKING_WEIGHT = 0.03


class VisualPlanDecisionEstimator:
    """候选图 ranking + 最终 gate admission 的统一入口。"""

    def __init__(
        self,
        *,
        representation_gate_threshold: float = 0.50,
        min_evidence_support: float = 0.58,
        min_frontier_evidence_support: float = 0.42,
    ) -> None:
        self.analysis_tendency_scorer = AnalysisTendencyAlignmentScorer()
        self.evidence_support_scorer = EvidenceSupportScorer()
        self.encoding_advantage_scorer = VisualEncodingAdvantageScorer()
        self.evidence_intent_scorer = EvidenceIntentAlignmentScorer()
        self.online_prior = 0.5
        self.representation_gate_threshold = clip01(representation_gate_threshold)
        self.min_evidence_support = clip01(min_evidence_support)
        self.min_frontier_evidence_support = clip01(min_frontier_evidence_support)

    def score_plans(
        self,
        raw_plans: Sequence[Mapping[str, Any]],
        veg: Mapping[str, Any],
        analysis_tendency: Sequence[Mapping[str, Any]],
        artifact_store: Mapping[str, Any],
        evidence_profile: Mapping[str, Any] | None = None,
        task_anchor_text: str = "",
    ) -> List[Dict[str, Any]]:
        """对候选计划打分并排序。

        Ranking priority:
        1. plans passing hard structure/evidence/representation gates;
        2. answer utility, where QEP tendency has a small explicit weight;
        3. hard-gate margins;
        4. deterministic plan id tie-breaking only.
        """

        normalized_tendency = normalize_analysis_tendency(
            list(analysis_tendency or []),
            question_text=str(dict(evidence_profile or {}).get("round_question") or ""),
        )
        scored: List[Dict[str, Any]] = []
        for plan in list(raw_plans or []):
            sanity_gate, support_df = self._plan_sanity_gate(plan, veg, artifact_store)
            if not sanity_gate.get("passed"):
                scored.append(self._invalid_plan_item(plan, sanity_gate))
                continue

            try:
                l1, r1 = self.analysis_tendency_scorer.score(plan, normalized_tendency)
                l2, r2 = self.evidence_support_scorer.score(plan, veg, artifact_store)
                frontier_l2, frontier_r2 = self.evidence_support_scorer.score_frontier(
                    plan,
                    veg,
                    artifact_store,
                    task_anchor_text=task_anchor_text,
                )
                l3_result = self.encoding_advantage_scorer.score(plan, artifact_store)
                l3 = clip01(l3_result.get("score", 0.0))
                l3_details = dict(l3_result.get("details") or {})
                l3_reasons = list(l3_result.get("reasons") or [])
                intent_score, intent_reasons = self.evidence_intent_scorer.score(plan, evidence_profile)
                answer_contribution = self._answer_contribution_score(plan, l3_details, task_anchor_text=task_anchor_text)
                exploration_potential = self._exploration_potential_score(
                    l2=l2,
                    frontier_l2=frontier_l2,
                    l3=l3,
                    intent_score=intent_score,
                    l3_details=l3_details,
                )
                # QEP tendency is a threshold-free ranking preference.  It is kept
                # outside ``gates`` so it cannot accidentally become an admission rule.
                qep_preference = {
                    "score": float(l1),
                    "mode": "ranking_only",
                    "reasons": [
                        "QEP tendency affects ordering only; it cannot reject a plan or alter a hard threshold",
                        *list(r1 or []),
                    ],
                }

                # Answer Utility 强调当前问题的直接证据支撑和 Evidence Intent 对齐。
                answer_score = clip01(
                    QEP_ANSWER_RANKING_WEIGHT * l1
                    + 0.48 * l2
                    + 0.20 * l3
                    + 0.10 * intent_score
                    + 0.16 * answer_contribution
                )
                # Exploration Utility 使用更宽的 frontier 支撑，并奖励可形成后续问题的结构性信号。
                exploration_score = clip01(
                    QEP_EXPLORATION_RANKING_WEIGHT * l1
                    + 0.42 * frontier_l2
                    + 0.24 * l3
                    + 0.08 * intent_score
                    + 0.23 * exploration_potential
                )
                representation_threshold = self._dynamic_representation_threshold(plan, l3_details)

                evidence_gate = {
                    "score": float(l2),
                    "threshold": float(self.min_evidence_support),
                    "margin": float(l2 - self.min_evidence_support),
                    "passed": bool(l2 >= self.min_evidence_support),
                    "reasons": list(r2 or []),
                }
                frontier_evidence_gate = {
                    "score": float(frontier_l2),
                    "threshold": float(self.min_frontier_evidence_support),
                    "margin": float(frontier_l2 - self.min_frontier_evidence_support),
                    "passed": bool(frontier_l2 >= self.min_frontier_evidence_support),
                    "reasons": list(frontier_r2 or []),
                }
                representation_gate = {
                    "score": float(l3),
                    "threshold": float(representation_threshold),
                    "margin": float(l3 - representation_threshold),
                    "passed": bool(l3 >= representation_threshold),
                    "reasons": l3_reasons,
                    "details": l3_details,
                }
                admission = self._admission(sanity_gate, evidence_gate, representation_gate)

                item = dict(plan or {})
                item["answer_utility"] = {
                    "score": float(answer_score),
                    "breakdown": {
                        "qep_ranking_preference": float(l1),
                        "evidence_support": float(l2),
                        "card_utility": float(l3),
                        "evidence_intent_alignment": float(intent_score),
                        "answer_contribution": float(answer_contribution),
                    },
                    "reasons": [
                        f"answer_utility={answer_score:.2f}",
                        *list(intent_reasons or []),
                    ],
                }
                item["exploration_utility"] = {
                    "score": float(exploration_score),
                    "breakdown": {
                        "qep_ranking_preference": float(l1),
                        "frontier_support": float(frontier_l2),
                        "card_utility": float(l3),
                        "evidence_intent_alignment": float(intent_score),
                        "followup_potential": float(exploration_potential),
                    },
                    "reasons": [
                        f"exploration_utility={exploration_score:.2f}",
                        *list(intent_reasons or []),
                    ],
                }
                item["preferences"] = {"qep": qep_preference}
                item["gates"] = {
                    "sanity": sanity_gate,
                    "evidence": evidence_gate,
                    "frontier_evidence": frontier_evidence_gate,
                    "representation": representation_gate,
                }
                item["admission"] = admission
                scored.append(item)
            except Exception as exc:
                failed_gate = self._make_sanity_gate(
                    False,
                    [f"plan_scoring_failed:{type(exc).__name__}:{exc}"],
                )
                scored.append(self._invalid_plan_item(plan, failed_gate))

        scored.sort(key=self._sort_key, reverse=True)
        return scored

    def _sort_key(self, item: Mapping[str, Any]) -> tuple:
        admission = dict(item.get("admission") or {})
        answer_utility = dict(item.get("answer_utility") or {})
        gates = dict(item.get("gates") or {})
        evidence = dict(gates.get("evidence") or {})
        representation = dict(gates.get("representation") or {})
        sanity = dict(gates.get("sanity") or {})
        return (
            1 if admission.get("admitted") else 0,
            1 if sanity.get("passed") else 0,
            float(answer_utility.get("score") or 0.0),
            float(evidence.get("margin") or 0.0),
            float(representation.get("margin") or 0.0),
            str(item.get("plan_id") or ""),
        )

    def _plan_sanity_gate(
        self,
        plan: Mapping[str, Any],
        veg: Mapping[str, Any],
        artifact_store: Mapping[str, Any],
    ) -> Tuple[Dict[str, Any], pd.DataFrame | None]:
        """对候选图做最小可执行性检查。

        这一步只回答“这个 plan 结构上能不能继续进入 L1/L2/L3”。
        不在这里判断类别太多、点太少、趋势弱不弱等表达质量问题；
        这些都交给 L3 representation gate，以保持研究语义清晰。
        """

        reasons: List[str] = []
        artifact_store = dict(artifact_store or {})
        source_tid = str((plan or {}).get("source_tid") or "")
        source_df = artifact_store.get(source_tid)

        if not source_tid:
            reasons.append("missing_source_tid")
        if source_tid and source_tid not in dict((veg or {}).get("tables") or {}):
            reasons.append("source_tid_not_in_veg")
        if not isinstance(source_df, pd.DataFrame):
            reasons.append("source_dataframe_not_found")
            return self._make_sanity_gate(False, reasons), None
        if source_df.empty:
            reasons.append("source_dataframe_empty")
            return self._make_sanity_gate(False, reasons), None

        encoding = dict((plan or {}).get("encoding") or {})
        chart_type = str(encoding.get("chart_type") or "")
        slots = dict(encoding.get("slots") or {})
        if not is_supported_chart(chart_type):
            reasons.append("unsupported_chart_type")
            return self._make_sanity_gate(False, reasons), None

        # 先检查必需 slot 是否声明完整。列是否真实存在，要在 transform 后再判断。
        for slot in required_slots(chart_type):
            if not str(slots.get(slot) or ""):
                reasons.append(f"missing_slot_{slot}")
        if reasons:
            return self._make_sanity_gate(False, reasons), None

        try:
            support_df = apply_transform_ops(source_df, list(((plan or {}).get("transform") or {}).get("ops") or []))
        except Exception as exc:
            return self._make_sanity_gate(False, [f"transform_failed:{exc}"]), None

        if not isinstance(support_df, pd.DataFrame) or support_df.empty:
            return self._make_sanity_gate(False, ["support_dataframe_empty"]), None

        # transform 执行后，renderer 实际消费的是 support_df，因此最终列检查必须以 support_df 为准。
        required_columns = [str(slots.get(slot) or "") for slot in required_slots(chart_type)]
        missing_columns = [col for col in required_columns if col and col not in support_df.columns]
        if missing_columns:
            reasons.extend([f"slot_column_not_found:{col}" for col in missing_columns])
            return self._make_sanity_gate(False, reasons), support_df

        numeric_reasons = self._numeric_slot_reasons(chart_type, slots, support_df)
        if numeric_reasons:
            reasons.extend(numeric_reasons)
            return self._make_sanity_gate(False, reasons), support_df

        scheme_reasons = self._scheme_validity_reasons(chart_type, slots, support_df, plan)
        if scheme_reasons:
            reasons.extend(scheme_reasons)
            return self._make_sanity_gate(False, reasons), support_df

        gate = self._make_sanity_gate(True, [])
        gate["support_shape"] = [int(support_df.shape[0]), int(support_df.shape[1])]
        return gate, support_df

    def _numeric_slot_reasons(self, chart_type: str, slots: Mapping[str, Any], support_df: pd.DataFrame) -> List[str]:
        """检查 renderer 必须数值化的通道是否有可用数值。

        注意：这里仍然是“能否渲染”的最低要求，不判断差异是否显著、趋势是否强。
        """
        reasons: List[str] = []
        if chart_type in {"bar", "line", "boxplot"}:
            numeric_slots = ["y"]
        elif chart_type == "scatter":
            numeric_slots = ["x", "y"]
        elif chart_type == "heatmap":
            numeric_slots = ["value"]
        else:
            numeric_slots = []

        for slot in numeric_slots:
            col = str(slots.get(slot) or "")
            if not col or col not in support_df.columns:
                continue
            if pd.api.types.is_bool_dtype(support_df[col]):
                reasons.append(f"slot_column_is_boolean:{slot}:{col}")
                continue
            numeric = pd.to_numeric(support_df[col], errors="coerce")
            if int(numeric.notna().sum()) == 0:
                reasons.append(f"slot_column_not_numeric:{slot}:{col}")
        return reasons


    def _scheme_validity_reasons(
        self,
        chart_type: str,
        slots: Mapping[str, Any],
        support_df: pd.DataFrame,
        plan: Mapping[str, Any],
    ) -> List[str]:
        """Reject schemes that are executable but statistically/semantically invalid.

        This is deliberately a small P0 check.  It runs before utility/novelty scoring,
        uses only internal metadata, and does not change any frontier selection weights.
        """
        reasons: List[str] = []
        semantics = dict((dict(plan or {}).get("semantics") or {}))
        column_semantics = {
            str(key): dict(value or {})
            for key, value in dict(semantics.get("columns") or {}).items()
        }

        def semantic(column: str) -> Dict[str, Any]:
            if column == "count":
                return {"kind": "count", "additive": True, "identifier": False, "temporal": False}
            return dict(column_semantics.get(column) or {})

        def unique_count(column: str) -> int:
            if not column or column not in support_df.columns:
                return 0
            try:
                return int(safe_nunique(support_df[column], dropna=True))
            except Exception:
                return 0

        x = str(slots.get("x") or "")
        y = str(slots.get("y") or "")
        value = str(slots.get("value") or "")
        x_sem = semantic(x)
        y_sem = semantic(y)

        aggregation = str(semantics.get("aggregation") or "").lower()
        if aggregation == "sum" and y and y_sem.get("additive") is False:
            reasons.append(f"unsupported_sum_for_nonadditive_metric:{y}")

        if chart_type == "bar":
            if unique_count(x) < 2:
                reasons.append(f"insufficient_comparable_groups:{x}")

        elif chart_type == "line":
            temporal = bool(x_sem.get("temporal"))
            if not temporal and x in support_df.columns:
                temporal = bool(pd.api.types.is_datetime64_any_dtype(support_df[x]))
            if not temporal:
                reasons.append(f"invalid_time_axis:{x}")
            if unique_count(x) < 2:
                reasons.append(f"insufficient_time_points:{x}")

        elif chart_type == "scatter":
            for slot_name, column, sem in (("x", x, x_sem), ("y", y, y_sem)):
                if sem.get("identifier"):
                    reasons.append(f"identifier_used_as_numeric_measure:{slot_name}:{column}")
                if str(sem.get("kind") or "") in {"category_code", "coordinate", "text", "boolean", "temporal"}:
                    reasons.append(f"non_measure_used_in_relationship:{slot_name}:{column}")
                if unique_count(column) < 3:
                    reasons.append(f"insufficient_unique_relationship_values:{slot_name}:{column}")
            if x in support_df.columns and y in support_df.columns:
                valid = pd.DataFrame({
                    "x": pd.to_numeric(support_df[x], errors="coerce"),
                    "y": pd.to_numeric(support_df[y], errors="coerce"),
                }).dropna()
                if len(valid) < 3:
                    reasons.append("insufficient_relationship_points")

        elif chart_type == "boxplot":
            if unique_count(x) < 2:
                reasons.append(f"insufficient_distribution_groups:{x}")
            if y_sem.get("identifier") or str(y_sem.get("kind") or "") in {
                "category_code", "coordinate", "text", "boolean", "temporal"
            }:
                reasons.append(f"invalid_distribution_measure:{y}")
            if unique_count(y) < 4:
                reasons.append(f"insufficient_distribution_variation:{y}")

        elif chart_type == "heatmap":
            value_sem = semantic(value)
            if value_sem.get("identifier") or str(value_sem.get("kind") or "") in {
                "category_code", "coordinate", "text", "boolean", "temporal"
            }:
                reasons.append(f"invalid_heatmap_measure:{value}")

        # Keep output deterministic and concise when multiple checks identify the same issue.
        return list(dict.fromkeys(reasons))

    def _make_sanity_gate(self, passed: bool, reasons: Sequence[str]) -> Dict[str, Any]:
        return {
            "passed": bool(passed),
            "reasons": list(reasons or []),
        }

    def _invalid_plan_item(self, plan: Mapping[str, Any], sanity_gate: Mapping[str, Any]) -> Dict[str, Any]:
        """把结构无效的 raw plan 也包装成统一 scored plan。"""
        qep_preference = {
            "score": 0.0,
            "mode": "ranking_only",
            "reasons": ["QEP preference scoring skipped because sanity gate failed"],
        }
        evidence_gate = {
            "score": 0.0,
            "threshold": float(self.min_evidence_support),
            "margin": -float(self.min_evidence_support),
            "passed": False,
            "reasons": ["skipped because sanity gate failed"],
        }
        frontier_evidence_gate = {
            "score": 0.0,
            "threshold": float(self.min_frontier_evidence_support),
            "margin": -float(self.min_frontier_evidence_support),
            "passed": False,
            "reasons": ["skipped because sanity gate failed"],
        }
        representation_gate = {
            "score": 0.0,
            "threshold": float(self.representation_gate_threshold),
            "margin": -float(self.representation_gate_threshold),
            "passed": False,
            "reasons": ["skipped because sanity gate failed"],
            "details": {},
        }
        item = dict(plan or {})
        empty_utility = {
            "score": 0.0,
            "breakdown": {},
            "reasons": ["utility scoring skipped because visual plan is structurally invalid"],
        }
        item["answer_utility"] = dict(empty_utility)
        item["exploration_utility"] = dict(empty_utility)
        item["preferences"] = {"qep": qep_preference}
        item["gates"] = {
            "sanity": dict(sanity_gate or {}),
            "evidence": evidence_gate,
            "frontier_evidence": frontier_evidence_gate,
            "representation": representation_gate,
        }
        item["admission"] = self._admission(dict(sanity_gate or {}), evidence_gate, representation_gate)
        return item


    def _answer_contribution_score(
        self,
        plan: Mapping[str, Any],
        l3_details: Mapping[str, Any],
        *,
        task_anchor_text: str = "",
    ) -> float:
        """估计候选图对最终 insight 抽取的直接贡献。

        L3 关注“图能不能被转成可靠文字事实”；本函数再补一个更贴近 answer 的信号：
        这张图是否容易产出具体、可写入最终结论的 rank/gap/trend/relationship/stability。
        该分数只参与排序，不新增复杂 gate，避免过度控制候选图准入。
        """
        details = dict(l3_details or {})
        fact_extractability = float(details.get("fact_extractability") or 0.0)
        signal = float(details.get("perceptual_signal_gain") or 0.0)
        weak_signal = float(details.get("weak_signal_penalty") or 0.0)
        pattern = str(details.get("pattern") or plan.get("pattern") or "")
        chart_type = str(((plan or {}).get("encoding") or {}).get("chart_type") or "")
        score = 0.45 * fact_extractability + 0.30 * signal + 0.25 * (1.0 - weak_signal)

        # top-k、分布、趋势、关系图通常更容易被转成 evaluator 可匹配的结论。
        if pattern in {"category_count_distribution", "category_metric_comparison", "topk_ranking"}:
            score += 0.10
        if chart_type in {"line", "scatter", "heatmap"}:
            score += 0.06

        # 任务关键词绑定：字段名命中 goal/round question 中的 agent/location/status/text 等锚点时，
        # 该图更可能直接辅助最终 answer；这只加排序分，不改变 gate 结构。
        slot_text = " ".join(str(v or "") for v in list(((plan or {}).get("encoding") or {}).get("slots", {}).values())).lower()
        anchor = str(task_anchor_text or "").lower()
        if slot_text and anchor:
            if any(word in anchor and word in slot_text for word in [
                "agent", "assigned", "user", "manager", "location", "country", "city",
                "leave", "pto", "status", "state", "priority", "category", "department",
                "description", "reason", "cause", "resolution", "printer", "asset", "model",
            ]):
                score += 0.08

        return clip01(score)

    def _exploration_potential_score(
        self,
        *,
        l2: float,
        frontier_l2: float,
        l3: float,
        intent_score: float,
        l3_details: Mapping[str, Any],
    ) -> float:
        """估计候选图形成后续分析问题的潜力。

        探索证据允许远离当前 stage_result，但必须有 frontier 支撑和可读模式。
        当 frontier 支撑明显高于 answer 支撑时，说明它更像一个未来方向而非当前结论。
        """
        details = dict(l3_details or {})
        signal = float(details.get("perceptual_signal_gain") or 0.0)
        fact_extractability = float(details.get("fact_extractability") or 0.0)
        frontier_gap = max(0.0, float(frontier_l2) - float(l2))
        return clip01(
            0.30 * float(frontier_l2)
            + 0.24 * float(l3)
            + 0.18 * float(intent_score)
            + 0.16 * signal
            + 0.07 * fact_extractability
            + 0.05 * min(1.0, frontier_gap * 2.0)
        )

    def _dynamic_representation_threshold(
        self,
        plan: Mapping[str, Any],
        l3_details: Mapping[str, Any],
    ) -> float:
        """根据文字信息卡价值动态调整 L3 gate。

        旧逻辑会因为“小表格本来就清楚”而上调阈值。当前不传图，
        小型 stage_result 反而最适合抽 top、占比、差距、均衡性等事实，
        因此这里只对高风险/弱事实抽取场景上调阈值。
        """

        threshold = float(self.representation_gate_threshold)
        profile = dict(l3_details.get("profile") or {})
        rows = int(profile.get("rows") or 0)
        pattern = str(profile.get("pattern") or plan.get("pattern") or "")
        fact_extractability = float(l3_details.get("fact_extractability") or 0.0)
        signal = float(l3_details.get("perceptual_signal_gain") or 0.0)
        clutter = float(l3_details.get("clutter_risk") or 0.0)
        transform_cost = float(l3_details.get("transform_cost") or 0.0)
        weak_signal = float(l3_details.get("weak_signal_penalty") or 0.0)

        # Small, fact-extractable results should pass more easily than noisy views.
        if 2 <= rows <= 8 and fact_extractability >= 0.65:
            threshold -= 0.05
        elif 9 <= rows <= 16 and fact_extractability >= 0.70:
            threshold -= 0.03

        # 明显弱信号或高解释成本才上调阈值。
        if fact_extractability < 0.35:
            threshold += 0.06
        if signal < 0.20 and pattern not in {"category_count_distribution", "category_metric_comparison", "topk_ranking"}:
            threshold += 0.04
        if clutter >= 0.35:
            threshold += 0.04
        if transform_cost >= 0.35:
            threshold += 0.03
        if weak_signal >= 0.45 and fact_extractability < 0.60:
            threshold += 0.04

        return clip01(max(0.42, min(0.72, threshold)))

    def _admission(
        self,
        sanity_gate: Mapping[str, Any],
        evidence_gate: Mapping[str, Any],
        representation_gate: Mapping[str, Any],
    ) -> Dict[str, Any]:
        """Admit using hard structural, runtime-evidence, and representation gates only.

        QEP does not appear in this function by design.  This prevents a ranking
        preference from becoming a hidden threshold or veto in later refactors.
        """

        sanity_pass = bool(sanity_gate.get("passed"))
        evidence_pass = bool(evidence_gate.get("passed"))
        representation_pass = bool(representation_gate.get("passed"))
        if not sanity_pass:
            decision = "reject_visual_plan_invalid_structure"
            reason = "candidate plan is not executable or missing required chart fields"
        elif not evidence_pass:
            decision = "reject_visual_plan_insufficient_evidence"
            reason = "candidate plan is not sufficiently grounded in runtime evidence"
        elif not representation_pass:
            decision = "reject_low_textual_visual_fact_utility"
            reason = "candidate chart does not provide enough reliable visual facts"
        else:
            decision = "emit_chart"
            reason = "candidate passes hard structure, runtime-evidence, and representation gates"
        return {
            "decision": decision,
            "admitted": bool(sanity_pass and evidence_pass and representation_pass),
            "reason": reason,
            "sanity_passed": bool(sanity_pass),
            "evidence_margin": float(evidence_gate.get("margin") or 0.0),
            "representation_margin": float(representation_gate.get("margin") or 0.0),
        }



def score_visual_plans(
    raw_plans: Sequence[Mapping[str, Any]],
    veg: Mapping[str, Any],
    analysis_tendency: Sequence[Mapping[str, Any]],
    artifact_store: Mapping[str, Any],
    *,
    representation_gate_threshold: float = 0.50,
    min_evidence_support: float = 0.58,
    min_frontier_evidence_support: float = 0.42,
    evidence_profile: Mapping[str, Any] | None = None,
    task_anchor_text: str = "",
) -> List[Dict[str, Any]]:
    """函数式入口，供 evidence_layer 编排层调用。

    raw_plans 不再经过独立 filter；结构合法性由 estimator 内部的 sanity gate 统一处理。
    """

    return VisualPlanDecisionEstimator(
        representation_gate_threshold=representation_gate_threshold,
        min_evidence_support=min_evidence_support,
        min_frontier_evidence_support=min_frontier_evidence_support,
    ).score_plans(
        raw_plans,
        veg,
        analysis_tendency,
        artifact_store,
        evidence_profile=evidence_profile,
        task_anchor_text=task_anchor_text,
    )
