"""
evaluate/metrics.py
-------------------
InsightBench 风格的评估底层实现。

这版重点对齐官方开源实现：
1. `compute_rouge`：insight 级 one-to-many matching；
2. `score_insight`：summary / 单对文本直接打分；
3. `compute_g_eval_o2m` / `compute_llama3_eval_o2m`：名称与逻辑尽量贴近官方；
4. G-Eval prompt 与 1-10 分缩放方式对齐官方。

说明：
- 官方仓库的 G-Eval 会尝试读取 top_logprobs 做加权评分；
- 这里同样支持 `top_logprobs`，若后端不返回对应字段，则自动回退为解析模型明文评分。
"""

from __future__ import annotations

from collections import Counter, defaultdict
import json
import math
import random
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

from llm_client import OpenAICompatibleClient
from query_logger import QueryLogger
from vis_project_utils.utils import merge_token_usage, safe_float

from .prompts import get_g_eval_prompt

_WORD_RE = re.compile(r"[a-z0-9]+")
_SCORE_RE = re.compile(r"(-?\d+(?:\.\d+)?)")
_THINK_BLOCK_RE = re.compile(r"<think>.*?</think>", re.IGNORECASE | re.DOTALL)
_THINK_START_RE = re.compile(r"<think>.*$", re.IGNORECASE | re.DOTALL)
_SCORE_KEY_RE = re.compile(r"[\']?(?:score|rating|final_score)[\']?\s*[:=]\s*[\']?(-?\d+(?:\.\d+)?)", re.IGNORECASE)
_SCORE_LABEL_RE = re.compile(r"(?:final\s*(?:answer|score|rating)|score|rating)\s*(?:is|=|:|：)\s*(-?\d+(?:\.\d+)?)", re.IGNORECASE)
_NUMERIC_LINE_RE = re.compile(r"^\s*(-?\d+(?:\.\d+)?)(?:\s*/\s*10)?\s*[。.!]?\s*$")
_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

try:  # pragma: no cover
    import evaluate as hf_evaluate
except Exception:  # pragma: no cover
    hf_evaluate = None

try:  # pragma: no cover
    from rouge_score import rouge_scorer
except Exception:  # pragma: no cover
    rouge_scorer = None


def normalize_text(text: Any) -> str:
    """轻量规范化文本。"""
    return re.sub(r"\s+", " ", str(text or "").strip())


def tokenize(text: Any) -> List[str]:
    """按英文数字 token 切分。"""
    return _WORD_RE.findall(normalize_text(text).lower())


def normalize_insights(raw_insights: Any, *, keep_empty: bool = False) -> List[str]:
    """把多种输入形态统一成字符串列表。

    keep_empty=True 用于对齐官方 InsightBench：gold insights 原样参与匹配，
    包括 flag-36 这种空字符串 gold。
    """
    normalized: List[str] = []
    if raw_insights is None:
        return normalized
    if isinstance(raw_insights, str):
        cleaned = normalize_text(raw_insights)
        return [cleaned] if (cleaned or keep_empty) else []
    if not isinstance(raw_insights, Sequence):
        return normalized

    for item in raw_insights:
        if isinstance(item, str):
            cleaned = normalize_text(item)
            if cleaned or keep_empty:
                normalized.append(cleaned)
            continue
        if isinstance(item, dict):
            found = False
            for key in ("insight", "text", "summary"):
                if key in item:
                    cleaned = normalize_text(item.get(key))
                    if cleaned or keep_empty:
                        normalized.append(cleaned)
                    found = True
                    break
            if keep_empty and not found:
                normalized.append("")
    return normalized


_rouge_metric = None


def _load_hf_rouge():  # pragma: no cover
    global _rouge_metric
    if hf_evaluate is None or not hasattr(hf_evaluate, "load"):
        return None
    if _rouge_metric is None:
        _rouge_metric = hf_evaluate.load("rouge")
    return _rouge_metric


def compute_rouge_score(pred_text: str, gt_text: str) -> float:
    """计算单对文本的 rouge1 分数。"""
    pred_text = normalize_text(pred_text)
    gt_text = normalize_text(gt_text)
    if not pred_text or not gt_text:
        return 0.0

    metric = _load_hf_rouge()
    if metric is not None:  # pragma: no cover
        try:
            result = metric.compute(predictions=[pred_text], references=[gt_text], rouge_types=["rouge1"])
            return float(result.get("rouge1", 0.0))
        except Exception:
            pass

    if rouge_scorer is not None:  # pragma: no cover
        try:
            scorer = rouge_scorer.RougeScorer(["rouge1"], use_stemmer=True)
            return float(scorer.score(gt_text, pred_text)["rouge1"].fmeasure)
        except Exception:
            pass

    pred_tokens = tokenize(pred_text)
    gt_tokens = tokenize(gt_text)
    if not pred_tokens or not gt_tokens:
        return 0.0
    pred_counter = Counter(pred_tokens)
    gt_counter = Counter(gt_tokens)
    overlap = sum((pred_counter & gt_counter).values())
    precision = overlap / max(len(pred_tokens), 1)
    recall = overlap / max(len(gt_tokens), 1)
    if precision + recall == 0:
        return 0.0
    return float(2 * precision * recall / (precision + recall))


def _strip_thinking_blocks(content: str) -> str:
    """移除 reasoning 模型常见的 <think>...</think> 区块。

    评估 parser 不能从思考过程里抓数字，否则 `1-10`、`247`、
    `Printer546` 等都会被误认为最终分数。
    """
    text = str(content or "").strip()
    text = _THINK_BLOCK_RE.sub("", text).strip()
    text = _THINK_START_RE.sub("", text).strip()
    return text


def _coerce_score(value: Any) -> Optional[float]:
    """把候选分数约束到 1-10；无效候选返回 None。"""
    score = safe_float(value, None)
    if score is None:
        return None
    if 1.0 <= score <= 10.0:
        return float(score)
    return None


def _parse_json_score(content: str) -> Optional[float]:
    """兼容 judge 返回 JSON 的情况，例如 {"score": 8}."""
    candidate = str(content or "").strip()
    if not candidate:
        return None

    try:
        parsed = json.loads(candidate)
    except Exception:
        parsed = None
    if isinstance(parsed, dict):
        for key in ("score", "rating", "final_score"):
            if key in parsed:
                score = _coerce_score(parsed.get(key))
                if score is not None:
                    return score

    match = re.search(r"\{.*?\}", candidate, flags=re.DOTALL)
    if match:
        try:
            parsed = json.loads(match.group(0))
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            for key in ("score", "rating", "final_score"):
                if key in parsed:
                    score = _coerce_score(parsed.get(key))
                    if score is not None:
                        return score
    return None


def parse_judge_score(content: str) -> Dict[str, Any]:
    """稳健解析 LLM judge 的最终 1-10 分数。

    解析策略只看最终答案区，而不是全文第一个数字。优先级：
    1. 去掉 <think> 后的 JSON score；
    2. 去掉 <think> 后整体就是一个数字；
    3. 带标签的 final score / score / rating；
    4. 最后一行独立数字；
    5. 兜底取最终答案区最后一个 1-10 数字。

    如果模型只输出了被截断的 <think> 而没有最终答案，则返回 0，
    并在 detail 中标记 parse_method=missing_score。
    """
    raw = str(content or "")
    cleaned = _strip_thinking_blocks(raw)
    search_spaces = [cleaned, raw] if cleaned != raw else [cleaned]

    for candidate in search_spaces:
        score = _parse_json_score(candidate)
        if score is not None:
            return {"score": score, "parse_method": "json_score", "cleaned_output": cleaned}

    exact = cleaned.strip()
    exact_match = _NUMERIC_LINE_RE.match(exact)
    if exact_match:
        score = _coerce_score(exact_match.group(1))
        if score is not None:
            return {"score": score, "parse_method": "exact_numeric", "cleaned_output": cleaned}

    for pattern, method in ((_SCORE_KEY_RE, "score_key"), (_SCORE_LABEL_RE, "score_label")):
        matches = list(pattern.finditer(cleaned))
        for match in reversed(matches):
            score = _coerce_score(match.group(1))
            if score is not None:
                return {"score": score, "parse_method": method, "cleaned_output": cleaned}

    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    for line in reversed(lines[-5:]):
        match = _NUMERIC_LINE_RE.match(line)
        if match:
            score = _coerce_score(match.group(1))
            if score is not None:
                return {"score": score, "parse_method": "final_numeric_line", "cleaned_output": cleaned}

    numeric_matches = list(_SCORE_RE.finditer(cleaned))
    for match in reversed(numeric_matches):
        score = _coerce_score(match.group(1))
        if score is not None:
            return {"score": score, "parse_method": "last_numeric_fallback", "cleaned_output": cleaned}

    return {"score": 0.0, "parse_method": "missing_score", "cleaned_output": cleaned}


def _extract_score_from_text(content: str) -> float:
    """从 judge 文本里解析 1-10 的评分，保留旧接口。"""
    return float(parse_judge_score(content).get("score", 0.0))


def _request_llm_judge(
    *,
    llm_client: OpenAICompatibleClient,
    step_name: str,
    system_prompt: str,
    user_prompt: str,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    temperature: Optional[float] = None,
    top_logprobs: int = 5,
) -> Tuple[str, Dict[str, Any], Dict[str, int]]:
    """通过统一 LLM client 请求 judge。

    这里不走 `generate_json`，因为官方 G-Eval 是纯文本数值输出，
    同时还会可选请求 `logprobs/top_logprobs`，需要保留原始 choice。
    """
    response = llm_client.chat_completion_raw(
        step_name=step_name,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        logger=logger,
        model=model,
        temperature=temperature,

        max_tokens=1024,
        top_p=1,
        logprobs=bool(top_logprobs and int(top_logprobs) > 0),
        top_logprobs=int(top_logprobs) if top_logprobs and int(top_logprobs) > 0 else None,
    )
    return response.content, response.choice, response.usage


def _expected_score_from_top_logprobs(choice: Dict[str, Any], rating_text: str) -> Optional[float]:
    """尽量复现官方基于 top_logprobs 的期望分数计算。"""
    logprobs = choice.get("logprobs") or {}
    content_items = logprobs.get("content") or []
    if not isinstance(content_items, list) or not content_items:
        return None

    target = str(rating_text or "").strip()
    if not target:
        return None

    for item in content_items:
        if not isinstance(item, dict):
            continue
        token_text = str(item.get("token") or "").strip()
        if token_text != target:
            continue
        top_candidates = item.get("top_logprobs") or []
        if not isinstance(top_candidates, list) or not top_candidates:
            return None

        weights: List[Tuple[float, float]] = []
        for candidate in top_candidates:
            if not isinstance(candidate, dict):
                continue
            cand_token = str(candidate.get("token") or "").strip()
            if not cand_token:
                continue
            try:
                prob = math.exp(float(candidate.get("logprob")))
            except Exception:
                continue
            score_match = _SCORE_RE.search(cand_token)
            score_value = float(score_match.group(1)) if score_match else 0.0
            weights.append((score_value, prob))

        if not weights:
            return None
        total_prob = sum(prob for _score, prob in weights)
        if total_prob <= 0:
            return None
        return sum(score * prob for score, prob in weights) / total_prob

    return None


def compute_g_eval(
    pred_insight: str,
    gt_insight: str,
    *,
    llm_client: OpenAICompatibleClient,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> Tuple[float, str, Dict[str, int], Dict[str, Any]]:
    """计算官方风格的 G-Eval 原始分数（0-10）。"""
    template, system_message = get_g_eval_prompt(method="basic")
    user_prompt = template.format(answer=normalize_text(pred_insight), gt_answer=normalize_text(gt_insight))
    content, choice, usage = _request_llm_judge(
        llm_client=llm_client,
        step_name="eval_g_eval_pair",
        system_prompt=system_message,
        user_prompt=user_prompt,
        logger=logger,
        model=model,
        top_logprobs=top_logprobs,
    )
    parse_info = parse_judge_score(content)
    parsed_score = float(parse_info.get("score", 0.0))

    # 只有模型最终答案本身就是一个纯数字时，top_logprobs 的 token 位置才可靠。
    # 如果输出包含 <think>/解释/JSON，全文中可能有多个同样数字，不能用第一个匹配 token
    # 计算期望分，否则会复现把 `1-10` 里的 1 当成分数的问题。
    expected_score = None
    if parse_info.get("parse_method") == "exact_numeric":
        expected_score = _expected_score_from_top_logprobs(
            choice,
            str(int(parsed_score)) if parsed_score.is_integer() else str(parsed_score),
        )
    raw_score = expected_score if expected_score is not None else parsed_score
    raw_score = min(10.0, max(0.0, raw_score))
    return raw_score, content, usage, parse_info


def compute_llama3_eval(
    pred_insight: str,
    gt_insight: str,
    *,
    llm_client: OpenAICompatibleClient,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> Tuple[float, str, Dict[str, int], Dict[str, Any]]:
    """与官方接口保持一致；当前统一走同一类 judge 请求。"""
    return compute_g_eval(
        pred_insight=pred_insight,
        gt_insight=gt_insight,
        llm_client=llm_client,
        logger=logger,
        model=model,
        top_logprobs=top_logprobs,
    )


def score_insight(
    gt_insight: str,
    pred_insight: str,
    score_name: str,
    *,
    llm_client: Optional[OpenAICompatibleClient] = None,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> Tuple[float, Dict[str, Any], Dict[str, int]]:
    """Get the scoring function based on the score_name.

    返回：
    - score: 0-1
    - detail: 详细信息
    - usage: token 使用量
    """
    score_name = str(score_name or "g_eval").strip().lower()
    gt_insight = normalize_text(gt_insight)
    pred_insight = normalize_text(pred_insight)

    if score_name == "rouge1":
        score = compute_rouge_score(pred_insight, gt_insight)
        return score, {"metric": "rouge1", "score": score}, dict(_ZERO_USAGE)

    if llm_client is None:
        raise RuntimeError(f"score_name={score_name} 需要评估模型客户端")

    parse_info: Dict[str, Any] = {}

    if score_name == "g_eval":
        raw_score, raw_text, usage, parse_info = compute_g_eval(
            pred_insight=pred_insight,
            gt_insight=gt_insight,
            llm_client=llm_client,
            logger=logger,
            model=model,
            top_logprobs=top_logprobs,
        )
    elif score_name == "llama3_eval":
        raw_score, raw_text, usage, parse_info = compute_llama3_eval(
            pred_insight=pred_insight,
            gt_insight=gt_insight,
            llm_client=llm_client,
            logger=logger,
            model=model,
            top_logprobs=top_logprobs,
        )
    else:
        raise ValueError(f"Unknown score_name: {score_name}")

    score = raw_score / 10.0
    score = min(1.0, max(0.0, score))
    detail = {
        "metric": score_name,
        "raw_score": raw_score,
        "score": score,
        "raw_judge_output": raw_text,
        "judge_score_parse_method": parse_info.get("parse_method", ""),
        "judge_cleaned_output": parse_info.get("cleaned_output", ""),
    }
    return score, detail, usage


def compute_rouge(pred_insights: Sequence[str], gt_insights: Sequence[str]) -> Tuple[float, List[Dict[str, Any]]]:
    """官方 InsightBench 风格的 rouge1 one-to-many matching。"""
    pred_insights = normalize_insights(pred_insights)
    gt_insights = normalize_insights(gt_insights, keep_empty=True)
    if not gt_insights:
        return 0.0, []

    score_dict = defaultdict(list)
    for gt_id, gt_insight in enumerate(gt_insights):
        for pred_id, pred_insight in enumerate(pred_insights):
            score, _detail, _usage = score_insight(gt_insight, pred_insight, score_name="rouge1")
            score_dict[gt_id].append(score)

    matches: List[Dict[str, Any]] = []
    for gt_id, scores in score_dict.items():
        if not scores:
            matches.append(
                {
                    "pred_insight": "",
                    "gt_insight": gt_insights[gt_id],
                    "score": 0.0,
                }
            )
            continue
        best_pred_id = max(range(len(scores)), key=lambda idx: scores[idx])
        matches.append(
            {
                "pred_insight": pred_insights[best_pred_id],
                "gt_insight": gt_insights[gt_id],
                "score": float(scores[best_pred_id]),
            }
        )
    score = float(sum(item["score"] for item in matches) / len(matches)) if matches else 0.0
    return score, matches


def compute_g_eval_o2m(
    pred_insights: Sequence[str],
    gt_insights: Sequence[str],
    *,
    llm_client: OpenAICompatibleClient,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> Tuple[float, List[Dict[str, Any]], Dict[str, int]]:
    """Compute the G-Eval score for a list of predictions and ground truths."""
    pred_insights = normalize_insights(pred_insights)
    gt_insights = normalize_insights(gt_insights, keep_empty=True)
    if not gt_insights:
        return 0.0, [], dict(_ZERO_USAGE)

    total_usage = dict(_ZERO_USAGE)
    score_dict: List[Dict[str, Any]] = []
    for gt_insight in gt_insights:
        if not pred_insights:
            score_dict.append({"pred_insight": "", "gt_insight": gt_insight, "score": 0.0})
            continue
        candidate_scores: List[Tuple[int, float, Dict[str, Any], Dict[str, int]]] = []
        for pred_id, pred_insight in enumerate(pred_insights):
            score, detail, usage = score_insight(
                gt_insight,
                pred_insight,
                score_name="g_eval",
                llm_client=llm_client,
                logger=logger,
                model=model,
                top_logprobs=top_logprobs,
            )
            total_usage = merge_token_usage(total_usage, usage)
            candidate_scores.append((pred_id, score, detail, usage))
        best_pred_id, best_score, best_detail, _ = max(candidate_scores, key=lambda item: item[1])
        score_dict.append(
            {
                "pred_insight": pred_insights[best_pred_id],
                "gt_insight": gt_insight,
                "score": best_score,
                "raw_score": best_detail.get("raw_score"),
                "raw_judge_output": best_detail.get("raw_judge_output", ""),
                "judge_score_parse_method": best_detail.get("judge_score_parse_method", ""),
                "judge_cleaned_output": best_detail.get("judge_cleaned_output", ""),
            }
        )
    score = float(sum(item["score"] for item in score_dict) / len(score_dict)) if score_dict else 0.0
    return score, score_dict, total_usage


def compute_llama3_eval_o2m(
    pred_insights: Sequence[str],
    gt_insights: Sequence[str],
    *,
    llm_client: OpenAICompatibleClient,
    logger: Optional[QueryLogger] = None,
    model: Optional[str] = None,
    top_logprobs: int = 5,
) -> Tuple[float, List[Dict[str, Any]], Dict[str, int]]:
    """Compute the LLaMA-3-Eval score for a list of predictions and ground truths."""
    pred_insights = normalize_insights(pred_insights)
    gt_insights = normalize_insights(gt_insights, keep_empty=True)
    if not gt_insights:
        return 0.0, [], dict(_ZERO_USAGE)

    total_usage = dict(_ZERO_USAGE)
    score_dict: List[Dict[str, Any]] = []
    for gt_insight in gt_insights:
        if not pred_insights:
            score_dict.append({"pred_insight": "", "gt_insight": gt_insight, "score": 0.0})
            continue
        candidate_scores: List[Tuple[int, float, Dict[str, Any], Dict[str, int]]] = []
        for pred_id, pred_insight in enumerate(pred_insights):
            score, detail, usage = score_insight(
                gt_insight,
                pred_insight,
                score_name="llama3_eval",
                llm_client=llm_client,
                logger=logger,
                model=model,
                top_logprobs=top_logprobs,
            )
            total_usage = merge_token_usage(total_usage, usage)
            candidate_scores.append((pred_id, score, detail, usage))
        best_pred_id, best_score, best_detail, _ = max(candidate_scores, key=lambda item: item[1])
        score_dict.append(
            {
                "pred_insight": pred_insights[best_pred_id],
                "gt_insight": gt_insight,
                "score": best_score,
                "raw_score": best_detail.get("raw_score"),
                "raw_judge_output": best_detail.get("raw_judge_output", ""),
                "judge_score_parse_method": best_detail.get("judge_score_parse_method", ""),
                "judge_cleaned_output": best_detail.get("judge_cleaned_output", ""),
            }
        )
    score = float(sum(item["score"] for item in score_dict) / len(score_dict)) if score_dict else 0.0
    return score, score_dict, total_usage
