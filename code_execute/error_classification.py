"""Shared error classification for execution and experiment summaries.

The labels are intentionally coarse: they are audit fields for result analysis, not
control-flow switches.  Keeping the classifier small prevents the main algorithm from
accumulating scattered string matching logic.
"""

from __future__ import annotations

from typing import Any


CODE_EXECUTION_ERROR = "code_execution_error"
CODE_GENERATION_ERROR = "code_generation_error"
STAGE_RESULT_CONTRACT_ERROR = "stage_result_contract_error"
VISUAL_EXTRACTION_ERROR = "visual_extraction_error"
FRONTIER_SELECTION_ERROR = "frontier_selection_error"
INTERPRETATION_ERROR = "interpretation_error"
LLM_API_ERROR = "llm_api_error"
EVALUATION_ERROR = "evaluation_error"
AGENT_RUNTIME_ERROR = "agent_runtime_error"
UNKNOWN_ERROR = "unknown_error"


def classify_error_message(message: Any, *, default: str = UNKNOWN_ERROR) -> str:
    """Return a stable coarse error type from an exception/error message."""
    text = str(message or "").lower()
    if not text:
        return default

    if "stage_result" in text:
        return STAGE_RESULT_CONTRACT_ERROR
    if "generated code did not set" in text or "extract_python_code" in text or "no python code" in text:
        return CODE_GENERATION_ERROR
    if "visual_pipeline" in text or "visual" in text and "traceback" in text:
        return VISUAL_EXTRACTION_ERROR
    if "frontier" in text or "select_frontier" in text or "_frontier_" in text:
        return FRONTIER_SELECTION_ERROR
    if "interpret" in text or "conclusion" in text or "json" in text and "answer" in text:
        return INTERPRETATION_ERROR
    if (
        "rate limit" in text
        or "timeout" in text
        or "api" in text
        or "unauthorized" in text
        or "forbidden" in text
        or "connection" in text
        or "http" in text
    ):
        return LLM_API_ERROR
    if "agent_runtime_error" in text:
        return AGENT_RUNTIME_ERROR
    return default
