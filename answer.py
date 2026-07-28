"""answer.py
------------
把 evidence layer 的结果直接解释成一条 question-level insight，并生成最终 summary。

interpret 阶段按数据集使用不同提示：InsightBench 请求官方风格的
answer / insight / justification 三元组，BIRD-EDA 继续请求 insight-only JSON。
核心流程在两种情况下都只消费 `insight`；answer / justification 仅用于提示对齐，
不参与校验、记录、重试或后续 summary。
"""

from __future__ import annotations

import json
import math
import re
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from data_loader import InsightBenchTask
from code_execute.error_classification import INTERPRETATION_ERROR
from llm_client import OpenAICompatibleClient, LLMConversation
from prompts import (
    SUMMARY_SYSTEM_PROMPT,
    build_interpret_evidence_prompt,
    build_json_retry_prompt,
    build_merge_insights_prompt,
    build_write_summary_from_conclusions_prompt,
    get_task_benchmark,
)
from query_logger import QueryLogger
from vis_project_utils.utils import merge_token_usage

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
_NUMBER_TOKEN_RE = re.compile(r"(?<![A-Za-z_])[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?%?(?![A-Za-z_])")


class AnswerExecuter:
    """负责单题解释和最终 summary。"""

    def __init__(
        self,
        *,
        llm_client: OpenAICompatibleClient,
        config: Optional[Dict[str, Any]],
        task: InsightBenchTask,
        logger: Optional[QueryLogger] = None,
    ) -> None:
        self.llm_client = llm_client
        self.config = dict(config or {})
        self.task = task
        self.logger = logger
        agent_config = dict(self.config.get("agent") or {})
        # Prefer the new insight_retries key, but keep answer_retries as a config alias
        # so existing experiment configs continue to run.
        self.insight_retries = int(
            agent_config.get("insight_retries", agent_config.get("answer_retries", agent_config.get("question_retries", 3))) or 3
        )
        self.total_usage = dict(_ZERO_USAGE)

    def interpret_question(
        self,
        *,
        question_index: int,
        question: str,
        evidence_payload: Dict[str, Any],
        conversation: LLMConversation,
    ) -> Dict[str, Any]:
        """把当前 question 的证据直接解释成一条 insight。

        InsightBench 提示会请求 answer / insight / justification，BIRD-EDA 提示只
        请求 insight；核心流程在两种情况下都只解析非空 `insight`。
        """
        prompt = build_interpret_evidence_prompt(
            question=question,
            evidence_payload=evidence_payload,
            benchmark_name=get_task_benchmark(self.task),
        )
        parsed, raw, interpretation_valid, validation_error = self._request_interpret_with_retry(
            conversation=conversation,
            step_name=f"question_{question_index}_interpret",
            prompt=prompt,
        )

        insight = self._clean_text(parsed.get("insight"))
        fallback_fields: List[str] = []

        if not insight:
            insight = self._fallback_insight(question=question, evidence_payload=evidence_payload)
            fallback_fields.append("insight")

        if self.logger is not None:
            self.logger.log_json(
                f"question_{question_index}_interpret_diagnostic",
                self._insight_evidence_retention_diagnostic(
                    insight=insight,
                    evidence_payload=evidence_payload,
                ),
            )

        fallback_used = bool(fallback_fields or not interpretation_valid)
        return {
            "insight": insight,
            "diagnostics": {
                "interpretation_status": "fallback_after_invalid_output" if fallback_used else "model_output_valid",
                "error_type": INTERPRETATION_ERROR if fallback_used else "",
                "error": validation_error if fallback_used else "",
                "fallback_fields": fallback_fields,
                "raw_response_present": bool(str(raw or "").strip()),
            },
        }

    def summarize(self, predicted_insights: List[str]) -> str:
        """两阶段 summary：merge insights -> write final summary。

        Summary 阶段只消费已经生成的 insights；visual/stat/table evidence 的作用应当已经
        体现在 insight 文本中。这里不再读取旧的 question-answer history，也不保留旧版本
        summary prompt / parser 兼容。
        """
        insights = [self._clean_text(item) for item in predicted_insights]
        insights = [item for item in insights if item]
        if not insights:
            return ""

        conclusions = self._request_merged_conclusions_with_retry(insights=insights)
        if not conclusions:
            conclusions = insights

        summary = self._request_summary_from_conclusions_with_retry(conclusions=conclusions)
        if summary:
            return summary
        return " ".join(conclusions)

    def _request_interpret_with_retry(
        self,
        *,
        conversation: LLMConversation,
        step_name: str,
        prompt: str,
    ) -> Tuple[Dict[str, str], str, bool, str]:
        """在当前问题会话中请求解释，并只校验 insight 非空。"""
        current_prompt = prompt
        latest_raw = ""
        latest_parsed: Dict[str, str] = {}
        latest_error = ""
        attempts = max(1, self.insight_retries)
        for attempt in range(attempts):
            response = conversation.generate_json(
                step_name=step_name if attempt == 0 else f"{step_name}_retry_{attempt}",
                user_prompt=current_prompt,
                logger=self.logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else {}
            latest_parsed = {
                "insight": self._clean_text(parsed.get("insight")),
            }
            valid, error = self._validate_interpretation(latest_parsed)
            latest_error = error
            if valid:
                return latest_parsed, latest_raw, True, ""
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message=error,
            )
        return latest_parsed, latest_raw, False, latest_error or "Interpretation output remained invalid."

    def _request_merged_conclusions_with_retry(self, *, insights: List[str]) -> List[str]:
        """第一阶段：把相同含义或相互支撑的 insights 合并为若干结论。"""
        prompt = build_merge_insights_prompt(task=self.task, insights=insights)
        current_prompt = prompt
        latest_raw = ""
        latest_conclusions: List[str] = []
        attempts = max(1, self.insight_retries)
        for attempt in range(attempts):
            response = self.llm_client.generate_json(
                step_name="final_summary_merge_insights" if attempt == 0 else f"final_summary_merge_insights_retry_{attempt}",
                system_prompt=SUMMARY_SYSTEM_PROMPT,
                user_prompt=current_prompt,
                logger=self.logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else {}
            latest_conclusions, error = self._parse_conclusions_payload(parsed)
            if latest_conclusions and not error:
                return latest_conclusions
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message=error or "Error: conclusions output is missing or empty.",
            )
        return latest_conclusions

    def _request_summary_from_conclusions_with_retry(self, *, conclusions: List[str]) -> str:
        """第二阶段：根据合并后的结论生成最终 summary。"""
        prompt = build_write_summary_from_conclusions_prompt(task=self.task, conclusions=conclusions)
        current_prompt = prompt
        latest_raw = ""
        latest_summary = ""
        attempts = max(1, self.insight_retries)
        for attempt in range(attempts):
            response = self.llm_client.generate_json(
                step_name="final_summary_write_from_conclusions" if attempt == 0 else f"final_summary_write_from_conclusions_retry_{attempt}",
                system_prompt=SUMMARY_SYSTEM_PROMPT,
                user_prompt=current_prompt,
                logger=self.logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else {}
            latest_summary, error = self._parse_summary_payload(parsed)
            if latest_summary:
                return latest_summary
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message=error or "Error: summary output is missing or empty.",
            )
        return latest_summary

    def _parse_conclusions_payload(self, parsed: Dict[str, Any]) -> Tuple[List[str], str]:
        """解析 merge 阶段输出，只接受 conclusions list。"""
        raw_conclusions = parsed.get("conclusions") if isinstance(parsed, dict) else None
        if not isinstance(raw_conclusions, list):
            return [], "Error: expected a JSON object with a conclusions list."

        conclusions: List[str] = []
        seen: set[str] = set()
        for item in raw_conclusions:
            if isinstance(item, dict):
                text = self._clean_text(item.get("conclusion"))
            else:
                text = self._clean_text(item)
            if not text:
                continue
            key = " ".join(text.lower().split())
            if key in seen:
                continue
            seen.add(key)
            conclusions.append(text)

        if not conclusions:
            return [], "Error: conclusions field must contain at least one non-empty conclusion."
        return conclusions, ""

    def _parse_summary_payload(self, parsed: Dict[str, Any]) -> Tuple[str, str]:
        """解析 write 阶段输出，只接受非空 summary 字段。"""
        if not isinstance(parsed, dict):
            return "", "Error: expected a JSON object."
        summary = self._clean_text(parsed.get("summary"))
        if summary:
            return summary, ""
        return "", "Error: expected a non-empty summary field."

    def _validate_interpretation(self, parsed: Dict[str, str]) -> Tuple[bool, str]:
        """校验解释输出是否包含非空 insight。"""
        if not self._clean_text(parsed.get("insight")):
            return False, "Error: field 'insight' is missing or empty."
        return True, ""

    def _fallback_insight(self, *, question: str, evidence_payload: Dict[str, Any]) -> str:
        """LLM 没给出 insight 时，从 evidence 中生成保守兜底句。"""
        answer_evidence = dict((evidence_payload or {}).get("answer_evidence") or {})
        cards = str((evidence_payload or {}).get("answer_evidence_cards") or "")
        for line in cards.splitlines():
            stripped = line.strip()
            lowered = stripped.lower()
            if lowered.startswith("candidate local finding:"):
                candidate = stripped.split(":", 1)[1].strip()
                if candidate:
                    return self._ensure_sentence(candidate)

        summary = self._clean_text(answer_evidence.get("summary"))
        if summary:
            return self._ensure_sentence(summary)
        return f"The executed analysis produced evidence for the question: {question}"

    def _insight_evidence_retention_diagnostic(
        self,
        *,
        insight: str,
        evidence_payload: Dict[str, Any],
    ) -> Dict[str, Any]:
        """记录 evidence → insight 的轻量保留率诊断。

        该诊断只写入本地 query log，不触发重试，不进入结果 schema，不进入后续
        LLM prompt。它用于区分两类问题：
        1. 严重丢失：证据有数字但 insight 完全没有数字；
        2. 弱保留：证据中有多个关键数字/实体，但 insight 只保留了很少一部分。
        """
        insight_text = self._clean_text(insight)
        evidence_text = self._diagnostic_evidence_text(evidence_payload)

        evidence_numbers = _dedupe_preserve_order(_extract_number_tokens(evidence_text))
        insight_numbers = _dedupe_preserve_order(_extract_number_tokens(insight_text))
        matched_numbers = _match_number_tokens(evidence_numbers, insight_numbers)

        evidence_entities = _dedupe_preserve_order(_extract_entity_tokens(evidence_text))
        insight_entities = _dedupe_preserve_order(_extract_entity_tokens(insight_text))
        matched_entities = _match_entity_tokens(evidence_entities, insight_text)

        numeric_retention_ratio = _safe_ratio(len(matched_numbers), len(evidence_numbers))
        entity_retention_ratio = _safe_ratio(len(matched_entities), len(evidence_entities))

        severe_numeric_drop = bool(evidence_numbers and not insight_numbers)
        weak_numeric_retention = bool(
            len(evidence_numbers) >= 3 and len(matched_numbers) <= 1
        )
        weak_entity_retention = bool(
            len(evidence_entities) >= 3 and len(matched_entities) <= 1
        )

        return {
            # Kept as a concise headline flag for quick grep in query logs.
            "numeric_evidence_dropped": severe_numeric_drop,
            "severe_numeric_drop": severe_numeric_drop,
            "weak_numeric_retention": weak_numeric_retention,
            "weak_entity_retention": weak_entity_retention,
            "evidence_number_count": len(evidence_numbers),
            "insight_number_count": len(insight_numbers),
            "matched_number_count": len(matched_numbers),
            "numeric_retention_ratio": numeric_retention_ratio,
            "evidence_entity_count": len(evidence_entities),
            "insight_entity_count": len(insight_entities),
            "matched_entity_count": len(matched_entities),
            "entity_retention_ratio": entity_retention_ratio,
            "unmatched_number_examples": _first_unmatched_examples(evidence_numbers, matched_numbers),
            "unmatched_entity_examples": _first_unmatched_examples(evidence_entities, matched_entities),
        }

    def _diagnostic_evidence_text(self, evidence_payload: Dict[str, Any]) -> str:
        """收集用于本地诊断的短证据文本，避免把完整大表写入日志诊断。"""
        payload = dict(evidence_payload or {})
        brief = dict(payload.get("evidence_brief") or {})
        answer_evidence = dict(payload.get("answer_evidence") or {})
        stage_result = dict(answer_evidence.get("stage_result") or {})

        parts: List[str] = []
        for key in ("key_facts", "important_numbers", "compact_table", "caveats"):
            value = brief.get(key)
            if value:
                parts.append(_safe_json_text(value))

        cards = str(payload.get("answer_evidence_cards") or "").strip()
        if cards:
            parts.append(cards)

        stat_items = stage_result.get("stat")
        if isinstance(stat_items, list):
            for item in stat_items[:6]:
                if not isinstance(item, Mapping):
                    continue
                short_item: Dict[str, Any] = {}
                for key in ("name", "description"):
                    if item.get(key):
                        short_item[key] = item.get(key)
                value = item.get("value")
                compact_value = _compact_diagnostic_value(value)
                if compact_value not in (None, "", [], {}):
                    short_item["value"] = compact_value
                if short_item:
                    parts.append(_safe_json_text(short_item))

        return "\n".join(part for part in parts if part)

    def _clean_text(self, value: Any) -> str:
        """去掉多余空白和常见标签。"""
        text = re.sub(r"\s+", " ", str(value or "")).strip()
        text = re.sub(r"^<(answer|insight|justification|summary)>|</(answer|insight|justification|summary)>$", "", text, flags=re.I)
        return text.strip()

    def _ensure_sentence(self, text: str) -> str:
        """保证兜底文本像一句完整结论。"""
        cleaned = self._clean_text(text)
        if cleaned and cleaned[-1] not in ".!?。！？":
            cleaned += "."
        return cleaned


def _safe_json_text(value: Any) -> str:
    """Best-effort JSON text for diagnostics."""
    try:
        return json.dumps(value, ensure_ascii=False, default=str)
    except Exception:
        return str(value)


def _compact_diagnostic_value(value: Any) -> Any:
    """Compact stage_result values for retention diagnostics."""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, Mapping):
        compact: Dict[str, Any] = {}
        for index, (key, item) in enumerate(value.items()):
            if index >= 8:
                break
            compact[str(key)] = _compact_diagnostic_value(item)
        return compact
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        items = list(value[:8]) if hasattr(value, "__getitem__") else list(value)[:8]
        return [_compact_diagnostic_value(item) for item in items]
    return str(value)


def _extract_number_tokens(text: str) -> List[str]:
    """Extract compact numeric tokens from evidence/insight text."""
    tokens: List[str] = []
    for match in _NUMBER_TOKEN_RE.finditer(str(text or "")):
        token = match.group(0).strip()
        if token:
            tokens.append(token)
    return tokens


def _extract_entity_tokens(text: str) -> List[str]:
    """Heuristic entity/category extraction for diagnostics only.

    It intentionally stays conservative: multi-word title-case phrases, slash-composed
    group labels, and all-caps codes are enough to identify common dropped group/entity
    anchors without adding a model-visible schema.
    """
    source = str(text or "")
    candidates: List[str] = []

    slash_label = r"[A-Z0-9][A-Za-z0-9&().'’_-]*(?:\s+[A-Z0-9][A-Za-z0-9&().'’_-]*){0,3}"
    slash_pattern = re.compile(rf"\b{slash_label}/{slash_label}\b")
    candidates.extend(match.group(0).strip() for match in slash_pattern.finditer(source))

    title_phrase = re.compile(
        r"\b(?:[A-Z][A-Za-z0-9&().'’_-]+)(?:\s+(?:[A-Z][A-Za-z0-9&().'’_-]+|and|of|for|the|&)){1,5}"
    )
    candidates.extend(match.group(0).strip() for match in title_phrase.finditer(source))

    acronym = re.compile(r"\b[A-Z][A-Z0-9_&-]{2,}\b")
    candidates.extend(match.group(0).strip() for match in acronym.finditer(source))

    cleaned: List[str] = []
    stop_heads = {
        "the", "this", "these", "there", "key", "setup", "chart", "candidate",
        "evidence", "result", "json", "true", "false", "none", "null", "nan",
        "pearson", "within", "because", "overall", "relative", "question",
    }
    for candidate in candidates:
        item = re.sub(r"\s+", " ", candidate).strip(" .,:;[]{}()")
        if len(item) < 2 or len(item) > 80:
            continue
        if item.split()[0].lower() in stop_heads:
            continue
        if _NUMBER_TOKEN_RE.fullmatch(item):
            continue
        cleaned.append(item)
    return cleaned[:50]


def _dedupe_preserve_order(items: Iterable[str]) -> List[str]:
    seen: set[str] = set()
    out: List[str] = []
    for item in items:
        text = str(item or "").strip()
        key = text.lower()
        if not text or key in seen:
            continue
        seen.add(key)
        out.append(text)
    return out


def _match_number_tokens(evidence_numbers: Sequence[str], insight_numbers: Sequence[str]) -> List[str]:
    matched: List[str] = []
    used: set[int] = set()
    for evidence_token in evidence_numbers:
        for index, insight_token in enumerate(insight_numbers):
            if index in used:
                continue
            if _number_tokens_equivalent(evidence_token, insight_token):
                matched.append(evidence_token)
                used.add(index)
                break
    return matched


def _number_tokens_equivalent(left: str, right: str) -> bool:
    left_norm = _normalize_number_token(left)
    right_norm = _normalize_number_token(right)
    if left_norm and right_norm and left_norm == right_norm:
        return True
    left_value = _number_token_to_float(left)
    right_value = _number_token_to_float(right)
    if left_value is None or right_value is None:
        return False
    scale = max(abs(left_value), abs(right_value), 1.0)
    if abs(left_value - right_value) <= max(1e-6, 1e-3 * scale):
        return True
    # Allow ratio-vs-percentage expression, e.g. 0.445 vs 44.5%.
    pct_scale = max(abs(left_value * 100.0), abs(right_value), 1.0)
    if abs(left_value * 100.0 - right_value) <= max(0.05, 1e-3 * pct_scale):
        return True
    pct_scale = max(abs(left_value), abs(right_value * 100.0), 1.0)
    if abs(left_value - right_value * 100.0) <= max(0.05, 1e-3 * pct_scale):
        return True
    return False



def _normalize_number_token(token: str) -> str:
    text = str(token or "").strip().replace(",", "")
    text = text[:-1] if text.endswith("%") else text
    try:
        value = float(text)
    except Exception:
        return text.lower()
    if not math.isfinite(value):
        return ""
    if abs(value - round(value)) <= 1e-9:
        return str(int(round(value)))
    return f"{value:.8g}"


def _number_token_to_float(token: str) -> Optional[float]:
    text = str(token or "").strip().replace(",", "")
    text = text[:-1] if text.endswith("%") else text
    try:
        value = float(text)
    except Exception:
        return None
    if not math.isfinite(value):
        return None
    return value


def _match_entity_tokens(evidence_entities: Sequence[str], insight_text: str) -> List[str]:
    insight_norm = _normalize_entity_text(insight_text)
    matched: List[str] = []
    for entity in evidence_entities:
        entity_norm = _normalize_entity_text(entity)
        if entity_norm and entity_norm in insight_norm:
            matched.append(entity)
    return matched


def _normalize_entity_text(text: str) -> str:
    out = re.sub(r"[^a-z0-9]+", " ", str(text or "").lower())
    return f" {re.sub(r'\\s+', ' ', out).strip()} "


def _safe_ratio(numerator: int, denominator: int) -> Optional[float]:
    if denominator <= 0:
        return None
    return round(float(numerator) / float(denominator), 4)


def _first_unmatched_examples(evidence_items: Sequence[str], matched_items: Sequence[str], limit: int = 5) -> List[str]:
    matched_keys = {str(item).lower() for item in matched_items}
    return [item for item in evidence_items if str(item).lower() not in matched_keys][:limit]
