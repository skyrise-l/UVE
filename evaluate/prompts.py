"""
evaluate/prompts.py
-------------------
尽量对齐 InsightBench 官方仓库的评估 prompt。

核心对齐点：
1. 使用官方 G-Eval 风格的 `get_g_eval_prompt(method="basic")`；
2. judge 输出是 1-10 的分数文本，而不是自定义 JSON；
3. summary 评估与 insight 评估共用同一套 pairwise 打分提示。
"""

from __future__ import annotations

from typing import Tuple


def get_g_eval_prompt(method: str = "basic") -> Tuple[str, str]:
    """返回官方风格的 G-Eval 模板与 system message。"""
    if method == "basic":
        return G_EVAL_BASIC_TEMPLATE, G_EVAL_BASIC_SYSTEM_MESSAGE
    if method == "binary":
        return G_EVAL_BINARY_TEMPLATE, G_EVAL_BINARY_SYSTEM_MESSAGE
    raise ValueError(f"Unknown G-Eval prompt method: {method}")


G_EVAL_BASIC_TEMPLATE = """Below is an instruction that describes a task. Write a response that appropriately completes the request.

### Instruction:
Provided Answer: {answer}
Ground Truth Answer: {gt_answer}

Follow these instructions when writing your response:
* On a scale of 1-10, provide a numerical rating for how close the provided answer is to the ground truth answer, with 10 denoting that the provided answer is the same as ground truth answer.
* Your response should contain only the numerical rating.
* Do not include anything else like the provided answer, the ground truth answer, or an explanation of your rating scale in your response.
* Check very carefully before answering.

### Response:
"""

G_EVAL_BASIC_SYSTEM_MESSAGE = (
    "You are a high school teacher evaluating student responses to a question. "
    "You are tasked with grading the response based on how well it answers the question. "
    "You are to provide a numerical rating for how well the response answers the question "
    "based on the ground truth answer."
)

G_EVAL_BINARY_TEMPLATE = """Below is an instruction that describes a task. Write a response that appropriately completes the request.

### Instruction:
Provided answer: {answer}
GT Answer: {gt_answer}

On a scale of 1-10, provide a numerical rating for how close the provided answer is to the ground truth answer, with 10 denoting that the provided answer is the same as ground truth answer. The response should contain only the numerical rating. Check very carefully before answering.

### Response:
"""

G_EVAL_BINARY_SYSTEM_MESSAGE = (
    "You are a high school teacher evaluating student responses to a question. "
    "You are tasked with grading the response based on how well the provided response matches the ground truth answer."
)
