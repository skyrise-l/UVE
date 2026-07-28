"""
query_logger.py
---------------
每条 query 一个日志文件，并额外维护一个完整代码文件。

原则：
1. 日志里只记录人会看的 prompt / 回复 / 执行摘要；
2. 各阶段最终代码单独累计到一个 .py 文件，便于整体阅读；
3. 不重复存过多解析结果。
"""

from __future__ import annotations

import json
import traceback
import threading
from pathlib import Path
from typing import Any, Dict, Optional

from vis_project_utils.utils import ensure_dir


class QueryLogger:
    """单条 query 的轻量日志器。"""

    def __init__(self, log_path: str | Path, code_path: Optional[str | Path] = None):
        self._lock = threading.RLock()
        self.log_path = Path(log_path)
        ensure_dir(self.log_path.parent)
        self.log_path.write_text("", encoding="utf-8")

        if code_path is None:
            code_name = self.log_path.stem.replace("_query_log", "_generated_code") + ".py"
            self.code_path = self.log_path.with_name(code_name)
        else:
            self.code_path = Path(code_path)

        ensure_dir(self.code_path.parent)
        self.code_path.write_text("# Generated code for this task\n\n", encoding="utf-8")

    def _append(self, text: str) -> None:
        """向 markdown 日志追加文本；支持评估线程并发写入。"""
        with self._lock:
            with self.log_path.open("a", encoding="utf-8") as file:
                file.write(text)

    def _append_code_file(self, text: str) -> None:
        """向累计代码文件追加文本。"""
        with self._lock:
            with self.code_path.open("a", encoding="utf-8") as file:
                file.write(text)

    def _code_block(self, content: str, language: str = "text") -> str:
        """包装成 markdown 代码块。"""
        content = content if content is not None else ""
        return f"```{language}\n{content}\n```\n"

    def log_header(self, task: Any) -> None:
        """记录当前 task 的头信息。

        当前项目已经不再使用旧 benchmark 的 qid / case / question 接口，
        因此这里统一改成围绕 task 自身记录。
        """
        if hasattr(task, "task_id"):
            task_id = str(getattr(task, "task_id"))
        else:
            task_id = getattr(getattr(task, "json_path", None), "stem", "unknown_task")
        metadata = dict(getattr(task, "metadata", {}) or {})
        table_names = []

        if hasattr(task, "all_tables"):
            try:
                table_names = [str(table.name) for table in task.all_tables()]
            except Exception:
                table_names = []

        header = str(metadata.get("header") or "")
        goal = str(metadata.get("goal") or getattr(task, "query", "") or getattr(task, "question", "") or "")
        role = str(metadata.get("role") or "")
        category = str(metadata.get("category") or getattr(task, "domain", "") or getattr(task, "question_type", "") or "")

        self._append(
            f"# Query Log\n\n"
            f"- task_id: {task_id}\n"
            f"- header: {header}\n"
            f"- goal: {goal}\n"
            f"- role: {role}\n"
            f"- category: {category}\n"
            f"- tables: {json.dumps(table_names, ensure_ascii=False)}\n"
            f"- generated_code_file: {self.code_path.name}\n\n"
        )

        self._append_code_file(
            f"# task_id: {task_id}\n"
            f"# header: {header}\n"
            f"# goal: {goal}\n"
            f"# role: {role}\n"
            f"# category: {category}\n"
            f"# tables: {table_names}\n\n"
        )

    def log_text(self, title: str, text: str) -> None:
        """记录普通文本段落。"""
        self._append(f"## {title}\n\n{text}\n\n")

    def log_code(self, title: str, code: str, language: str = "python") -> None:
        """记录代码片段。"""
        self._append(f"## {title}\n\n")
        self._append(self._code_block(code, language=language))
        self._append("\n")

    def log_json(self, title: str, payload: Any) -> None:
        """记录 JSON 结构。"""
        dumped = json.dumps(payload, ensure_ascii=False, indent=2, default=str)
        self._append(f"## {title}\n\n")
        self._append(self._code_block(dumped, language="json"))
        self._append("\n")

    def log_round_brief(self, round_index: int, payload: Dict[str, Any]) -> None:
        """记录单轮极简摘要。

        只建议传当前轮真正关键的结论性信息，避免日志塞满中间变量。
        """
        self.log_json(f"round_{round_index}_brief", payload)

    def log_llm(
        self,
        step_name: str,
        system_prompt: str,
        user_prompt: str,
        response_content: str,
        duration_sec: float,
        usage: Optional[Dict[str, Any]] = None,
        image_paths: Optional[list[str]] = None,
    ) -> None:
        """记录一次 LLM 调用；整条记录以原子方式写入，避免并发日志交错。"""
        image_paths = list(image_paths or [])
        content = (response_content or "").strip()
        parts = [
            f"## LLM Step: {step_name}\n\n",
            f"- duration_sec: {duration_sec}\n",
            f"- usage: {json.dumps(usage or {}, ensure_ascii=False)}\n",
        ]
        if image_paths:
            parts.append(f"- image_paths: {json.dumps(image_paths, ensure_ascii=False)}\n")
        parts.extend([
            "**system_prompt**\n\n",
            self._code_block(system_prompt, language="text"),
            "\n**user_prompt**\n\n",
            self._code_block(user_prompt, language="text"),
            "\n**response_content**\n\n",
        ])
        if content.startswith("```"):
            parts.append(content + "\n\n")
        else:
            parts.extend([self._code_block(content, language="text"), "\n"])
        self._append("".join(parts))

    def append_stage_code(self, code: str, round_index: Optional[int] = None) -> None:
        """把本轮最终代码追加到累计代码文件。"""
        if round_index is not None:
            self._append_code_file(f"# ===== round_{round_index} =====\n")
        self._append_code_file((code or "").rstrip() + "\n\n")

    def log_exception(self, title: str, exc: BaseException) -> None:
        """记录异常堆栈。"""
        trace = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        self._append(f"## {title}\n\n")
        self._append(self._code_block(trace, language="text"))
        self._append("\n")
