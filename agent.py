"""InsightBench 主 Agent。

当前编排把一个持续 LLM 会话视为一条分析线：首轮三个 root 分别建立独立会话，
每条新分析线默认获得一次自然续问；之后中央管理会话结合全部 Question--Insight
历史、各分析线提出的下一问和可选 frontier，选择下一组问题。已有分析线每次只向前
执行一步，新角度则建立新会话并默认执行两问。

frontier 只提供问题生成线索，不替代原始目标、Schema、执行结果和会话上下文。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from answer import AnswerExecuter
from code_execute.error_classification import (
    AGENT_RUNTIME_ERROR,
    CODE_EXECUTION_ERROR,
    classify_error_message,
)
from code_execute.code_executer import CodeExecuter
from data_loader import InsightBenchTask
from evidence_layer.evidence_layer import EvidenceOrganizer
from evidence_layer.evidence_contracts import task_benchmark
from evidence_layer.benchmark_exploration import build_benchmark_exploration_policy
from evidence_layer.global_exploration import (
    GlobalExplorationSelector,
    format_global_exploration_evidence,
)
from evidence_profile import QuestionEvidenceProfiler
from llm_client import LLMConversation, OpenAICompatibleClient
from prompts import ANALYSIS_BRANCH_SYSTEM_PROMPT
from query_logger import QueryLogger
from retrieval import GoalSchemaRetriever, RetrievalFrontierBuilder
from question_policy import QuestionPolicy
from vis_project_utils.utils import merge_token_usage, timed_block

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


@dataclass
class AnalysisAgentState:
    """一个持续分析会话的最小状态。

    同一状态中的问题共享 LLM conversation，以保留局部分析连续性。这里只保存
    后续编排真实需要的下一问和最近 insight，不复制历史记录或执行证据。
    """

    agent_id: str
    conversation: LLMConversation
    questions_completed: int = 0
    latest_insight: str = ""
    next_question: Optional[Dict[str, Any]] = None
    active: bool = True


class InsightBenchAgent:
    """运行一个 InsightBench 或兼容任务的主 Agent。"""

    def __init__(self, llm_client: OpenAICompatibleClient, config: Optional[Dict[str, Any]] = None) -> None:
        self.llm_client = llm_client
        self.config = dict(config or {})
        agent_config = dict(self.config.get("agent") or {})
        raw_max_questions = agent_config.get("max_questions", 3)
        self.max_questions = int(3 if raw_max_questions is None else raw_max_questions)
        if self.max_questions <= 0:
            raise ValueError("agent.max_questions must be a positive integer.")
        self.max_followup_choices = min(2, max(1, int(agent_config.get("max_followup_choices", 2) or 2)))
        self.max_new_angle_candidates = min(2, max(1, int(agent_config.get("max_new_angle_candidates", 2) or 2)))
        raw_max_rounds = agent_config.get("max_rounds", 12)
        self.max_rounds = int(12 if raw_max_rounds is None else raw_max_rounds)
        if self.max_rounds < self.max_questions:
            raise ValueError("agent.max_rounds must be at least agent.max_questions.")
        raw_global_candidates = agent_config.get(
            "max_global_exploration_candidates", self.max_followup_choices
        )
        self.max_global_exploration_candidates = max(
            0,
            int(
                self.max_followup_choices
                if raw_global_candidates is None
                else raw_global_candidates
            ),
        )
        self.generate_summary_config = agent_config.get("generate_summary")

    def run(
        self,
        *,
        task: InsightBenchTask,
        output_dir: str | Path,
        logger: Optional[QueryLogger] = None,
    ) -> Dict[str, Any]:
        """执行完整多轮探索，并返回 Insights、轮次记录和 Token 使用量。"""
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        execution_config = dict(self.config.get("execution") or {})
        copy_on_start = bool(execution_config.get("copy_tables_on_agent_start", False))
        raw_tables = {
            table.name: (table.dataframe.copy(deep=True) if copy_on_start else table.dataframe)
            for table in task.all_tables()
        }
        round_history: List[Dict[str, Any]] = []
        predicted_insights: List[str] = []
        predicted_summary = ""
        task_error = ""
        task_error_type = ""
        task_diagnostic_error_types: List[str] = []
        summary_error = ""
        profile_usage = dict(_ZERO_USAGE)
        exploration_control: Dict[str, Any] = {
            "completed_batches": 0,
            "planned_round_capacity": int(self.max_rounds),
            "executed_rounds": 0,
            "root_question_count": 0,
            "termination_reason": "not_started",
        }
        # Keep a live snapshot so a manager/global-selection exception after several
        # completed branches does not erase already consumed profile tokens or control
        # progress from the persisted result.
        self._last_profile_usage = dict(profile_usage)
        self._last_exploration_control = dict(exploration_control)

        with timed_block() as run_timer:
            question_policy = QuestionPolicy(llm_client=self.llm_client, config=self.config)
            code_executer = CodeExecuter(
                config=self.config,
                task=task,
                raw_tables=raw_tables,
                output_dir=output_dir,
                logger=logger,
            )
            evidence_organizer = EvidenceOrganizer(self.config, task, output_dir, logger)
            schema_retriever = GoalSchemaRetriever(
                llm_client=self.llm_client,
                config=self.config,
            )
            answer_executer = AnswerExecuter(
                llm_client=self.llm_client,
                config=self.config,
                task=task,
                logger=logger,
            )

            try:
                profile_usage, exploration_control = self._run_budgeted_exploration(
                    task=task,
                    question_policy=question_policy,
                    code_executer=code_executer,
                    evidence_organizer=evidence_organizer,
                    schema_retriever=schema_retriever,
                    answer_executer=answer_executer,
                    round_history=round_history,
                    predicted_insights=predicted_insights,
                    logger=logger,
                )
            except Exception as exc:  # 单个任务失败不应终止整批实验。
                profile_usage = dict(getattr(self, "_last_profile_usage", profile_usage) or profile_usage)
                exploration_control = dict(
                    getattr(self, "_last_exploration_control", exploration_control)
                    or exploration_control
                )
                task_error = f"agent_runtime_error: {str(exc)[:1000]}"
                task_error_type = classify_error_message(task_error, default=AGENT_RUNTIME_ERROR)
                exploration_control = {
                    **exploration_control,
                    "executed_rounds": len(round_history),
                    "termination_reason": "agent_runtime_exception",
                }

            if predicted_insights and self._should_generate_summary(task):
                if exploration_control.get("termination_reason") == "root_unanswerable":
                    predicted_summary = str(predicted_insights[0] or "").strip()
                else:
                    try:
                        predicted_summary = answer_executer.summarize(predicted_insights)
                    except Exception as exc:
                        # Preserve usable question-level insights even when the optional
                        # summary stage fails.  The failure remains visible and the run is
                        # marked partial rather than silently dropping all prior work.
                        summary_error = str(exc)[:1000]
                        summary_error_type = classify_error_message(
                            summary_error, default=AGENT_RUNTIME_ERROR
                        )
                        task_diagnostic_error_types.append(summary_error_type)
                        predicted_summary = " ".join(
                            str(item or "").strip()
                            for item in predicted_insights
                            if str(item or "").strip()
                        )
            elif not task_error and not predicted_insights:
                task_error = "no_successful_rounds_generated"
                task_error_type = "no_successful_rounds"

            total_usage = merge_token_usage(
                question_policy.total_usage,
                profile_usage,
                code_executer.total_usage,
                evidence_organizer.total_usage,
                schema_retriever.total_usage,
                answer_executer.total_usage,
            )

        return {
            "predicted_insights": predicted_insights,
            "predicted_summary": predicted_summary,
            "round_history": round_history,
            "duration_sec": run_timer["duration_sec"],
            "token_usage": total_usage,
            "error": task_error,
            "summary_error": summary_error,
            **self._run_status_payload(
                round_history=round_history,
                task_error=task_error,
                task_error_type=task_error_type,
                task_diagnostic_error_types=task_diagnostic_error_types,
                exploration_control=exploration_control,
            ),
            "exploration": {
                "max_root_questions": self.max_questions,
                "max_followup_choices_per_global_review": self.max_followup_choices,
                "max_new_angle_candidates_per_review": self.max_new_angle_candidates,
                "max_rounds": self.max_rounds,
                "max_global_candidates": self.max_global_exploration_candidates,
            },
            "exploration_control": exploration_control,
        }

    def _run_status_payload(
        self,
        *,
        round_history: Sequence[Mapping[str, Any]],
        task_error: str,
        task_error_type: str = "",
        task_diagnostic_error_types: Sequence[str] = (),
        exploration_control: Optional[Mapping[str, Any]] = None,
    ) -> Dict[str, Any]:
        """汇总任务执行状态，区分完整、部分完成与失败。

        只有执行或控制流失败会把一个原本可继续评估的任务标记为 partial。
        QEP 和代码阶段不再输出可回答性控制结果。代码多次修复仍失败时，
        该分支按 execution_error 正常结束。
        """
        records = [dict(record) for record in list(round_history or []) if isinstance(record, Mapping)]
        # success=True means the branch produced a valid question-level insight.
        answered_rounds = sum(bool(record.get("success")) for record in records)
        failed_rounds = sum(
            str(record.get("outcome") or "") in {"execution_error", "branch_error"}
            for record in records
        )
        interpretation_fallback_rounds = sum(
            str(record.get("interpretation_status") or "") == "fallback_after_invalid_output"
            for record in records
        )
        error_type_counts: Dict[str, int] = {}
        for record in records:
            error_type = str(record.get("error_type") or "").strip()
            if error_type:
                error_type_counts[error_type] = error_type_counts.get(error_type, 0) + 1
            for diagnostic_type in list(record.get("diagnostic_error_types") or []):
                diagnostic_type = str(diagnostic_type or "").strip()
                if diagnostic_type:
                    error_type_counts[diagnostic_type] = error_type_counts.get(diagnostic_type, 0) + 1

        for diagnostic_type in list(task_diagnostic_error_types or []):
            diagnostic_type = str(diagnostic_type or "").strip()
            if diagnostic_type:
                error_type_counts[diagnostic_type] = error_type_counts.get(diagnostic_type, 0) + 1

        primary_task_error_type = str(task_error_type or "").strip()
        if primary_task_error_type:
            error_type_counts[primary_task_error_type] = (
                error_type_counts.get(primary_task_error_type, 0) + 1
            )

        termination_reason = str(
            dict(exploration_control or {}).get("termination_reason") or ""
        ).strip()
        control_flow_failed = termination_reason in {
            "global_planning_failed",
        }

        if answered_rounds == 0 and (str(task_error or "").strip() or failed_rounds):
            run_status = "failed"
        elif (
            str(task_error or "").strip()
            or failed_rounds
            or interpretation_fallback_rounds
            or task_diagnostic_error_types
            or control_flow_failed
        ):
            run_status = "partial"
        elif not records:
            run_status = "failed"
        else:
            run_status = "complete"

        return {
            "run_status": run_status,
            "total_rounds": len(records),
            "answered_rounds": int(answered_rounds),
            "failed_rounds": int(failed_rounds),
            "interpretation_fallback_rounds": int(interpretation_fallback_rounds),
            "expected_rounds": int(self.max_rounds),
            "error_type": str(task_error_type or ""),
            "error_type_counts": error_type_counts,
        }

    # ------------------------------------------------------------------
    # 预算驱动探索控制
    # ------------------------------------------------------------------

    def _run_budgeted_exploration(
        self,
        *,
        task: InsightBenchTask,
        question_policy: QuestionPolicy,
        code_executer: CodeExecuter,
        evidence_organizer: EvidenceOrganizer,
        schema_retriever: GoalSchemaRetriever,
        answer_executer: AnswerExecuter,
        round_history: List[Dict[str, Any]],
        predicted_insights: List[str],
        logger: Optional[QueryLogger],
    ) -> Tuple[Dict[str, int], Dict[str, Any]]:
        """执行“新分析会话默认两问、后续每次只走一步”的预算流程。

        第一阶段为三个 root 分别创建持续会话，并在首问成功且存在合理续问时
        各执行一次受保护续问。之后中央管理会话每轮补充新角度、汇总所有局部
        续问并选择下一组问题。新角度会创建新会话并默认执行两问；已有会话每次
        只执行一个问题。预算适配完全由代码完成，不暴露给提示词。
        """
        profile_usage = dict(_ZERO_USAGE)

        retrieval_space = schema_retriever.get_or_generate(task=task, logger=logger)
        retrieval_frontier = RetrievalFrontierBuilder(
            task=task,
            retrieval_space=retrieval_space,
            config=self.config,
            join_engine=evidence_organizer.join_engine,
        )

        manager_conversation, root_questions, root_answerability = question_policy.begin_exploration(
            task=task,
            logger=logger,
        )
        control: Dict[str, Any] = {
            "completed_batches": 0,
            "planned_round_capacity": int(self.max_rounds),
            "executed_rounds": 0,
            "root_question_count": len(root_questions),
            "root_answerability": dict(root_answerability or {}),
            "analysis_agent_count": 0,
            "global_review_count": 0,
            "termination_reason": "running",
        }
        self._last_profile_usage = dict(profile_usage)
        self._last_exploration_control = dict(control)

        if dict(root_answerability or {}).get("can_answer") is False:
            insight, insight_usage, insight_diagnostics = self._generate_root_unanswerable_insight(
                task=task,
                root_answerability=dict(root_answerability or {}),
                logger=logger,
            )
            profile_usage = merge_token_usage(profile_usage, insight_usage)
            record = self._question_record(
                question="Can the original task goal be answered from the available schema?",
                insight=insight,
                evidence_payload={
                    "diagnostics": {"visual_status": "root_answerability_false"},
                    "exploration_candidates": [],
                },
                trigger_evidence=[],
                success=True,
                outcome="root_unanswerable",
                chain_stop_reason="root_answerability_false",
                interpretation_diagnostics={"interpretation_status": "root_unanswerable_insight"},
            )
            record.update({
                "round_index": 1,
                "batch_index": 0,
                "analysis_agent_id": "manager",
                "agent_question_index": 0,
                "question_mode": "root_answerability",
                "root_answerability": dict(root_answerability or {}),
                "root_unanswerable_insight_diagnostics": dict(insight_diagnostics or {}),
            })
            round_history.append(record)
            self._append_insight(record, predicted_insights)
            control.update({
                "executed_rounds": 1,
                "termination_reason": "root_unanswerable",
            })
            self._last_profile_usage = dict(profile_usage)
            self._last_exploration_control = dict(control)
            return profile_usage, control

        root_questions = [str(item or "").strip() for item in root_questions if str(item or "").strip()]
        if not root_questions:
            control["termination_reason"] = "no_root_questions"
            return profile_usage, control

        exploration_policy = build_benchmark_exploration_policy(task=task, config=self.config)
        global_selector = GlobalExplorationSelector(
            max_candidates=self.max_global_exploration_candidates,
            policy=exploration_policy,
        )

        analysis_agents: Dict[str, AnalysisAgentState] = {}
        question_index = 0
        new_agent_index = 0
        recent_records: List[Dict[str, Any]] = []

        # 第一阶段：先执行全部 root，再让每个有效 root 会话自然续问一次。
        # 局部续问去重时同时参考全部已选 root，避免 B1 提出的下一问直接复制 B2/B3。
        selected_root_questions = root_questions[: self.max_questions]
        root_agent_ids: List[str] = []
        # 受保护续问会自动执行，因此生成时也要避免不同 root 会话提出近重复问题。
        # 这里仅把已接受的 sibling proposal 加入轻量去重集合，不把其文本写入别的
        # 分支提示或共享完整会话。
        reserved_protected_questions: List[str] = []
        for root_position, question in enumerate(selected_root_questions, start=1):
            if question_index >= self.max_rounds:
                break
            agent_id = f"B{root_position}"
            state = self._create_analysis_agent(agent_id)
            analysis_agents[agent_id] = state
            root_agent_ids.append(agent_id)
            question_index, usage, record = self._execute_analysis_agent_question(
                task=task,
                state=state,
                question=question,
                question_mode="root",
                trigger_evidence=[],
                question_index=question_index,
                batch_index=1,
                question_policy=question_policy,
                code_executer=code_executer,
                evidence_organizer=evidence_organizer,
                answer_executer=answer_executer,
                global_selector=global_selector,
                exploration_policy=exploration_policy,
                previous_questions=[
                    *[str(item.get("question") or "") for item in round_history],
                    *selected_root_questions,
                    *reserved_protected_questions,
                ],
                allow_next_question=(question_index + 1 < self.max_rounds),
                logger=logger,
            )
            profile_usage = merge_token_usage(profile_usage, usage)
            round_history.append(record)
            recent_records.append(record)
            self._append_insight(record, predicted_insights)
            if state.next_question:
                reserved_question = str(state.next_question.get("question") or "").strip()
                if reserved_question:
                    reserved_protected_questions.append(reserved_question)

        for agent_id in root_agent_ids:
            if question_index >= self.max_rounds:
                break
            state = analysis_agents[agent_id]
            proposal = dict(state.next_question or {})
            if not proposal:
                continue
            state.next_question = None
            proposal_triggers = list(proposal.get("trigger_evidence") or [])
            question_index, usage, record = self._execute_analysis_agent_question(
                task=task,
                state=state,
                question=str(proposal.get("question") or ""),
                question_mode="protected_continuation",
                trigger_evidence=proposal_triggers,
                question_index=question_index,
                batch_index=1,
                question_policy=question_policy,
                code_executer=code_executer,
                evidence_organizer=evidence_organizer,
                answer_executer=answer_executer,
                global_selector=global_selector,
                exploration_policy=exploration_policy,
                previous_questions=[str(item.get("question") or "") for item in round_history],
                allow_next_question=(question_index + 1 < self.max_rounds),
                logger=logger,
            )
            profile_usage = merge_token_usage(profile_usage, usage)
            if bool(record.get("success")) and proposal_triggers:
                self._remove_triggered_candidates(recent_records, proposal_triggers)
            round_history.append(record)
            recent_records.append(record)
            self._append_insight(record, predicted_insights)

        control.update({
            "completed_batches": 1,
            "executed_rounds": question_index,
            "analysis_agent_count": len(analysis_agents),
        })
        self._last_profile_usage = dict(profile_usage)
        self._last_exploration_control = dict(control)

        # 后续阶段：每轮全局回顾后最多选择两个问题。新角度默认两问，已有会话一步。
        global_review_index = 0
        while question_index < self.max_rounds:
            global_review_index += 1
            control["global_review_count"] = global_review_index

            continuation_candidates = self._build_continuation_candidates(
                analysis_agents,
                generation_index=global_review_index,
            )
            current_batch_candidates = [
                dict(candidate)
                for record in recent_records
                for candidate in list(record.get("exploration_candidates") or [])
                if isinstance(candidate, Mapping)
            ]
            retrieval_candidates = retrieval_frontier.build(
                explored_columns=evidence_organizer.explored_analysis_columns(),
                current_candidates=current_batch_candidates,
            )
            selected_exploration = global_selector.select(
                recent_records,
                extra_candidates=retrieval_candidates,
            )
            selected_text = format_global_exploration_evidence(
                selected_exploration,
                policy=exploration_policy,
            )
            selected_by_id = {
                str(item.get("id") or ""): dict(item)
                for item in selected_exploration
                if str(item.get("id") or "").strip()
            }
            selected_evidence_ids = list(selected_by_id)

            if logger is not None:
                logger.log_json(
                    f"global_exploration_selection_review_{global_review_index}",
                    [
                        {
                            "id": str(item.get("id") or ""),
                            "candidate_group": str(item.get("candidate_group") or ""),
                            "candidate_subtype": str(item.get("candidate_subtype") or ""),
                            "title": str(item.get("title") or ""),
                            "utility": item.get("utility"),
                            "global_utility": item.get("global_utility"),
                        }
                        for item in selected_exploration
                    ],
                )

            # 每轮都先完成一次自然的全局回顾。是否能完整执行新角度由后面的
            # 代码预算规则判断，不把预算或会话创建概念写入提示词。
            try:
                new_angles = question_policy.generate_global_new_angles(
                    benchmark_name=task_benchmark(task),
                    conversation=manager_conversation,
                    previous_questions=[str(record.get("question") or "") for record in round_history],
                    analysis_history=self._compose_analysis_history(recent_records),
                    continuation_candidates=continuation_candidates,
                    selected_exploration_evidence=selected_text,
                    selected_evidence_ids=selected_evidence_ids,
                    generation_index=global_review_index,
                    logger=logger,
                )
            except Exception as exc:
                self._log_planning_exception(
                    logger,
                    f"global_new_angle_generation_error_review_{global_review_index}",
                    exc,
                )
                control["termination_reason"] = "global_planning_failed"
                control["planning_error"] = str(exc)[:500]
                break

            candidate_pool = self._build_global_question_pool(
                continuation_candidates=continuation_candidates,
                new_angles=new_angles,
                selected_by_id=selected_by_id,
                generation_index=global_review_index,
            )
            try:
                selected_ids = question_policy.select_next_questions(
                    conversation=manager_conversation,
                    candidates=candidate_pool,
                    generation_index=global_review_index,
                    logger=logger,
                )
            except Exception as exc:
                self._log_planning_exception(
                    logger,
                    f"global_question_selection_error_review_{global_review_index}",
                    exc,
                )
                control["termination_reason"] = "global_planning_failed"
                control["planning_error"] = str(exc)[:500]
                break

            actions = self._choose_executable_questions(
                candidate_pool=candidate_pool,
                selected_ids=selected_ids,
                remaining_budget=self.max_rounds - question_index,
            )

            self._discard_used_exploration_candidates(recent_records)
            recent_records = []

            if not actions:
                control["termination_reason"] = (
                    "insufficient_budget_for_selected_questions"
                    if selected_ids
                    else "no_worthwhile_next_question"
                )
                break

            batch_index = global_review_index + 1
            for action in actions:
                if question_index >= self.max_rounds:
                    break
                action_kind = str(action.get("kind") or "")
                if action_kind == "continuation":
                    agent_id = str(action.get("analysis_agent_id") or "")
                    state = analysis_agents.get(agent_id)
                    if state is None or not state.active:
                        continue
                    state.next_question = None
                    question_index, usage, record = self._execute_analysis_agent_question(
                        task=task,
                        state=state,
                        question=str(action.get("question") or ""),
                        question_mode="continuation",
                        trigger_evidence=list(action.get("trigger_evidence") or []),
                        question_index=question_index,
                        batch_index=batch_index,
                        question_policy=question_policy,
                        code_executer=code_executer,
                        evidence_organizer=evidence_organizer,
                        answer_executer=answer_executer,
                        global_selector=global_selector,
                        exploration_policy=exploration_policy,
                        previous_questions=[str(item.get("question") or "") for item in round_history],
                        allow_next_question=(question_index + 1 < self.max_rounds),
                        logger=logger,
                    )
                    profile_usage = merge_token_usage(profile_usage, usage)
                    round_history.append(record)
                    recent_records.append(record)
                    self._append_insight(record, predicted_insights)
                    continue

                if action_kind != "new_angle":
                    continue
                new_agent_index += 1
                agent_id = f"C{new_agent_index}"
                state = self._create_analysis_agent(agent_id)
                analysis_agents[agent_id] = state

                question_index, usage, record = self._execute_analysis_agent_question(
                    task=task,
                    state=state,
                    question=str(action.get("question") or ""),
                    question_mode="new_angle",
                    trigger_evidence=list(action.get("trigger_evidence") or []),
                    question_index=question_index,
                    batch_index=batch_index,
                    question_policy=question_policy,
                    code_executer=code_executer,
                    evidence_organizer=evidence_organizer,
                    answer_executer=answer_executer,
                    global_selector=global_selector,
                    exploration_policy=exploration_policy,
                    previous_questions=[str(item.get("question") or "") for item in round_history],
                    allow_next_question=(question_index + 1 < self.max_rounds),
                    logger=logger,
                )
                profile_usage = merge_token_usage(profile_usage, usage)
                round_history.append(record)
                recent_records.append(record)
                self._append_insight(record, predicted_insights)

                # 新分析会话的第一问成功后，默认把它自然提出的下一问执行一次。
                if question_index < self.max_rounds and state.next_question:
                    proposal = dict(state.next_question)
                    state.next_question = None
                    proposal_triggers = list(proposal.get("trigger_evidence") or [])
                    question_index, usage, record = self._execute_analysis_agent_question(
                        task=task,
                        state=state,
                        question=str(proposal.get("question") or ""),
                        question_mode="protected_continuation",
                        trigger_evidence=proposal_triggers,
                        question_index=question_index,
                        batch_index=batch_index,
                        question_policy=question_policy,
                        code_executer=code_executer,
                        evidence_organizer=evidence_organizer,
                        answer_executer=answer_executer,
                        global_selector=global_selector,
                        exploration_policy=exploration_policy,
                        previous_questions=[str(item.get("question") or "") for item in round_history],
                        allow_next_question=(question_index + 1 < self.max_rounds),
                        logger=logger,
                    )
                    profile_usage = merge_token_usage(profile_usage, usage)
                    if bool(record.get("success")) and proposal_triggers:
                        self._remove_triggered_candidates(recent_records, proposal_triggers)
                    round_history.append(record)
                    recent_records.append(record)
                    self._append_insight(record, predicted_insights)

            control.update({
                "completed_batches": batch_index,
                "executed_rounds": question_index,
                "analysis_agent_count": len(analysis_agents),
            })
            self._last_profile_usage = dict(profile_usage)
            self._last_exploration_control = dict(control)

        if recent_records:
            self._discard_used_exploration_candidates(recent_records)
        if question_index >= self.max_rounds:
            control["termination_reason"] = "max_rounds_reached"
        elif control["termination_reason"] == "running":
            control["termination_reason"] = "loop_completed"
        control.update({
            "executed_rounds": question_index,
            "analysis_agent_count": len(analysis_agents),
        })
        self._last_profile_usage = dict(profile_usage)
        self._last_exploration_control = dict(control)
        return profile_usage, control

    def _create_analysis_agent(self, agent_id: str) -> AnalysisAgentState:
        """创建一个新的持续分析会话。"""
        return AnalysisAgentState(
            agent_id=str(agent_id),
            conversation=self.llm_client.start_conversation(ANALYSIS_BRANCH_SYSTEM_PROMPT),
        )

    def _execute_analysis_agent_question(
        self,
        *,
        task: InsightBenchTask,
        state: AnalysisAgentState,
        question: str,
        question_mode: str,
        trigger_evidence: Sequence[Mapping[str, Any]],
        question_index: int,
        batch_index: int,
        question_policy: QuestionPolicy,
        code_executer: CodeExecuter,
        evidence_organizer: EvidenceOrganizer,
        answer_executer: AnswerExecuter,
        global_selector: GlobalExplorationSelector,
        exploration_policy: Any,
        previous_questions: Sequence[str],
        allow_next_question: bool,
        logger: Optional[QueryLogger],
    ) -> Tuple[int, Dict[str, int], Dict[str, Any]]:
        """在指定分析会话中执行一个问题，并更新该会话的下一问。"""
        next_index = int(question_index) + 1
        success, record, usage = self._run_one_question(
            task=task,
            question=question,
            question_index=next_index,
            trigger_evidence=trigger_evidence,
            conversation=state.conversation,
            include_schema=(state.questions_completed == 0),
            code_executer=code_executer,
            evidence_organizer=evidence_organizer,
            answer_executer=answer_executer,
            logger=logger,
        )
        record.update({
            "round_index": next_index,
            "batch_index": int(batch_index),
            "analysis_agent_id": state.agent_id,
            "agent_question_index": state.questions_completed + 1,
            "question_mode": str(question_mode or ""),
        })

        if success:
            state.questions_completed += 1
            state.latest_insight = str(record.get("insight") or "").strip()
            if trigger_evidence:
                global_selector.mark_successful_directions(trigger_evidence)
                evidence_organizer.mark_selected_exploration(trigger_evidence)
            if allow_next_question:
                local_candidates = self._select_local_frontier_candidates(
                    record.get("exploration_candidates") or [],
                    question_index=next_index,
                )
                local_text = format_global_exploration_evidence(
                    local_candidates,
                    policy=exploration_policy,
                )
                local_by_id = {
                    str(item.get("id") or ""): dict(item)
                    for item in local_candidates
                    if str(item.get("id") or "").strip()
                }
                try:
                    proposal = question_policy.generate_local_next_question(
                        conversation=state.conversation,
                        current_question=question,
                        current_insight=state.latest_insight,
                        previous_questions=[*previous_questions, question],
                        selected_exploration_evidence=local_text,
                        selected_evidence_ids=list(local_by_id),
                        question_index=next_index,
                        logger=logger,
                    )
                except Exception as exc:
                    # 当前问题已经成功完成。局部续问生成失败只表示这条分析线暂时
                    # 没有下一问，不能反向把已完成的问题或整个任务判为失败。
                    self._log_planning_exception(
                        logger,
                        f"{state.agent_id}_question_{next_index}_next_question_error",
                        exc,
                    )
                    record["chain_stop_reason"] = "next_question_generation_failed"
                    proposal = None
                if proposal:
                    trigger_ids = list(proposal.get("trigger_evidence_ids") or [])
                    state.next_question = {
                        "question": str(proposal.get("question") or ""),
                        "trigger_evidence": [
                            local_by_id[evidence_id]
                            for evidence_id in trigger_ids
                            if evidence_id in local_by_id
                        ],
                    }
                else:
                    state.next_question = None
            else:
                state.next_question = None
        else:
            # 代码修复失败只结束当前分析线，不生成替代问题，也不影响其他会话。
            state.active = False
            state.next_question = None
        return next_index, usage, record

    def _select_local_frontier_candidates(
        self,
        candidates: Sequence[Mapping[str, Any]],
        *,
        question_index: int,
        limit: int = 3,
    ) -> List[Dict[str, Any]]:
        """为局部续问保留少量高质量且不重复的 frontier 线索。

        同一分析会话会多次生成局部续问，因此候选 ID 必须在会话历史中保持唯一。
        否则后续提示再次出现 ``F1`` 时，模型可能把它与早先问题中的 ``F1`` 混淆。
        """
        selected: List[Dict[str, Any]] = []
        seen: set[str] = set()
        ordered = sorted(
            [dict(item) for item in candidates if isinstance(item, Mapping)],
            key=lambda item: float(item.get("utility") or 0.0),
            reverse=True,
        )
        for item in ordered:
            signature = str(
                item.get("exploration_signature")
                or item.get("signature")
                or item.get("title")
                or ""
            ).strip().lower()
            if signature and signature in seen:
                continue
            if signature:
                seen.add(signature)
            # ID 只表达“本次已完成问题产生的局部线索”，不暴露分析会话或预算规则；
            # 加入问题序号仅用于避免持续会话历史中的 ID 重用。
            item["id"] = f"F{int(question_index)}_{len(selected) + 1}"
            selected.append(item)
            if len(selected) >= int(limit):
                break
        return selected

    def _build_continuation_candidates(
        self,
        analysis_agents: Mapping[str, AnalysisAgentState],
        *,
        generation_index: int = 1,
    ) -> List[Dict[str, Any]]:
        """把每个分析会话当前唯一的下一问整理成中性候选。

        候选 ID 只使用当前全局回顾序号和中性位置编号。这样既避免 ``P1`` 在
        不同轮次指代不同问题，也不会把内部分析会话 ID 或两轮保护规则暴露给提示词。
        """
        result: List[Dict[str, Any]] = []
        for position, state in enumerate(analysis_agents.values(), start=1):
            proposal = dict(state.next_question or {})
            question = str(proposal.get("question") or "").strip()
            if not state.active or not question:
                continue
            result.append({
                "id": f"P{int(generation_index)}_{position}",
                "question": question,
                "supporting_insight": state.latest_insight,
                "kind": "continuation",
                "analysis_agent_id": state.agent_id,
                "trigger_evidence": list(proposal.get("trigger_evidence") or []),
            })
        return result

    def _log_planning_exception(
        self,
        logger: Optional[QueryLogger],
        title: str,
        exc: BaseException,
    ) -> None:
        """记录非执行阶段异常；日志失败本身不能再次中断主流程。"""
        if logger is None:
            return
        try:
            logger.log_exception(str(title), exc)
        except Exception:
            pass

    def _build_global_question_pool(
        self,
        *,
        continuation_candidates: Sequence[Mapping[str, Any]],
        new_angles: Sequence[Mapping[str, Any]],
        selected_by_id: Mapping[str, Mapping[str, Any]],
        generation_index: int,
    ) -> List[Dict[str, Any]]:
        """合并局部续问与中央管理器补充的新角度。"""
        pool: List[Dict[str, Any]] = []
        for item in continuation_candidates:
            pool.append({
                "id": str(item.get("id") or ""),
                "question": str(item.get("question") or ""),
                "basis": str(item.get("supporting_insight") or ""),
                "kind": "continuation",
                "analysis_agent_id": str(item.get("analysis_agent_id") or ""),
                "trigger_evidence": list(item.get("trigger_evidence") or []),
            })
        for index, item in enumerate(new_angles, start=1):
            trigger_ids = [
                str(value or "").strip()
                for value in list(item.get("trigger_evidence_ids") or [])
                if str(value or "").strip()
            ]
            pool.append({
                "id": f"N{generation_index}_{index}",
                "question": str(item.get("question") or ""),
                "basis": "A different analytical angle proposed after reviewing the completed work.",
                "kind": "new_angle",
                "trigger_evidence": [
                    dict(selected_by_id[evidence_id])
                    for evidence_id in trigger_ids
                    if evidence_id in selected_by_id
                ],
            })
        return [item for item in pool if item["id"] and item["question"]]

    def _choose_executable_questions(
        self,
        *,
        candidate_pool: Sequence[Mapping[str, Any]],
        selected_ids: Sequence[str],
        remaining_budget: int,
    ) -> List[Dict[str, Any]]:
        """按实际剩余问题数选择可完整执行的候选。

        已有分析会话需要一个问题预算；新角度预留两个问题预算。该规则仅存在于
        代码中，提示词不讨论预算或会话创建。若模型只选择了当前预算无法完整执行
        的新角度，则退回到一个可执行的局部续问。
        """
        by_id = {
            str(item.get("id") or ""): dict(item)
            for item in candidate_pool
            if str(item.get("id") or "").strip()
        }
        remaining = max(0, int(remaining_budget))
        actions: List[Dict[str, Any]] = []
        new_angle_selected = False

        requested_ids: List[str] = []
        for candidate_id in selected_ids:
            normalized_id = str(candidate_id or "")
            item = by_id.get(normalized_id)
            if item is None or normalized_id in requested_ids:
                continue
            requested_ids.append(normalized_id)
            kind = str(item.get("kind") or "")
            cost = 2 if kind == "new_angle" else 1
            if kind == "new_angle" and new_angle_selected:
                continue
            if cost > remaining:
                continue
            actions.append(item)
            remaining -= cost
            new_angle_selected = new_angle_selected or kind == "new_angle"
            if len(actions) >= self.max_followup_choices:
                break

        # 若模型选择的组合与内部预算规则冲突，用一个未选中的局部续问补足该位置。
        requested_slots = min(len(requested_ids), self.max_followup_choices)
        if len(actions) < requested_slots and remaining >= 1:
            used_ids = {str(item.get("id") or "") for item in actions}
            for item in candidate_pool:
                item_id = str(item.get("id") or "")
                if item_id in used_ids or str(item.get("kind") or "") != "continuation":
                    continue
                actions.append(dict(item))
                remaining -= 1
                if len(actions) >= requested_slots or remaining <= 0:
                    break

        if actions or remaining_budget <= 0:
            return actions

        # 只剩一个问题预算且所选新角度无法完整执行时，退回一个现有续问。
        for item in candidate_pool:
            if str(item.get("kind") or "") == "continuation" and remaining >= 1:
                return [dict(item)]
        return []


    def _generate_root_unanswerable_insight(
        self,
        *,
        task: InsightBenchTask,
        root_answerability: Mapping[str, Any],
        logger: Optional[QueryLogger],
    ) -> Tuple[str, Dict[str, int], Dict[str, Any]]:
        """直接把 root manager 的不可回答原因作为正式 no-answer insight。

        root 阶段已经看过 context/goal/schema 并完成 answerability 判断，这里不再
        重新调用 LLM、不重复发送 schema，也不重新判断。若 reason 为空，仅使用
        一个确定性兜底句。
        """
        insight = self._format_root_unanswerable_insight(task, root_answerability)
        diagnostics = {
            "status": "root_reason_as_insight",
            "llm_rewrite": False,
        }
        return insight, dict(_ZERO_USAGE), diagnostics

    def _format_root_unanswerable_insight(
        self,
        task: InsightBenchTask,
        root_answerability: Mapping[str, Any],
    ) -> str:
        """把 root answerability.reason 作为 insight；仅在缺失时兜底。"""
        reason = str((root_answerability or {}).get("reason") or "").strip()
        if reason:
            return reason
        metadata = getattr(task, "metadata", {}) or {}
        goal = str(
            metadata.get("goal")
            or getattr(task, "query", "")
            or "the original analysis goal"
        ).strip()
        return (
            f"The original goal cannot be answered from the available schema because the required evidence for '{goal}' is missing from the provided tables."
        )

    def _discard_used_exploration_candidates(self, records: Sequence[Dict[str, Any]]) -> None:
        """全局选择完成后删除临时候选，避免把大段证据重复写入 round_history。"""
        for record in records:
            record.pop("exploration_candidates", None)

    def _remove_triggered_candidates(
        self,
        records: Sequence[Dict[str, Any]],
        trigger_evidence: Sequence[Mapping[str, Any]],
    ) -> None:
        """从当前待汇总记录中移除刚刚成功触发过的 frontier。

        受保护续问是在全局回顾前直接执行的。若不清理，触发该续问的 root/new-angle
        frontier 会在紧接着的全局回顾中再次出现。这里仅清理当前内存候选，不把
        retrieval 或 Join 方向永久退休；是否真正覆盖仍由成功 trace 状态决定。
        """
        identities = set()
        for item in list(trigger_evidence or []):
            identity = self._candidate_identity(item)
            if identity:
                identities.add(identity)
        if not identities:
            return
        for record in records:
            remaining = [
                dict(item)
                for item in list(record.get("exploration_candidates") or [])
                if isinstance(item, Mapping) and self._candidate_identity(item) not in identities
            ]
            record["exploration_candidates"] = remaining

    def _candidate_identity(self, item: Mapping[str, Any]) -> str:
        """生成仅用于当前批次去重的稳定候选标识。"""
        signature = str(
            item.get("exploration_signature")
            or item.get("signature")
            or ""
        ).strip()
        if signature:
            return f"signature:{signature}"
        title = " ".join(str(item.get("title") or "").lower().split())
        provenance = str(item.get("provenance") or "").strip()
        columns = ",".join(sorted(
            str(value or "").strip().lower()
            for value in list(item.get("columns") or [])
            if str(value or "").strip()
        ))
        return f"fallback:{provenance}|{title}|{columns}" if title or columns else ""

    # ------------------------------------------------------------------
    # 单个问题分支
    # ------------------------------------------------------------------

    def _run_one_question(
        self,
        *,
        task: InsightBenchTask,
        question: str,
        question_index: int,
        trigger_evidence: Sequence[Mapping[str, Any]],
        conversation: LLMConversation,
        include_schema: bool,
        code_executer: CodeExecuter,
        evidence_organizer: EvidenceOrganizer,
        answer_executer: AnswerExecuter,
        logger: Optional[QueryLogger],
    ) -> Tuple[bool, Dict[str, Any], Dict[str, int]]:
        """在同一会话内完成证据画像、代码、修复和最终解释。

        新分析会话的首问发送完整 Schema；同一会话中的后续问题、代码生成和修复
        都复用既有上下文，并在提示中要求遵循已经建立的 Schema。修复请求只发送
        当前 QEP、失败代码和错误信息。Trace 由代码执行器客观记录，不把 LLM 的
        语义判断混入运行时 lineage。
        """
        profiler = QuestionEvidenceProfiler(
            task=task,
            conversation=conversation,
            logger=logger,
        )
        try:
            evidence_profile = profiler.execute(
                round_index=question_index,
                fixed_question=question,
                trigger_evidence=[dict(item) for item in trigger_evidence],
                include_schema=bool(include_schema),
            )

            success, code_result = code_executer.execute(
                question_index=question_index,
                evidence_profile=evidence_profile,
                conversation=conversation,
            )

            if not success:
                error = str(code_result.get("error") or "unknown code execution error")[:1200]
                error_type = str(code_result.get("error_type") or classify_error_message(error, default=CODE_EXECUTION_ERROR))
                record = self._question_record(
                    question=question,
                    insight="",
                    evidence_payload={},
                    trigger_evidence=trigger_evidence,
                    success=False,
                    outcome="execution_error",
                    chain_stop_reason="code_execution_failed",
                    error_type=error_type,
                )
                return False, record, profiler.total_usage

            evidence_payload = evidence_organizer.organize(
                round_index=question_index,
                code_result=code_result,
                evidence_profile=evidence_profile,
            )
            interpretation = answer_executer.interpret_question(
                question_index=question_index,
                question=question,
                evidence_payload=evidence_payload,
                conversation=conversation,
            )
            record = self._question_record(
                question=question,
                insight=str(interpretation.get("insight") or "").strip(),
                evidence_payload=evidence_payload,
                trigger_evidence=trigger_evidence,
                success=True,
                outcome="answered",
                interpretation_diagnostics=dict(interpretation.get("diagnostics") or {}),
            )
            return True, record, profiler.total_usage
        except Exception as exc:
            error = str(exc)[:1200]
            error_type = classify_error_message(error, default=AGENT_RUNTIME_ERROR)
            record = self._question_record(
                question=question,
                insight="",
                evidence_payload={},
                trigger_evidence=trigger_evidence,
                success=False,
                outcome="branch_error",
                chain_stop_reason="question_branch_exception",
                error_type=error_type,
            )
            return False, record, profiler.total_usage

    def _question_record(
        self,
        *,
        question: str,
        insight: str,
        evidence_payload: Mapping[str, Any],
        trigger_evidence: Sequence[Mapping[str, Any]],
        success: bool,
        outcome: str,
        chain_stop_reason: str = "",
        error_type: str = "",
        interpretation_diagnostics: Optional[Mapping[str, Any]] = None,
    ) -> Dict[str, Any]:
        """构造单轮最小记录。

        只保存最终汇总和后续结果分析真正会使用的字段。局部探索候选仅在
        同批全局选择前临时挂载，选择结束后会立即删除；不再复制执行结果或证据卡全文。
        """
        visual_diagnostics = dict((evidence_payload or {}).get("diagnostics") or {})
        interpretation_diagnostics = dict(interpretation_diagnostics or {})
        diagnostic_error_types = [
            str(item)
            for item in list(visual_diagnostics.get("diagnostic_error_types") or [])
            if str(item or "").strip()
        ]
        interpretation_error_type = str(interpretation_diagnostics.get("error_type") or "").strip()
        if interpretation_error_type:
            diagnostic_error_types.append(interpretation_error_type)

        return {
            "question": question,
            "insight": insight,
            "success": bool(success),
            "outcome": str(outcome or ""),
            "chain_stop_reason": str(chain_stop_reason or ""),
            "error_type": str(error_type or ""),
            "diagnostic_error_types": sorted(set(diagnostic_error_types)),
            "visual_status": str(visual_diagnostics.get("visual_status") or ""),
            "visual_error": str(visual_diagnostics.get("visual_error") or ""),
            "interpretation_status": str(interpretation_diagnostics.get("interpretation_status") or ""),
            "interpretation_error": str(interpretation_diagnostics.get("error") or ""),
            "interpretation_fallback_fields": list(interpretation_diagnostics.get("fallback_fields") or []),
            "execution_summary": self._compact_execution_summary(evidence_payload),
            "exploration_candidates": list((evidence_payload or {}).get("exploration_candidates") or []),
            "trigger_evidence_ids": [
                str(item.get("id") or "")
                for item in list(trigger_evidence or [])
                if str(item.get("id") or "").strip()
            ],
        }

    def _compact_execution_summary(self, evidence_payload: Mapping[str, Any]) -> str:
        """提取给中央管理会话使用的短执行事实，不复制结果表。"""
        brief = dict((evidence_payload or {}).get("evidence_brief") or {})
        facts = [
            " ".join(str(item or "").split())
            for item in list(brief.get("key_facts") or [])[:3]
            if str(item or "").strip()
        ]
        caveats = [
            " ".join(str(item or "").split())
            for item in list(brief.get("caveats") or [])[:1]
            if str(item or "").strip()
        ]
        text = " | ".join([*facts, *[f"Caveat: {item}" for item in caveats]])
        return text[:700].rstrip()

    # ------------------------------------------------------------------
    # 轻量摘要
    # ------------------------------------------------------------------

    def _should_generate_summary(self, task: InsightBenchTask) -> bool:
        """BIRD experiments can skip summary because the evaluator scores insights only."""
        if self.generate_summary_config is not None:
            return bool(self.generate_summary_config)
        return task_benchmark(task) != "bird"

    def _compose_analysis_history(self, records: Sequence[Mapping[str, Any]]) -> str:
        """压缩给定记录中的问题、Insight 与执行摘要，供当前全局回顾读取。

        调用方只传自上次回顾后新完成的记录；更早内容已经保存在持续的 manager
        conversation 中，避免每轮重复序列化全部历史。
        """
        blocks: List[str] = []
        for index, record in enumerate(records, start=1):
            question = str(record.get("question") or "").strip()
            insight = str(record.get("insight") or "").strip() or "No valid insight was produced."
            execution_summary = str(record.get("execution_summary") or "").strip()
            block = f"[Q{index}]\nQuestion: {question}\nInsight: {insight}"
            if execution_summary:
                block += f"\nExecution evidence: {execution_summary}"
            blocks.append(block)
        return "\n\n".join(blocks)

    def _append_insight(self, record: Mapping[str, Any], predicted_insights: List[str]) -> None:
        """把成功分支的非空 Insight 加入全局预测列表。"""
        if not bool(record.get("success")):
            return
        insight = str(record.get("insight") or "").strip()
        if insight:
            predicted_insights.append(insight)
