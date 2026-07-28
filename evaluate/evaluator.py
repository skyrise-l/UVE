"""evaluate/evaluator.py
-----------------------
官方 InsightBench 评估封装。

正式评估默认直接调用官方 ``insightbench.benchmarks``：

- ``benchmarks.evaluate_insights``
- ``benchmarks.evaluate_summary``

官方仓库路径通过 ``config["evaluation"]["official_insightbench_path"]`` 配置。
本文件只负责：
1. 把官方仓库加入 ``sys.path``；
2. 按 config 设置官方 evaluator 需要的环境变量；
3. 规范化主算法输出并调用官方评估入口；
4. 统一保存 task 级评估结果。

不再默认调用本项目内复刻的 ``evaluate/benchmarks.py``。
"""

from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional, Tuple

from data_loader import InsightBenchTask
from query_logger import QueryLogger
from .metrics import normalize_insights, normalize_text


@dataclass
class EvaluatorConfig:
    """评估配置。

    ``official_insightbench_path`` 指向官方 insight-bench 仓库根目录，
    该目录下应包含 ``insightbench/benchmarks.py``。
    """

    insight_score_name: str = "llama3_eval"
    summary_score_name: str = "llama3_eval"
    official_insightbench_path: str = ""
    judge_model: str = ""
    top_logprobs: int = 5
    llm: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "EvaluatorConfig":
        payload = dict(data or {})
        allowed = {key: value for key, value in payload.items() if key in cls.__dataclass_fields__}
        return cls(**allowed)


def build_evaluation_client(
    *,
    base_llm_config: Optional[Dict[str, Any]],
    evaluation_config: Optional[Dict[str, Any]],
):
    """保留旧调用入口，但官方 evaluator 不再需要项目内 LLM client。

    官方 ``insightbench`` 通过环境变量创建 OpenAI-compatible client。
    具体环境变量由 :class:`InsightBenchEvaluator` 初始化时配置。
    """
    return None


class InsightBenchEvaluator:
    """单个 InsightBench task 的官方评估器。"""

    def __init__(
        self,
        *,
        llm_client=None,
        config: Optional[Dict[str, Any]] = None,
        base_llm_config: Optional[Dict[str, Any]] = None,
    ):
        self.config = EvaluatorConfig.from_dict(config)
        self.base_llm_config = dict(base_llm_config or {})
        self._configure_official_eval_env(config or {}, self.base_llm_config)
        self._benchmarks = self._load_official_benchmarks(config or {})

    def skipped_result(self, reason: str, logger: Optional[QueryLogger] = None) -> Dict[str, Any]:
        """代码阶段失败时跳过当前 task 的评估。"""
        result = {
            "status": "skipped",
            "reason": str(reason or ""),
            "score_insights": 0.0,
            "score_summary": 0.0,
            "evaluation_source": "official_insightbench.benchmarks",
        }
        if logger is not None:
            logger.log_json("evaluation_skipped", result)
        return result

    def evaluate_task(
        self,
        *,
        task: InsightBenchTask,
        predicted_insights,
        predicted_summary: str,
        logger: Optional[QueryLogger] = None,
        skip_reason: str = "",
    ) -> Dict[str, Any]:
        """评估单个 task 的两个官方输出。"""
        if str(skip_reason or "").strip():
            return self.skipped_result(reason=skip_reason, logger=logger)

        pred_insights = normalize_insights(predicted_insights)
        pred_summary = normalize_text(predicted_summary)
        gold_insights = normalize_insights(task.gold_insights, keep_empty=True)
        gold_summary = normalize_text(task.gold_summary)

        insight_score_name = str(self.config.insight_score_name or "llama3_eval").lower()
        summary_score_name = str(self.config.summary_score_name or "llama3_eval").lower()

        if logger is not None:
            logger.log_json(
                "official_evaluation_start",
                {
                    "evaluation_source": "official_insightbench.benchmarks",
                    "official_insightbench_path": str(self.config.official_insightbench_path or "<installed>"),
                    "insight_score_name": insight_score_name,
                    "summary_score_name": summary_score_name,
                    "num_pred_insights": len(pred_insights),
                    "num_gold_insights": len(gold_insights),
                },
            )

        score_insights, insight_matches = self._evaluate_insights_official(
            pred_insights=pred_insights,
            gold_insights=gold_insights,
            score_name=insight_score_name,
        )
        score_summary = self._evaluate_summary_official(
            pred_summary=pred_summary,
            gold_summary=gold_summary,
            score_name=summary_score_name,
        )

        result = {
            "status": "evaluated",
            "evaluation_source": "official_insightbench.benchmarks",
            "official_insightbench_path": str(self.config.official_insightbench_path or "<installed>"),
            "score_insights": float(score_insights),
            "score_summary": float(score_summary),
            "score_overall": (float(score_insights) + float(score_summary)) / 2.0,
            "insight_score_name": insight_score_name,
            "summary_score_name": summary_score_name,
            "insight_matches": insight_matches,
        }
        if logger is not None:
            logger.log_json("evaluation_result", result)
        return result

    def _evaluate_insights_official(
        self,
        *,
        pred_insights: List[str],
        gold_insights: List[str],
        score_name: str,
    ) -> Tuple[float, List[Dict[str, Any]]]:
        """调用官方 insight-level evaluator。"""
        if not gold_insights:
            return 0.0, []
        if not pred_insights:
            return 0.0, [
                {"pred_insight": "", "gt_insight": gt, "score": 0.0}
                for gt in gold_insights
            ]
        score, matches = self._benchmarks.evaluate_insights(
            pred_insights=pred_insights,
            gt_insights=gold_insights,
            score_name=score_name,
            return_scores=True,
        )
        return float(score), _json_safe(matches)

    def _evaluate_summary_official(
        self,
        *,
        pred_summary: str,
        gold_summary: str,
        score_name: str,
    ) -> float:
        """调用官方 summary evaluator。"""
        if not pred_summary or not gold_summary:
            return 0.0
        return float(
            self._benchmarks.evaluate_summary(
                pred=pred_summary,
                gt=gold_summary,
                score_name=score_name,
            )
        )

    def _load_official_benchmarks(self, raw_config: Dict[str, Any]):
        """加载官方 ``insightbench.benchmarks``。"""
        official_path = str(raw_config.get("official_insightbench_path") or "").strip()
        if official_path:
            root = Path(official_path).expanduser().resolve()
            package_dir = root / "insightbench"
            if not package_dir.is_dir():
                raise FileNotFoundError(
                    "evaluation.official_insightbench_path 必须指向官方 insight-bench 仓库根目录，"
                    f"该目录下应包含 insightbench/。当前路径: {root}"
                )
            root_str = str(root)
            if root_str not in sys.path:
                sys.path.insert(0, root_str)

        try:
            from insightbench import benchmarks  # type: ignore
        except Exception as exc:
            raise RuntimeError(
                "无法导入官方 insightbench.benchmarks。请确认 config[\"evaluation\"] 中的 "
                "official_insightbench_path 指向官方 insight-bench 仓库根目录，并已安装官方依赖。"
                f" 原始错误: {type(exc).__name__}: {exc}"
            ) from exc
        return benchmarks

    def _configure_official_eval_env(
        self,
        raw_config: Dict[str, Any],
        base_llm_config: Dict[str, Any],
    ) -> None:
        """把 config 中的 evaluator 设置写入官方代码读取的环境变量。"""
        eval_llm = dict(raw_config.get("llm") or {})

        # llama3_eval uses LLAMA3_EVAL_* in official InsightBench.
        judge_model = str(raw_config.get("judge_model") or eval_llm.get("model") or "").strip()
        if judge_model:
            os.environ["LLAMA3_EVAL_MODEL"] = judge_model
        _set_env_from_config("LLAMA3_EVAL_BASE_URL", eval_llm, "base_url")
        _set_api_key_env("LLAMA3_EVAL_API_KEY", eval_llm)

        # g_eval uses OPENAI_* and G_EVAL_MODEL.
        if judge_model:
            os.environ["G_EVAL_MODEL"] = judge_model
        # Prefer evaluator endpoint for all official judge calls. Fall back to system LLM only if absent.
        openai_source = eval_llm if eval_llm.get("base_url") or eval_llm.get("api_key") else base_llm_config
        _set_env_from_config("OPENAI_BASE_URL", openai_source, "base_url")
        _set_api_key_env("OPENAI_API_KEY", openai_source)

        # Official retry knobs. API/network retry still belongs to official evaluator code.
        max_retries = eval_llm.get("max_retries") or raw_config.get("max_retries")
        if max_retries is not None:
            os.environ["INSIGHTBENCH_EVAL_MAX_RETRIES"] = str(max_retries)
        retry_sleep = eval_llm.get("retry_sleep") or raw_config.get("retry_sleep")
        if retry_sleep is not None:
            os.environ["INSIGHTBENCH_EVAL_RETRY_SLEEP"] = str(retry_sleep)

        if bool(raw_config.get("skip_healthcheck") or eval_llm.get("skip_healthcheck")):
            os.environ["LLAMA3_EVAL_SKIP_HEALTHCHECK"] = "1"


def _set_env_from_config(env_name: str, payload: Dict[str, Any], key: str) -> None:
    value = payload.get(key)
    if value is not None and str(value).strip():
        os.environ[env_name] = str(value).strip()


def _set_api_key_env(env_name: str, payload: Dict[str, Any]) -> None:
    """按 config api_key / api_key_env 设置目标环境变量。"""
    api_key = str(payload.get("api_key") or "").strip()
    if not api_key:
        source_env = str(payload.get("api_key_env") or "").strip()
        if source_env:
            api_key = str(os.environ.get(source_env) or "").strip()
    if api_key:
        os.environ[env_name] = api_key


def _json_safe(value: Any) -> Any:
    """把 numpy scalar 等官方 evaluator 返回值转为 json 可写类型。"""
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    try:
        import numpy as np  # type: ignore
        if isinstance(value, np.generic):
            return value.item()
    except Exception:
        pass
    return value
