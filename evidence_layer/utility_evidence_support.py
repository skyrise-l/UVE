"""utility_evidence_support.py
-----------------------------
L2：Evidence Support。

这一层只回答一个问题：候选图计划是否被当前运行时证据支持。
它不负责判断“图是不是比表格/文本更值得表达”，后者属于 L3。

评分来源
========
1. 槽位绑定可靠性：generator / binder 给出的字段绑定分数；
2. 与 stage_result 的距离：候选表是否接近当前轮真正返回的结果；
3. 上游 trace 操作：候选计划是否能被 VEG 中的操作类型解释；
4. 数据模式信号：support table 中是否真的存在该 pattern 的基本数据迹象。
"""

from __future__ import annotations

from collections import deque
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Set, Tuple

import pandas as pd

from chart.transforms import apply_transform_ops
from evidence_layer.pattern_signal import compute_pattern_signal
from vis_project_utils.utils import clip01


_TEMPLATE_OPERATION_HINTS = {
    "count_by_group": {
        "ops": {"value_counts", "groupby_count", "size", "count"},
        "families": {"aggregate"},
        "weight": 0.95,
    },
    "comparison_bar": {
        "ops": {"groupby_agg", "pivot_table", "value_counts"},
        "families": {"aggregate", "reshape"},
        "weight": 0.85,
    },
    "trend_line": {
        "ops": {"resample", "rolling", "time_floor", "groupby_agg", "sort_by"},
        "families": {"aggregate", "derive", "sort_rank"},
        "weight": 0.80,
    },
    "relation_scatter": {
        "ops": {"corr", "merge", "join", "select", "select_series"},
        "families": {"join", "select", "derive"},
        "weight": 0.70,
    },
    "distribution_box": {
        "ops": {"groupby_agg", "filter", "select"},
        "families": {"filter", "select", "aggregate"},
        "weight": 0.65,
    },
}


@dataclass
class _RuntimeTraceIndex:
    """从轻量 VEG 临时派生出的表级索引。

    注意：这个索引只在打分时使用，不会写回 VEG，也不会额外落盘。
    """

    transforms: List[Dict[str, Any]]
    producer_by_output: Dict[str, Dict[str, Any]]
    result_tids: Set[str]

    @classmethod
    def from_veg(cls, veg: Mapping[str, Any]) -> "_RuntimeTraceIndex":
        transforms: List[Dict[str, Any]] = []
        producer_by_output: Dict[str, Dict[str, Any]] = {}
        for raw in list((dict(veg or {}).get("transforms") or [])):
            transform = dict(raw or {})
            transforms.append(transform)
            output_tid = str(transform.get("output") or "")
            if output_tid:
                producer_by_output[output_tid] = transform

        refs = list((dict((dict(veg or {}).get("stage_result") or {})).get("refs") or []))
        result_tids = {
            str((ref or {}).get("tid") or "")
            for ref in refs
            if str((ref or {}).get("tid") or "")
        }
        return cls(transforms=transforms, producer_by_output=producer_by_output, result_tids=result_tids)

    def upstream_transforms(self, tid: str) -> List[Dict[str, Any]]:
        """返回生成 tid 所依赖的全部上游 transform，按 event id 近似排序。"""

        start = str(tid or "")
        if not start:
            return []
        visited_tids: Set[str] = set()
        visited_events: Set[str] = set()
        out: List[Dict[str, Any]] = []

        def visit(current_tid: str) -> None:
            if not current_tid or current_tid in visited_tids:
                return
            visited_tids.add(current_tid)
            transform = self.producer_by_output.get(current_tid)
            if not transform:
                return
            event_key = str(transform.get("id") or id(transform))
            if event_key not in visited_events:
                visited_events.add(event_key)
                out.append(transform)
            for input_tid in list(transform.get("inputs") or []):
                visit(str(input_tid or ""))

        visit(start)
        out.sort(key=lambda item: int(item.get("id") or 0))
        return out

    def distance_to_result(self, tid: str) -> Optional[int]:
        """计算 tid 到 stage_result.refs 的最短上游距离。"""

        target = str(tid or "")
        if not target or not self.result_tids:
            return None
        queue = deque((result_tid, 0) for result_tid in self.result_tids)
        visited: Set[str] = set()
        while queue:
            current_tid, distance = queue.popleft()
            if current_tid in visited:
                continue
            visited.add(current_tid)
            if current_tid == target:
                return int(distance)
            transform = self.producer_by_output.get(current_tid)
            if not transform:
                continue
            for input_tid in list(transform.get("inputs") or []):
                key = str(input_tid or "")
                if key and key not in visited:
                    queue.append((key, distance + 1))
        return None


class EvidenceSupportScorer:
    """L2：候选计划的运行时证据支撑评分。"""

    def score(self, plan: Mapping[str, Any], veg: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Tuple[float, List[str]]:
        source_tid = str(plan.get("source_tid") or "")
        trace_index = _RuntimeTraceIndex.from_veg(veg)

        binding_score = self._binding_score(plan)
        proximity_score, proximity_reasons = self._result_proximity(source_tid, trace_index)
        operation_score, operation_reasons = self._upstream_operation_support(plan, source_tid, trace_index)
        signal_score, signal_reasons = self._data_signal_strength(plan, artifact_store)

        # L2 的核心目标是让候选图忠实贴近当前轮 stage_result。
        # binding / operation / signal 仍然有用，但不能让远离结果的原始表模式反超最终结果。
        score = clip01(
            0.58 * proximity_score
            + 0.17 * binding_score
            + 0.15 * operation_score
            + 0.10 * signal_score
        )
        reasons = [
            f"binding_score={binding_score:.2f}",
            f"result_proximity={proximity_score:.2f}",
            f"upstream_operation_support={operation_score:.2f}",
            f"data_signal_strength={signal_score:.2f}",
        ]
        reasons.extend(proximity_reasons)
        reasons.extend(operation_reasons)
        reasons.extend(signal_reasons[:4])
        return score, reasons

    def score_frontier(
        self,
        plan: Mapping[str, Any],
        veg: Mapping[str, Any],
        artifact_store: Mapping[str, Any],
        *,
        task_anchor_text: str = "",
    ) -> Tuple[float, List[str]]:
        """Frontier 分支专用证据评分。

        Answer 分支要求图强贴近 stage_result；frontier 分支的目标是提示下一轮
        探索，因此允许 raw/source table 进入，但必须满足：真实列、可执行、
        有基本数据信号，并且和任务/当前问题存在列名或语义锚点关系。
        """
        source_tid = str(plan.get("source_tid") or "")
        trace_index = _RuntimeTraceIndex.from_veg(veg)

        binding_score = self._binding_score(plan)
        proximity_score, proximity_reasons = self._result_proximity(source_tid, trace_index)
        operation_score, operation_reasons = self._upstream_operation_support(plan, source_tid, trace_index)
        signal_score, signal_reasons = self._data_signal_strength(plan, artifact_store)
        relevance_score, relevance_reasons = self._task_column_relevance(plan, task_anchor_text)

        distance = trace_index.distance_to_result(source_tid)
        drift_penalty = 0.0
        if distance is None and relevance_score < 0.18:
            drift_penalty = 0.16
        elif distance is not None and distance >= 4 and relevance_score < 0.12:
            drift_penalty = 0.08

        score = clip01(
            0.18 * proximity_score
            + 0.22 * binding_score
            + 0.14 * operation_score
            + 0.24 * signal_score
            + 0.22 * relevance_score
            - drift_penalty
        )
        reasons = [
            f"frontier_binding_score={binding_score:.2f}",
            f"frontier_result_proximity={proximity_score:.2f}",
            f"frontier_operation_support={operation_score:.2f}",
            f"frontier_data_signal={signal_score:.2f}",
            f"frontier_task_relevance={relevance_score:.2f}",
        ]
        if drift_penalty:
            reasons.append(f"frontier_drift_penalty={drift_penalty:.2f}")
        reasons.extend(proximity_reasons)
        reasons.extend(operation_reasons[:3])
        reasons.extend(relevance_reasons[:4])
        reasons.extend(signal_reasons[:3])
        return score, reasons

    def _binding_score(self, plan: Mapping[str, Any]) -> float:
        binding = dict(plan.get("binding") or {})
        if "score" in binding:
            return clip01(binding.get("score"))
        return 0.45

    def _result_proximity(self, source_tid: str, trace_index: _RuntimeTraceIndex) -> Tuple[float, List[str]]:
        distance = trace_index.distance_to_result(source_tid)
        if distance is None:
            return 0.04, ["result_distance=not_on_result_upstream"]
        if distance == 0:
            return 1.00, ["result_distance=0"]
        if distance == 1:
            return 0.78, ["result_distance=1"]
        if distance == 2:
            return 0.52, ["result_distance=2"]
        if distance == 3:
            return 0.32, ["result_distance=3"]
        return 0.16, [f"result_distance={distance}"]

    def _upstream_operation_support(
        self,
        plan: Mapping[str, Any],
        source_tid: str,
        trace_index: _RuntimeTraceIndex,
    ) -> Tuple[float, List[str]]:
        template_id = str(plan.get("template_id") or "")
        hints = _TEMPLATE_OPERATION_HINTS.get(template_id) or {}
        distance = trace_index.distance_to_result(source_tid)
        upstream = trace_index.upstream_transforms(source_tid)
        if not upstream:
            # source 本身就是 stage_result 时，没有上游操作不是缺陷；
            # 它已经是当前代码执行返回给 answer 的最终证据。
            if distance == 0:
                return 0.75, ["upstream_ops=stage_result_direct"]
            return 0.18, ["upstream_ops=none"]

        hint_ops = {str(item) for item in hints.get("ops", set())}
        hint_families = {str(item) for item in hints.get("families", set())}
        template_weight = float(hints.get("weight", 0.50))
        best = 0.0
        best_label = ""
        labels: List[str] = []
        for transform in upstream:
            op = str(transform.get("op") or "")
            family = str(transform.get("family") or "")
            label = f"{transform.get('id')}:{op or family}"
            labels.append(label)
            local = 0.0
            if op in hint_ops or any(token and token in op for token in hint_ops):
                local = max(local, template_weight)
            if family in hint_families:
                local = max(local, template_weight * 0.78)
            if local > best:
                best = local
                best_label = label

        if best <= 0.0:
            return 0.25, [f"upstream_ops={','.join(labels[:8])}", "no_template_operation_match"]
        return clip01(best), [f"upstream_ops={','.join(labels[:8])}", f"best_operation_match={best_label}:{best:.2f}"]

    def _task_column_relevance(self, plan: Mapping[str, Any], task_anchor_text: str) -> Tuple[float, List[str]]:
        """计算 plan 中列名/表名与任务锚点的弱相关性。

        这里不做语义检索，只做透明的 token overlap。它的作用不是证明该方向
        一定正确，而是防止 raw frontier 看到任意有模式的列后跑偏。
        """
        anchors = _tokenize_anchor_text(task_anchor_text)
        if not anchors:
            return 0.25, ["task_relevance=no_anchor_text"]

        columns = _plan_column_names(plan)
        source_tid = str(plan.get("source_tid") or "")
        haystack = " ".join([source_tid] + columns).lower()
        if not haystack.strip():
            return 0.05, ["task_relevance=no_plan_columns"]

        hits = [term for term in anchors if term and term in haystack]
        exact_column_hits = []
        for column in columns:
            lowered = column.lower()
            if any(term and term in lowered for term in anchors):
                exact_column_hits.append(column)

        if exact_column_hits:
            score = min(1.0, 0.45 + 0.18 * len(exact_column_hits))
        elif hits:
            score = min(0.70, 0.22 + 0.08 * len(hits))
        else:
            score = 0.10

        reasons = [f"task_relevance_hits={','.join(hits[:5]) or 'none'}"]
        if exact_column_hits:
            reasons.append(f"task_relevant_columns={','.join(exact_column_hits[:4])}")
        return clip01(score), reasons

    def _data_signal_strength(self, plan: Mapping[str, Any], artifact_store: Mapping[str, Any]) -> Tuple[float, List[str]]:
        """复用 pattern_signal，避免 L2/L3 各自维护一套相似算法。"""

        source_tid = str(plan.get("source_tid") or "")
        df = artifact_store.get(source_tid)
        if not isinstance(df, pd.DataFrame) or df.empty:
            return 0.0, ["source dataframe missing or empty"]
        try:
            support_df = apply_transform_ops(df, list((plan.get("transform") or {}).get("ops") or []))
        except Exception as exc:
            return 0.0, [f"transform failed while scoring: {exc}"]

        signal = compute_pattern_signal(support_df, plan)
        return clip01(signal.score), list(signal.reasons or [])


def _tokenize_anchor_text(text: str) -> Set[str]:
    """把任务/问题文本拆成少量锚点词。"""
    stop = {
        "the", "and", "for", "with", "from", "that", "this", "there", "which",
        "what", "when", "where", "have", "has", "are", "was", "were", "data",
        "table", "analysis", "analyze", "find", "show", "compare", "using", "about",
    }
    tokens = re.findall(r"[a-z][a-z0-9_\-]{2,}|[\u4e00-\u9fff]{2,}", str(text or "").lower())
    return {token for token in tokens if token not in stop and len(token) >= 3}


def _plan_column_names(plan: Mapping[str, Any]) -> List[str]:
    """提取 plan 中真实参与表达的列名。"""
    columns: List[str] = []
    seen: Set[str] = set()

    def add(value: Any) -> None:
        text = str(value or "").strip()
        key = text.lower()
        if text and key not in seen:
            seen.add(key)
            columns.append(text)

    encoding = dict((plan or {}).get("encoding") or {})
    for value in dict(encoding.get("slots") or {}).values():
        add(value)
    for value in dict((plan or {}).get("template_slots") or {}).values():
        add(value)
    for op in list(dict((plan or {}).get("transform") or {}).get("ops") or []):
        if not isinstance(op, Mapping):
            continue
        for key in ["column", "value", "index", "columns"]:
            add(op.get(key))
        for value in list(op.get("by") or []):
            add(value)
    return columns
