"""把静态检索表列转换为任务级 frontier 候选。

候选构建优先尚未在成功执行 trace 中使用过的业务列；“未探索”只决定候选来源，
不进入效用公式。连接路径由 JoinOpportunityEngine 根据真实 PK/FK 关系解析，检索模型
不负责设计 join。输出仍是现有全局选择器可消费的 ``new_direction`` 候选。
"""

from __future__ import annotations

import hashlib
import re
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

import pandas as pd
from pandas.api.types import (
    is_bool_dtype,
    is_datetime64_any_dtype,
    is_float_dtype,
    is_integer_dtype,
    is_numeric_dtype,
)

from evidence_layer.evidence_contracts import EXPLORATION_ROLE, GOAL_RETRIEVAL_PROVENANCE
from evidence_layer.join_opportunities import JoinOpportunityEngine
from evidence_layer.visual_semantics import (
    build_table_column_semantics,
    infer_column_semantics,
    normalize_name,
)
from vis_project_utils.utils import clip01

_MEASURE_KINDS = {
    "additive_measure",
    "numeric_measure",
    "nonadditive_statistic",
    "count",
}
_DIMENSION_KINDS = {"dimension", "completeness"}


class RetrievalFrontierBuilder:
    """从检索空间构造少量、具体且可执行的未执行分析方向。"""

    def __init__(
        self,
        *,
        task: Any,
        retrieval_space: Mapping[str, Any],
        config: Optional[Mapping[str, Any]] = None,
        join_engine: Optional[JoinOpportunityEngine] = None,
    ) -> None:
        self.task = task
        self.retrieval_space = dict(retrieval_space or {})
        retrieval_config = dict((dict(config or {}).get("retrieval") or {}))
        self.max_candidates = max(
            0,
            int(retrieval_config.get("max_frontier_candidates", 6) or 0),
        )
        self.join_engine = join_engine or JoinOpportunityEngine(task, config)
        self.column_catalog = self._build_column_catalog()
        self.retrieved_columns = self._retrieved_column_order()
        self._connection_cache: Dict[Tuple[str, ...], Optional[Dict[str, Any]]] = {}

    def build(
        self,
        *,
        explored_columns: Sequence[str],
        current_candidates: Sequence[Mapping[str, Any]] = (),
    ) -> List[Dict[str, Any]]:
        """生成本批次的检索驱动候选。

        输入：全局实际执行过的 ``table.column`` 和当前批次已有候选。
        输出：最多 ``max_frontier_candidates`` 个任务级 new_direction 候选。
        每个候选至少包含一个尚未执行过的非标识符业务列。
        """
        if self.max_candidates <= 0 or not self.retrieved_columns:
            return []

        explored = {
            str(value or "").strip().casefold()
            for value in explored_columns
            if str(value or "").strip()
        }
        targets = [
            name
            for name in self.retrieved_columns
            if name.casefold() not in explored
            and not bool((self.column_catalog.get(name) or {}).get("identifier"))
        ]
        if not targets:
            return []

        blocked_signatures = {
            str(item.get("exploration_signature") or "").strip()
            for item in current_candidates
            if str(item.get("exploration_signature") or "").strip()
        }
        candidates: List[Dict[str, Any]] = []
        seen_signatures: Set[str] = set(blocked_signatures)

        # 先为全部未探索目标构造候选，再按候选自身效用排序。不能把 LLM 返回顺序
        # 隐式当成相关性排名，否则高召回输出中靠前的字段会垄断 frontier 预算。
        for target in targets:
            candidate = self._build_for_target(target)
            if not candidate:
                continue
            signature = str(candidate.get("exploration_signature") or "")
            if not signature or signature in seen_signatures:
                continue
            seen_signatures.add(signature)
            candidates.append(candidate)

        candidates.sort(
            key=lambda item: (
                -float(item.get("utility") or 0.0),
                str(item.get("exploration_signature") or ""),
            )
        )
        return candidates[: self.max_candidates]

    def _build_for_target(self, target_name: str) -> Optional[Dict[str, Any]]:
        """为一个未探索目标列选择确定性模板和必要连接上下文。"""
        target = self.column_catalog.get(target_name)
        if not target:
            return None

        companion = self._best_companion(target_name)
        if companion:
            connection = self._connection_for_tables([target["table"], companion["table"]])
            if target["table"] == companion["table"] or connection is not None:
                candidate = self._paired_candidate(target, companion, connection or {})
                if candidate:
                    return candidate

        return self._single_column_candidate(target)

    def _best_companion(self, target_name: str) -> Optional[Dict[str, Any]]:
        """按稳定性优先级寻找能形成完整分析模板的另一个业务列。"""
        target = self.column_catalog[target_name]
        target_kind = str(target.get("analysis_kind") or "unknown")

        if target_kind == "measure":
            accepted_kinds = _DIMENSION_KINDS | {"temporal"}
        elif target_kind == "temporal":
            accepted_kinds = {"measure"}
        elif target_kind in _DIMENSION_KINDS:
            accepted_kinds = {"measure"}
        else:
            return None

        same_table: List[Dict[str, Any]] = []
        cross_table: List[Dict[str, Any]] = []
        for name in self.retrieved_columns:
            if name == target_name:
                continue
            item = self.column_catalog.get(name)
            if (
                not item
                or item.get("identifier")
                or item.get("analysis_kind") not in accepted_kinds
            ):
                continue
            if item["table"] == target["table"]:
                same_table.append(item)
            else:
                cross_table.append(item)

        # 同表组合最稳定；同表不存在时才通过 Join Engine 扩展到跨表组合。
        if same_table:
            return same_table[0]
        for item in cross_table:
            connection = self._connection_for_tables([target["table"], item["table"]])
            if connection is None:
                continue
            # 跨表时间趋势只有在度量表本身就是安全粒度时才足够明确。否则需要先把
            # 两侧归并到中间实体，会把“时间趋势”变成含义不清的实体级摘要。
            kinds = {target_kind, str(item.get("analysis_kind") or "unknown")}
            if "temporal" in kinds:
                measure = target if target_kind == "measure" else item
                if str(connection.get("grain_table") or "") != str(measure.get("table") or ""):
                    continue
            return item
        return None

    def _paired_candidate(
        self,
        left: Mapping[str, Any],
        right: Mapping[str, Any],
        join_context: Mapping[str, Any],
    ) -> Optional[Dict[str, Any]]:
        """构造 measure×dimension、time trend 或 completeness×outcome 候选。"""
        connection = dict(join_context or {})
        join_signature = str(connection.pop("signature", "") or "")
        left_kind = str(left.get("analysis_kind") or "unknown")
        right_kind = str(right.get("analysis_kind") or "unknown")

        if left_kind == "measure":
            measure, other = left, right
        elif right_kind == "measure":
            measure, other = right, left
        else:
            return None

        measure_name = str(measure["qualified_name"])
        other_name = str(other["qualified_name"])
        other_kind = str(other.get("analysis_kind") or "unknown")
        connection = self._prepare_join_context(
            measure=measure,
            other=other,
            other_kind=other_kind,
            join_context=connection,
        )
        grain = str(connection.get("grain_table") or measure.get("table") or "")

        if other_kind == "temporal":
            template = "time_trend"
            title = f"Examine {measure_name} over {other_name}"
            direction = f"Analyze the time pattern of {measure_name} using {other_name}."
            concrete = (
                f"At {grain} grain, aggregate {measure_name} by an appropriate period derived from "
                f"{other_name}, report the level and change over time, and check whether the pattern is "
                "stable or concentrated in a small number of periods."
            )
            template_score = 0.78
        elif other_kind == "completeness":
            template = "completeness_by_outcome"
            title = f"Compare {measure_name} by completeness of {other_name}"
            direction = (
                f"Test whether presence or completeness of {other_name} is associated with differences "
                f"in {measure_name}."
            )
            concrete = (
                f"At {grain} grain, convert {other_name} into present/missing (and only a small number of "
                f"stable completeness groups when supported), then compare {measure_name} across the groups "
                "and report important exceptions."
            )
            template_score = 0.84
        else:
            template = "measure_by_dimension"
            title = f"Compare {measure_name} across {other_name}"
            direction = f"Compare {measure_name} across groups defined by {other_name}."
            concrete = (
                f"At {grain} grain, aggregate {measure_name} by {other_name}, report group size together "
                "with the measure, and identify both the main contrast and important exceptions."
            )
            template_score = 0.80

        concrete = self._prepend_join_instruction(
            concrete,
            connection,
            measure=measure,
            other=other,
            other_kind=other_kind,
        )
        columns = [measure_name, other_name]
        signature = self._signature(template, columns, grain)
        return {
            "id": f"retrieval_{self._short_id(signature)}",
            "kind": "retrieval",
            "candidate_group": "new_direction",
            "title": title,
            "available_direction": direction,
            "why_it_may_matter": (
                "These columns were independently retrieved from the original task goal, and at least one "
                "has not yet appeared in a successful analysis trace."
            ),
            "concrete_analysis": concrete,
            "columns": columns,
            "utility": self._utility(template_score, connection, paired=True),
            "evidence_role": EXPLORATION_ROLE,
            "provenance": GOAL_RETRIEVAL_PROVENANCE,
            "exploration_signature": signature,
            **({"join_context": connection} if connection else {}),
            **({"signature": join_signature} if join_signature else {}),
        }

    def _single_column_candidate(self, column: Mapping[str, Any]) -> Dict[str, Any]:
        """在找不到安全组合时，为单个未探索列生成保守分析方向。"""
        name = str(column["qualified_name"])
        kind = str(column.get("analysis_kind") or "unknown")
        table = str(column.get("table") or "")

        if kind == "temporal":
            template = "record_count_over_time"
            title = f"Examine record volume over {name}"
            direction = f"Check how record volume changes over {name}."
            concrete = (
                f"Within {table}, group records by an appropriate period derived from {name}, report counts "
                "and missing dates, and identify sustained changes rather than isolated spikes."
            )
            template_score = 0.66
        elif kind == "completeness":
            template = "text_completeness"
            title = f"Examine completeness of {name}"
            direction = f"Measure missingness and usable content coverage for {name}."
            concrete = (
                f"Within {table}, report present, missing, and blank values for {name}; use text-length bands "
                "only when they form stable and interpretable groups."
            )
            template_score = 0.64
        elif kind == "dimension":
            template = "category_distribution"
            title = f"Examine the distribution of {name}"
            direction = f"Compare the prevalence of categories in {name}."
            concrete = (
                f"Within {table}, report category counts and shares for {name}, include missing values, and "
                "avoid drawing conclusions from tiny categories."
            )
            template_score = 0.62
        elif kind == "free_text":
            template = "text_coverage"
            title = f"Examine usable coverage of {name}"
            direction = f"Check whether {name} contains analysable repeated structure or only free-form text."
            concrete = (
                f"Within {table}, report missing and blank coverage for {name}; only extract repeated categories "
                "or length bands when they are stable enough to support a reproducible comparison."
            )
            template_score = 0.48
        else:
            template = "measure_distribution"
            title = f"Examine the distribution of {name}"
            direction = f"Inspect the range, concentration, and unusual values of {name}."
            concrete = (
                f"Within {table}, report valid count, missingness, robust summary statistics, and the most "
                "important concentration or outlier pattern for {name}."
            )
            template_score = 0.60

        signature = self._signature(template, [name], table)
        return {
            "id": f"retrieval_{self._short_id(signature)}",
            "kind": "retrieval",
            "candidate_group": "new_direction",
            "title": title,
            "available_direction": direction,
            "why_it_may_matter": (
                "This task-relevant column was retrieved before analysis but has not appeared in a successful "
                "analysis trace."
            ),
            "concrete_analysis": concrete,
            "columns": [name],
            "utility": self._utility(template_score, {}, paired=False),
            "evidence_role": EXPLORATION_ROLE,
            "provenance": GOAL_RETRIEVAL_PROVENANCE,
            "exploration_signature": signature,
        }

    def _connection_for_tables(self, tables: Sequence[str]) -> Optional[Dict[str, Any]]:
        """缓存 Join Engine 的确定性连接解析结果。"""
        unique = tuple(dict.fromkeys(str(value or "") for value in tables if str(value or "")))
        if len(unique) <= 1:
            return {}
        key = tuple(sorted(unique))
        if key not in self._connection_cache:
            self._connection_cache[key] = self.join_engine.resolve_connection(unique)
        value = self._connection_cache[key]
        return dict(value) if value is not None else None

    def _prepare_join_context(
        self,
        *,
        measure: Mapping[str, Any],
        other: Mapping[str, Any],
        other_kind: str,
        join_context: Mapping[str, Any],
    ) -> Dict[str, Any]:
        """根据度量所在表确定最终分析粒度，避免 Join 后重复累计父表度量。"""
        context = dict(join_context or {})
        if not context:
            return context

        measure_table = str(measure.get("table") or "")
        current_grain = str(context.get("grain_table") or "")
        safe_use = str(context.get("safe_use") or "").strip()

        if measure_table and current_grain and measure_table != current_grain:
            shared_parent = "shared parent key first" in safe_use.lower()
            if shared_parent:
                # 两个明细表通过共同父表连接时，统一先聚合到父实体粒度。
                context["grain_table"] = current_grain
            else:
                # 父表度量与子表属性组合时，不能在子表行上重复父表度量。
                context["grain_table"] = measure_table
                safe_use = (
                    f"Preserve {measure_table} as the final grain and reduce the related detail side to one "
                    "summary per measure entity before comparison. "
                    + safe_use
                ).strip()

        context["safe_use"] = safe_use
        return context

    def _prepend_join_instruction(
        self,
        concrete: str,
        join_context: Mapping[str, Any],
        *,
        measure: Mapping[str, Any],
        other: Mapping[str, Any],
        other_kind: str,
    ) -> str:
        """把连接和预聚合约束写入具体分析说明，不生成独立 Join 层级。"""
        if not join_context:
            return concrete

        path_text = str(join_context.get("path_text") or "")
        grain = str(join_context.get("grain_table") or "")
        measure_table = str(measure.get("table") or "")
        other_table = str(other.get("table") or "")
        safe_use = str(join_context.get("safe_use") or "")

        if measure_table != grain:
            measure_step = f"First aggregate {measure.get('qualified_name')} from {measure_table} to {grain}."
        else:
            measure_step = f"Keep {measure_table} at {grain} grain without duplicating measure rows."

        if other_kind == "completeness":
            other_step = (
                f"Reduce {other_table} to one {grain}-level presence/completeness summary before combining it."
            )
        elif other_kind == "dimension" and other_table != grain:
            other_step = (
                f"Reduce {other_table} to {grain}-level category counts or shares rather than raw-joining "
                "multiple detail rows."
            )
        else:
            other_step = f"Attach {other_table} through the declared keys while preserving {grain} grain."

        return (
            f"Use the declared path {path_text} and report matched coverage. {measure_step} {other_step} "
            f"{safe_use} {concrete}"
        ).strip()

    def _utility(
        self,
        template_score: float,
        join_context: Mapping[str, Any],
        *,
        paired: bool,
    ) -> float:
        """评估模板完整性、连接可执行性和方向具体度，不奖励“新列”。

        Retrieval card 尚未执行，因此其效用刻意低于强计算证据，避免一个可执行方向
        仅凭“任务相关”就压过已经观察到的可靠模式。
        """
        if not join_context:
            feasibility = 1.0
        elif int(join_context.get("hop_count") or 0) <= 1:
            feasibility = 0.90
        else:
            feasibility = 0.76
        specificity = 1.0 if paired else 0.68
        return round(
            clip01(
                0.24
                + 0.24 * float(template_score)
                + 0.12 * feasibility
                + 0.06 * specificity
            ),
            6,
        )

    def _build_column_catalog(self) -> Dict[str, Dict[str, Any]]:
        """为检索到的真实列建立轻量语义索引。

        只分析检索结果实际包含的列，避免对全库所有字段做无意义的数据画像。
        元数据语义优先；缺失时用 pandas dtype 做保守兜底。
        """
        requested: Dict[str, Set[str]] = {}
        for item in list(self.retrieval_space.get("tables") or []):
            table_name = str((item or {}).get("table") or "")
            if not table_name:
                continue
            requested.setdefault(table_name, set()).update(
                str(column)
                for column in list((item or {}).get("columns") or [])
                if str(column)
            )

        catalog: Dict[str, Dict[str, Any]] = {}
        for table in list(getattr(self.task, "all_tables", lambda: [])() or []):
            table_name = str(getattr(table, "name", "") or "")
            requested_columns = requested.get(table_name, set())
            if not table_name or not requested_columns:
                continue

            dataframe = getattr(table, "dataframe", None)
            if not isinstance(dataframe, pd.DataFrame):
                continue
            metadata = dict(getattr(table, "metadata", {}) or {})
            semantics = build_table_column_semantics(metadata)
            semantic_by_normalized: Dict[str, List[Tuple[str, Dict[str, Any]]]] = {}
            for name, semantic in semantics.items():
                semantic_by_normalized.setdefault(normalize_name(name), []).append(
                    (str(name), dict(semantic or {}))
                )

            for column_name in [str(value) for value in dataframe.columns]:
                if column_name not in requested_columns:
                    continue
                semantic = dict(semantics.get(column_name) or {})
                if not semantic:
                    matches = semantic_by_normalized.get(normalize_name(column_name), [])
                    if len(matches) == 1:
                        semantic = dict(matches[0][1])
                if not semantic:
                    semantic = infer_column_semantics(
                        column_name,
                        data_format=self._dtype_format(dataframe[column_name]),
                    )

                qualified = f"{table_name}.{column_name}"
                catalog[qualified] = {
                    "table": table_name,
                    "column": column_name,
                    "qualified_name": qualified,
                    "identifier": bool(semantic.get("identifier")),
                    "analysis_kind": self._analysis_kind(
                        dataframe[column_name],
                        column_name=column_name,
                        semantic_kind=str(semantic.get("kind") or "unknown"),
                    ),
                }
        return catalog

    def _analysis_kind(
        self,
        series: pd.Series,
        *,
        column_name: str,
        semantic_kind: str,
    ) -> str:
        """把底层列语义压缩成模板构建真正需要的几类。

        低基数类别即使存在少量缺失，也仍应作为分组维度；只有高基数文本或名称明显
        表示资料/描述内容时，缺失才优先解释为 completeness。否则 region/status 一类
        字段会被错误转换成“是否缺失”的二元比较。
        """
        if semantic_kind == "identifier":
            return "identifier"
        if semantic_kind == "temporal" or is_datetime64_any_dtype(series.dtype):
            return "temporal"
        if semantic_kind in _MEASURE_KINDS or is_numeric_dtype(series.dtype):
            return "measure"
        if semantic_kind in {"boolean", "category_code"} or is_bool_dtype(series.dtype):
            return "dimension"
        if semantic_kind != "text" and series.dtype != object:
            return "unknown"

        sample = series.head(20_000)
        missing = float(sample.isna().mean()) if len(sample) else 0.0
        non_null = sample.dropna()
        blank = 0.0
        if len(non_null):
            try:
                blank = float(non_null.astype("string").str.strip().eq("").mean())
            except Exception:
                blank = 0.0
        missing_or_blank = min(1.0, missing + (1.0 - missing) * blank)

        try:
            distinct = int(non_null.nunique(dropna=True))
        except Exception:
            distinct = len(non_null)
        category_limit = min(40, max(8, int(max(1, len(non_null)) * 0.20)))
        low_cardinality = distinct <= category_limit
        normalized_name = normalize_name(column_name)
        content_hints = {
            "about",
            "abstract",
            "bio",
            "comment",
            "content",
            "description",
            "detail",
            "info",
            "note",
            "profile",
            "summary",
            "text",
        }
        name_suggests_content = any(hint in normalized_name for hint in content_hints)

        if low_cardinality and not name_suggests_content:
            return "dimension"
        if missing_or_blank >= 0.01:
            return "completeness"
        return "free_text"

    def _dtype_format(self, series: pd.Series) -> str:
        """把 pandas dtype 转为现有语义推断器使用的最小格式。"""
        if is_datetime64_any_dtype(series.dtype):
            return "datetime"
        if is_bool_dtype(series.dtype):
            return "boolean"
        if is_integer_dtype(series.dtype):
            return "integer"
        if is_float_dtype(series.dtype):
            return "real"
        return "text"

    def _retrieved_column_order(self) -> List[str]:
        """按两次检索确定性并集后的顺序展开真实列。"""
        result: List[str] = []
        for item in list(self.retrieval_space.get("tables") or []):
            table = str((item or {}).get("table") or "")
            for column in list((item or {}).get("columns") or []):
                qualified = f"{table}.{column}"
                if qualified in self.column_catalog and qualified not in result:
                    result.append(qualified)
        return result

    def _signature(self, template: str, columns: Sequence[str], grain: str) -> str:
        """构造与候选表达无关的稳定分析签名。"""
        normalized_columns = "|".join(sorted(str(value).casefold() for value in columns))
        normalized_grain = re.sub(r"[^a-z0-9]+", "_", str(grain or "").lower()).strip("_")
        return f"new_direction|retrieval|{template}|{normalized_grain}|{normalized_columns}"

    def _short_id(self, value: str) -> str:
        """把稳定签名压缩成便于中央管理器引用的短 ID。"""
        return hashlib.sha1(value.encode("utf-8")).hexdigest()[:12]
