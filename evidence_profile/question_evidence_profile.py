"""单轮问题证据画像生成器。

本模块替代旧 Logical Planner。它不再生成 S1/S2 步骤、输入列或中间变量，
而是围绕已选问题生成一个轻量语义画像，供同一问题分支中的代码生成、
视觉证据选择和最终解释共同使用。

输入：当前任务、已选问题、可选的触发探索证据。
输出：只包含后续真实会使用的 question_evidence_profile 字段。QEP 不再进行
可回答性拦截，也不输出执行计划。
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence

from analysis_tendency import normalize_analysis_tendency
from data_loader import InsightBenchTask
from llm_client import LLMConversation
from prompts import build_question_evidence_profile_prompt
from query_logger import QueryLogger
from vis_project_utils.utils import merge_token_usage


class QuestionEvidenceProfiler:
    """生成并规范化单个问题的证据画像。"""

    def __init__(
        self,
        *,
        task: InsightBenchTask,
        conversation: LLMConversation,
        logger: Optional[QueryLogger] = None,
    ) -> None:
        self.task = task
        self.conversation = conversation
        self.logger = logger
        self.total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

    def execute(
        self,
        *,
        round_index: int,
        fixed_question: str,
        trigger_evidence: Optional[Sequence[Dict[str, Any]]] = None,
        include_schema: bool = True,
    ) -> Dict[str, Any]:
        """围绕已选问题生成证据画像。

        `trigger_evidence` 只在问题由探索证据触发时提供。`include_schema` 仅在
        新分析会话的第一个问题为真；同一会话后续问题复用已有目标与 Schema。
        """
        prompt = build_question_evidence_profile_prompt(
            task=self.task,
            fixed_question=fixed_question,
            round_index=round_index,
            trigger_evidence=list(trigger_evidence or []),
            include_schema=bool(include_schema),
        )
        response = self.conversation.generate_json(
            step_name=f"round_{round_index}_evidence_profile",
            user_prompt=prompt,
            logger=self.logger,
        )
        self.total_usage = merge_token_usage(self.total_usage, response.usage)
        return self._normalize_profile(
            raw_profile=dict(response.parsed or {}),
            fallback_question=fixed_question,
        )

    def _normalize_profile(self, *, raw_profile: Dict[str, Any], fallback_question: str) -> Dict[str, Any]:
        """把模型输出压成稳定且最小的画像结构。"""
        # round_question 是调用侧已知输入，不再由 LLM 复制生成，避免模型改写问题。
        round_question = str(fallback_question or "").strip()

        raw_focus = raw_profile.get("evidence_focus")
        if isinstance(raw_focus, str):
            raw_focus = [raw_focus]
        if not isinstance(raw_focus, list):
            raw_focus = []

        evidence_focus: List[str] = []
        seen = set()
        for item in raw_focus:
            text = self._clean_text(item, max_chars=360)
            key = " ".join(text.lower().split())
            if not text or key in seen:
                continue
            seen.add(key)
            evidence_focus.append(text)
            if len(evidence_focus) >= 4:
                break
        if not evidence_focus:
            evidence_focus = ["Preserve compact, concrete evidence that directly answers the selected question."]

        return {
            "round_question": round_question,
            "evidence_focus": evidence_focus,
            "analysis_tendency": normalize_analysis_tendency(
                raw_profile.get("analysis_tendency"),
                question_text=round_question,
            ),
        }

    def _clean_text(self, value: Any, *, max_chars: int) -> str:
        """压缩空白并限制长度，避免画像文本在后续多次传递时膨胀。"""
        text = " ".join(str(value or "").split()).strip()
        if len(text) <= max_chars:
            return text
        return text[: max(0, max_chars - 3)].rstrip() + "..."
