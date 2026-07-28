"""检索模块提示词。

提示词刻意只要求模型返回真实表列，不要求相关性分层、分析角色、连接路径或视图模板。
这些结构由后续确定性代码根据真实 schema 和 PK/FK 关系生成，避免把过多判断压给模型。
"""

from __future__ import annotations

import json
from typing import Any, Mapping

from prompts import format_task_schema, get_task_context, get_task_goal


RETRIEVAL_SYSTEM_PROMPT = """You retrieve schema fields for exploratory data analysis.
Return valid JSON only. Use exact table and column names from the supplied schema.
Your task is high-recall retrieval, not analysis planning: do not assign roles, scores, tiers,
join paths, chart types, questions, or conclusions."""


def build_initial_retrieval_prompt(task: Any) -> str:
    """构造第一次高召回检索请求。

    输入是原始任务目标、上下文和完整 schema；输出只允许包含表名和列名。
    """
    return f"""Retrieve all schema columns that could reasonably help analyze the original goal.

Context:
{get_task_context(task)}

Original goal:
{get_task_goal(task)}

Full schema and declared relationships:
{format_task_schema(task)}

Requirements:
* Aim for high recall rather than a small Top-K list.
* Include direct outcomes and measures, useful grouping or comparison fields, time/status fields,
  missingness or completeness fields, relevant text fields, and plausible proxy fields.
* Do not include a technical identifier only because it is needed for a join. Deterministic code
  will recover declared primary/foreign keys and bridge tables later.
* Do not invent names and do not return explanations.

Return exactly this JSON shape:
{{
  "tables": [
    {{"table": "exact_table_name", "columns": ["exact_column_name"]}}
  ]
}}
"""


def build_supplement_retrieval_prompt(task: Any, initial_space: Mapping[str, Any]) -> str:
    """构造第二次遗漏检查请求。

    第二次只补充第一次漏掉的表列，不重新排序，也不删除已检索结果。
    当第一次请求失败时，本提示仍包含完整 schema，可独立完成一次高召回补充。
    """
    initial_text = json.dumps(dict(initial_space or {}), ensure_ascii=False, indent=2)
    return f"""Check the original goal and full schema again for omissions in the validated initial retrieval.
Return only additional table/column items that were missed. Do not repeat existing items and do not
remove or re-rank them.

Context:
{get_task_context(task)}

Original goal:
{get_task_goal(task)}

Full schema and declared relationships:
{format_task_schema(task)}

Validated initial retrieval:
{initial_text}

Look especially for less obvious outcome fields, comparison dimensions, status/time/completeness
fields, text fields, and proxy variables whose names do not literally match the goal. Pure join keys
will be supplied deterministically and need not be returned.

Return exactly this JSON shape; use an empty list when nothing is missing:
{{
  "tables": [
    {{"table": "exact_table_name", "columns": ["exact_column_name"]}}
  ]
}}
"""
