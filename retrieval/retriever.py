"""任务级高召回表列检索与可复用结果缓存。

该模块提供主程序和独立启动程序共用的唯一检索入口。每个任务先尝试从
``retrieval/results`` 中按“数据集 + 模型”加载结果；任务不存在时才执行两次 LLM
请求，并把该任务结果追加到同一个数据集文件中。缓存只保存后续真正使用的表列和
Token 统计，不保存重复的提示、原始回复或任务上下文。
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from evidence_layer.evidence_contracts import task_benchmark
from evidence_layer.visual_semantics import normalize_name
from llm_client import OpenAICompatibleClient
from query_logger import QueryLogger
from retrieval.prompts import (
    RETRIEVAL_SYSTEM_PROMPT,
    build_initial_retrieval_prompt,
    build_supplement_retrieval_prompt,
)
from vis_project_utils.utils import merge_token_usage

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


class GoalSchemaRetriever:
    """加载或生成一个任务的静态、高召回真实表列集合。"""

    def __init__(
        self,
        *,
        llm_client: OpenAICompatibleClient,
        config: Optional[Mapping[str, Any]] = None,
    ) -> None:
        self.llm_client = llm_client
        self.config = dict(config or {})
        self.retrieval_config = dict(self.config.get("retrieval") or {})
        self.enabled = bool(self.retrieval_config.get("enabled", True))

        configured_model = str(self.retrieval_config.get("model") or "").strip()
        client_model = str(getattr(getattr(llm_client, "config", None), "model", "") or "").strip()
        self.model = configured_model or client_model or "default_model"

        configured_results_dir = str(self.retrieval_config.get("results_dir") or "").strip()
        self.results_dir = (
            Path(configured_results_dir)
            if configured_results_dir
            else Path(__file__).resolve().parent / "results"
        )
        self.total_usage = dict(_ZERO_USAGE)
        self.last_source = "not_started"

    def get_or_generate(
        self,
        *,
        task: Any,
        logger: Optional[QueryLogger] = None,
        force: bool = False,
    ) -> Dict[str, Any]:
        """优先加载缓存；任务未缓存时执行检索并写回统一结果文件。

        输入是当前任务和可选日志器，输出始终是简洁的 ``{"tables": [...]}``。
        ``force=True`` 只重新生成当前任务，不影响同一文件中的其他任务。
        检索异常不会阻断主流程；两次请求都失败时返回空空间且不写入缓存，便于下次重试。
        """
        self.total_usage = dict(_ZERO_USAGE)
        self.last_source = "disabled"
        if not self.enabled:
            return {"tables": []}

        dataset = self._dataset_name(task)
        task_id = self._task_id(task)
        if not force:
            cached = self._load_task(dataset=dataset, task_id=task_id)
            if cached is not None:
                self.total_usage = self._normalize_usage(cached.get("token_usage"))
                self.last_source = "cached"
                return {"tables": list(cached.get("tables") or [])}

        retrieval_space, successful_requests = self._generate(task=task, logger=logger)
        if successful_requests > 0:
            try:
                self._save_task(
                    dataset=dataset,
                    task_id=task_id,
                    retrieval_space=retrieval_space,
                    token_usage=self.total_usage,
                )
                self.last_source = "generated"
            except Exception as exc:
                # 检索结果已可继续使用；缓存写入失败不能使整个分析任务失败。
                self.last_source = "generated_not_saved"
                self._log_error(logger, "goal_schema_retrieval_cache_write_error", exc)
        else:
            self.last_source = "failed"
        return retrieval_space

    def result_path(self, dataset: str) -> Path:
        """返回当前数据集和检索模型共用的唯一结果文件路径。"""
        dataset_name = self._safe_filename_part(dataset)
        model_name = self._safe_filename_part(self.model)
        return self.results_dir / f"{dataset_name}__{model_name}.json"

    def _generate(
        self,
        *,
        task: Any,
        logger: Optional[QueryLogger],
    ) -> Tuple[Dict[str, Any], int]:
        """执行“初次检索 + 遗漏补充”并返回确定性并集和成功请求数。"""
        initial_space: Dict[str, Any] = {"tables": []}
        successful_requests = 0
        try:
            initial_conversation = self.llm_client.start_conversation(
                RETRIEVAL_SYSTEM_PROMPT,
                model=self.model,
            )
            response = initial_conversation.generate_json(
                step_name="goal_schema_retrieval_initial",
                user_prompt=build_initial_retrieval_prompt(task),
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            if not self._has_valid_space_shape(response.parsed):
                raise ValueError("initial retrieval response must contain a JSON `tables` list")
            successful_requests += 1
            initial_space = self._validate_space(task, response.parsed)
        except Exception as exc:
            self._log_error(logger, "goal_schema_retrieval_initial_error", exc)

        # 第二次请求使用独立会话，只检查第一次可能遗漏的表列。
        supplement_space: Dict[str, Any] = {"tables": []}
        try:
            supplement_conversation = self.llm_client.start_conversation(
                RETRIEVAL_SYSTEM_PROMPT,
                model=self.model,
            )
            response = supplement_conversation.generate_json(
                step_name="goal_schema_retrieval_supplement",
                user_prompt=build_supplement_retrieval_prompt(task, initial_space),
                logger=logger,
            )
            self.total_usage = merge_token_usage(self.total_usage, response.usage)
            if not self._has_valid_space_shape(response.parsed):
                raise ValueError("supplement retrieval response must contain a JSON `tables` list")
            successful_requests += 1
            supplement_space = self._validate_space(task, response.parsed)
        except Exception as exc:
            self._log_error(logger, "goal_schema_retrieval_supplement_error", exc)

        return self._merge_spaces(initial_space, supplement_space), successful_requests

    def _has_valid_space_shape(self, payload: Any) -> bool:
        """判断 LLM 回复是否满足最小检索结构，避免把解析失败缓存为空结果。"""
        if not isinstance(payload, Mapping):
            return False
        tables = payload.get("tables")
        return isinstance(tables, Sequence) and not isinstance(tables, (str, bytes))

    def _load_task(self, *, dataset: str, task_id: str) -> Optional[Dict[str, Any]]:
        """从统一结果文件读取一个任务；只校验数据集和模型是否一致。"""
        payload = self._read_result_file(dataset)
        if payload is None:
            return None
        tasks = payload.get("tasks")
        if not isinstance(tasks, Mapping):
            return None
        item = tasks.get(task_id)
        if not isinstance(item, Mapping) or not isinstance(item.get("tables"), list):
            return None
        return dict(item)

    def _save_task(
        self,
        *,
        dataset: str,
        task_id: str,
        retrieval_space: Mapping[str, Any],
        token_usage: Mapping[str, Any],
    ) -> None:
        """把一个任务写入“一个数据集 + 一个模型”的统一 JSON 文件。"""
        payload = self._read_result_file(dataset)
        if payload is None:
            payload = {"dataset": dataset, "model": self.model, "tasks": {}}

        tasks = dict(payload.get("tasks") or {})
        tasks[task_id] = {
            "tables": list(dict(retrieval_space or {}).get("tables") or []),
            "token_usage": self._normalize_usage(token_usage),
        }
        payload["tasks"] = tasks

        path = self.result_path(dataset)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = path.with_suffix(path.suffix + ".tmp")
        temporary_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary_path.replace(path)

    def _read_result_file(self, dataset: str) -> Optional[Dict[str, Any]]:
        """读取统一缓存文件；元数据不一致或文件损坏时视为无缓存。"""
        path = self.result_path(dataset)
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return None
        if not isinstance(payload, Mapping):
            return None
        if str(payload.get("dataset") or "") != dataset:
            return None
        if str(payload.get("model") or "") != self.model:
            return None
        return dict(payload)

    def _validate_space(self, task: Any, payload: Any) -> Dict[str, Any]:
        """删除幻觉表列并恢复为运行时精确名称。

        输入只接受约定的 ``tables`` 列表；输出保留模型顺序。模型顺序仅用于稳定生成，
        不会作为效用分数或硬性优先级。
        """
        table_names: List[str] = []
        column_names: Dict[str, List[str]] = {}
        for table in list(getattr(task, "all_tables", lambda: [])() or []):
            table_name = str(getattr(table, "name", "") or "").strip()
            if not table_name:
                continue
            table_names.append(table_name)
            columns: List[str] = []
            dataframe_columns = getattr(getattr(table, "dataframe", None), "columns", [])
            for column in list(dataframe_columns):
                column_name = str(column or "").strip()
                if column_name and column_name not in columns:
                    columns.append(column_name)
            column_names[table_name] = columns

        parsed = payload if isinstance(payload, Mapping) else {}
        raw_tables = parsed.get("tables")
        if not isinstance(raw_tables, Sequence) or isinstance(raw_tables, (str, bytes)):
            raw_tables = []
        result: List[Dict[str, Any]] = []
        position_by_table: Dict[str, int] = {}
        for raw_table in list(raw_tables or []):
            if not isinstance(raw_table, Mapping):
                continue
            exact_table = self._resolve_schema_name(raw_table.get("table"), table_names)
            if not exact_table:
                continue
            raw_columns = raw_table.get("columns")
            if not isinstance(raw_columns, Sequence) or isinstance(raw_columns, (str, bytes)):
                raw_columns = []
            exact_columns: List[str] = []
            seen_columns = set()
            for raw_column in list(raw_columns or []):
                exact_column = self._resolve_schema_name(
                    raw_column,
                    column_names.get(exact_table, []),
                )
                if not exact_column or exact_column in seen_columns:
                    continue
                seen_columns.add(exact_column)
                exact_columns.append(exact_column)
            if not exact_columns:
                continue
            if exact_table in position_by_table:
                existing = result[position_by_table[exact_table]]["columns"]
                existing.extend(column for column in exact_columns if column not in existing)
            else:
                position_by_table[exact_table] = len(result)
                result.append({"table": exact_table, "columns": exact_columns})
        return {"tables": result}

    def _resolve_schema_name(self, raw_name: Any, candidates: Sequence[str]) -> str:
        """把模型名称解析为唯一真实名称，规范化碰撞时不做猜测。"""
        text = str(raw_name or "").strip()
        if not text:
            return ""
        values = [str(value) for value in candidates if str(value)]
        if text in values:
            return text

        casefold_matches = [value for value in values if value.casefold() == text.casefold()]
        if len(casefold_matches) == 1:
            return casefold_matches[0]

        normalized = normalize_name(text)
        normalized_matches = [value for value in values if normalize_name(value) == normalized]
        return normalized_matches[0] if len(normalized_matches) == 1 else ""

    def _merge_spaces(
        self,
        initial_space: Mapping[str, Any],
        supplement_space: Mapping[str, Any],
    ) -> Dict[str, Any]:
        """按“第一次结果在前、补充结果在后”的顺序做确定性并集。"""
        merged: List[Dict[str, Any]] = []
        positions: Dict[str, int] = {}
        for space in (initial_space, supplement_space):
            for item in list(dict(space or {}).get("tables") or []):
                table = str((item or {}).get("table") or "").strip()
                columns = [
                    str(column or "").strip()
                    for column in list((item or {}).get("columns") or [])
                    if str(column or "").strip()
                ]
                if not table or not columns:
                    continue
                if table not in positions:
                    positions[table] = len(merged)
                    merged.append({"table": table, "columns": []})
                target = merged[positions[table]]["columns"]
                target.extend(column for column in columns if column not in target)
        return {"tables": merged}

    def _dataset_name(self, task: Any) -> str:
        """得到用于缓存标识的数据集名称。"""
        return str(task_benchmark(task) or "insightbench").strip().lower()

    def _task_id(self, task: Any) -> str:
        """读取任务唯一标识；结果文件以该标识作为任务键。"""
        task_id = str(getattr(task, "task_id", "") or "").strip()
        if task_id:
            return task_id
        metadata = dict(getattr(task, "metadata", {}) or {})
        task_id = str(metadata.get("task_id") or "").strip()
        if task_id:
            return task_id
        json_path = getattr(task, "json_path", None)
        if json_path is not None:
            return Path(json_path).stem
        raise ValueError("检索任务缺少可用的 task_id")

    def _normalize_usage(self, usage: Any) -> Dict[str, int]:
        """把模型 Token 统计规范化为项目统一的三个整数。"""
        data = dict(usage or {}) if isinstance(usage, Mapping) else {}
        return {
            "prompt_tokens": int(data.get("prompt_tokens") or 0),
            "completion_tokens": int(data.get("completion_tokens") or 0),
            "total_tokens": int(data.get("total_tokens") or 0),
        }

    def _safe_filename_part(self, value: Any) -> str:
        """把数据集或模型名转换为便于人工识别的安全文件名。"""
        text = re.sub(r"[^0-9A-Za-z._-]+", "_", str(value or "").strip())
        return text.strip("._-") or "unknown"

    def _log_error(
        self,
        logger: Optional[QueryLogger],
        step_name: str,
        error: Exception,
    ) -> None:
        """把非阻断检索错误写入统一日志。"""
        if logger is None:
            return
        try:
            logger.log_json(step_name, {"error": str(error)[:1000]})
        except Exception:
            return
