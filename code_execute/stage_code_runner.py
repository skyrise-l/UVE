"""stage_code_runner.py
---------------------
主流程使用的阶段代码生成、执行和修复循环。

这个模块只处理通用控制流：生成代码、执行代码、失败后请求修复、重新执行。
具体 prompt、执行环境和 trace 收集由调用方注入。
"""

from __future__ import annotations

from typing import Any, Callable, Dict, Optional, Tuple

from llm_client import LLMConversation
from query_logger import QueryLogger
from vis_project_utils.utils import extract_python_code, merge_token_usage

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

ExecuteCodeFn = Callable[[str], Dict[str, Any]]
RepairPromptFn = Callable[[str, Dict[str, Any]], str]


def _append_stage_code(
    logger: Optional[QueryLogger],
    code: str,
    round_index: Optional[int],
) -> None:
    """追加阶段代码到日志；兼容没有 logger 的批量运行。"""
    if logger is None:
        return
    logger.append_stage_code(code, round_index=round_index)


def run_stage_code_generation_loop(
    *,
    conversation: LLMConversation,
    execute_code: ExecuteCodeFn,
    repair_prompt_builder: RepairPromptFn,
    max_repairs: int,
    logger: Optional[QueryLogger] = None,
    round_index: Optional[int] = None,
    initial_step_name: str = "stage_code",
    code_prompt: Optional[str] = None,
    initial_code: Optional[str] = None,
    repair_step_prefix: str = "stage_repair",
    log_prefix: str = "stage",
) -> Tuple[bool, Dict[str, Any], Dict[str, int]]:
    """运行阶段代码的生成、执行和修复循环。

    参数：
        conversation: 当前 question 使用的 LLM conversation。
        execute_code: 调用方提供的代码执行函数。
        repair_prompt_builder: 根据失败代码和执行结果生成修复 prompt。
        max_repairs: 最多修复次数。初始代码也会执行，因此总执行次数为
            ``1 + max_repairs``。
        code_prompt / initial_code: 二选一；传入 initial_code 时跳过首次
            LLM 代码生成。

    返回：
        ``(是否成功, 最后一次执行结果, 本循环产生的 token usage)``。
    """
    usage: Dict[str, int] = dict(_ZERO_USAGE)

    if initial_code is None:
        if not code_prompt:
            raise ValueError("Either code_prompt or initial_code must be provided.")
        code_step = conversation.generate_text(
            step_name=initial_step_name,
            user_prompt=code_prompt,
            logger=logger,
        )
        usage = merge_token_usage(usage, code_step.usage)
        stage_code = extract_python_code(code_step.raw_content)
    else:
        stage_code = str(initial_code or "").strip()

    _append_stage_code(logger, stage_code, round_index=round_index)

    for repair_count in range(0, max_repairs + 1):
        execution = execute_code(stage_code)
        if execution.get("success"):
            return True, execution, usage

        if repair_count >= max_repairs:
            return False, execution, usage

        repair_index = repair_count + 1
        repair_step = conversation.generate_text(
            step_name=f"{repair_step_prefix}_{repair_index}",
            user_prompt=repair_prompt_builder(stage_code, execution),
            logger=logger,
        )
        usage = merge_token_usage(usage, repair_step.usage)
        stage_code = extract_python_code(repair_step.raw_content)

        if logger is not None:
            logger.log_code(f"{log_prefix}_repaired_code_{repair_index}", stage_code)
        _append_stage_code(logger, stage_code, round_index=round_index)

    return False, {"success": False, "error": "unexpected execution loop exit"}, usage
