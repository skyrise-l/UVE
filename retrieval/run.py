"""独立运行任务级表列检索。

使用方式：
    python -m retrieval.run --config config_bird.json

程序只加载配置范围内的任务并生成检索结果，不运行 root question、代码执行或评估。
同一数据集和模型的全部任务保存在 ``retrieval/results`` 下的一个 JSON 文件中；默认
跳过已有任务，传入 ``--force`` 时重新生成当前配置范围内的任务。
"""

from __future__ import annotations

import argparse
from typing import Any, Dict, Iterable

from data_loader import MetadataEnrichmentConfig, load_tasks, stream_bird_tasks
from llm_client import LLMConfig, OpenAICompatibleClient
from retrieval.retriever import GoalSchemaRetriever
from vis_project_utils.utils import read_json


def _parse_args() -> argparse.Namespace:
    """读取独立检索所需的最少命令行参数。"""
    parser = argparse.ArgumentParser(description="Precompute reusable schema retrieval results.")
    parser.add_argument("--config", default="config.json", help="主项目配置文件路径")
    parser.add_argument(
        "--force",
        action="store_true",
        help="重新生成当前配置范围内已存在的任务结果",
    )
    return parser.parse_args()


def _normalize_benchmark(value: Any) -> str:
    """把配置中的 benchmark 名称规范化为项目支持的两种数据集。"""
    name = str(value or "insightbench").strip().lower().replace("_", "").replace("-", "")
    if name in {"insightbench", "insight"}:
        return "insightbench"
    if name in {"bird", "birdeda", "birdmted", "birdmultitableeda"}:
        return "bird"
    raise ValueError(f"不支持的 dataset.benchmark: {value}")


def _task_id(task: Any) -> str:
    """读取进度输出使用的任务标识。"""
    value = str(getattr(task, "task_id", "") or "").strip()
    if value:
        return value
    metadata = dict(getattr(task, "metadata", {}) or {})
    return str(metadata.get("task_id") or "unknown_task")


def _load_tasks(config: Dict[str, Any], benchmark: str) -> Iterable[Any]:
    """按主程序相同的数据集、offset 和 limit 配置加载任务。"""
    dataset_config = dict(config.get("dataset") or {})
    data_root = dataset_config.get("data_root")
    if not data_root:
        raise ValueError("配置文件缺少 dataset.data_root")

    enrichment_config = MetadataEnrichmentConfig(
        **dict(dataset_config.get("metadata_enrichment") or {})
    )
    metadata_cache_dir = dataset_config.get("metadata_cache_dir", "./cache/metadata")
    limit = dataset_config.get("limit")

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


def main() -> None:
    """批量加载或生成检索结果，并持续写入一个可复用 JSON 文件。"""
    args = _parse_args()
    config = read_json(args.config)
    dataset_config = dict(config.get("dataset") or {})
    benchmark = _normalize_benchmark(dataset_config.get("benchmark"))

    llm_client = OpenAICompatibleClient(LLMConfig.from_dict(config.get("system_llm")))
    retriever = GoalSchemaRetriever(llm_client=llm_client, config=config)
    if not retriever.enabled:
        raise RuntimeError("retrieval.enabled=false，独立检索未启用")

    cached_count = 0
    generated_count = 0
    failed_count = 0
    for index, task in enumerate(_load_tasks(config, benchmark), start=1):
        task_id = _task_id(task)
        result = retriever.get_or_generate(task=task, force=args.force)
        column_count = sum(len(item.get("columns") or []) for item in result.get("tables") or [])

        if retriever.last_source == "cached":
            cached_count += 1
        elif retriever.last_source.startswith("generated"):
            generated_count += 1
        else:
            failed_count += 1

        print(
            f"[{index}] task={task_id} source={retriever.last_source} "
            f"tables={len(result.get('tables') or [])} columns={column_count}"
        )
        if benchmark == "bird":
            del task

    print(
        f"完成：generated={generated_count}, cached={cached_count}, failed={failed_count}\n"
        f"结果文件：{retriever.result_path(benchmark).resolve()}"
    )


if __name__ == "__main__":
    main()
