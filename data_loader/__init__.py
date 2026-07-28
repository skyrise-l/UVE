"""数据加载模块统一入口。

当前主项目只支持 InsightBench 与自建 BIRD EDA 数据集。
"""

from .loader import (
    list_task_jsons,
    load_bird_evaluation_tasks,
    load_bird_task,
    load_bird_tasks,
    load_task,
    load_tasks,
    stream_bird_tasks,
)
from .metadata_enricher import MetadataEnrichmentConfig, build_table_metadata
from .models import BirdEDATask, InsightBenchTask, TableData

__all__ = [
    "list_task_jsons",
    "load_task",
    "load_tasks",
    "load_bird_task",
    "load_bird_tasks",
    "load_bird_evaluation_tasks",
    "stream_bird_tasks",
    "MetadataEnrichmentConfig",
    "build_table_metadata",
    "TableData",
    "BirdEDATask",
    "InsightBenchTask",
]
