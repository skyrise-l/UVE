"""视觉证据层总控。

本模块协调两套边界明确的证据系统：
1. Current-question evidence：只使用当前代码执行的 Trace/stage_result，服务当前 Insight；
2. Exploration candidate construction：使用未被 Answer 采用的计算结果、BIRD Join Probe
   或未执行 Join 机会，且只服务下一层问题生成。

两套系统复用表语义、方案合法性和事实提取基础设施，但不共享证据权限：Join/Schema
探索信息不得进入当前 Answer。中间计划与打分只写入审计文件。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence

import pandas as pd

from analysis_tendency import normalize_analysis_tendency
from chart.transforms import apply_transform_ops
from code_execute.error_classification import FRONTIER_SELECTION_ERROR, VISUAL_EXTRACTION_ERROR
from chart_extract.plan_selection import select_visual_plan_set
from evidence_layer.result_evidence_cards import build_result_evidence_cards
from evidence_layer.evidence_artifact_writer import EvidenceArtifactWriter
from evidence_layer.frontier_cards import build_frontier_cards
from evidence_layer.join_opportunities import JoinOpportunityEngine, JoinProbe
from evidence_layer.evidence_brief import build_evidence_brief
from evidence_layer.current_question_evidence import CurrentQuestionEvidenceOrganizer
from evidence_layer.evidence_contracts import (
    JOIN_OPPORTUNITY_PROVENANCE,
    JOIN_PROBE_PROVENANCE,
)
from evidence_layer.exploration_candidate_builder import ExplorationCandidateBuilder
from evidence_layer.benchmark_exploration import build_benchmark_exploration_policy
from evidence_layer.utility_estimator import score_visual_plans
from evidence_layer.veg_builder import build_veg
from evidence_layer.visual_plan_generator import generate_visual_plans
from evidence_layer.visual_semantics import normalize_name, task_table_metadata
from vis_project_utils.utils import preview_records, sanitize_filename, truncate_text
from vis_project_utils.dataframe_safety import normalize_analysis_dataframe, normalize_artifact_store


# 本文件中对外返回的统一类型。
# 保持为普通 dict，避免引入额外 dataclass，降低与现有调用代码的耦合。
VisualReturn = Dict[str, Any]

# VisualPlan 在其他模块中以 dict 形式流转，这里只声明只读 Mapping，提示本文件不应修改 plan 本身。
Plan = Mapping[str, Any]


def _config_value(mapping: Mapping[str, Any], key: str, default: Any) -> Any:
    """Return the configured value while preserving explicit zero/False."""
    value = dict(mapping or {}).get(key, default)
    return default if value is None else value


class EvidenceOrganizer:
    """视觉证据组织器。

    该类负责把一轮代码执行结果转为 answer 层可消费的证据。

    职责边界：
    - 负责调用各模块，而不负责实现打分、gate、渲染、辅助观察抽取算法；
    - 负责把 result_payload 压缩成 answer 层可读的证据预览；
    - 负责把多图选择真正接入主链路；
    - 负责控制对外返回内容和审计文件内容的复杂度。
    """

    def __init__(self, config: Optional[Dict[str, Any]], task, output_dir, logger):
        """初始化视觉证据组织器。

        参数说明：
        - ``config``：全局配置，主要读取 chart 相关配置；
        - ``task``：当前任务对象，本文件不直接解析任务内容，只保留引用；
        - ``output_dir``：本轮运行产物目录；
        - ``logger``：外部日志对象，可为空。
        """
        self.config = dict(config or {})
        self.task = task
        self.output_dir = Path(output_dir)
        self.logger = logger

        # 供总用量统计读取。本文件不调用 LLM，因此 token 使用量固定为 0。
        self.total_usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}

        chart_config = dict(self.config.get("chart") or {})
        self.chart_enabled = bool(chart_config.get("enabled", True))
        # VEG is required in memory for plan generation, but is too verbose for normal
        # result packages. Enable only for targeted debugging.
        self.save_veg = bool(chart_config.get("save_veg", False))
        self.representation_gate_threshold = float(
            _config_value(chart_config, "representation_gate_threshold", 0.50)
        )
        self.min_evidence_support = float(_config_value(chart_config, "min_evidence_support", 0.58))
        self.min_frontier_evidence_support = float(_config_value(chart_config, "min_frontier_evidence_support", 0.42))

        # answer 图卡预算。默认最多 3 张图；每张卡内部只保留少量关键事实和候选 insight。
        self.max_charts = max(1, int(_config_value(chart_config, "max_charts", 3)))

        # 结果卡预算。结果卡不依赖图表渲染，用于把文本/表格/趋势结果直接压成候选 insight。
        # 它和图卡共用 answer_evidence_cards 字段，避免在主流程中增加新的复杂数据结构。
        self.max_result_cards = max(0, int(_config_value(chart_config, "max_result_cards", 2)))

        # frontier 图数量单独控制。frontier 卡片只服务下一轮探索，因此默认更保守。
        self.max_frontiers = max(0, int(_config_value(chart_config, "max_frontiers", 2)))

        # Recall starts only when no plan passes the hard evidence/representation gates.
        # QEP tendency is not a gate; recall only relaxes L2/L3 within explicit floors.
        self.recall_enabled = bool(chart_config.get("recall_enabled", True))
        self.recall_max_charts = max(1, int(_config_value(chart_config, "recall_max_charts", 1)))
        self.recall_evidence_relaxation = max(
            0.0,
            float(_config_value(chart_config, "recall_evidence_relaxation", 0.12)),
        )
        self.recall_representation_relaxation = max(
            0.0,
            float(_config_value(chart_config, "recall_representation_relaxation", 0.12)),
        )
        self.recall_min_evidence_support = max(
            0.0,
            float(_config_value(chart_config, "recall_min_evidence_support", 0.35)),
        )
        self.recall_min_representation_threshold = max(
            0.0,
            float(_config_value(chart_config, "recall_min_representation_threshold", 0.42)),
        )

        # answer 层直接阅读的结果预览规模。
        # 这个参数只控制传给 Answer LLM 的表格/列表文本预览行数，
        # 不参与是否画图、是否生成 frontier、是否跳过视觉证据的判断。
        execution_config = dict(self.config.get("execution") or {})
        self.max_answer_preview_rows = max(1, int(
            _config_value(execution_config, "max_result_preview_rows", 8)
        ))
        self.max_answer_preview_cols = max(1, int(
            _config_value(execution_config, "max_result_preview_cols", 10)
        ))
        self.max_answer_text_chars = max(1200, int(_config_value(execution_config, "max_result_text_chars", 1200)))

        stage_result_config = dict(self.config.get("stage_result") or {})
        self.max_full_table_rows = max(1, int(_config_value(stage_result_config, "max_full_table_rows", 30)))
        self.max_full_table_cols = max(1, int(_config_value(stage_result_config, "max_full_table_cols", 10)))

        self.artifact_writer = EvidenceArtifactWriter(self.output_dir)
        self.exploration_policy = build_benchmark_exploration_policy(
            task=self.task,
            config=self.config,
        )
        # Answer / Exploration 两条证据路径在结构上拆分，底层仍复用本类的通用工具。
        self.current_question_path = CurrentQuestionEvidenceOrganizer(self)
        self.exploration_path = ExplorationCandidateBuilder(self)
        self.latest_evidence: VisualReturn = self._empty_visual_return()
        self.evidence: List[VisualReturn] = []
        self._latest_trace_stats: Dict[str, Any] = {}
        self.join_engine = JoinOpportunityEngine(task, self.config)
        self._latest_trace_table_names: List[str] = []
        self._seen_join_signatures: set[str] = set()
        # 只记录成功执行 trace 中真正参与分析操作的源表列。该状态供任务级
        # retrieval frontier 构建使用，不进入当前问题 Answer。
        self._explored_analysis_columns: set[str] = set()

    # ------------------------------------------------------------------
    # 对外入口
    # ------------------------------------------------------------------

    def organize(
        self,
        round_index: int,
        code_result: Dict[str, Any],
        evidence_profile: Optional[Dict[str, Any]] = None,
    ) -> VisualReturn:
        """把一轮执行结果整理成 Answer 证据和局部 Exploration 候选。

        返回值只保留后续真实消费的四项：结果预览、解释摘要、Answer 证据卡和
        结构化探索候选。视觉选择的中间分数只写入审计文件，不层层传递。
        """
        answer_evidence = self._build_answer_evidence(
            round_index=round_index,
            code_result=code_result,
            evidence_profile=evidence_profile,
        )
        visual = self._build_visual_evidence(
            round_index=round_index,
            code_result=code_result,
            evidence_profile=evidence_profile,
        )
        evidence_brief = build_evidence_brief(
            question=self._round_question(evidence_profile),
            goal=self._task_goal_text(),
            answer_evidence=answer_evidence,
            answer_evidence_cards=str(visual.get("answer_evidence_cards") or ""),
        )
        payload = {
            "answer_evidence": answer_evidence,
            "evidence_brief": evidence_brief,
            "answer_evidence_cards": str(visual.get("answer_evidence_cards") or ""),
            "exploration_candidates": list(visual.get("exploration_candidates") or []),
            "diagnostics": dict(visual.get("diagnostics") or {}),
        }
        self.latest_evidence = payload
        self.evidence.append(payload)
        return payload

    def organize_execution_error(
        self,
        *,
        round_index: int,
        evidence_profile: Optional[Dict[str, Any]],
        error: str,
    ) -> VisualReturn:
        """把代码执行失败转为恢复型探索候选，不伪造业务 Insight。"""
        error_card = self._execution_error_card(evidence_profile=evidence_profile, error=error)
        exploration_candidates = self.exploration_path.build_error(
            evidence_profile=evidence_profile,
            error_card=error_card,
        )
        diagnostic_value = {
            "error_type": "execution_error",
            "error": truncate_text(str(error or ""), 900),
        }
        answer_evidence = {
            "summary": "Code execution failed before producing reliable evidence.",
            "value": diagnostic_value,
            "stage_result": {
                "stat": [
                    {
                        "name": "execution_error",
                        "description": "Code execution failed after the configured repair attempts.",
                        "value": diagnostic_value,
                    }
                ],
            },
            "note": "Execution failure is not evidence for a business conclusion.",
        }
        evidence_brief = build_evidence_brief(
            question=self._round_question(evidence_profile),
            goal=self._task_goal_text(),
            answer_evidence=answer_evidence,
            answer_evidence_cards="",
        )
        payload = {
            "answer_evidence": answer_evidence,
            "evidence_brief": evidence_brief,
            "answer_evidence_cards": "",
            "exploration_candidates": exploration_candidates,
            "diagnostics": {
                "visual_status": "skip_visual_due_to_code_execution_error",
                "visual_error": "",
                "diagnostic_error_types": [],
            },
        }
        self._write_visual_audit(
            round_index,
            {
                "status": "skip_visual_due_to_code_execution_error",
                "error": truncate_text(str(error or ""), 900),
                "answer_selected_plans": [],
                "frontier_selected_plans": [],
                "exploration_candidates": exploration_candidates,
                "p0_route_gate": {
                    "current_question": {},
                    "exploration": dict(getattr(self.exploration_path, "last_route_gate_audit", {}) or {}),
                },
            },
        )
        self.latest_evidence = payload
        self.evidence.append(payload)
        return payload

    # ------------------------------------------------------------------
    # answer 层结果证据整理
    # ------------------------------------------------------------------

    def _build_answer_evidence(
        self,
        *,
        round_index: int,
        code_result: Dict[str, Any],
        evidence_profile: Optional[Dict[str, Any]],
    ) -> Dict[str, Any]:
        """把代码执行结果整理成 answer 层可直接阅读的证据。

        当前代码 prompt 的唯一出口是 ``stage_result['stat']``。这里只保留
        answer 阶段真正需要的 stat、预览后的 value 和截断说明。
        """
        result_payload = dict((code_result or {}).get("result_payload") or {})
        result_value = result_payload.get("value")
        result_summary = str(result_payload.get("summary") or "").strip()

        preview_value, notes = self._preview_value_for_answer(result_value, path="result")
        note = " ".join(item for item in notes if item).strip()

        stage_result = {
            "stat": self._preview_stat_items(result_payload.get("stat") or []),
        }

        return {
            "summary": result_summary,
            "value": preview_value,
            "stage_result": stage_result,
            "note": note,
        }

    def _preview_stat_items(self, stat_items: Any) -> List[Dict[str, Any]]:
        """预览 stat 列表里的 value，避免把大表完整塞给解释模型。"""
        if not isinstance(stat_items, list):
            return []
        previewed: List[Dict[str, Any]] = []
        for item in stat_items:
            if not isinstance(item, dict):
                continue
            value_preview, _notes = self._preview_value_for_answer(item.get("value"), path=str(item.get("name") or "stat.value"))
            previewed.append({
                "name": str(item.get("name") or ""),
                "description": str(item.get("description") or ""),
                "value": value_preview,
            })
        return previewed

    def _round_question(self, evidence_profile: Optional[Dict[str, Any]]) -> str:
        """从 evidence_profile 中读取当前轮问题。"""
        return str((evidence_profile or {}).get("round_question") or "").strip()

    def _task_goal_text(self) -> str:
        """读取当前 task 的 goal，用于 evidence brief 判断证据是否贴近任务目标。"""
        metadata = dict(getattr(self.task, "metadata", {}) or {})
        return str(metadata.get("goal") or metadata.get("dataset_description") or "").strip()

    def _preview_value_for_answer(self, value: Any, *, path: str) -> tuple[Any, List[str]]:
        """递归生成 answer 层预览值和截断说明。

        预览策略保持简单：
        - 表格按配置展示前 N 行、前 M 列；
        - 字典按配置展示前 M 个键；
        - 列表/元组/集合按配置展示前 N 项；
        - 文本按配置截断到固定字符数。
        """
        dataframe = self._coerce_to_dataframe(value)
        if dataframe is not None:
            return self._preview_dataframe_for_answer(dataframe, path=path)

        if isinstance(value, dict):
            items = list(value.items())
            shown_items = items[: self.max_answer_preview_cols]
            notes: List[str] = []
            preview: Dict[str, Any] = {}
            for key, item in shown_items:
                item_preview, item_notes = self._preview_value_for_answer(item, path=f"{path}.{key}")
                preview[str(key)] = item_preview
                notes.extend(item_notes)
            if len(items) > len(shown_items):
                notes.insert(
                    0,
                    f"{path} is a dictionary with {len(items)} keys; only the first {len(shown_items)} keys are shown.",
                )
            return preview, notes

        if isinstance(value, (list, tuple, set)):
            values = list(value)
            shown_values = values[: self.max_answer_preview_rows]
            notes: List[str] = []
            preview: List[Any] = []
            for index, item in enumerate(shown_values):
                item_preview, item_notes = self._preview_value_for_answer(item, path=f"{path}[{index}]")
                preview.append(item_preview)
                notes.extend(item_notes)
            if len(values) > len(shown_values):
                notes.insert(
                    0,
                    f"{path} is a sequence with {len(values)} items; only the first {len(shown_values)} items are shown.",
                )
            return preview, notes

        if isinstance(value, str):
            preview = truncate_text(value, self.max_answer_text_chars)
            if len(value) > len(preview):
                return preview, [
                    f"{path} is text with {len(value)} characters; only the first {self.max_answer_text_chars} characters are shown."
                ]
            return preview, []

        return value, []

    def _preview_dataframe_for_answer(self, dataframe: pd.DataFrame, *, path: str) -> tuple[List[Dict[str, Any]], List[str]]:
        """生成表格结果预览。

        小型分组表通常正是 InsightBench 的关键证据，因此行列都不大时完整保留；
        只有超过阈值的大表才截断，并在 note 中明确说明。
        """
        row_count, col_count = int(dataframe.shape[0]), int(dataframe.shape[1])
        if row_count <= self.max_full_table_rows and col_count <= self.max_full_table_cols:
            return preview_records(dataframe, max_rows=row_count, max_cols=col_count), []

        rows = min(row_count, self.max_answer_preview_rows)
        cols = min(col_count, self.max_answer_preview_cols)
        preview = preview_records(dataframe.iloc[:rows, :cols], max_rows=rows, max_cols=cols)
        return preview, [
            f"{path} is a tabular result with {row_count} rows and {col_count} columns; "
            f"only the first {rows} rows and first {cols} columns are shown, so unseen rows should not be inferred."
        ]

    def _coerce_to_dataframe(self, value: Any) -> Optional[pd.DataFrame]:
        """尽量把常见表状结果转为 DataFrame，便于统一预览。"""
        if isinstance(value, pd.DataFrame):
            return value
        if isinstance(value, pd.Series):
            series_name = value.name if value.name is not None else "value"
            return value.to_frame(name=str(series_name)).reset_index()
        if isinstance(value, list) and value and all(isinstance(item, dict) for item in value):
            try:
                dataframe = pd.DataFrame(value)
            except Exception:
                return None
            return dataframe if not dataframe.empty else None
        if isinstance(value, dict) and value:
            sequence_values = []
            for item in value.values():
                if isinstance(item, (list, tuple, pd.Series)):
                    sequence_values.append(item)
                else:
                    return None
            lengths = {len(item) for item in sequence_values}
            if len(lengths) != 1 or not lengths or next(iter(lengths)) == 0:
                return None
            try:
                dataframe = pd.DataFrame(value)
            except Exception:
                return None
            return dataframe if not dataframe.empty else None
        return None

    # ------------------------------------------------------------------
    # 结果证据卡
    # ------------------------------------------------------------------

    def _build_result_evidence_cards(
        self,
        *,
        code_result: Dict[str, Any],
        evidence_profile: Optional[Dict[str, Any]],
    ) -> str:
        """从 stage_result.value 生成非图表结果卡。

        这一步服务两个场景：
        1. 当前轮没有合适图表，但表格/文本结果本身已经能支持结论；
        2. 图卡只覆盖 top-k 或趋势，而 stage_result 中还含有文本/条件对比补充信息。

        输出仍然是短文本卡片，并合并到 answer_evidence_cards，避免新增数据通道。
        """
        result_payload = dict((code_result or {}).get("result_payload") or {})
        card_value = result_payload.get("value")
        return build_result_evidence_cards(
            card_value,
            evidence_profile=evidence_profile,
            task=self.task,
            max_cards=self.max_result_cards,
        )

    # ------------------------------------------------------------------
    # 视觉证据主链路
    # ------------------------------------------------------------------
    def _build_visual_evidence(
        self,
        *,
        round_index: int,
        code_result: Dict[str, Any],
        evidence_profile: Optional[Dict[str, Any]],
    ) -> VisualReturn:
        """Ground the current execution once, then route evidence into two systems.

        Current-question evidence receives only Trace-grounded plans. Exploration may
        additionally receive computed Join probes and schema opportunities. The routing
        boundary is enforced before plan selection, not only through a score or prompt.
        """
        trace_bundle = dict((code_result or {}).get("trace_bundle") or {})
        self.current_question_path.last_route_gate_audit = {}
        self.exploration_path.last_route_gate_audit = {}
        self.exploration_path.last_quality_audit = {
            "precheck_rejections": [],
            "materialized_rejections": [],
        }
        self._latest_trace_stats = dict(trace_bundle.get("trace_stats") or {})
        self._latest_trace_table_names = self._trace_source_table_names(trace_bundle)
        self._update_explored_analysis_columns(trace_bundle)
        result_cards = self._build_result_evidence_cards(
            code_result=code_result,
            evidence_profile=evidence_profile,
        )

        if not self.chart_enabled:
            exploration_candidates = self.exploration_path.build(
                evidence_profile=evidence_profile,
                frontier_plans=[],
                materialize_df=None,
            )
            status = "chart_disabled"
            self._write_visual_audit(
                round_index,
                {
                    "status": status,
                    "error": "",
                    "answer_selected_plans": [],
                    "frontier_selected_plans": [],
                    "answer_evidence_cards": result_cards,
                    "exploration_candidates": exploration_candidates,
                    "p0_route_gate": {
                        "current_question": dict(getattr(self.current_question_path, "last_route_gate_audit", {}) or {}),
                        "exploration": dict(getattr(self.exploration_path, "last_route_gate_audit", {}) or {}),
                    },
                    "exploration_quality_audit": dict(
                        getattr(self.exploration_path, "last_quality_audit", {}) or {}
                    ),
                },
            )
            return {
                "answer_evidence_cards": result_cards,
                "exploration_candidates": exploration_candidates,
                "diagnostics": {
                    "visual_status": status,
                    "visual_error": "",
                    "diagnostic_error_types": [],
                },
            }

        # Visual analysis uses a normalized copy so pandas nullable scalars cannot
        # abort plan generation/scoring.  The original execution artifacts remain
        # unchanged for answer evidence and trace auditing.
        artifact_store = normalize_artifact_store((code_result or {}).get("artifact_store") or {})
        try:
            veg = build_veg(trace_bundle=trace_bundle, artifact_store=artifact_store)
            if self.save_veg:
                self._write_veg(round_index, veg)

            raw_plans = generate_visual_plans(
                veg,
                artifact_store,
                source_table_metadata=task_table_metadata(self.task),
            )
            normalized_tendency = normalize_analysis_tendency(
                (evidence_profile or {}).get("analysis_tendency"),
                question_text=str((evidence_profile or {}).get("round_question") or ""),
            )
            scored_regular_plans = score_visual_plans(
                raw_plans,
                veg,
                normalized_tendency,
                artifact_store,
                representation_gate_threshold=self.representation_gate_threshold,
                min_evidence_support=self.min_evidence_support,
                min_frontier_evidence_support=self.min_frontier_evidence_support,
                evidence_profile=evidence_profile,
                task_anchor_text=self._task_anchor_text(evidence_profile),
            )
        except Exception as exc:
            exploration_candidates = self.exploration_path.build(
                evidence_profile=evidence_profile,
                frontier_plans=[],
                materialize_df=None,
                )
            self._write_visual_audit(
                round_index,
                {
                    "status": "visual_pipeline_error",
                    "error": str(exc),
                    "answer_selected_plans": [],
                    "frontier_selected_plans": [],
                    "answer_evidence_cards": result_cards,
                    "exploration_candidates": exploration_candidates,
                    "p0_route_gate": {
                        "current_question": dict(getattr(self.current_question_path, "last_route_gate_audit", {}) or {}),
                        "exploration": dict(getattr(self.exploration_path, "last_route_gate_audit", {}) or {}),
                    },
                    "exploration_quality_audit": dict(
                        getattr(self.exploration_path, "last_quality_audit", {}) or {}
                    ),
                },
            )
            return {
                "answer_evidence_cards": result_cards,
                "exploration_candidates": exploration_candidates,
                "diagnostics": {
                    "visual_status": "visual_pipeline_error",
                    "visual_error": str(exc),
                    "diagnostic_error_types": [VISUAL_EXTRACTION_ERROR],
                },
            }

        # Join exploration is optional.  A malformed constraint, an oversized table or
        # any probe-specific failure must never remove the regular Trace-grounded visual
        # evidence that was already scored successfully above.
        join_artifacts: Dict[str, pd.DataFrame] = {}
        scored_join_plans: List[Dict[str, Any]] = []
        join_initialization_error = str(getattr(self.join_engine, "initialization_error", "") or "")
        join_pipeline_error = join_initialization_error
        join_probe_audit: List[Dict[str, Any]] = []
        try:
            join_probes = self.join_engine.build_probes(
                evidence_profile=evidence_profile,
                seed_tables=self._latest_trace_table_names,
                exclude_signatures=self._seen_join_signatures,
            )
            join_probe_audit = list(self.join_engine.last_probe_audit or [])
            join_veg, join_artifacts, join_metadata = self._join_probe_visual_inputs(
                round_index=round_index,
                probes=join_probes,
            )
            if join_artifacts:
                raw_join_plans = generate_visual_plans(
                    join_veg,
                    join_artifacts,
                    source_table_metadata=join_metadata,
                )
                self._mark_join_probe_plans(raw_join_plans, join_probes)
                scored_join_plans = score_visual_plans(
                    raw_join_plans,
                    join_veg,
                    normalized_tendency,
                    join_artifacts,
                    representation_gate_threshold=self.representation_gate_threshold,
                    min_evidence_support=self.min_evidence_support,
                        min_frontier_evidence_support=self.min_frontier_evidence_support,
                    evidence_profile=evidence_profile,
                    task_anchor_text=self._task_anchor_text(evidence_profile),
                )
        except Exception as exc:
            join_pipeline_error = str(exc)
            join_artifacts = {}
            scored_join_plans = []

        combined_artifacts = {**artifact_store, **join_artifacts}

        diagnostic_error_types: List[str] = []
        if join_initialization_error:
            diagnostic_error_types.append(FRONTIER_SELECTION_ERROR)
        elif join_pipeline_error:
            diagnostic_error_types.append(VISUAL_EXTRACTION_ERROR)

        # Route/selection failures are non-fatal to the current answer because result
        # cards remain available, but they must be visible in error_type_counts.
        try:
            # System A: current-question evidence.  Only plans grounded in the current
            # execution Trace are eligible; computed Join probes remain exploration-only.
            answer_plans, selection_status = self.current_question_path.select_plans(
                scored_trace_plans=scored_regular_plans,
                analysis_tendency=normalized_tendency,
            )

            # System B: next-question exploration.  It may use unused Trace views and
            # computed Join probes, but never feeds the current Insight directly.
            frontier_plans = self.exploration_path.select_plans(
                scored_trace_plans=scored_regular_plans,
                scored_join_plans=scored_join_plans,
                answer_plans=answer_plans,
            )
        except Exception as exc:
            answer_plans = []
            frontier_plans = []
            selection_status = "frontier_selection_error"
            diagnostic_error_types.append(FRONTIER_SELECTION_ERROR)
            join_pipeline_error = "; ".join(value for value in (join_pipeline_error, str(exc)) if value)

        render_records: List[Dict[str, Any]] = []
        audit_error = join_pipeline_error
        if answer_plans:
            render_records = self._render_selected_plans(round_index, answer_plans, combined_artifacts)
            render_error = self._join_render_errors(render_records)
            if render_error:
                diagnostic_error_types.append(VISUAL_EXTRACTION_ERROR)
            audit_error = "; ".join(value for value in (audit_error, render_error) if value)

        materialize_df = self._materializer(combined_artifacts)
        answer_payload = self.current_question_path.build(
            code_result=code_result,
            evidence_profile=evidence_profile,
            selected_answer_plans=answer_plans,
            materialize_df=materialize_df,
        )
        answer_evidence_cards = str(answer_payload.get("answer_evidence_cards") or result_cards or "")
        exploration_candidates = self.exploration_path.build(
            evidence_profile=evidence_profile,
            frontier_plans=frontier_plans,
            materialize_df=materialize_df,
        )

        route_audit = dict(getattr(self.exploration_path, "last_route_gate_audit", {}) or {})
        rejection_reasons = dict(route_audit.get("rejection_reasons") or {})
        if (
            int(route_audit.get("input_count") or 0) > 0
            and int(route_audit.get("allowed_count") or 0) == 0
            and any(
                str(reason).startswith((
                    "unknown_exploration_provenance:",
                    "missing_exploration_provenance",
                    "exploration_channel_provenance_mismatch:",
                ))
                for reason in rejection_reasons
            )
        ):
            diagnostic_error_types.append(FRONTIER_SELECTION_ERROR)
            invariant_error = "all computed exploration plans were rejected by provenance legality checks"
            audit_error = "; ".join(value for value in (audit_error, invariant_error) if value)

        if not answer_plans and not frontier_plans:
            selection_status = "no_visual_plan"

        self._write_visual_audit(
            round_index,
            {
                "status": selection_status,
                "error": audit_error,
                "answer_selected_plans": [
                    self._plan_score_record(record["plan"], render_result=record["render"])
                    for record in render_records
                ],
                "frontier_selected_plans": [self._plan_score_record(plan) for plan in frontier_plans],
                "join_probe_audit": join_probe_audit,
                "evidence_systems": {
                    "current_question": {
                        "source_policy": "current_trace_only",
                        "selected_plan_count": len(answer_plans),
                    },
                    "exploration": {
                        "source_policy": "trace_frontier_plus_join_expansion",
                        "selected_plan_count": len(frontier_plans),
                        "candidate_count": len(exploration_candidates),
                    },
                },
                "p0_route_gate": {
                    "current_question": dict(getattr(self.current_question_path, "last_route_gate_audit", {}) or {}),
                    "exploration": dict(getattr(self.exploration_path, "last_route_gate_audit", {}) or {}),
                },
                "exploration_quality_audit": dict(
                    getattr(self.exploration_path, "last_quality_audit", {}) or {}
                ),
                "answer_evidence_cards": answer_evidence_cards,
                "exploration_candidates": exploration_candidates,
            },
        )
        return {
            "answer_evidence_cards": answer_evidence_cards,
            "exploration_candidates": exploration_candidates,
            "diagnostics": {
                "visual_status": selection_status,
                "visual_error": audit_error,
                "diagnostic_error_types": sorted(set(diagnostic_error_types)),
            },
        }

    def mark_selected_exploration(self, candidates: Sequence[Mapping[str, Any]]) -> None:
        """在触发问题成功执行后，记录已经消费的局部 Join 路径。

        Retrieval direction 不在这里记录：它是否完成只看成功 trace 中实际使用的业务列。
        这样一次代码失败或问题改写不会提前屏蔽同一任务级检索区域。
        """
        executed_tables = set(self._latest_trace_table_names)
        for candidate in list(candidates or []):
            provenance = str((candidate or {}).get("provenance") or "")
            if provenance not in {JOIN_PROBE_PROVENANCE, JOIN_OPPORTUNITY_PROVENANCE}:
                continue

            join_context = dict((candidate or {}).get("join_context") or {})
            path_tables = {
                str(value)
                for value in list(join_context.get("path_tables") or [])
                if str(value)
            }
            if not path_tables:
                path_text = str(join_context.get("path_text") or "")
                path_tables = {
                    value.strip()
                    for value in path_text.split("->")
                    if value.strip()
                }
            if path_tables and not path_tables.issubset(executed_tables):
                # 问题虽引用了 Join 卡，但成功代码没有实际触达完整路径，不能提前退休。
                continue

            signature = str((candidate or {}).get("signature") or "").strip()
            if signature:
                self._seen_join_signatures.add(signature)

    def _join_probe_visual_inputs(
        self,
        *,
        round_index: int,
        probes: Sequence[JoinProbe],
    ) -> tuple[Dict[str, Any], Dict[str, pd.DataFrame], Dict[str, Dict[str, Any]]]:
        """Build a synthetic VEG for computed join probes.

        Probe tables are exploration-only and are never eligible for Answer selection.
        They still use the normal P0 slot binding, scheme validation, scoring and fact
        extraction pipeline.
        """
        tables: Dict[str, Any] = {}
        artifacts: Dict[str, pd.DataFrame] = {}
        metadata: Dict[str, Dict[str, Any]] = {}
        refs: List[Dict[str, str]] = []
        for probe in list(probes or []):
            if not isinstance(probe.dataframe, pd.DataFrame) or probe.dataframe.empty:
                continue
            tid = str(probe.tid)
            artifacts[tid] = normalize_analysis_dataframe(probe.dataframe)
            metadata[tid] = dict(probe.metadata or {})
            tables[tid] = {
                "name": tid,
                "kind": "join_probe",
                "shape": [int(probe.dataframe.shape[0]), int(probe.dataframe.shape[1])],
                "columns": [str(column) for column in probe.dataframe.columns],
                "column_count": int(probe.dataframe.shape[1]),
                "columns_truncated": False,
                "artifact_key": tid,
            }
            refs.append({"path": f"join_probe.{tid}", "tid": tid})
        veg = {
            "round_index": int(round_index),
            "tables": tables,
            "transforms": [],
            "stage_result": {"type": "join_probe", "refs": refs},
            "trace_stats": {},
        }
        return veg, artifacts, metadata

    def _mark_join_probe_plans(
        self,
        plans: Sequence[Dict[str, Any]],
        probes: Sequence[JoinProbe],
    ) -> None:
        by_tid = {str(probe.tid): probe for probe in list(probes or [])}
        for plan in list(plans or []):
            probe = by_tid.get(str(plan.get("source_tid") or ""))
            if probe is None:
                continue
            plan["exploration_only"] = True
            plan["title"] = f"{probe.title} — {str(plan.get('title') or plan.get('pattern') or 'visual')}"
            plan["join_probe"] = {
                "signature": probe.signature,
                "path": list(probe.path.tables),
                "path_text": " -> ".join(probe.path.tables),
                "coverage": round(float(probe.coverage), 6),
                "note": probe.evidence_note,
                "context": dict(probe.context or {}),
            }
            faithfulness = dict(plan.get("faithfulness") or {})
            faithfulness.update({
                "source": "computed_join_probe",
                "derived_from_existing_result": False,
                "exploration_only": True,
            })
            plan["faithfulness"] = faithfulness

    def _trace_source_table_names(self, trace_bundle: Mapping[str, Any]) -> List[str]:
        """返回本轮 trace 真正触达的源表，而不是执行前绑定的全部表。

        CodeExecuter 会在执行前把所有任务表绑定到 trace patcher，因此仅查看
        ``trace_bundle.tables`` 会把整个数据库误判为当前局部轨迹。这里沿事件的
        input/read/output 传播表级来源，只保留至少参与过一个实际操作的源表。
        """
        trace = dict(trace_bundle or {})
        source_by_tid = self._trace_source_table_by_tid(trace)
        origins: Dict[str, set[str]] = {
            tid: {table_name}
            for tid, table_name in source_by_tid.items()
        }
        result: List[str] = []

        for raw_event in list(trace.get("events") or []):
            event = dict(raw_event or {})
            referenced_tids = [
                *[str(value) for value in list(event.get("inputs") or []) if str(value)],
                *[str(value) for value in dict(event.get("read") or {}) if str(value)],
            ]
            event_origins: set[str] = set()
            for tid in referenced_tids:
                event_origins.update(origins.get(tid) or set())

            for table_name in sorted(event_origins):
                if table_name not in result:
                    result.append(table_name)

            output_tid = str(event.get("output") or "")
            if output_tid and event_origins:
                origins[output_tid] = set(event_origins)
        return result

    def _trace_source_table_by_tid(
        self,
        trace_bundle: Mapping[str, Any],
    ) -> Dict[str, str]:
        """把 trace 中的源表 tid 唯一解析为任务里的真实表名。"""
        task_names = [
            str(getattr(table, "name", "") or "")
            for table in self.task.all_tables()
            if str(getattr(table, "name", "") or "")
        ]
        normalized: Dict[str, List[str]] = {}
        for name in task_names:
            normalized.setdefault(normalize_name(name), []).append(name)

        result: Dict[str, str] = {}
        for tid, raw_info in dict((dict(trace_bundle or {}).get("tables") or {})).items():
            name = str((dict(raw_info or {})).get("name") or "")
            if name in task_names:
                resolved = name
            else:
                matches = normalized.get(normalize_name(name), [])
                resolved = matches[0] if len(matches) == 1 else ""
            if resolved:
                result[str(tid)] = resolved
        return result

    def explored_analysis_columns(self) -> List[str]:
        """返回当前任务中已由成功 trace 实际使用过的源表业务列。"""
        return sorted(self._explored_analysis_columns)

    def _update_explored_analysis_columns(self, trace_bundle: Mapping[str, Any]) -> None:
        """从一轮成功 trace 更新全局已探索列。

        Trace 中后续聚合经常读取派生 tid，而不是直接读取源表 tid。因此这里先沿事件
        顺序传播“派生列 -> 源表列”血缘，再把过滤、聚合、派生、排序等分析操作的
        read 展开为真实 ``table.column``。source_read、copy、sink 和纯 Join 只传播
        血缘，不单独把列标记为业务探索。
        """
        task_tables = {
            str(getattr(table, "name", "") or ""): table
            for table in self.task.all_tables()
            if str(getattr(table, "name", "") or "")
        }
        trace = dict(trace_bundle or {})
        table_by_tid = self._trace_source_table_by_tid(trace)
        trace_tables = {
            str(tid): dict(info or {})
            for tid, info in dict(trace.get("tables") or {}).items()
        }

        # tid -> column -> 源表限定列集合。源表节点直接初始化，派生节点在事件循环中补齐。
        lineage: Dict[str, Dict[str, set[str]]] = {}
        for tid, table_name in table_by_tid.items():
            actual_columns = [str(value) for value in task_tables[table_name].dataframe.columns]
            lineage[tid] = {
                column: {f"{table_name}.{column}"}
                for column in actual_columns
            }

        ignored_ops = {"source_read", "copy", "sink_write", "join", "merge", "concat"}
        for raw_event in list(trace.get("events") or []):
            event = dict(raw_event or {})
            op = str(event.get("op") or "")
            expanded_reads = self._expand_trace_reads(event.get("read"), lineage)

            if op not in ignored_ops:
                for source_columns in expanded_reads.values():
                    self._explored_analysis_columns.update(source_columns)

            output_tid = str(event.get("output") or "")
            if not output_tid:
                continue
            output_columns = [
                str(value)
                for value in list((trace_tables.get(output_tid) or {}).get("columns") or [])
                if str(value)
            ]
            input_tids = [str(value) for value in list(event.get("inputs") or []) if str(value)]
            lineage[output_tid] = self._derive_output_lineage(
                output_columns=output_columns,
                input_tids=input_tids,
                write_columns=[str(value) for value in list(event.get("write") or []) if str(value)],
                expanded_reads=expanded_reads,
                lineage=lineage,
            )

    def _expand_trace_reads(
        self,
        raw_read: Any,
        lineage: Mapping[str, Mapping[str, set[str]]],
    ) -> Dict[str, set[str]]:
        """把事件 read 中的派生 tid 列展开为真实源表列。"""
        expanded: Dict[str, set[str]] = {}
        for raw_tid, raw_columns in dict(raw_read or {}).items():
            tid = str(raw_tid)
            column_map = dict(lineage.get(tid) or {})
            for raw_column in list(raw_columns or []):
                column = str(raw_column or "")
                sources = set(column_map.get(column) or set())
                if not sources:
                    # Join 后重名列常带 _x/_y 后缀；优先恢复同一输入节点中的原列。
                    for suffix in ("_x", "_y"):
                        if column.endswith(suffix):
                            sources.update(column_map.get(column[: -len(suffix)]) or set())
                if sources:
                    expanded.setdefault(f"{tid}.{column}", set()).update(sources)
        return expanded

    def _derive_output_lineage(
        self,
        *,
        output_columns: Sequence[str],
        input_tids: Sequence[str],
        write_columns: Sequence[str],
        expanded_reads: Mapping[str, set[str]],
        lineage: Mapping[str, Mapping[str, set[str]]],
    ) -> Dict[str, set[str]]:
        """为一个派生表建立足够支持后续探索状态判断的列血缘。

        同名列和 Join 后缀列优先做精确继承；新写出的聚合/派生列使用本事件实际读取
        的源列。该逻辑不试图成为完整 SQL 血缘引擎，只保证常见 pandas 分析链路中
        已探索列不会因为中间 tid 而丢失。
        """
        input_maps = [dict(lineage.get(tid) or {}) for tid in input_tids]
        all_event_sources: set[str] = set()
        for sources in expanded_reads.values():
            all_event_sources.update(sources)
        writes = set(write_columns)

        output: Dict[str, set[str]] = {}
        for column in output_columns:
            inherited: set[str] = set()
            for input_map in input_maps:
                inherited.update(input_map.get(column) or set())
                for suffix in ("_x", "_y"):
                    if column.endswith(suffix):
                        inherited.update(input_map.get(column[: -len(suffix)]) or set())

            if column in writes and all_event_sources and not inherited:
                inherited.update(all_event_sources)
            elif not inherited and len(output_columns) == 1 and all_event_sources:
                inherited.update(all_event_sources)

            if inherited:
                output[column] = inherited
        return output

    def _join_frontier_candidates(
        self,
        evidence_profile: Optional[Mapping[str, Any]],
        *,
        has_join_visual: bool,
        exclude_signatures: Sequence[str] = (),
    ) -> List[Dict[str, Any]]:
        """Return unexecuted Join routes distinct from used and current probe paths.

        A computed probe on one BIRD path must not suppress every other legal path.  The
        benchmark policy later bounds how many routes reach the manager, so exposing a
        small alternative set here improves recall without increasing final evidence size.
        ``has_join_visual`` remains in the signature for compatibility and audit clarity.
        """
        excluded = set(self._seen_join_signatures)
        excluded.update(str(value) for value in list(exclude_signatures or []) if str(value).strip())
        return self.join_engine.supplemental_candidates(
            evidence_profile=evidence_profile,
            seed_tables=self._latest_trace_table_names,
            exclude_signatures=excluded,
        )

    def _recall_visual_plans(
        self,
        *,
        scored_plans: Sequence[Plan],
        analysis_tendency: Sequence[Mapping[str, Any]],
    ) -> List[Dict[str, Any]]:
        """在正常三层过滤无图时，补选一张接近阈值的图。

        输入：score_visual_plans 产出的完整候选列表。
        输出：被召回并可直接渲染的 plan 列表，默认最多一张。

        Design boundary:
        - never relax structural sanity;
        - QEP tendency remains a ranking preference and is not checked as a gate;
        - relax only L2/L3 within explicit floors;
        - run only when no normally admitted plan exists.
        """
        if not self.recall_enabled:
            return []

        recall_candidates: List[Dict[str, Any]] = []
        for plan in list(scored_plans or []):
            recalled = self._make_recalled_plan(plan)
            if recalled is not None:
                recall_candidates.append(recalled)

        if not recall_candidates:
            return []

        selected = select_visual_plan_set(
            recall_candidates,
            max_charts=self.recall_max_charts,
            analysis_tendency=analysis_tendency,
        )
        for plan in selected:
            selection = dict(plan.get("selection") or {})
            selection["strategy"] = "recall"
            plan["selection"] = selection
        return selected

    def _make_recalled_plan(self, plan: Plan) -> Optional[Dict[str, Any]]:
        """把一个 L2/L3 接近阈值的 rejected plan 转成召回 plan。

        返回 None 表示该候选不适合召回。返回 dict 时，会把 L2/L3 gate 的阈值改为
        召回阈值，并把 admission 标记为可渲染。这样后续 selector 和 renderer 可以复用
        原有 admitted-plan 链路，不需要新增并行流程。
        """
        plan_dict = dict(plan or {})
        admission = dict(plan_dict.get("admission") or {})
        if admission.get("admitted"):
            return None

        gates = dict(plan_dict.get("gates") or {})
        sanity_gate = dict(gates.get("sanity") or {})
        if not sanity_gate.get("passed"):
            return None

        evidence_gate = self._relax_gate_for_recall(
            gates.get("evidence"),
            relaxation=self.recall_evidence_relaxation,
            floor=self.recall_min_evidence_support,
        )
        if evidence_gate is None:
            return None

        representation_gate = self._relax_gate_for_recall(
            gates.get("representation"),
            relaxation=self.recall_representation_relaxation,
            floor=self.recall_min_representation_threshold,
        )
        if representation_gate is None:
            return None

        gates["evidence"] = evidence_gate
        gates["representation"] = representation_gate
        plan_dict["gates"] = gates
        plan_dict["admission"] = {
            "decision": "emit_chart",
            "admitted": True,
            "reason": "selected by recall after no normal visual plan was admitted; only L2/L3 thresholds were relaxed",
            "sanity_passed": True,
            "evidence_margin": _float_or_zero(evidence_gate.get("margin")),
            "representation_margin": _float_or_zero(representation_gate.get("margin")),
        }
        ranking = dict(plan_dict.get("ranking") or {})
        reasons = list(ranking.get("reasons") or [])
        reasons.append("selected by recall because the normal hard evidence/representation gates admitted no chart")
        ranking["reasons"] = reasons
        plan_dict["ranking"] = ranking
        return plan_dict

    def _relax_gate_for_recall(
        self,
        gate: Any,
        *,
        relaxation: float,
        floor: float,
    ) -> Optional[Dict[str, Any]]:
        """对单个 L2/L3 gate 应用召回阈值。

        如果 score 达不到放松后的阈值，返回 None；否则返回更新后的 gate。
        该函数只保存新的阈值、margin 和一条召回原因，不保留旧阈值，避免审计字段膨胀。
        """
        gate_dict = dict(gate or {})
        score = _float_or_zero(gate_dict.get("score"))
        old_threshold = _float_or_zero(gate_dict.get("threshold"))
        relaxed_threshold = max(_float_or_zero(floor), old_threshold - _float_or_zero(relaxation))
        if score < relaxed_threshold:
            return None

        reasons = list(gate_dict.get("reasons") or [])
        if "passed_by_recall_relaxed_threshold" not in reasons:
            reasons.append("passed_by_recall_relaxed_threshold")
        gate_dict["threshold"] = float(relaxed_threshold)
        gate_dict["margin"] = float(score - relaxed_threshold)
        gate_dict["passed"] = True
        gate_dict["reasons"] = reasons
        return gate_dict

    def _render_selected_plans(
        self,
        round_index: int,
        selected_plans: Sequence[Plan],
        artifact_store: Mapping[str, Any],
    ) -> List[Dict[str, Any]]:
        """Dry-run selected visual plans without writing PNG files.

        The answer layer consumes text cards built from the plan support table,
        not the rendered image path. This function therefore preserves the
        success/filtering contract used downstream, while leaving chart_path
        empty so no image artifact is saved.
        """
        records: List[Dict[str, Any]] = []

        for index, plan in enumerate(selected_plans, start=1):
            source_tid = str(plan.get("source_tid") or "")
            source_df = artifact_store.get(source_tid)

            try:
                if not isinstance(source_df, pd.DataFrame):
                    raise ValueError("source dataframe not available")

                support_df = apply_transform_ops(
                    source_df,
                    list((plan.get("transform") or {}).get("ops") or []),
                )
                if not isinstance(support_df, pd.DataFrame) or support_df.empty:
                    raise ValueError("support dataframe is empty after transforms")

                render_result = {
                    "success": True,
                    "chart_path": "",
                    "support_shape": [int(support_df.shape[0]), int(support_df.shape[1])],
                    "error": "",
                }
            except Exception as exc:
                render_result = {
                    "success": False,
                    "chart_path": "",
                    "support_shape": [0, 0],
                    "error": str(exc),
                }

            records.append(
                {
                    "plan": plan,
                    "render": self._compact_render_result(render_result),
                }
            )

        return records

    def _materializer(self, artifact_store: Mapping[str, Any]) -> Callable[[Plan], Any]:
        """创建辅助观察抽取所需的数据加载函数。

        visual_fact_extractor 模块需要根据 plan 找到原始数据，并应用 plan 中的 transform。
        本函数把这部分逻辑包装成闭包，避免在主链路中展开细节。
        """

        def materialize(plan: Plan) -> Optional[pd.DataFrame]:
            """根据单个 plan 返回其用于绘图和辅助观察提取的 support DataFrame。"""
            source_tid = str(plan.get("source_tid") or "")
            source_df = artifact_store.get(source_tid)
            if not isinstance(source_df, pd.DataFrame):
                return None
            try:
                return apply_transform_ops(
                    source_df,
                    list((plan.get("transform") or {}).get("ops") or []),
                )
            except Exception:
                # One malformed candidate must not remove cards from other valid plans.
                return None

        return materialize

    # ------------------------------------------------------------------
    # 精简审计记录
    # ------------------------------------------------------------------

    def _plan_score_record(
        self,
        plan: Optional[Plan],
        *,
        render_result: Optional[Mapping[str, Any]] = None,
    ) -> Optional[Dict[str, Any]]:
        """生成单个图表 plan 的最小审计记录。

        保留原则：
        - 能解释“为什么这张图被选中”；
        - 能解释“这张图是否渲染成功”；
        - 不复制真实数据、不复制 support preview、不复制大型 details。
        """
        if not plan:
            return None

        gates = dict(plan.get("gates") or {})
        answer_utility = dict(plan.get("answer_utility") or {})
        exploration_utility = dict(plan.get("exploration_utility") or {})
        admission = dict(plan.get("admission") or {})
        encoding = dict(plan.get("encoding") or {})
        preferences = dict(plan.get("preferences") or {})
        qep_preference = dict(preferences.get("qep") or {})

        return {
            "plan_id": plan.get("plan_id"),
            "pattern": plan.get("pattern"),
            "source_tid": plan.get("source_tid"),
            "chart_type": encoding.get("chart_type"),
            "title": plan.get("title"),
            "evidence_role": plan.get("evidence_role"),
            "provenance": plan.get("provenance"),
            "answer_utility": {
                "score": answer_utility.get("score"),
                "breakdown": answer_utility.get("breakdown"),
            },
            "exploration_utility": {
                "score": exploration_utility.get("score"),
                "breakdown": exploration_utility.get("breakdown"),
            },
            "preferences": {
                "qep": {
                    "score": qep_preference.get("score"),
                    "mode": qep_preference.get("mode"),
                    "reasons": qep_preference.get("reasons") or [],
                }
            },
            "gates": {
                "sanity": self._compact_gate(gates.get("sanity"), include_support_shape=True),
                "evidence": self._compact_gate(gates.get("evidence")),
                "frontier_evidence": self._compact_gate(gates.get("frontier_evidence")),
                "representation": self._compact_gate(gates.get("representation")),
            },
            "admission": {
                "admitted": admission.get("admitted"),
                "decision": admission.get("decision"),
                "reason": admission.get("reason"),
                "evidence_margin": admission.get("evidence_margin"),
                "representation_margin": admission.get("representation_margin"),
            },
            "selection": dict(plan.get("selection") or {}),
            "join_probe": dict(plan.get("join_probe") or {}),
            "render": dict(render_result or {}),
        }

    def _compact_gate(self, gate: Any, *, include_support_shape: bool = False) -> Dict[str, Any]:
        """压缩单个 gate 的记录。

        只保留：
        - 是否通过；
        - 分数；
        - 阈值；
        - margin；
        - 失败或解释原因。

        ``support_shape`` 只在 sanity gate 中保留，用于判断数据是否为空或形状异常。
        """
        gate = dict(gate or {})
        out = {
            "passed": gate.get("passed"),
            "score": gate.get("score"),
            "threshold": gate.get("threshold"),
            "margin": gate.get("margin"),
            "reasons": gate.get("reasons") or [],
        }
        if include_support_shape and gate.get("support_shape") is not None:
            out["support_shape"] = gate.get("support_shape")
        return {key: value for key, value in out.items() if _has_compact_value(value)}

    def _compact_render_result(self, render_result: Mapping[str, Any]) -> Dict[str, Any]:
        """压缩 renderer 返回值。

        renderer 可能返回 support preview 等较重字段，这些不进入审计文件。
        这里仅保留渲染是否成功、图路径、support 形状和错误信息。
        """
        render_result = dict(render_result or {})
        return {
            "success": bool(render_result.get("success")),
            "chart_path": str(render_result.get("chart_path") or ""),
            "support_shape": render_result.get("support_shape") or [0, 0],
            "error": str(render_result.get("error") or ""),
        }

    # ------------------------------------------------------------------
    # 小型工具函数
    # ------------------------------------------------------------------

    def _join_render_errors(self, render_records: Sequence[Mapping[str, Any]]) -> str:
        """合并多张图的渲染错误，形成一行审计信息。"""
        errors: List[str] = []
        for record in render_records:
            render_result = dict(record.get("render") or {})
            error = str(render_result.get("error") or "").strip()
            if error:
                plan = dict(record.get("plan") or {})
                errors.append(f"{plan.get('plan_id')}: {error}")
        return "; ".join(errors)

    def _chart_filename(self, round_index: int, index: int, plan: Plan) -> str:
        """为图表生成稳定、可读且安全的文件名。"""
        plan_id = str(plan.get("plan_id") or f"chart_{index}")
        return sanitize_filename(f"round_{round_index}_{index}_{plan_id}") + ".png"

    def _empty_visual_return(self) -> VisualReturn:
        """生成 EvidenceOrganizer 的空返回结构。"""
        return {
            "answer_evidence_cards": "",
            "exploration_candidates": [],
            "diagnostics": {
                "visual_status": "not_run",
                "visual_error": "",
                "diagnostic_error_types": [],
            },
        }

    def _schema_frontier_cards(
        self,
        evidence_profile: Optional[Mapping[str, Any]],
    ) -> str:
        """生成不依赖视觉渲染的 Schema frontier 卡片。"""
        schema_candidate_budget = max(
            self.max_frontiers,
            min(self.max_frontiers * 2, self.max_frontiers + 3),
        )
        return build_frontier_cards(
            task=self.task,
            evidence_profile=evidence_profile,
            # Generate a small reserve before global cross-branch selection.  Truncating
            # schema cues to the local visual budget made later layers see only the same
            # first text/time/location directions, while entity and metric angles never
            # entered the global pool.
            max_cards=schema_candidate_budget,
        )

    def _task_anchor_text(self, evidence_profile: Optional[Mapping[str, Any]]) -> str:
        """构造 frontier 支撑和语义对齐使用的任务锚点文本。"""
        metadata = dict(getattr(self.task, "metadata", {}) or {})
        profile = dict(evidence_profile or {})
        focus = profile.get("evidence_focus")
        if isinstance(focus, str):
            focus = [focus]
        parts = [
            metadata.get("goal"),
            metadata.get("role"),
            metadata.get("category"),
            metadata.get("dataset_description"),
            profile.get("round_question"),
            *list(focus or []),
        ]
        return " ".join(str(part or "") for part in parts if str(part or "").strip())

    def _execution_error_card(self, *, evidence_profile: Optional[Mapping[str, Any]], error: str) -> str:
        """生成代码失败后的恢复型探索候选文本。"""
        profile = dict(evidence_profile or {})
        question = self._round_question(evidence_profile)
        focus = profile.get("evidence_focus")
        if isinstance(focus, str):
            focus = [focus]
        focus_text = "; ".join(str(item) for item in list(focus or [])[:3]) or "the evidence required by the selected question"
        error_text = truncate_text(str(error or "unknown execution error"), 420)
        return (
            "[Execution recovery follow-up]\n"
            f"Current question: {question}\n"
            f"Evidence focus: {focus_text}\n"
            "Suggested follow-up: verify the real schema fields and simplify the computation while preserving the same analytical target. "
            "If the required evidence is absent, state that directly rather than inventing proxy variables. "
            f"Error excerpt: {error_text}"
        )

    def _join_card_blocks(self, *blocks: str) -> str:
        """合并多类 frontier 卡片，去掉空块，避免主流程传递重复字段。"""
        return "\n\n".join(str(block or "").strip() for block in blocks if str(block or "").strip())

    def _write_veg(self, round_index: int, veg: Mapping[str, Any]) -> None:
        """写入 VEG 审计文件。

        审计写入失败不应影响主流程，因此这里吞掉异常。
        """
        try:
            self.artifact_writer.write_veg(round_index, veg)
        except Exception:
            pass

    def _write_visual_audit(self, round_index: int, payload: Mapping[str, Any]) -> None:
        """写入图选择与渲染的最小审计文件。

        该文件对应 ``round_{i}_selected_visual_plan_scores.json``。
        内容应保持简短，只用于人工复核关键选择结果。
        """
        try:
            audit_payload = dict(payload or {})
            if self._latest_trace_stats:
                audit_payload["trace_stats"] = dict(self._latest_trace_stats)
            self.artifact_writer.write_selected_plan_scores(round_index, audit_payload)
        except Exception:
            pass

def _float_or_zero(value: Any) -> float:
    """Convert scalar-like values to float without pandas truth-value errors."""
    try:
        if value is None or pd.isna(value):
            return 0.0
    except Exception:
        pass
    try:
        return float(value)
    except Exception:
        return 0.0


def _has_compact_value(value: Any) -> bool:
    """Whether an audit value should be kept, without comparing pandas objects."""
    if value is None:
        return False
    if isinstance(value, (list, tuple, set, dict)):
        return bool(value)
    if isinstance(value, (pd.DataFrame, pd.Series)):
        return not value.empty
    try:
        missing = pd.isna(value)
        if isinstance(missing, bool):
            return not missing
    except Exception:
        pass
    return True

