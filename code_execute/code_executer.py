"""code_executer.py
------------------
当前 question 的代码生成、执行、修复与 trace 收集。

当前主流程接收 Question Evidence Profile，并在同一 LLM conversation 中完成
代码生成、修复和后续解释。代码仍只需要设置 `stage_result`；
视觉证据由 evidence layer 根据 trace、stage_result 和证据画像自动组织。
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import traceback
from typing import Any, Dict, Optional

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy import stats
import statsmodels.api as sm
import statsmodels.formula.api as smf

from code_execute.error_classification import CODE_EXECUTION_ERROR, classify_error_message
from code_execute.stage_code_runner import run_stage_code_generation_loop
from code_execute.stage_result_contract import (
    normalize_stage_result_contract,
    validate_stage_result_contract,
)
from code_execute.trace_bundle_normalizer import normalize_trace_bundle
from code_execute.trace_pandas_patch import TRACE_PATCHER
from data_loader import InsightBenchTask
from llm_client import LLMConversation
from prompts import build_stage_code_prompt, build_stage_repair_prompt
from query_logger import QueryLogger
from vis_project_utils.utils import _clone_value, merge_token_usage

_ZERO_USAGE = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}


class CodeExecuter:
    """为一个确定的 question 生成并执行 pandas 代码。"""

    def __init__(
        self,
        *,
        config: Optional[Dict[str, Any]],
        task: InsightBenchTask,
        raw_tables: Dict[str, pd.DataFrame],
        output_dir: str | Path,
        logger: Optional[QueryLogger] = None,
    ) -> None:
        self.config = dict(config or {})
        self.task = task
        execution_config = dict(self.config.get("execution") or {})
        copy_on_init = bool(execution_config.get("copy_tables_on_executor_init", False))
        self.raw_tables = {
            name: (frame.copy(deep=True) if copy_on_init else frame)
            for name, frame in raw_tables.items()
        }
        self.output_dir = Path(output_dir)
        self.logger = logger

        raw_max_repairs = execution_config.get("max_code_repairs", execution_config.get("max_stage_repairs", 3))
        self.max_repairs = max(0, int(3 if raw_max_repairs is None else raw_max_repairs))
        self.max_trace_tables = int(execution_config.get("max_trace_tables", 2000) or 2000)
        self.max_trace_events = int(execution_config.get("max_trace_events", 5000) or 5000)
        self.max_trace_columns = int(execution_config.get("max_trace_columns", 200) or 200)
        self.total_usage = dict(_ZERO_USAGE)

    def execute(
        self,
        *,
        question_index: int,
        evidence_profile: Dict[str, Any],
        conversation: LLMConversation,
    ) -> tuple[bool, Dict[str, Any]]:
        """根据 Question Evidence Profile 生成并执行当前问题的代码。

        证据画像、代码生成、代码修复和解释共用同一会话。新分析会话只在首问
        提供完整 Schema；后续代码生成与修复均遵循会话中已经建立的 Schema。
        修复请求只补充当前画像、失败代码和错误信息，不重复发送完整 Schema。
        """
        if not isinstance(evidence_profile, dict) or not evidence_profile:
            raise ValueError("CodeExecuter.execute requires a non-empty evidence_profile.")

        question_dir = self.output_dir / f"question_{question_index}"
        question_dir.mkdir(parents=True, exist_ok=True)

        code_prompt = build_stage_code_prompt(task=self.task)
        def _execute_and_attach(code: str) -> Dict[str, Any]:
            result = self.run(code=code, question_index=question_index, question_dir=question_dir)
            result["generated_code"] = code
            return result

        def _repair_prompt(code: str, result: Dict[str, Any]) -> str:
            error_message = str(result.get("error") or "")
            return build_stage_repair_prompt(
                task=self.task,
                error_message=error_message,
                evidence_profile=evidence_profile,
                failed_code=code,
            )

        success, execution, usage = run_stage_code_generation_loop(
            conversation=conversation,
            code_prompt=code_prompt,
            execute_code=_execute_and_attach,
            repair_prompt_builder=_repair_prompt,
            max_repairs=self.max_repairs,
            logger=self.logger,
            round_index=question_index,
            initial_step_name=f"question_{question_index}_code",
            repair_step_prefix=f"question_{question_index}_repair",
            log_prefix=f"question_{question_index}",
        )
        self.total_usage = merge_token_usage(self.total_usage, usage)
        self._write_final_code(question_dir, str(execution.get("generated_code") or ""))
        return success, execution

    def run(self, *, code: str, question_index: int, question_dir: Path) -> Dict[str, Any]:
        """在隔离 namespace 中执行代码并收集 trace。"""
        stdout_buffer = io.StringIO()
        stderr_buffer = io.StringIO()
        namespace = self._build_namespace(question_dir)

        try:
            plt.close("all")
            TRACE_PATCHER.configure(
                max_tables=self.max_trace_tables,
                max_events=self.max_trace_events,
                max_columns=self.max_trace_columns,
            )
            TRACE_PATCHER.clear()
            self._bind_trace_sources(namespace)
            TRACE_PATCHER.patch_all()
            with redirect_stdout(stdout_buffer), redirect_stderr(stderr_buffer):
                exec(code, namespace, namespace)

            raw_result = namespace.get("stage_result")
            if raw_result is None:
                raise RuntimeError("Generated code did not set `stage_result`.")

            result_payload, contract_diagnostics = normalize_stage_result_contract(raw_result)
            if self.logger is not None:
                self.logger.log_json(f"question_{question_index}_stage_result_contract", contract_diagnostics)
            valid, validation_error, validation_error_type = validate_stage_result_contract(result_payload)
            if not valid:
                return {
                    "success": False,
                    "result_payload": result_payload,
                    "trace_bundle": {},
                    "artifact_store": {},
                    "error": validation_error,
                    "error_type": validation_error_type,
                    "stage_result_diagnostics": contract_diagnostics,
                }
            raw_trace_bundle = TRACE_PATCHER.export_trace()
            raw_trace_bundle["round_index"] = question_index
            raw_trace_bundle["stage_result"] = {
                "type": result_payload.get("type"),
                # Bind only the validated, cleaned evidence items.  Referencing the raw
                # generated object would re-introduce stat items that the contract layer
                # deliberately removed as empty.
                "refs": TRACE_PATCHER.describe_value_refs(
                    result_payload.get("stat"), path="stage_result.stat"
                ),
            }
            trace_bundle = normalize_trace_bundle(raw_trace_bundle, round_index=question_index)
            artifact_store = TRACE_PATCHER.export_live_artifacts()

            return {
                "success": True,
                "result_payload": result_payload,
                "trace_bundle": trace_bundle,
                "artifact_store": artifact_store,
                "error": "",
                "error_type": "",
                "stage_result_diagnostics": contract_diagnostics,
            }
        except SystemExit as exc:
            return {
                "success": False,
                "result_payload": None,
                "trace_bundle": {},
                "artifact_store": {},
                "error": f"Generated code called SystemExit/exit: {exc}",
                "error_type": CODE_EXECUTION_ERROR,
            }
        except Exception as exc:
            return {
                "success": False,
                "result_payload": None,
                "trace_bundle": {},
                "artifact_store": {},
                "error": str(exc) + "\n" + traceback.format_exc(),
                "error_type": classify_error_message(str(exc), default=CODE_EXECUTION_ERROR),
            }
        finally:
            TRACE_PATCHER.unpatch_all()
            plt.close("all")


    def _build_namespace(self, question_dir: Path) -> Dict[str, Any]:
        """构建每个 question 独立的执行 namespace。

        ``tables`` 仍是正式访问入口。对合法 Python 标识符形式的表名同时提供
        同对象别名，兼容模型偶尔生成的 ``orders`` 而非 ``tables["orders"]``，
        避免一次简单的表访问偏差把整轮错误判为不可回答。
        """
        runtime_tables = {name: _clone_value(frame) for name, frame in self.raw_tables.items()}
        namespace: Dict[str, Any] = {
            "pd": pd,
            "np": np,
            "sm": sm,
            "smf": smf,
            "stats": stats,
            "plt": plt,
            "Path": Path,
            "tables": runtime_tables,
            "output_dir": question_dir,
        }
        for name, value in runtime_tables.items():
            table_name = str(name or "")
            if table_name.isidentifier() and table_name not in namespace:
                namespace[table_name] = value
        return namespace

    def _bind_trace_sources(self, namespace: Dict[str, Any]) -> None:
        """执行前把源表绑定到 trace patcher。"""
        tables = namespace.get("tables")
        if isinstance(tables, dict):
            for name, value in tables.items():
                if isinstance(value, (pd.DataFrame, pd.Series)):
                    TRACE_PATCHER.bind_name(value, name)

    def _write_final_code(self, question_dir: Path, code: str) -> None:
        """保存最终一次生成/修复后的代码，便于人工审计。"""
        if not code.strip():
            return
        try:
            question_dir.mkdir(parents=True, exist_ok=True)
            (question_dir / "generated_code.py").write_text(code, encoding="utf-8")
        except Exception:
            pass

