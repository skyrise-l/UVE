"""main.py
-------
项目主入口。

主流程：读取配置 -> 加载任务 -> 跳过已完成任务 -> 运行 agent -> 按配置评估 -> 保存结果。
"""

from __future__ import annotations

import argparse
import json
import shutil
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from agent import InsightBenchAgent
from visual_policy_experiment import VisualPolicyComparisonAgent
from code_execute.error_classification import EVALUATION_ERROR, classify_error_message
from data_loader import MetadataEnrichmentConfig, load_tasks, stream_bird_tasks
from evaluate import BirdEDAEvaluator, InsightBenchEvaluator, build_evaluation_client
from llm_client import LLMConfig, OpenAICompatibleClient
from query_logger import QueryLogger
from vis_project_utils.utils import ensure_dir, read_json, write_json

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run visual-evidence experiments.")
    parser.add_argument("--config", type=str, default="config.json", help="配置文件路径")
    return parser.parse_args()


def _normalize_benchmark_name(value: Any) -> str:
    name = str(value or "insightbench").strip().lower().replace("_", "").replace("-", "")
    if name in {"insightbench", "insight"}:
        return "insightbench"
    if name in {"bird", "birdeda", "birdmted", "birdmultitableeda"}:
        return "bird"
    raise ValueError(f"当前主项目只支持 InsightBench 和 BIRD，收到未知 benchmark: {value}")


def _persist_bird_evaluation_report(
    evaluation: Dict[str, Any],
    output_dir: Path,
    *,
    filename: str = "bird_evaluation_report.json",
) -> Dict[str, Any]:
    """Save the compact BIRD evaluation report outside result.json."""
    payload = dict(evaluation or {})
    report = payload.pop("_evaluation_report", None)
    if isinstance(report, dict) and report:
        report_path = output_dir / filename
        write_json(report_path, report)
        payload["evaluation_report_path"] = report_path.name
    return payload


def _task_id(task: Any) -> str:
    if hasattr(task, "task_id"):
        return str(getattr(task, "task_id"))
    json_path = getattr(task, "json_path", None)
    if json_path is not None:
        return Path(json_path).stem
    return "unknown_task"


def _run_metadata(
    config_path: str,
    benchmark: str,
    agent_mode: str,
    evaluation_enabled: bool,
) -> Dict[str, Any]:
    """记录本次实验的基本运行方式。"""
    return {
        "run_id": f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}_{uuid.uuid4().hex[:8]}",
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "config_path": str(Path(config_path).resolve()),
        "benchmark": benchmark,
        "agent_mode": agent_mode,
        "evaluation_enabled": bool(evaluation_enabled),
    }


def _evaluation_enabled(config: Mapping[str, Any]) -> bool:
    """读取评估开关；未配置时保持原有的默认评估行为。"""
    evaluation_config = dict(config.get("evaluation") or {})
    return bool(evaluation_config.get("enabled", True))


def _disabled_evaluation_result() -> Dict[str, Any]:
    """评估关闭时写入一个明确状态，不伪造任何分数。"""
    return {
        "status": "disabled",
        "reason": "evaluation.enabled=false",
    }


def _load_existing_task_result(
    result_path: Path,
    task_id: str,
    expected_agent_mode: str,
    *,
    require_evaluation: bool,
) -> Optional[Dict[str, Any]]:
    """复用已有成功结果；开启评估时额外要求 evaluation 已完成。"""
    if not result_path.is_file():
        return None
    try:
        result = read_json(result_path)
    except Exception as exc:
        print(f"[WARN] existing result unreadable, rerun task={task_id}: {exc}")
        return None

    if not isinstance(result, dict) or str(result.get("task_id") or "") != task_id:
        return None
    if str(result.get("agent_mode") or "") != expected_agent_mode:
        return None

    agent_result = result.get("agent_result")
    if not isinstance(agent_result, dict):
        return None
    if str(agent_result.get("error") or "").strip():
        return None

    if require_evaluation:
        evaluation = result.get("evaluation")
        if not isinstance(evaluation, dict):
            return None
        if str(evaluation.get("status") or "").strip().lower() != "evaluated":
            return None
    return result


def _clean_task_output_dir(run_path: Path) -> None:
    if run_path.exists():
        shutil.rmtree(run_path)
    run_path.mkdir(parents=True, exist_ok=True)


def _score_row_from_result(task_result: Dict[str, Any], benchmark: str) -> Dict[str, Any]:
    evaluation = dict(task_result.get("evaluation") or {})
    agent_result = dict(task_result.get("agent_result") or {})
    token_usage = dict(agent_result.get("token_usage") or {})
    row: Dict[str, Any] = {
        "task_id": str(task_result.get("task_id") or ""),
        "status": str(evaluation.get("status") or ""),
        "run_status": str(agent_result.get("run_status") or ""),
        "error": str(agent_result.get("error") or ""),
        "error_type": str(agent_result.get("error_type") or ""),
        "error_type_counts": dict(agent_result.get("error_type_counts") or {}),
        "duration_sec": float(agent_result.get("duration_sec") or 0.0),
        "prompt_tokens": int(token_usage.get("prompt_tokens") or 0),
        "completion_tokens": int(token_usage.get("completion_tokens") or 0),
        "total_tokens": int(token_usage.get("total_tokens") or 0),
    }
    if benchmark == "bird":
        row["metric"] = str(evaluation.get("metric") or "harmonic_grounded_coverage")
        row["score"] = float(evaluation.get("score") or 0.0)
        row["num_pairs"] = int(evaluation.get("num_pairs") or 0)
        row["numeric_anchor_mean_on_best_pairs"] = float(evaluation.get("numeric_anchor_mean_on_best_pairs") or 0.0)
        row["num_numeric_anchors"] = int(evaluation.get("num_numeric_anchors") or 0)
        row["num_numeric_anchors_matched"] = int(evaluation.get("num_numeric_anchors_matched") or 0)
        row["num_numeric_anchors_partial"] = int(evaluation.get("num_numeric_anchors_partial") or 0)
    else:
        row["score_insights"] = float(evaluation.get("score_insights") or 0.0)
        row["score_summary"] = float(evaluation.get("score_summary") or 0.0)
        row["score_overall"] = float(evaluation.get("score_overall") or 0.0)
    return row


def _load_tasks_from_config(
    *,
    benchmark: str,
    dataset_config: Dict[str, Any],
    enrichment_config: MetadataEnrichmentConfig,
) -> Iterable[Any]:
    data_root = dataset_config.get("data_root")
    if not data_root:
        raise ValueError("配置文件缺少 dataset.data_root")

    limit = dataset_config.get("limit")
    metadata_cache_dir = dataset_config.get("metadata_cache_dir", "./cache/metadata")

    if benchmark == "bird":
        bird_config = dict(dataset_config.get("bird") or {})
        return stream_bird_tasks(
            data_root=data_root,
            task_jsonl=bird_config.get("task_jsonl") or dataset_config.get("task_jsonl"),
            limit=bird_config.get("limit", limit),
            offset=int(bird_config.get("offset") or dataset_config.get("offset") or 0),
            enrichment_config=enrichment_config,
            metadata_cache_dir=metadata_cache_dir,
            table_selection=str(
                bird_config.get("table_selection")
                or dataset_config.get("table_selection")
                or "gold_tables"
            ),
        )

    return load_tasks(
        data_root,
        limit=limit,
        enrichment_config=enrichment_config,
        metadata_cache_dir=metadata_cache_dir,
    )


def _build_agent_and_evaluator(
    *,
    benchmark: str,
    config: Dict[str, Any],
    llm_client: OpenAICompatibleClient,
    evaluation_enabled: bool = True,
) -> Tuple[Any, Optional[Any], str]:
    agent_config = dict(config.get("agent") or {})
    requested_mode = str(agent_config.get("mode") or "main").strip().lower()

    if requested_mode == "visual_policy_comparison":
        agent = VisualPolicyComparisonAgent(llm_client=llm_client, config=config)
        agent_mode = "visual_policy_comparison"
    elif requested_mode == "main":
        agent = InsightBenchAgent(llm_client=llm_client, config=config)
        agent_mode = "bird_eda_v2" if benchmark == "bird" else "insightbench"
    else:
        raise ValueError(f"Unsupported agent.mode: {requested_mode}")

    # 关闭评估时不初始化 judge client 或官方评估依赖，避免无意义的模型和环境检查。
    if not evaluation_enabled:
        return agent, None, agent_mode

    if benchmark == "bird":
        evaluator = BirdEDAEvaluator(
            config=config.get("evaluation"),
            base_llm_config=config.get("system_llm"),
        )
        return agent, evaluator, agent_mode

    evaluation_client = build_evaluation_client(
        base_llm_config=config.get("system_llm"),
        evaluation_config=config.get("evaluation"),
    )
    evaluator = InsightBenchEvaluator(
        llm_client=evaluation_client,
        config=config.get("evaluation"),
        base_llm_config=config.get("system_llm"),
    )
    return agent, evaluator, agent_mode


def _failed_agent_result(exc: Exception) -> Dict[str, Any]:
    error_type = classify_error_message(str(exc), default="agent_runtime_error")
    return {
        "predicted_insights": [],
        "predicted_summary": "",
        "round_history": [],
        "duration_sec": 0.0,
        "token_usage": dict(_ZERO_USAGE),
        "error": str(exc),
        "error_type": error_type,
        "error_type_counts": {error_type: 1},
        "run_status": "failed",
    }


def _load_existing_comparison_result(
    result_path: Path,
    task_id: str,
    variants: Sequence[str],
    *,
    require_evaluation: bool,
) -> Optional[Dict[str, Any]]:
    """复用已有视觉策略结果；开启评估时要求所有模式均已评估。"""
    if not result_path.is_file():
        return None
    try:
        result = read_json(result_path)
    except Exception as exc:
        print(f"[WARN] existing comparison result unreadable, rerun task={task_id}: {exc}")
        return None

    if not isinstance(result, dict):
        return None
    if str(result.get("task_id") or "") != task_id:
        return None
    if str(result.get("agent_mode") or "") != "visual_policy_comparison":
        return None
    if not isinstance(result.get("shared_root_token_usage"), dict):
        return None
    if not isinstance(result.get("bound_experiment_token_usage"), dict):
        return None

    stored_variants = result.get("variants")
    if not isinstance(stored_variants, dict):
        return None
    for variant in variants:
        item = stored_variants.get(variant)
        if not isinstance(item, dict):
            return None
        agent_result = item.get("agent_result")
        if not isinstance(agent_result, dict):
            return None
        if str(agent_result.get("error") or "").strip():
            return None
        if require_evaluation:
            evaluation = item.get("evaluation")
            if not isinstance(evaluation, dict):
                return None
            if str(evaluation.get("status") or "").strip().lower() != "evaluated":
                return None
    return result


def _failed_comparison_result(exc: Exception, variants: Sequence[str]) -> Dict[str, Any]:
    """当绑定实验整体异常时，为三个模式生成一致的失败结果。"""
    return {
        "shared_root_questions": [],
        "shared_root_token_usage": dict(_ZERO_USAGE),
        "bound_experiment_token_usage": dict(_ZERO_USAGE),
        "variants": {
            variant: _failed_agent_result(exc)
            for variant in variants
        },
    }


def _comparison_task_result_payload(
    *,
    benchmark: str,
    task: Any,
    task_id: str,
    run_metadata: Mapping[str, Any],
    comparison_result: Dict[str, Any],
    evaluations: Mapping[str, Dict[str, Any]],
) -> Dict[str, Any]:
    """保存共享 Root Questions，并为每个模式保存一组 agent/evaluation 结果。"""
    variant_results = dict(comparison_result.get("variants") or {})
    if not variant_results:
        raise ValueError("Comparison agent returned no variant results.")

    first_variant = next(iter(variant_results))
    payload = _task_result_payload(
        benchmark=benchmark,
        task=task,
        task_id=task_id,
        agent_mode="visual_policy_comparison",
        run_metadata=run_metadata,
        agent_result=dict(variant_results[first_variant] or {}),
        evaluation=dict(evaluations.get(first_variant) or {}),
    )
    payload.pop("agent_result", None)
    payload.pop("evaluation", None)
    payload["shared_root_questions"] = list(comparison_result.get("shared_root_questions") or [])
    payload["shared_root_token_usage"] = dict(
        comparison_result.get("shared_root_token_usage") or _ZERO_USAGE
    )
    payload["bound_experiment_token_usage"] = dict(
        comparison_result.get("bound_experiment_token_usage") or _ZERO_USAGE
    )
    payload["variants"] = {
        variant: {
            "agent_result": dict(agent_result or {}),
            "evaluation": dict(evaluations.get(variant) or {}),
        }
        for variant, agent_result in variant_results.items()
    }
    return payload


def _comparison_score_rows(
    task_result: Mapping[str, Any],
    benchmark: str,
) -> List[Dict[str, Any]]:
    """把一个绑定任务结果展开为三个可直接汇总的 score row。"""
    task_id = str(task_result.get("task_id") or "")
    rows: List[Dict[str, Any]] = []
    for variant, item in dict(task_result.get("variants") or {}).items():
        row = _score_row_from_result(
            {
                "task_id": task_id,
                "agent_result": dict(item.get("agent_result") or {}),
                "evaluation": dict(item.get("evaluation") or {}),
            },
            benchmark,
        )
        row["variant"] = str(variant)
        rows.append(row)
    return rows


def _evaluate_result(
    *,
    benchmark: str,
    evaluator: Any,
    task: Any,
    agent_result: Dict[str, Any],
    logger: QueryLogger,
) -> Dict[str, Any]:
    skip_reason = ""
    if str(agent_result.get("run_status") or "").strip().lower() == "failed":
        skip_reason = str(agent_result.get("error") or "")

    if benchmark == "bird":
        return evaluator.evaluate_task(
            task=task,
            predicted_insights=agent_result.get("predicted_insights") or [],
            logger=logger,
            skip_reason=skip_reason,
        )

    return evaluator.evaluate_task(
        task=task,
        predicted_insights=agent_result.get("predicted_insights") or [],
        predicted_summary=str(agent_result.get("predicted_summary") or ""),
        logger=logger,
        skip_reason=skip_reason,
    )


def _task_result_payload(
    *,
    benchmark: str,
    task: Any,
    task_id: str,
    agent_mode: str,
    run_metadata: Mapping[str, Any],
    agent_result: Dict[str, Any],
    evaluation: Dict[str, Any],
) -> Dict[str, Any]:
    common = {
        "benchmark": benchmark,
        "task_id": task_id,
        "agent_mode": agent_mode,
        "run_metadata": dict(run_metadata or {}),
        "agent_result": agent_result,
        "evaluation": evaluation,
    }
    if benchmark == "bird":
        return {
            **common,
            "jsonl_path": str(task.jsonl_path),
            "line_index": int(task.line_index),
            "db_id": str(task.db_id),
            "query": str(task.query),
            "query_zh": str(task.query_zh),
            "target_dataset": dict(task.target_dataset or {}),
            "table_selection": str(task.table_selection),
            "loaded_table_names": [table.name for table in task.tables],
            "gold_tables": list(task.gold_tables or []),
            "gold_insight_items": list(task.insight_items or []),
        }
    return {
        **common,
        "json_path": str(task.json_path),
        "metadata": dict(task.metadata or {}),
        "gold_insights": list(task.gold_insights or []),
        "gold_summary": str(task.gold_summary or ""),
    }


def _aggregate_error_type_counts(score_rows: List[Dict[str, Any]]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for row in score_rows:
        error_counts = row.get("error_type_counts") or {}
        if not isinstance(error_counts, dict):
            continue
        for key, value in error_counts.items():
            error_type = str(key or "").strip()
            if not error_type:
                continue
            try:
                count = int(value or 0)
            except Exception:
                count = 0
            counts[error_type] = counts.get(error_type, 0) + count
    return counts


def _mean(rows: List[Dict[str, Any]], key: str) -> float:
    return (sum(float(row.get(key) or 0.0) for row in rows) / len(rows)) if rows else 0.0


def _overview_payload(
    *,
    score_rows: List[Dict[str, Any]],
    benchmark: str,
    agent_mode: str,
    run_metadata: Mapping[str, Any],
) -> Dict[str, Any]:
    evaluated_rows = [row for row in score_rows if str(row.get("status") or "") == "evaluated"]
    complete_evaluated_rows = [
        row for row in evaluated_rows if str(row.get("run_status") or "") == "complete"
    ]
    skipped_rows = [row for row in score_rows if str(row.get("status") or "") != "evaluated"]
    disabled_rows = [row for row in score_rows if str(row.get("status") or "") == "disabled"]
    total_agent_tokens = sum(int(row.get("total_tokens") or 0) for row in score_rows)

    overview: Dict[str, Any] = {
        "benchmark": benchmark,
        "agent_mode": agent_mode,
        "run_metadata": dict(run_metadata or {}),
        "num_tasks": len(score_rows),
        "num_evaluated_tasks": len(evaluated_rows),
        "num_complete_evaluated_tasks": len(complete_evaluated_rows),
        "num_skipped_tasks": len(skipped_rows),
        "num_evaluation_disabled_tasks": len(disabled_rows),
        "num_complete_tasks": sum(str(row.get("run_status") or "") == "complete" for row in score_rows),
        "num_partial_tasks": sum(str(row.get("run_status") or "") == "partial" for row in score_rows),
        "num_failed_tasks": sum(str(row.get("run_status") or "") == "failed" for row in score_rows),
        "num_reused_tasks": sum(bool(row.get("reused_existing_result")) for row in score_rows),
        "error_type_counts": _aggregate_error_type_counts(score_rows),
        "total_agent_prompt_tokens": sum(int(row.get("prompt_tokens") or 0) for row in score_rows),
        "total_agent_completion_tokens": sum(int(row.get("completion_tokens") or 0) for row in score_rows),
        "total_agent_tokens": total_agent_tokens,
        "mean_agent_tokens_per_task": (total_agent_tokens / len(score_rows)) if score_rows else 0.0,
    }

    if benchmark == "bird":
        overview.update({
            "metric": "harmonic_grounded_coverage",
            "mean_score": _mean(evaluated_rows, "score"),
            "mean_harmonic_grounded_coverage": _mean(evaluated_rows, "score"),
            "complete_mean_harmonic_grounded_coverage": _mean(complete_evaluated_rows, "score"),
            "total_pair_judgements": sum(int(row.get("num_pairs") or 0) for row in evaluated_rows),
            "complete_mean_score": _mean(complete_evaluated_rows, "score"),
            "total_numeric_anchors": sum(int(row.get("num_numeric_anchors") or 0) for row in evaluated_rows),
            "total_numeric_anchors_matched": sum(
                int(row.get("num_numeric_anchors_matched") or 0) for row in evaluated_rows
            ),
            "total_numeric_anchors_partial": sum(
                int(row.get("num_numeric_anchors_partial") or 0) for row in evaluated_rows
            ),
        })
    else:
        overview.update({
            "mean_score_insights": _mean(evaluated_rows, "score_insights"),
            "mean_score_summary": _mean(evaluated_rows, "score_summary"),
            "complete_mean_score_insights": _mean(complete_evaluated_rows, "score_insights"),
            "complete_mean_score_summary": _mean(complete_evaluated_rows, "score_summary"),
        })
    return overview


def _comparison_overview_payload(
    *,
    score_rows: List[Dict[str, Any]],
    benchmark: str,
    run_metadata: Mapping[str, Any],
    variants: Sequence[str],
) -> Dict[str, Any]:
    """按模式分别汇总指标，避免把三种策略混成一个平均数。"""
    variant_overviews: Dict[str, Any] = {}
    for variant in variants:
        rows = [row for row in score_rows if str(row.get("variant") or "") == variant]
        overview = _overview_payload(
            score_rows=rows,
            benchmark=benchmark,
            agent_mode=variant,
            run_metadata=run_metadata,
        )
        overview.pop("benchmark", None)
        overview.pop("agent_mode", None)
        overview.pop("run_metadata", None)
        variant_overviews[variant] = overview

    return {
        "benchmark": benchmark,
        "agent_mode": "visual_policy_comparison",
        "run_metadata": dict(run_metadata or {}),
        "variants": variant_overviews,
    }


def main() -> None:
    args = parse_args()
    config = read_json(args.config)

    dataset_config = dict(config.get("dataset") or {})
    benchmark = _normalize_benchmark_name(dataset_config.get("benchmark"))
    output_root = Path(dataset_config.get("output_dir") or "./results").resolve()
    evaluation_enabled = _evaluation_enabled(config)
    enrichment_config = MetadataEnrichmentConfig(**dict(dataset_config.get("metadata_enrichment") or {}))

    tasks = _load_tasks_from_config(
        benchmark=benchmark,
        dataset_config=dataset_config,
        enrichment_config=enrichment_config,
    )
    task_count = len(tasks) if hasattr(tasks, "__len__") else None
    if task_count == 0:
        raise RuntimeError(f"没有找到任何可运行的 {benchmark} 任务")

    ensure_dir(output_root)
    llm_client = OpenAICompatibleClient(LLMConfig.from_dict(config.get("system_llm")))
    agent, evaluator, agent_mode = _build_agent_and_evaluator(
        benchmark=benchmark,
        config=config,
        llm_client=llm_client,
        evaluation_enabled=evaluation_enabled,
    )
    run_metadata = _run_metadata(
        args.config,
        benchmark,
        agent_mode,
        evaluation_enabled,
    )
    is_comparison = agent_mode == "visual_policy_comparison"
    variants = list(getattr(agent, "variants", [])) if is_comparison else []

    score_rows: List[Dict[str, Any]] = []
    for index, task in enumerate(tasks, start=1):
        task_id = _task_id(task)
        run_path = output_root / task_id
        result_path = run_path / "result.json"
        log_path = run_path / f"{task_id}_query_log.md"
        progress = f"{index}/{task_count}" if task_count is not None else str(index)
        print(f"[{progress}] benchmark={benchmark} task={task_id}")

        if is_comparison:
            existing_result = _load_existing_comparison_result(
                result_path,
                task_id,
                variants,
                require_evaluation=evaluation_enabled,
            )
        else:
            existing_result = _load_existing_task_result(
                result_path,
                task_id,
                agent_mode,
                require_evaluation=evaluation_enabled,
            )

        if existing_result is not None:
            print(f"[SKIP] task={task_id} already completed: {result_path}")
            if is_comparison:
                reused_rows = _comparison_score_rows(existing_result, benchmark)
                for row in reused_rows:
                    row["reused_existing_result"] = True
                score_rows.extend(reused_rows)
            else:
                reused_row = _score_row_from_result(existing_result, benchmark)
                reused_row["reused_existing_result"] = True
                score_rows.append(reused_row)
            if benchmark == "bird":
                del task
            continue

        _clean_task_output_dir(run_path)
        logger = QueryLogger(log_path)
        logger.log_header(task)

        if is_comparison:
            try:
                comparison_result = agent.run(task=task, output_dir=run_path, logger=logger)
            except Exception as exc:
                logger.log_exception("runtime_error", exc)
                comparison_result = _failed_comparison_result(exc, variants)

            evaluations: Dict[str, Dict[str, Any]] = {}
            for variant, agent_result in dict(comparison_result.get("variants") or {}).items():
                if not evaluation_enabled:
                    evaluations[variant] = _disabled_evaluation_result()
                    continue
                try:
                    evaluations[variant] = _evaluate_result(
                        benchmark=benchmark,
                        evaluator=evaluator,
                        task=task,
                        agent_result=agent_result,
                        logger=logger,
                    )
                except Exception as exc:
                    logger.log_exception(f"{variant}_evaluation_error", exc)
                    agent_result["evaluation_error"] = str(exc)[:1000]
                    error_counts = dict(agent_result.get("error_type_counts") or {})
                    error_counts[EVALUATION_ERROR] = int(error_counts.get(EVALUATION_ERROR) or 0) + 1
                    agent_result["error_type_counts"] = error_counts
                    evaluations[variant] = evaluator.skipped_result(reason=str(exc), logger=logger)

            if benchmark == "bird" and evaluation_enabled:
                evaluations = {
                    variant: _persist_bird_evaluation_report(
                        evaluation,
                        run_path,
                        filename=f"bird_evaluation_report_{variant}.json",
                    )
                    for variant, evaluation in evaluations.items()
                }

            task_result = _comparison_task_result_payload(
                benchmark=benchmark,
                task=task,
                task_id=task_id,
                run_metadata=run_metadata,
                comparison_result=comparison_result,
                evaluations=evaluations,
            )
            write_json(result_path, task_result)

            task_rows = _comparison_score_rows(task_result, benchmark)
            for row in task_rows:
                row["reused_existing_result"] = False
            score_rows.extend(task_rows)
        else:
            try:
                agent_result = agent.run(task=task, output_dir=run_path, logger=logger)
            except Exception as exc:
                logger.log_exception("runtime_error", exc)
                agent_result = _failed_agent_result(exc)

            if not evaluation_enabled:
                evaluation = _disabled_evaluation_result()
            else:
                try:
                    evaluation = _evaluate_result(
                        benchmark=benchmark,
                        evaluator=evaluator,
                        task=task,
                        agent_result=agent_result,
                        logger=logger,
                    )
                except Exception as exc:
                    logger.log_exception("evaluation_error", exc)
                    agent_result["evaluation_error"] = str(exc)[:1000]
                    error_counts = dict(agent_result.get("error_type_counts") or {})
                    error_counts[EVALUATION_ERROR] = int(error_counts.get(EVALUATION_ERROR) or 0) + 1
                    agent_result["error_type_counts"] = error_counts
                    evaluation = evaluator.skipped_result(reason=str(exc), logger=logger)

            if benchmark == "bird" and evaluation_enabled:
                evaluation = _persist_bird_evaluation_report(evaluation, run_path)

            task_result = _task_result_payload(
                benchmark=benchmark,
                task=task,
                task_id=task_id,
                agent_mode=agent_mode,
                run_metadata=run_metadata,
                agent_result=agent_result,
                evaluation=evaluation,
            )
            write_json(result_path, task_result)

            score_row = _score_row_from_result(task_result, benchmark)
            score_row["reused_existing_result"] = False
            score_rows.append(score_row)

        if benchmark == "bird":
            del task

    if is_comparison:
        overview = _comparison_overview_payload(
            score_rows=score_rows,
            benchmark=benchmark,
            run_metadata=run_metadata,
            variants=variants,
        )
    else:
        overview = _overview_payload(
            score_rows=score_rows,
            benchmark=benchmark,
            agent_mode=agent_mode,
            run_metadata=run_metadata,
        )

    write_json(output_root / "overview.json", overview)
    write_json(output_root / "task_scores.json", score_rows)
    print(json.dumps(overview, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
