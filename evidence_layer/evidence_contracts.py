"""Shared contracts for the two evidence systems.

The project deliberately keeps two evidence flows separate:

1. ``current_question``: computed evidence from the current code execution, used only
   to answer the selected question and generate its Insight.
2. ``exploration``: computed or schema-grounded signals used only to propose later
   questions.  These signals must never be promoted into the current Answer.

The constants in this module are internal metadata.  They are not added to LLM
schemas and therefore do not increase prompt token usage.
"""

from __future__ import annotations

from typing import Any

CURRENT_QUESTION_ROLE = "current_question"
EXPLORATION_ROLE = "exploration"

TRACE_RESULT_PROVENANCE = "trace_result_computed"
TRACE_FRONTIER_PROVENANCE = "trace_frontier_computed"
JOIN_PROBE_PROVENANCE = "join_probe_computed"
JOIN_OPPORTUNITY_PROVENANCE = "join_opportunity_unexecuted"
GOAL_RETRIEVAL_PROVENANCE = "goal_retrieval_unexecuted"
SINGLE_TABLE_SCHEMA_FALLBACK_PROVENANCE = "single_table_schema_fallback"
EXECUTION_RECOVERY_PROVENANCE = "execution_recovery"


def task_benchmark(task: Any) -> str:
    """Return the normalized benchmark name without depending on a concrete task class."""
    metadata = dict(getattr(task, "metadata", {}) or {})
    return str(metadata.get("benchmark") or metadata.get("source") or "insightbench").strip().lower()


def is_bird_task(task: Any) -> bool:
    """Whether the task uses the BIRD multi-table exploration policy."""
    return task_benchmark(task) == "bird"
