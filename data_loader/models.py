"""
data_loader/models.py
--------------------
定义数据加载阶段使用的最小运行时对象。

当前框架支持两类任务：
1. InsightBench：一个 flag json 对应一个分析任务；
2. BIRD EDA：自建 JSONL 中一条 task 对应一个多表开放式 EDA 任务。

这里的对象只保存后续 agent、prompt、evaluator 确实会用到的信息。
不会为了调试额外保存原始大字段，也不会把 gold answer 暴露到 prompt 输入里。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List

import pandas as pd


@dataclass
class TableData:
    """一张已经加载到内存中的数据表。

    name 是运行时 tables 字典里的键；metadata 是 prompt schema 的来源。
    """

    name: str
    path: Path
    dataframe: pd.DataFrame
    metadata: Dict[str, Any]

    @property
    def columns(self) -> List[Dict[str, Any]]:
        """返回列级 schema。"""
        return list(self.metadata.get("columns") or [])

    def to_prompt_dict(self) -> Dict[str, Any]:
        """转成 prompt 中使用的轻量表结构。

        不输出文件路径，因为代码生成只能使用运行时变量 tables，不能读取外部文件。
        """
        result = {
            "table_name": self.name,
            "num_rows": int(self.metadata.get("num_rows") or self.dataframe.shape[0]),
            "num_columns": int(self.metadata.get("num_columns") or self.dataframe.shape[1]),
            "columns": self.columns,
        }
        description = str(self.metadata.get("description") or "").strip()
        if description:
            result["description"] = description
        return result


@dataclass
class InsightBenchTask:
    """一个 InsightBench flag 任务。"""

    json_path: Path
    metadata: Dict[str, Any]
    primary_table: TableData
    extra_tables: List[TableData]
    gold_insights: List[str]
    gold_summary: str
    insight_items: List[Dict[str, Any]]

    def insight_questions(self) -> List[str]:
        """返回官方 json 中 insight_list 提供的人工问题，仅用于人工审计。"""
        questions: List[str] = []
        for item in self.insight_items or []:
            if not isinstance(item, dict):
                continue
            question = str(item.get("question") or "").strip()
            if question:
                questions.append(question)
        return questions

    def all_tables(self) -> List[TableData]:
        """按固定顺序返回当前任务涉及的全部表。"""
        return [self.primary_table, *self.extra_tables]

    def to_prompt_dict(self) -> Dict[str, Any]:
        """整理成 agent / prompt 可消费的任务上下文。"""
        return {
            "task_id": self.metadata.get("task_id"),
            "goal": self.metadata.get("goal"),
            "role": self.metadata.get("role"),
            "category": self.metadata.get("category"),
            "dataset_description": self.metadata.get("dataset_description"),
            "header": self.metadata.get("header"),
            "tables": [table.to_prompt_dict() for table in self.all_tables()],
        }


@dataclass
class BirdEDATask:
    """一个 BIRD CSV 多表 EDA 任务。

    任务来自自建 JSONL。运行时可按 table_selection 读取全部表或任务标注的
    gold tables。gold 表名本身不会直接进入 prompt；agent 只看到实际加载后的表。
    gold_insights 仅用于 evaluation。
    """

    jsonl_path: Path
    line_index: int
    raw_payload: Dict[str, Any]
    task_id_value: str
    query: str
    query_zh: str
    db_id: str
    target_dataset: Dict[str, Any]
    tables: List[TableData]
    table_relationships: str
    table_selection: str
    gold_tables: List[str]
    gold_insights: List[str]
    insight_items: List[Dict[str, Any]]

    @property
    def task_id(self) -> str:
        return str(self.task_id_value)

    @property
    def metadata(self) -> Dict[str, Any]:
        return {
            "task_id": self.task_id,
            "benchmark": "bird",
            "goal": self.query,
            "goal_zh": self.query_zh,
            "db_id": self.db_id,
            "target_dataset": dict(self.target_dataset or {}),
            "table_selection": self.table_selection,
            # debug/eval only; prompt 不读取 metadata.gold_tables。
            "gold_tables": list(self.gold_tables or []),
        }

    def all_tables(self) -> List[TableData]:
        return list(self.tables)

    def to_prompt_dict(self) -> Dict[str, Any]:
        """整理成 agent / prompt 可消费的 BIRD EDA 上下文。

        这里不输出 gold_tables / gold_insights / evidence_sql。
        Agent 只看到 loader 已实际加载的表及其 schema。
        """
        result = {
            "task_id": self.task_id,
            "benchmark": "bird",
            "goal": self.query,
            "goal_zh": self.query_zh,
            "db_id": self.db_id,
            "tables": [table.to_prompt_dict() for table in self.tables],
        }
        relationships = str(self.table_relationships or "").strip()
        if relationships:
            result["table_relationships"] = relationships
        return result


