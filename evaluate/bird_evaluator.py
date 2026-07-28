"""
evaluate/bird_evaluator.py
--------------------------
BIRD EDA evaluator using full-pair harmonic grounded coverage (HGC).

Protocol:
1. Keep each original predicted insight intact. No evaluator-side atomization.
2. Extract explicit numeric/data anchors from all predictions with the prompt
   validated in ``bird_prompt_lab``.
3. Judge every Gold x Pred pair with the unchanged Prompt-Lab pair rubric.
4. For a Gold without numeric anchors, the pair score is semantic_score.
5. For a numerically anchored Gold, combine semantic and data scores within the
   same pair by their harmonic mean. Neither dimension can compensate for a
   missing other dimension.
6. For each Gold, take the highest pair score over all predictions.
7. Average Gold scores within a task. ``score``, ``score_gold_avg`` and
   ``score_weighted`` are backward-compatible aliases of this task HGC score.

Pair requests are executed with a bounded thread pool because the main project
uses a synchronous LLM client. ``evaluation.max_concurrency`` controls the
number of simultaneous Pair-Judge calls.
"""

from __future__ import annotations

from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
import json
from typing import Any, Dict, List, Optional, Tuple

from data_loader import BirdEDATask
from llm_client import LLMConfig, OpenAICompatibleClient
from query_logger import QueryLogger
from vis_project_utils.utils import merge_token_usage, safe_float
from .metrics import normalize_text

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

# ---------------------------------------------------------------------------
# Prompts copied verbatim from bird_prompt_lab/Prompts.py.
# Retrieval prompts are intentionally not included because HGC uses all pairs.
# ---------------------------------------------------------------------------

_ANCHOR_SYSTEM_PROMPT = """You extract explicit numeric/data anchors from data-analysis insights.
Follow the supplied rules exactly and return JSON only. Never infer unstated values."""


def _build_anchor_user_prompt(preds: List[Dict[str, Any]]) -> str:
    return f"""Extract explicit numeric/data anchors from every predicted insight.

Predicted insights JSON:
{json.dumps(preds, ensure_ascii=False, indent=2)}

Rules:
1. Process each prediction independently. Do not use any Gold insight.
2. Extract only values explicitly written in the prediction. Never infer, calculate, or restore a missing value.
3. An anchor may be a number, percentage, amount, count, ratio, rank, date/time, duration, interval, threshold, or another explicit value supporting the finding.
4. For each anchor return exactly:
   - meaning: a self-contained English description containing exactly one [VALUE] placeholder in place of this value;
   - value: the value as written, or a mathematically equivalent compact form.
5. Preserve entity, metric, aggregation, time scope, comparison, operator, threshold, condition, and direction in meaning.
6. Keep separate anchors when the same displayed value has different meanings or conditions.
7. Do not extract product/model/version identifiers unless the identifier itself is the analytical result.
8. If no explicit anchor exists, return an empty numeric_anchors list.
9. Preserve every input pred_id and do not rewrite the claim.

Return JSON only:
{{
  "preds": [
    {{
      "pred_id": "P1",
      "numeric_anchors": [
        {{"meaning": "... [VALUE] ...", "value": "..."}}
      ]
    }}
  ]
}}"""


_PAIR_JUDGE_SYSTEM_PROMPT = """You are a strict but calibrated evaluator of data-analysis findings.
Evaluate the Gold finding as the target, use only the supplied text and anchors, and return JSON only.  Use any value in the 0-1 continuous interval for scores"""


def _build_pair_judge_user_prompt(gold: Dict[str, Any], pred: Dict[str, Any]) -> str:
    return f"""Gold insight JSON:
  {json.dumps(gold, ensure_ascii=False, indent=2)}

  Predicted insight JSON:
  {json.dumps(pred, ensure_ascii=False, indent=2)}

  Evaluate whether the predicted insight supports this one Gold analytical finding.
  The prediction may contain additional findings. Judge only whether the target Gold finding is present and supported.

  A. SEMANTIC SCORE

  semantic_score must be a real number in [0, 1].

  Use the following ranges as calibration guidance. 
  - > 0.85: The same core finding is fully stated. The central entity, metric, aggregation or relationship, comparison, direction, and main scope or condition agree. Synonyms and non-conflicting extra details are allowed. Identical wording is not required.
  - > 0.65 and <= 0.85 : The same core finding and direction are clear, but a secondary scope, condition, comparison detail, or granularity detail is omitted or less specific. The main conclusion remains unchanged.
  - > 0.40 and <= 0.65 : The prediction partially supports the same analytical relationship, but an important scope, condition, comparison target, aggregation, or entity subset is missing or changed. The prediction is not contradictory, but the complete Gold finding is not established.
  - > 0.20 and <= 0.40 : The texts share a topic, entity, metric, or fragment of the finding, but they do not express the same complete analytical conclusion.
  - >= 0 and <= 0.20 : The findings are unrelated, use the wrong central entity, metric, or relationship, reverse the direction, use an incompatible condition, or explicitly contradict each other.

  Semantic scoring rules:
  1. Do not reduce the score because the prediction contains correct, non-conflicting extra information.
  2. Use the full continuous range.  First, determine the interval, and then select the score within the interval based on the degree of conformity within the interval.

  B. GOLD NUMERIC-ANCHOR SCORES

  Evaluate every Gold numeric anchor independently and in its original order.

  For each Gold numeric anchor, search the numeric anchors extracted from the predicted insight to determine whether they refer to the same analytical quantity, and then evaluate whether the specific numeric values match.

  Note that the format of the predicted numeric anchors may differ from that of the Gold insight numeric anchors. Evaluate them flexibly based on their actual meaning and context rather than applying rigid format matching.
  Return one score from 0.0 to 1.0 for each Gold anchor.

  Scoring rules:

  1. Assign 1.0 when the prediction explicitly states the exact Gold value or a mathematically equivalent value, such as:

  * equivalent units after conversion;
  * equivalent date, time, rank, ratio, or interval expressions;
  * differences caused only by displayed precision or valid rounding.

  2. Assign a value strictly between 0.0 and 1.0 only when the prediction explicitly states a comparable value that is partially consistent with the Gold value:

  * For scalar values, judge the magnitude of the numerical difference after normalizing units and formats.
  * For ranges or intervals, judge the overlap and agreement of the boundaries.
  * For dates or time spans, judge the overlap and precision of the stated period.
  * For rankings, counts, ratios, or thresholds, judge how closely the explicitly stated value agrees with the Gold value.

  3. Assign 0.0 when:

  * the Gold value is not explicitly stated in the prediction;
  * the numeric context does not match;
  * the stated value is contradictory.

  4. Do not award partial numeric credit merely because the qualitative or semantic conclusion matches. Numeric absence must receive 0.0.

  5. Do not infer values from words such as “highest,” “most,” “increased,” or “approximately” unless an explicit comparable value is also stated.

  6. Evaluate each Gold anchor independently. A match or mismatch involving another anchor must not affect the current anchor.

  7. If the Gold numeric_anchors list is empty, return an empty anchor_scores list.

  Return JSON only. Do not return labels, reasons, explanations, or additional fields:

  {{
  "semantic_score": 0.83,
  "anchor_scores": [1.0, 0.72]
  }}
"""


@dataclass
class BirdEDAEvaluatorConfig:
    """Configuration for full-pair harmonic grounded coverage."""

    judge_model: str = ""
    llm: Dict[str, Any] = field(default_factory=dict)
    metric: str = "harmonic_grounded_coverage"
    max_concurrency: int = 3
    deduplicate_predictions: bool = True

    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "BirdEDAEvaluatorConfig":
        payload = dict(data or {})
        allowed = {key: value for key, value in payload.items() if key in cls.__dataclass_fields__}
        config = cls(**allowed)
        llm_payload = dict(payload.get("llm") or {})
        if "max_concurrency" not in allowed and llm_payload.get("max_concurrency") is not None:
            config.max_concurrency = int(llm_payload["max_concurrency"])
        config.max_concurrency = max(1, int(config.max_concurrency or 1))
        metric = str(config.metric or "harmonic_grounded_coverage").strip().lower()
        if metric not in {"harmonic_grounded_coverage", "hgc"}:
            raise ValueError(f"Unsupported BIRD evaluation metric: {config.metric}")
        config.metric = "harmonic_grounded_coverage"
        return config


class BirdEDAEvaluator:
    """BIRD evaluator with Prompt-Lab prompts and bounded pair concurrency."""

    def __init__(
        self,
        *,
        llm_client: Optional[OpenAICompatibleClient] = None,
        config: Optional[Dict[str, Any]] = None,
        base_llm_config: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.config = BirdEDAEvaluatorConfig.from_dict(config)
        self.base_llm_config = dict(base_llm_config or {})
        if llm_client is not None:
            self.llm_client = llm_client
        else:
            eval_llm = dict(self.config.llm or {})
            if not eval_llm:
                eval_llm = dict(self.base_llm_config or {})
            if self.config.judge_model:
                eval_llm["model"] = self.config.judge_model
            eval_llm["force_json_mode"] = True
            eval_llm.setdefault("temperature", 0.0)
            self.llm_client = OpenAICompatibleClient(LLMConfig.from_dict(eval_llm))

    def skipped_result(self, reason: str, logger: Optional[QueryLogger] = None) -> Dict[str, Any]:
        result = {
            "status": "skipped",
            "reason": str(reason or ""),
            "metric": "harmonic_grounded_coverage",
            "score": 0.0,
            "score_gold_avg": 0.0,
            "score_weighted": 0.0,
            "num_pred_atoms": 0,
            "num_gold_insights": 0,
            "num_numeric_anchors": 0,
            "num_numeric_anchors_matched": 0,
            "num_numeric_anchors_partial": 0,
        }
        if logger is not None:
            logger.log_json("bird_evaluation_skipped", result)
        return result

    def evaluate_task(
        self,
        *,
        task: BirdEDATask,
        predicted_insights: Any,
        logger: Optional[QueryLogger] = None,
        skip_reason: str = "",
    ) -> Dict[str, Any]:
        if str(skip_reason or "").strip():
            return self.skipped_result(reason=skip_reason, logger=logger)

        gold_items = self._gold_items(task)
        pred_items = self._prediction_items(predicted_insights)
        if not gold_items:
            return self.skipped_result(reason="missing_gold_insights", logger=logger)
        if not pred_items:
            return self.skipped_result(reason="missing_predicted_insights", logger=logger)

        if logger is not None:
            logger.log_json(
                "bird_evaluation_start",
                {
                    "evaluation_source": "bird_full_pair_harmonic_grounded_coverage_v1",
                    "judge_model": self.config.judge_model or self.llm_client.config.model,
                    "metric": "harmonic_grounded_coverage",
                    "atomization": "disabled; original predicted insights are used directly",
                    "retrieval": "disabled; every Gold x Pred pair is judged",
                    "assignment": "disabled; each Gold independently takes its best prediction",
                    "pair_combination": "semantic-only for nonnumeric Gold; harmonic mean for numeric Gold",
                    "num_pred_insights": len(pred_items),
                    "num_gold_insights": len(gold_items),
                    "num_gold_numeric_anchors": sum(len(item.get("numeric_anchors") or []) for item in gold_items),
                    "max_pair_concurrency": self.config.max_concurrency,
                },
            )

        try:
            preds, anchor_usage = self._extract_pred_numeric_anchors(pred_items, logger=logger)
            result_payload, pair_usage = self._evaluate_all_pairs(
                gold_items=gold_items,
                preds=preds,
                logger=logger,
            )
            usage = merge_token_usage(anchor_usage, pair_usage)
        except Exception as exc:
            result = {
                "status": "failed",
                "reason": "evaluation_runtime_error",
                "error": str(exc),
                "metric": "harmonic_grounded_coverage",
                "score": 0.0,
                "score_gold_avg": 0.0,
                "score_weighted": 0.0,
            }
            if logger is not None:
                logger.log_json("bird_evaluation_failed", result)
            return result

        score = float(result_payload.get("score") or 0.0)
        result = {
            "status": "evaluated",
            "metric": "harmonic_grounded_coverage",
            "score": score,
            "score_gold_avg": score,
            "score_weighted": score,
            "num_pred_atoms": int(result_payload.get("num_pred_atoms") or 0),
            "num_gold_insights": int(result_payload.get("num_gold_insights") or 0),
            "num_pairs": int(result_payload.get("num_pairs") or 0),
            "num_numeric_anchors": int(result_payload.get("num_numeric_anchors") or 0),
            "num_numeric_anchors_matched": int(result_payload.get("num_numeric_anchors_matched") or 0),
            "num_numeric_anchors_partial": int(result_payload.get("num_numeric_anchors_partial") or 0),
            "numeric_anchor_mean_on_best_pairs": float(result_payload.get("numeric_anchor_mean_on_best_pairs") or 0.0),
            "_evaluation_report": dict(result_payload.get("evaluation_report") or {}),
        }
        if logger is not None:
            logger.log_json("bird_evaluation_report", result_payload.get("evaluation_report") or {})
            logger.log_json("bird_evaluation_token_usage", usage)
            logger.log_json(
                "bird_evaluation_result",
                {key: value for key, value in result.items() if key != "_evaluation_report"},
            )
        return result

    def _prediction_items(self, raw_insights: Any) -> List[Dict[str, Any]]:
        claims = _normalize_raw_predicted_insights(raw_insights)
        if self.config.deduplicate_predictions:
            seen: set[str] = set()
            deduplicated: List[str] = []
            for claim in claims:
                key = normalize_text(claim)
                if key and key not in seen:
                    seen.add(key)
                    deduplicated.append(key)
            claims = deduplicated
        return [
            {"pred_id": f"P{index}", "claim": claim, "numeric_anchors": []}
            for index, claim in enumerate(claims, start=1)
        ]

    def _gold_items(self, task: BirdEDATask) -> List[Dict[str, Any]]:
        """Flatten structured Gold insights and preserve frozen numeric anchors."""
        raw_payload = dict(getattr(task, "raw_payload", None) or {})
        items: List[Dict[str, Any]] = []

        for path_index, path in enumerate(list(raw_payload.get("gold_paths") or []), start=1):
            if not isinstance(path, dict):
                continue
            path_id = normalize_text(path.get("path_id") or f"P{path_index}")
            raw_insights = path.get("insights")
            if raw_insights is None:
                raw_insights = path.get("insight")
            insights = raw_insights if isinstance(raw_insights, list) else [raw_insights]
            for insight_index, raw_item in enumerate(insights, start=1):
                item = dict(raw_item or {}) if isinstance(raw_item, dict) else {"claim": raw_item}
                normalized = self._normalize_gold_item(
                    item=item,
                    fallback_id=f"{path_id}_I{insight_index}",
                    path_id=path_id,
                    sub_query=path.get("sub_query"),
                )
                if normalized is not None:
                    items.append(normalized)
        if items:
            return items

        for index, raw_item in enumerate(list(raw_payload.get("gold_insights") or []), start=1):
            item = dict(raw_item or {}) if isinstance(raw_item, dict) else {"claim": raw_item}
            normalized = self._normalize_gold_item(
                item=item,
                fallback_id=f"G{index}",
                path_id="",
                sub_query="",
            )
            if normalized is not None:
                items.append(normalized)
        if items:
            return items

        for index, raw_item in enumerate(list(getattr(task, "insight_items", None) or []), start=1):
            item = dict(raw_item or {}) if isinstance(raw_item, dict) else {"claim": raw_item}
            normalized = self._normalize_gold_item(
                item=item,
                fallback_id=f"G{index}",
                path_id="",
                sub_query="",
            )
            if normalized is not None:
                items.append(normalized)
        return items

    def _normalize_gold_item(
        self,
        *,
        item: Dict[str, Any],
        fallback_id: str,
        path_id: str,
        sub_query: Any,
    ) -> Optional[Dict[str, Any]]:
        claim = normalize_text(item.get("claim") or item.get("insight") or item.get("text") or "")
        if not claim:
            return None
        gold_id = normalize_text(item.get("gold_id") or item.get("insight_id") or item.get("id") or fallback_id)
        return {
            "gold_id": gold_id,
            "claim": claim,
            "numeric_anchors": _normalize_gold_anchor_definitions(item.get("numeric_anchors")),
            "path_id": str(path_id or ""),
            "sub_query": normalize_text(sub_query),
            "evidence_sql": item.get("evidence_sql"),
            "raw_item": dict(item),
        }

    def _extract_pred_numeric_anchors(
        self,
        preds: List[Dict[str, Any]],
        *,
        logger: Optional[QueryLogger],
    ) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
        request_preds = [
            {"pred_id": str(item["pred_id"]), "claim": normalize_text(item["claim"])}
            for item in preds
        ]
        response = self.llm_client.generate_json(
            step_name="bird_hgc_pred_anchor_extract",
            system_prompt=_ANCHOR_SYSTEM_PROMPT,
            user_prompt=_build_anchor_user_prompt(request_preds),
            logger=logger,
        )
        parsed = response.parsed if isinstance(response.parsed, dict) else {}
        anchor_map = _normalize_pred_anchor_map(parsed.get("preds"), valid_pred_ids={item["pred_id"] for item in preds})

        enriched: List[Dict[str, Any]] = []
        for item in preds:
            pred_id = str(item["pred_id"])
            enriched.append(
                {
                    "pred_id": pred_id,
                    "claim": normalize_text(item["claim"]),
                    "numeric_anchors": list(anchor_map.get(pred_id) or []),
                }
            )
        return enriched, response.usage or dict(_ZERO_USAGE)

    def _evaluate_all_pairs(
        self,
        *,
        gold_items: List[Dict[str, Any]],
        preds: List[Dict[str, Any]],
        logger: Optional[QueryLogger],
    ) -> Tuple[Dict[str, Any], Dict[str, int]]:
        pair_specs: List[Tuple[int, int, Dict[str, Any], Dict[str, Any]]] = []
        for gold_index, gold in enumerate(gold_items):
            for pred_index, pred in enumerate(preds):
                pair_specs.append((gold_index, pred_index, gold, pred))

        total_pairs = len(pair_specs)
        if not total_pairs:
            return self._aggregate_results(gold_items, preds, []), dict(_ZERO_USAGE)

        max_workers = min(self.config.max_concurrency, total_pairs)
        ordered_results: List[Optional[Tuple[Dict[str, Any], Dict[str, int]]]] = [None] * total_pairs

        print(
            f"[BIRD HGC] start {total_pairs} full-pair judge requests "
            f"with max_concurrency={max_workers}",
            flush=True,
        )
        with ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="bird-pair") as executor:
            future_to_index: Dict[Future[Tuple[Dict[str, Any], Dict[str, int]]], int] = {}
            for pair_index, (_, _, gold, pred) in enumerate(pair_specs):
                future = executor.submit(
                    self._evaluate_pair,
                    gold_item=gold,
                    pred=pred,
                    logger=logger,
                )
                future_to_index[future] = pair_index

            for future in as_completed(future_to_index):
                pair_index = future_to_index[future]
                ordered_results[pair_index] = future.result()

        pair_rows: List[Dict[str, Any]] = []
        total_usage = dict(_ZERO_USAGE)
        for result in ordered_results:
            if result is None:
                raise RuntimeError("Pair worker finished without returning a result")
            row, usage = result
            pair_rows.append(row)
            total_usage = merge_token_usage(total_usage, usage)

        print(f"[BIRD HGC] completed all {total_pairs} pair requests", flush=True)
        return self._aggregate_results(gold_items, preds, pair_rows), total_usage

    def _evaluate_pair(
        self,
        *,
        gold_item: Dict[str, Any],
        pred: Dict[str, Any],
        logger: Optional[QueryLogger],
    ) -> Tuple[Dict[str, Any], Dict[str, int]]:
        gold_payload = {
            "gold_id": str(gold_item.get("gold_id") or ""),
            "claim": normalize_text(gold_item.get("claim") or ""),
            "numeric_anchors": list(gold_item.get("numeric_anchors") or []),
        }
        pred_payload = {
            "pred_id": str(pred.get("pred_id") or ""),
            "claim": normalize_text(pred.get("claim") or ""),
            "numeric_anchors": list(pred.get("numeric_anchors") or []),
        }
        response = self.llm_client.generate_json(
            step_name=f"bird_hgc_pair_{gold_payload['gold_id']}_{pred_payload['pred_id']}",
            system_prompt=_PAIR_JUDGE_SYSTEM_PROMPT,
            user_prompt=_build_pair_judge_user_prompt(gold_payload, pred_payload),
            logger=logger,
        )
        parsed = response.parsed if isinstance(response.parsed, dict) else {}
        semantic_score = _continuous_score(parsed.get("semantic_score"), default=0.0)
        anchor_scores = _normalize_anchor_scores(
            parsed.get("anchor_scores"),
            expected_count=len(gold_payload["numeric_anchors"]),
        )
        data_score: Optional[float] = _mean(anchor_scores) if gold_payload["numeric_anchors"] else None
        pair_score = _harmonic_grounded_score(semantic_score, data_score)
        row = {
            "gold_id": gold_payload["gold_id"],
            "pred_id": pred_payload["pred_id"],
            "pred_atom_id": pred_payload["pred_id"],  # compatibility alias
            "semantic_score": semantic_score,
            "anchor_scores": anchor_scores,
            "data_score": data_score,
            "harmonic_grounded_score": pair_score,
            "pair_score": pair_score,
            "final_score": pair_score,
        }
        return row, response.usage or dict(_ZERO_USAGE)

    def _aggregate_results(
        self,
        gold_items: List[Dict[str, Any]],
        preds: List[Dict[str, Any]],
        pair_rows: List[Dict[str, Any]],
    ) -> Dict[str, Any]:
        rows_by_gold: Dict[str, List[Dict[str, Any]]] = {
            str(gold.get("gold_id") or ""): [] for gold in gold_items
        }
        for row in pair_rows:
            rows_by_gold.setdefault(str(row.get("gold_id") or ""), []).append(row)

        gold_scores: List[Dict[str, Any]] = []
        selected_anchor_scores: List[float] = []
        for gold in gold_items:
            gold_id = str(gold.get("gold_id") or "")
            candidates = rows_by_gold.get(gold_id) or []
            if candidates:
                best = max(candidates, key=lambda item: float(item.get("harmonic_grounded_score") or 0.0))
                score = float(best.get("harmonic_grounded_score") or 0.0)
                semantic_score = float(best.get("semantic_score") or 0.0)
                data_score = best.get("data_score")
                anchor_scores = list(best.get("anchor_scores") or [])
                best_pred_id = str(best.get("pred_id") or "") or None
            else:
                anchors = list(gold.get("numeric_anchors") or [])
                score = 0.0
                semantic_score = 0.0
                data_score = 0.0 if anchors else None
                anchor_scores = [0.0] * len(anchors)
                best_pred_id = None

            selected_anchor_scores.extend(float(value) for value in anchor_scores)
            gold_scores.append(
                {
                    "gold_id": gold_id,
                    "score": score,
                    "harmonic_grounded_score": score,
                    "semantic_score": semantic_score,
                    "data_score": data_score,
                    "anchor_scores": anchor_scores,
                    "best_pred_id": best_pred_id,
                    "best_pred_atom_id": best_pred_id,
                }
            )

        score = _mean([float(item["score"]) for item in gold_scores])
        num_numeric = sum(len(item.get("numeric_anchors") or []) for item in gold_items)
        num_numeric_matched = sum(1 for value in selected_anchor_scores if value >= 1.0 - 1e-9)
        num_numeric_partial = sum(1 for value in selected_anchor_scores if 0.0 < value < 1.0 - 1e-9)
        numeric_anchor_mean = _mean(selected_anchor_scores)

        report = {
            "protocol": {
                "metric": "harmonic_grounded_coverage",
                "atomization": "disabled; original predicted insights are used directly",
                "pred_anchor_prompt": "bird_prompt_lab unchanged",
                "pair_judge_prompt": "bird_prompt_lab unchanged",
                "retrieval": "none; full Gold x Pred matrix",
                "assignment": "none; independent max over predictions for each Gold",
                "pair_combination": {
                    "nonnumeric_gold": "semantic_score",
                    "numeric_gold": "2 * semantic_score * data_score / (semantic_score + data_score)",
                    "zero_rule": "0 when either required component is 0",
                },
                "task_aggregation": "macro average over Gold findings",
                "pair_concurrency": self.config.max_concurrency,
                "anchor_scores": "continuous [0, 1]",
            },
            "preds": preds,
            "pair_scores": pair_rows,
            "gold_scores": gold_scores,
            "task_score": score,
        }
        return {
            "score": score,
            "score_gold_avg": score,
            "score_weighted": score,
            "num_pred_atoms": len(preds),
            "num_gold_insights": len(gold_items),
            "num_pairs": len(pair_rows),
            "num_numeric_anchors": num_numeric,
            "num_numeric_anchors_matched": num_numeric_matched,
            "num_numeric_anchors_partial": num_numeric_partial,
            "numeric_anchor_mean_on_best_pairs": numeric_anchor_mean,
            "evaluation_report": report,
            "gold_scores": gold_scores,
        }


def _harmonic_grounded_score(semantic_score: float, data_score: Optional[float]) -> float:
    """Combine semantic and numeric evidence within one Gold-Pred pair."""
    semantic = min(1.0, max(0.0, float(semantic_score)))
    if data_score is None:
        return semantic
    numeric = min(1.0, max(0.0, float(data_score)))
    if semantic <= 0.0 or numeric <= 0.0:
        return 0.0
    return 2.0 * semantic * numeric / (semantic + numeric)


def _continuous_score(value: Any, *, default: float = 0.0) -> float:
    score = safe_float(value, default)
    if score is None:
        score = default
    return min(1.0, max(0.0, float(score)))


def _normalize_anchor_scores(value: Any, *, expected_count: int) -> List[float]:
    raw_scores = value if isinstance(value, list) else ([] if value in (None, "") else [value])
    scores = [_continuous_score(raw, default=0.0) for raw in raw_scores[: max(0, expected_count)]]
    while len(scores) < expected_count:
        scores.append(0.0)
    return scores


def _normalize_gold_anchor_definitions(value: Any) -> List[Dict[str, str]]:
    anchors: List[Dict[str, str]] = []
    seen: set[Tuple[str, str]] = set()
    if not isinstance(value, list):
        return anchors
    for item in value:
        if not isinstance(item, dict):
            continue
        meaning = normalize_text(item.get("meaning") or "")
        anchor_value = normalize_text(item.get("value") or "")
        if not meaning or not anchor_value:
            continue
        key = (meaning, anchor_value)
        if key in seen:
            continue
        seen.add(key)
        anchors.append({"meaning": meaning, "value": anchor_value})
    return anchors


def _normalize_pred_anchor_map(
    value: Any,
    *,
    valid_pred_ids: set[str],
) -> Dict[str, List[Dict[str, str]]]:
    """Port Prompt-Lab's tolerant prediction-anchor validation."""
    output: Dict[str, List[Dict[str, str]]] = {pred_id: [] for pred_id in valid_pred_ids}
    rows = value if isinstance(value, list) else []
    for item in rows:
        if not isinstance(item, dict):
            continue
        pred_id = normalize_text(item.get("pred_id") or item.get("pred_atom_id") or "")
        if pred_id not in valid_pred_ids:
            continue
        raw_anchors = item.get("numeric_anchors")
        if isinstance(raw_anchors, dict):
            raw_anchors = [raw_anchors]
        if not isinstance(raw_anchors, list):
            raw_anchors = []
        for anchor in raw_anchors:
            if isinstance(anchor, dict):
                meaning = normalize_text(anchor.get("meaning") or anchor.get("context") or "")
                anchor_value = normalize_text(anchor.get("value") or "")
            elif isinstance(anchor, (str, int, float)):
                meaning = normalize_text(anchor)
                anchor_value = ""
            else:
                continue
            if meaning or anchor_value:
                output[pred_id].append({"meaning": meaning, "value": anchor_value})
    return output


def _normalize_raw_predicted_insights(raw_insights: Any) -> List[str]:
    normalized: List[str] = []
    if raw_insights is None:
        return normalized
    if isinstance(raw_insights, str):
        cleaned = normalize_text(raw_insights)
        return [cleaned] if cleaned else []
    if not isinstance(raw_insights, list):
        return normalized
    for item in raw_insights:
        if isinstance(item, str):
            cleaned = normalize_text(item)
        elif isinstance(item, dict):
            cleaned = ""
            for key in ("claim", "insight", "text", "summary", "finding"):
                if key in item:
                    cleaned = normalize_text(item.get(key))
                    break
        else:
            cleaned = normalize_text(item)
        if cleaned:
            normalized.append(cleaned)
    return normalized


def _mean(values: List[float]) -> float:
    return sum(values) / len(values) if values else 0.0
