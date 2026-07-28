"""evaluate/benchmarks.py
------------------------
官方 InsightBench 评估入口的本项目版本。

只保留大模型评估方式：
- evaluate_insights：pred insight 列表对 ground-truth insight 列表，one-to-many 匹配；
- evaluate_summary：最终 summary 字符串对 ground-truth summary 字符串，单对评分。

不再提供 rouge1 分支，避免实验结果和官方大模型 judge 口径混用。
"""

from __future__ import annotations

from typing import Any, Optional, Sequence

from llm_client import OpenAICompatibleClient
from query_logger import QueryLogger

from .metrics import (
    compute_g_eval_o2m,
    compute_llama3_eval_o2m,
    normalize_insights,
    normalize_text,
    score_insight,
)


_SUPPORTED_LLM_SCORES = {"g_eval", "llama3_eval"}


def evaluate_insights(
    pred_insights: Sequence[str],
    gt_insights: Sequence[str],
    score_name: str = "g_eval",
    *,
    llm_client: Optional[OpenAICompatibleClient] = None,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
    return_scores: bool = False,
) -> Any:
    """评估逐轮 insight 列表。

    对齐官方 one-to-many 逻辑：每条 ground-truth insight 都和所有预测 insight
    两两打分，取最高预测分数，最后对所有 ground-truth insight 求平均。
    """
    score_name = _normalize_score_name(score_name)
    pred_insights = normalize_insights(pred_insights)
    gt_insights = normalize_insights(gt_insights, keep_empty=True)
    if llm_client is None:
        raise RuntimeError(f"score_name={score_name} 需要评估模型客户端")

    if score_name == "g_eval":
        score, score_dict, _usage = compute_g_eval_o2m(
            pred_insights,
            gt_insights,
            llm_client=llm_client,
            logger=logger,
            model=model,
            top_logprobs=top_logprobs,
        )
    else:
        score, score_dict, _usage = compute_llama3_eval_o2m(
            pred_insights,
            gt_insights,
            llm_client=llm_client,
            logger=logger,
            model=model,
            top_logprobs=top_logprobs,
        )
    return (score, score_dict) if return_scores else score


def evaluate_summary(
    pred: str,
    gt: str,
    score_name: str = "g_eval",
    *,
    llm_client: Optional[OpenAICompatibleClient] = None,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> float:
    """评估最终 summary 文本。"""
    score_name = _normalize_score_name(score_name)
    if llm_client is None:
        raise RuntimeError(f"score_name={score_name} 需要评估模型客户端")
    score, _detail, _usage = score_insight(
        gt_insight=normalize_text(gt),
        pred_insight=normalize_text(pred),
        score_name=score_name,
        llm_client=llm_client,
        logger=logger,
        model=model,
        top_logprobs=top_logprobs,
    )
    return float(score)


def _normalize_score_name(score_name: str) -> str:
    """只允许官方大模型 judge 名称。"""
    name = str(score_name or "g_eval").strip().lower()
    if name not in _SUPPORTED_LLM_SCORES:
        raise ValueError(f"Only LLM evaluation is supported: {_SUPPORTED_LLM_SCORES}. Got {score_name!r}.")
    return name
