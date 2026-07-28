"""问题生成与选择策略。

本模块只负责 LLM 问题决策，不执行代码。当前编排保留一个中央管理会话，
并让每条分析线复用自己的连续会话：
1. 中央管理会话生成并筛选 root questions；
2. 每条分析会话在完成一个问题后自然提出一个后续问题；
3. 中央管理会话补充尚未覆盖的新角度，并从所有候选中选择下一组问题。

预算、会话创建和新分析线的两轮保护由 Agent 代码处理，不写进提示词。
"""

from __future__ import annotations

from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

from data_loader import InsightBenchTask
from llm_client import OpenAICompatibleClient
from evidence_layer.join_opportunities import JoinOpportunityEngine
from prompts import (
    COMPARISON_SYSTEM_PROMPT,
    build_global_new_angle_questions_prompt,
    build_json_retry_prompt,
    build_local_next_question_prompt,
    build_root_question_candidates_prompt,
    build_select_next_questions_prompt,
    build_select_root_questions_prompt,
    get_task_benchmark,
)
from query_logger import QueryLogger
from vis_project_utils.utils import merge_token_usage

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


def _config_value(mapping: Dict[str, Any], key: str, default: Any) -> Any:
    value = dict(mapping or {}).get(key, default)
    return default if value is None else value


class QuestionPolicy:
    """生成 root、局部续问和全局下一步问题。"""

    def __init__(self, llm_client: OpenAICompatibleClient, config: Optional[Dict[str, Any]] = None) -> None:
        self.llm_client = llm_client
        self.config = dict(config or {})
        agent_config = dict(self.config.get("agent") or {})
        self.max_questions = int(_config_value(agent_config, "max_questions", 3))
        if self.max_questions <= 0:
            raise ValueError("agent.max_questions must be a positive integer.")
        self.root_candidate_count = int(
            _config_value(agent_config, "root_candidate_count", max(6, self.max_questions * 2))
        )
        self.max_new_angle_candidates = min(2, max(1, int(
            _config_value(agent_config, "max_new_angle_candidates", 2)
        )))
        self.max_followup_choices = min(2, max(1, int(
            _config_value(agent_config, "max_followup_choices", 2)
        )))
        self.question_retries = int(agent_config.get("question_retries", 3) or 3)
        self.dedupe_selected_questions = bool(agent_config.get("dedupe_selected_questions", True))
        self.duplicate_similarity_threshold = float(
            _config_value(agent_config, "duplicate_similarity_threshold", 0.75)
        )
        self.total_usage = dict(_ZERO_USAGE)

    # ------------------------------------------------------------------
    # root question 生成与筛选
    # ------------------------------------------------------------------

    def begin_exploration(
        self,
        task: InsightBenchTask,
        logger: Optional[QueryLogger] = None,
    ) -> Tuple[Any, List[str], Dict[str, Any]]:
        """开启中央管理会话，并完成 root 候选生成与筛选。"""
        candidate_count = max(self.max_questions, self.root_candidate_count)
        conversation, selected_questions, _candidate_questions, root_answerability = (
            self._request_root_questions_with_conversation(
                task=task,
                candidate_count=candidate_count,
                selected_count=self.max_questions,
                logger=logger,
            )
        )
        if root_answerability.get("can_answer") is False:
            roots: List[str] = []
        else:
            roots = [str(item or "").strip() for item in selected_questions if str(item or "").strip()]
        return conversation, roots[: self.max_questions], dict(root_answerability)

    # ------------------------------------------------------------------
    # 分析会话的局部续问
    # ------------------------------------------------------------------

    def generate_local_next_question(
        self,
        *,
        conversation: Any,
        current_question: str,
        current_insight: str,
        previous_questions: Sequence[str],
        selected_exploration_evidence: str = "",
        selected_evidence_ids: Sequence[str] = (),
        question_index: int,
        logger: Optional[QueryLogger] = None,
    ) -> Optional[Dict[str, Any]]:
        """在同一分析会话中生成一个自然续问；没有价值时返回 ``None``。"""
        prompt = build_local_next_question_prompt(
            current_question=current_question,
            current_insight=current_insight,
            selected_exploration_evidence=selected_exploration_evidence,
        )
        allowed_ids = {str(value or "").strip() for value in selected_evidence_ids if str(value or "").strip()}
        current_prompt = prompt
        latest_raw = ""
        for attempt in range(max(1, self.question_retries)):
            response = conversation.generate_json(
                step_name=(
                    f"question_{question_index}_next_question"
                    if attempt == 0
                    else f"question_{question_index}_next_question_retry_{attempt}"
                ),
                user_prompt=current_prompt,
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else None
            if parsed is None:
                current_prompt = build_json_retry_prompt(
                    original_prompt=prompt,
                    previous_response=latest_raw,
                    error_message="Error: return a JSON object with `question` and `trigger_evidence_ids`.",
                )
                continue

            question = self._normalize_question(parsed.get("question"))
            if not question:
                return None
            if self.dedupe_selected_questions and self._is_duplicate_question(question, previous_questions):
                current_prompt = build_json_retry_prompt(
                    original_prompt=prompt,
                    previous_response=latest_raw,
                    error_message=(
                        "Error: the proposed question repeats an existing question. "
                        "Return a materially different continuation."
                    ),
                )
                continue
            trigger_ids = self._normalize_trigger_ids(parsed.get("trigger_evidence_ids"), allowed_ids)
            return {
                "question": question,
                "trigger_evidence_ids": trigger_ids,
            }
        return None

    # ------------------------------------------------------------------
    # 中央管理会话的新角度生成与下一步选择
    # ------------------------------------------------------------------

    def generate_global_new_angles(
        self,
        *,
        benchmark_name: str,
        conversation: Any,
        previous_questions: Sequence[str],
        analysis_history: str,
        continuation_candidates: Sequence[Mapping[str, Any]],
        selected_exploration_evidence: str = "",
        selected_evidence_ids: Sequence[str] = (),
        generation_index: int = 1,
        logger: Optional[QueryLogger] = None,
    ) -> List[Dict[str, Any]]:
        """让中央管理会话基于本轮新增结果补充最多两个不同的新角度问题。"""
        prompt = build_global_new_angle_questions_prompt(
            benchmark_name=benchmark_name,
            analysis_history=analysis_history,
            continuation_candidates=[
                {
                    "id": str(item.get("id") or ""),
                    "question": str(item.get("question") or ""),
                    "supporting_insight": str(item.get("supporting_insight") or ""),
                }
                for item in continuation_candidates
                if str(item.get("question") or "").strip()
            ],
            selected_exploration_evidence=selected_exploration_evidence,
            max_questions=self.max_new_angle_candidates,
            generation_index=generation_index,
        )
        allowed_ids = {str(value or "").strip() for value in selected_evidence_ids if str(value or "").strip()}
        current_prompt = prompt
        latest_raw = ""
        for attempt in range(max(1, self.question_retries)):
            response = conversation.generate_json(
                step_name=(
                    f"global_new_angles_{generation_index}"
                    if attempt == 0
                    else f"global_new_angles_{generation_index}_retry_{attempt}"
                ),
                user_prompt=current_prompt,
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else None
            if parsed is None or not isinstance(parsed.get("questions"), list):
                current_prompt = build_json_retry_prompt(
                    original_prompt=prompt,
                    previous_response=latest_raw,
                    error_message="Error: field `questions` must be a JSON list.",
                )
                continue

            items: List[Dict[str, Any]] = []
            # 新角度不仅不能重复已执行问题，也不能只是改写某条现有分析会话
            # 已经提出的 continuation。否则二者会同时进入全局候选池并浪费预算。
            comparison_questions = [
                *list(previous_questions),
                *[
                    str(item.get("question") or "").strip()
                    for item in continuation_candidates
                    if str(item.get("question") or "").strip()
                ],
            ]
            for raw in parsed.get("questions"):
                if not isinstance(raw, Mapping):
                    continue
                question = self._normalize_question(raw.get("question"))
                if not question:
                    continue
                if self.dedupe_selected_questions and self._is_duplicate_question(question, comparison_questions):
                    continue
                comparison_questions.append(question)
                items.append({
                    "question": question,
                    "trigger_evidence_ids": self._normalize_trigger_ids(
                        raw.get("trigger_evidence_ids"), allowed_ids
                    ),
                })
                if len(items) >= self.max_new_angle_candidates:
                    break
            return items
        return []

    def select_next_questions(
        self,
        *,
        conversation: Any,
        candidates: Sequence[Mapping[str, Any]],
        generation_index: int,
        logger: Optional[QueryLogger] = None,
    ) -> List[str]:
        """从给定候选中选择最多两个下一步问题 ID。"""
        compact_candidates = [
            {
                "id": str(item.get("id") or ""),
                "question": str(item.get("question") or ""),
                "basis": str(item.get("basis") or ""),
            }
            for item in candidates
            if str(item.get("id") or "").strip() and str(item.get("question") or "").strip()
        ]
        if not compact_candidates:
            return []
        prompt = build_select_next_questions_prompt(
            candidates=compact_candidates,
            max_selected=self.max_followup_choices,
        )
        allowed_ids = [item["id"] for item in compact_candidates]
        current_prompt = prompt
        latest_raw = ""
        for attempt in range(max(1, self.question_retries)):
            response = conversation.generate_json(
                step_name=(
                    f"select_next_questions_{generation_index}"
                    if attempt == 0
                    else f"select_next_questions_{generation_index}_retry_{attempt}"
                ),
                user_prompt=current_prompt,
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else None
            if parsed is None or not isinstance(parsed.get("selected_ids"), list):
                current_prompt = build_json_retry_prompt(
                    original_prompt=prompt,
                    previous_response=latest_raw,
                    error_message="Error: field `selected_ids` must be a JSON list.",
                )
                continue
            raw_selected_ids = parsed.get("selected_ids")
            selected: List[str] = []
            for raw in raw_selected_ids:
                candidate_id = str(raw or "").strip()
                if candidate_id in allowed_ids and candidate_id not in selected:
                    selected.append(candidate_id)
                if len(selected) >= self.max_followup_choices:
                    break
            if selected or not raw_selected_ids:
                return selected
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message="Error: selected_ids must contain only IDs from the candidate list.",
            )
        return []

    def _normalize_question(self, value: Any) -> str:
        """规范单个问题文本。"""
        question = " ".join(str(value or "").split()).strip()
        if question and not question.endswith("?"):
            question += "?"
        return question

    def _normalize_trigger_ids(self, value: Any, allowed_ids: Set[str]) -> List[str]:
        """只保留当前提示中真实出现的 frontier ID。"""
        result: List[str] = []
        for raw in value if isinstance(value, list) else []:
            evidence_id = str(raw or "").strip()
            if evidence_id in allowed_ids and evidence_id not in result:
                result.append(evidence_id)
        return result

    # ------------------------------------------------------------------
    # root LLM 请求与解析
    # ------------------------------------------------------------------

    def _request_root_questions_with_conversation(
        self,
        *,
        task: InsightBenchTask,
        candidate_count: int,
        selected_count: int,
        logger: Optional[QueryLogger],
    ) -> Tuple[Any, List[str], List[str], Dict[str, Any]]:
        """在一个 conversation 中完成 root 候选生成与筛选，并返回 root answerability。"""
        conversation = self.llm_client.start_conversation(COMPARISON_SYSTEM_PROMPT)
        # Join opportunities are optional planning hints.  Invalid or missing constraint
        # metadata must not prevent the ordinary root-question workflow from running.
        try:
            join_engine = JoinOpportunityEngine(task, self.config)
            join_opportunities = join_engine.root_opportunity_text()
            if logger is not None and str(getattr(join_engine, "initialization_error", "") or ""):
                logger.log_json(
                    "join_opportunity_initialization_error",
                    {"error": str(join_engine.initialization_error)},
                )
        except Exception as exc:
            join_opportunities = ""
            if logger is not None:
                logger.log_json("join_opportunity_initialization_error", {"error": str(exc)})
        candidate_prompt = build_root_question_candidates_prompt(
            task=task,
            candidate_count=candidate_count,
            join_opportunities=join_opportunities,
        )
        _, candidate_questions, root_answerability = self._request_root_candidates_with_retry(
            conversation=conversation,
            prompt=candidate_prompt,
            expected_count=candidate_count,
            logger=logger,
        )
        if root_answerability.get("can_answer") is False:
            return conversation, [], [], root_answerability
        if not candidate_questions:
            return conversation, [], [], root_answerability

        effective_select_count = min(int(selected_count), len(candidate_questions))
        selection_prompt = build_select_root_questions_prompt(select_count=effective_select_count, benchmark_name=get_task_benchmark(task))
        selected_indices = self._request_root_selection_with_retry(
            conversation=conversation,
            prompt=selection_prompt,
            candidate_count=len(candidate_questions),
            expected_count=effective_select_count,
            logger=logger,
        )
        selected_questions = [candidate_questions[index] for index in selected_indices if 0 <= index < len(candidate_questions)]
        return conversation, selected_questions, candidate_questions, root_answerability

    def _request_root_candidates_with_retry(
        self,
        *,
        conversation: Any,
        prompt: str,
        expected_count: int,
        logger: Optional[QueryLogger],
    ) -> Tuple[List[Dict[str, Any]], List[str], Dict[str, Any]]:
        """请求 root candidates，并保留目标级 answerability 与 id/question 候选。"""
        current_prompt = prompt
        latest_raw = ""
        latest_items: List[Dict[str, Any]] = []
        latest_questions: List[str] = []
        latest_answerability: Dict[str, Any] = {"can_answer": None, "reason": ""}
        attempts = max(1, self.question_retries)
        for attempt in range(attempts):
            response = conversation.generate_json(
                step_name="root_question_candidates" if attempt == 0 else f"root_question_candidates_retry_{attempt}",
                user_prompt=current_prompt,
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else {}
            latest_items, latest_questions, latest_answerability, valid, error = self._parse_root_candidate_response(
                parsed=parsed,
                expected_count=expected_count,
            )
            if valid:
                return latest_items, latest_questions, latest_answerability
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message=error,
            )
        # 只有通过完整校验的 ``can_answer=false`` 才能终止整个任务。若模型在
        # 最后一次仍返回自相矛盾或缺少理由的 no-answer 结构，不把这个未校验
        # 判断当成正式结论。
        if latest_answerability.get("can_answer") is False:
            latest_answerability = {
                **latest_answerability,
                "can_answer": None,
            }
        return latest_items, latest_questions, latest_answerability

    def _request_root_selection_with_retry(
        self,
        *,
        conversation: Any,
        prompt: str,
        candidate_count: int,
        expected_count: int,
        logger: Optional[QueryLogger],
    ) -> List[int]:
        """在 root 候选生成后的同一 conversation 中请求 selected_indices。"""
        current_prompt = prompt
        latest_raw = ""
        latest_indices: List[int] = []
        attempts = max(1, self.question_retries)
        for attempt in range(attempts):
            response = conversation.generate_json(
                step_name="select_root_questions" if attempt == 0 else f"select_root_questions_retry_{attempt}",
                user_prompt=current_prompt,
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            latest_raw = response.raw_content
            parsed = response.parsed if isinstance(response.parsed, dict) else {}
            latest_indices, valid, error = self._parse_selected_indices(
                parsed.get("selected_indices"),
                candidate_count,
                expected_count,
            )
            if valid:
                return latest_indices
            current_prompt = build_json_retry_prompt(
                original_prompt=prompt,
                previous_response=latest_raw,
                error_message=error,
            )
        return latest_indices[:expected_count]


    # ------------------------------------------------------------------
    # 校验与去重
    # ------------------------------------------------------------------

    def _is_duplicate_question(self, question: str, previous_questions: Sequence[str]) -> bool:
        q_tokens = self._question_tokens(question)
        if not q_tokens:
            return False
        for prev in previous_questions:
            p_tokens = self._question_tokens(prev)
            if not p_tokens:
                continue
            similarity = len(q_tokens & p_tokens) / max(1, len(q_tokens | p_tokens))
            if similarity >= self.duplicate_similarity_threshold:
                return True
        return False

    def _question_tokens(self, question: str) -> set[str]:
        """提取问题关键词，用于轻量重复检测。"""
        import re
        stop = {"what", "which", "does", "the", "and", "are", "across", "over", "within", "from", "with", "most", "main", "data", "using", "between", "compare"}
        return {tok for tok in re.findall(r"[a-z0-9_]+", str(question or "").lower()) if tok not in stop and len(tok) > 2}

    def _validate_question_list(self, questions: Sequence[str], expected_count: int) -> Tuple[bool, str]:
        expected = max(1, int(expected_count or 1))
        if not questions:
            return False, "Error: you did not generate any questions. The questions array must be non-empty."
        if len(questions) != expected:
            return False, f"Error: expected exactly {expected} questions, but got {len(questions)}."
        for idx, question in enumerate(questions):
            if not str(question or "").strip():
                return False, f"Error: question at index {idx} is empty."
        return True, ""


    def _parse_root_candidate_response(
        self,
        *,
        parsed: Dict[str, Any],
        expected_count: int,
    ) -> Tuple[List[Dict[str, Any]], List[str], Dict[str, Any], bool, str]:
        """解析 root candidate 响应。

        返回：候选对象列表、候选问题文本列表、目标级 answerability、是否有效、错误信息。
        当前 prompt 要求模型先判断原始 goal/query 是否可由 schema 支撑；只有可回答
        时才输出简单 id/question 候选。若 can_answer=false 且 questions 为空，也视为
        有效响应，后续由 Agent 直接生成 no-answer insight。
        """
        if not isinstance(parsed, dict):
            return [], [], {"can_answer": None, "reason": ""}, False, "Error: root candidate response must be a JSON object."

        raw_answerability = parsed.get("answerability") or {}
        answerability = raw_answerability if isinstance(raw_answerability, Mapping) else {}
        can_answer_raw = answerability.get("can_answer")
        can_answer_goal: Optional[bool]
        if isinstance(can_answer_raw, bool):
            can_answer_goal = can_answer_raw
        elif isinstance(can_answer_raw, str):
            normalized = can_answer_raw.strip().lower()
            if normalized in {"true", "yes", "answerable", "can_answer"}:
                can_answer_goal = True
            elif normalized in {"false", "no", "unanswerable", "cannot_answer", "likely_unanswerable"}:
                can_answer_goal = False
            else:
                can_answer_goal = None
        else:
            can_answer_goal = None
        answerability_payload: Dict[str, Any] = {
            "can_answer": can_answer_goal,
            "reason": str(answerability.get("reason") or "").strip(),
        }

        raw_items = parsed.get("questions")
        if not isinstance(raw_items, list):
            return [], [], answerability_payload, False, "Error: field 'questions' must be a list."

        items: List[Dict[str, Any]] = []
        questions: List[str] = []
        for idx, raw in enumerate(raw_items):
            if isinstance(raw, dict):
                question = str(raw.get("question") or "").strip()
                qid = str(raw.get("id") or f"Q{idx + 1}").strip()
            else:
                question = str(raw or "").strip()
                qid = f"Q{idx + 1}"
            if question and not question.endswith("?"):
                question += "?"
            if question:
                item = {"id": qid or f"Q{idx + 1}", "question": question}
                items.append(item)
                questions.append(question)

        if can_answer_goal is False and not questions:
            if not answerability_payload["reason"]:
                return items, questions, answerability_payload, False, (
                    "Error: when answerability.can_answer is false, provide a concrete reason "
                    "that names the missing evidence."
                )
            return items, questions, answerability_payload, True, ""

        if can_answer_goal is False and questions:
            return items, questions, answerability_payload, False, (
                "Error: answerability.can_answer is false, so questions must be an empty list."
            )

        valid, error = self._validate_question_list(questions, expected_count=expected_count)
        if not valid:
            return items, questions, answerability_payload, False, error
        return items, questions, answerability_payload, True, ""

    def _parse_selected_indices(self, value: Any, candidate_count: int, expected_count: int) -> Tuple[List[int], bool, str]:
        if not isinstance(value, list):
            return [], False, "Error: selected_indices must be a list of integers."
        indices: List[int] = []
        for raw in value:
            try:
                index = int(raw)
            except Exception:
                return indices, False, "Error: every selected index must be an integer."
            if index < 0 or index >= candidate_count:
                return indices, False, f"Error: selected index {index} is outside [0, {candidate_count - 1}]."
            if index not in indices:
                indices.append(index)
        if len(indices) != int(expected_count):
            return indices, False, f"Error: expected exactly {expected_count} distinct selected indices, but got {len(indices)}."
        return indices, True, ""
