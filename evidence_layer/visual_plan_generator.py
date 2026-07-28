"""visual_plan_generator.py
--------------------------

基于轻量 VEG 和真实 artifact，使用“固定模板 + 实时槽位绑定”生成候选视觉计划。

本版本加入了供给侧限流：
- 明显优先从 stage_result 及其近邻上游表生成候选；
- 每张表、每种模板、全局候选数都有上限；
- comparison_bar 会根据源表是否已聚合决定是否先 groupby 聚合，避免一行一根 bar 的噪声图；
- 全局候选池使用按模板轮转的方式限流，避免某一类图在 gate 之前就挤掉其他图型；
- The generator does not read the query or make admission decisions. QEP tendency is
  only a later ranking preference; evidence and representation are the hard gates.
"""

from __future__ import annotations

from collections import defaultdict, deque
import hashlib
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

import pandas as pd
import json
from chart.slot_binding import TemplateBinding, TableSlotIndex, bind_templates_to_table, build_table_slot_index
from chart.template_registry import build_default_templates
from evidence_layer.schemas import make_visual_plan
from evidence_layer.visual_semantics import build_veg_column_semantics, compact_profile_semantics
from vis_project_utils.dataframe_safety import safe_nunique


# 候选池稍微放宽，配合后续较宽的 gate 使用。
# 这里不无限扩大，只给 bar/scatter/line/boxplot 更多进入打分阶段的机会。
MAX_PLANS_PER_TABLE = 8
MAX_TOTAL_PLANS = 36
MAX_SOURCE_TABLES = 8
MAX_PLANS_PER_TEMPLATE = 9
MAX_BARS = 12
MAX_TREND_POINTS = 80


def generate_visual_plans(
    veg: Mapping[str, Any],
    artifact_store: Mapping[str, Any],
    *,
    source_table_metadata: Optional[Mapping[str, Mapping[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """从 VEG 和 artifact_store 生成候选视觉计划。

    生成器只做“供给侧”限制，不决定最终是否画图：
    - 先用 VEG 的 stage_result.refs 计算每个 table 到最终结果的距离；
    - 只对最相关的少数表做 slot binding；
    - 对同源同模板的候选去重和限流；
    - 全局再做一次 per-template 限流，避免 bar candidate flood。
    """

    veg = dict(veg or {})
    artifacts = dict(artifact_store or {})
    templates = build_default_templates()
    tables = dict(veg.get("tables") or {})
    trace_index = _GeneratorTraceIndex.from_veg(veg)
    table_semantics = build_veg_column_semantics(veg, source_table_metadata)
    table_priorities = _rank_source_tables(tables, artifacts, trace_index)

    raw_plans: List[Dict[str, Any]] = []
    counter = 0

    for tid, table_score, table_reasons in table_priorities[:MAX_SOURCE_TABLES]:
        table = dict(tables.get(tid) or {})
        artifact_key = str(table.get("artifact_key") or "")
        if not artifact_key:
            continue
        df = artifacts.get(artifact_key)
        if isinstance(df, pd.Series):
            df = df.to_frame()
        if not isinstance(df, pd.DataFrame) or df.empty:
            continue

        table_index = build_table_slot_index(
            df,
            tid=tid,
            column_semantics=table_semantics.get(tid),
        )
        bindings = bind_templates_to_table(table_index, templates)
        bindings = _deduplicate_and_limit_bindings(bindings, limit=MAX_PLANS_PER_TABLE)

        for binding in bindings:
            counter += 1
            plan = _binding_to_visual_plan(
                veg=veg,
                tid=tid,
                binding=binding,
                counter=counter,
                source_df=df,
                table_index=table_index,
            )
            plan["candidate_source"] = {
                "priority": float(table_score),
                "reasons": list(table_reasons),
            }
            raw_plans.append(plan)

    return _limit_plans_global(raw_plans)


class _GeneratorTraceIndex:
    """仅供 generator 使用的轻量 lineage 索引。"""

    def __init__(self, producer_by_output: Mapping[str, Mapping[str, Any]], result_tids: Set[str]) -> None:
        self.producer_by_output = {str(k): dict(v or {}) for k, v in dict(producer_by_output or {}).items()}
        self.result_tids = {str(item) for item in set(result_tids or set()) if str(item)}

    @classmethod
    def from_veg(cls, veg: Mapping[str, Any]) -> "_GeneratorTraceIndex":
        producer_by_output: Dict[str, Dict[str, Any]] = {}
        for raw in list((dict(veg or {}).get("transforms") or [])):
            transform = dict(raw or {})
            output_tid = str(transform.get("output") or "")
            if output_tid:
                producer_by_output[output_tid] = transform
        refs = list((dict((dict(veg or {}).get("stage_result") or {})).get("refs") or []))
        result_tids = {str((ref or {}).get("tid") or "") for ref in refs if str((ref or {}).get("tid") or "")}
        return cls(producer_by_output=producer_by_output, result_tids=result_tids)

    def distance_to_result(self, tid: str) -> Optional[int]:
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


def _rank_source_tables(
    tables: Mapping[str, Any],
    artifacts: Mapping[str, Any],
    trace_index: _GeneratorTraceIndex,
) -> List[Tuple[str, float, List[str]]]:
    ranked: List[Tuple[str, float, List[str]]] = []
    for raw_tid, raw_table in dict(tables or {}).items():
        tid = str(raw_tid or "")
        if not tid:
            continue
        table = dict(raw_table or {})
        artifact_key = str(table.get("artifact_key") or "")
        value = artifacts.get(artifact_key)
        if isinstance(value, pd.Series):
            value = value.to_frame()
        if not isinstance(value, pd.DataFrame) or value.empty:
            continue

        distance = trace_index.distance_to_result(tid)
        proximity = _distance_priority(distance)
        rows, cols = int(value.shape[0]), int(value.shape[1])
        shape_score = _shape_priority(rows, cols)
        # 供给侧也偏向 stage_result，但不写死只允许 stage_result。
        # 如果最终结果表本身能绑定图，它会更稳定地进入 L1/L2/L3 排序。
        score = 0.84 * proximity + 0.16 * shape_score
        reasons = [
            f"distance_to_stage_result={distance if distance is not None else 'not_on_result_upstream'}",
            f"shape={rows}x{cols}",
            f"proximity_priority={proximity:.2f}",
            f"shape_priority={shape_score:.2f}",
        ]
        ranked.append((tid, float(score), reasons))
    ranked.sort(key=lambda item: (-item[1], item[0]))
    return ranked


def _distance_priority(distance: Optional[int]) -> float:
    if distance is None:
        return 0.05
    if distance == 0:
        return 1.00
    if distance == 1:
        return 0.76
    if distance == 2:
        return 0.48
    if distance == 3:
        return 0.26
    return 0.12


def _shape_priority(rows: int, cols: int) -> float:
    if rows <= 0 or cols <= 0:
        return 0.0
    if rows <= 2:
        return 0.28
    if 3 <= rows <= 80 and 1 <= cols <= 12:
        return 0.86
    if 81 <= rows <= 800 and 2 <= cols <= 20:
        return 0.68
    if rows > 5000 or cols > 60:
        return 0.30
    return 0.50


def _binding_to_visual_plan(
    veg: Mapping[str, Any],
    tid: str,
    binding: TemplateBinding,
    counter: int,
    source_df: Optional[pd.DataFrame] = None,
    table_index: Optional[TableSlotIndex] = None,
) -> Dict[str, Any]:
    """把模板绑定结果转换成当前 evidence_layer 使用的 VisualPlan dict。"""

    round_index = veg.get("round_index")
    source_table_node = f"table:{tid}"
    transform_ops = _materialize_transform_ops(
        binding,
        source_df=source_df,
        table_index=table_index,
    )
    encoding_slots = _encoding_slots(binding)
    plan_id = f"round_{round_index}_plan_{counter:03d}_{_short_binding_hash(tid, binding)}"

    plan = make_visual_plan(
        plan_id=plan_id,
        source_table_node=source_table_node,
        source_tid=tid,
        pattern=binding.pattern,
        transform_ops=transform_ops,
        chart_type=binding.chart_type,
        slots=encoding_slots,
        title=_plan_title(binding),
        generation_reason=[
            f"template={binding.template_id}",
            f"binding_score={binding.score:.2f}",
            *list(binding.reasons[:5]),
        ],
        source_event_ids=_source_event_ids(veg, tid),
    )
    plan["template_id"] = binding.template_id
    plan["view_family"] = binding.view_family
    plan["supported_tendencies"] = list(binding.supported_tendencies)
    plan["binding"] = {
        "score": float(binding.score),
        "slot_scores": dict(binding.slot_scores),
        "reasons": list(binding.reasons),
        "template_prior": float(binding.template_prior),
    }
    plan["template_slots"] = dict(binding.slots)
    plan["semantics"] = _binding_semantics(binding, table_index, transform_ops)
    return plan


def _materialize_transform_ops(
    binding: TemplateBinding,
    source_df: Optional[pd.DataFrame] = None,
    table_index: Optional[TableSlotIndex] = None,
) -> List[Dict[str, Any]]:
    """根据模板绑定生成当前 chart.transforms 支持的具体 transform ops。"""

    slots = dict(binding.slots)
    template_id = binding.template_id

    if template_id == "count_by_group":
        group = str(slots.get("group") or "")
        return [
            {"op": "value_counts", "column": group, "output": "count"},
            {"op": "sort_by", "column": "count", "ascending": False},
            {"op": "top_k", "k": MAX_BARS},
        ]

    if template_id == "comparison_bar":
        group = str(slots.get("group") or "")
        metric = str(slots.get("metric") or "")
        if _should_aggregate_group_metric(source_df, group, metric):
            aggregation = _aggregation_for_metric(table_index, metric)
            return [
                {"op": "groupby_agg", "by": [group], "value": metric, "agg": aggregation, "output": metric},
                {"op": "sort_by", "column": metric, "ascending": False},
                {"op": "top_k", "k": MAX_BARS},
            ]
        return [
            {"op": "use_columns", "columns": [group, metric]},
            {"op": "sort_by", "column": metric, "ascending": False},
            {"op": "top_k", "k": MAX_BARS},
        ]

    if template_id == "trend_line":
        time_col = str(slots.get("time") or "")
        metric = str(slots.get("metric") or "")
        aggregation = _aggregation_for_metric(table_index, metric)
        return [
            {"op": "groupby_agg", "by": [time_col], "value": metric, "agg": aggregation, "output": metric},
            {"op": "sort_by", "column": time_col, "ascending": True},
            {"op": "top_k", "k": MAX_TREND_POINTS},
        ]

    if template_id == "relation_scatter":
        x_metric = str(slots.get("x_metric") or "")
        y_metric = str(slots.get("y_metric") or "")
        return [{"op": "use_columns", "columns": [x_metric, y_metric]}]

    if template_id == "distribution_box":
        group = str(slots.get("group") or "")
        metric = str(slots.get("metric") or "")
        return [{"op": "use_columns", "columns": [group, metric]}]

    return []



def _aggregation_for_metric(table_index: Optional[TableSlotIndex], metric: str) -> str:
    if table_index is None:
        return "mean"
    profile = table_index.profiles.get(str(metric))
    if profile is None:
        return "mean"
    return "sum" if profile.is_additive is True else "mean"


def _binding_semantics(
    binding: TemplateBinding,
    table_index: Optional[TableSlotIndex],
    transform_ops: Sequence[Mapping[str, Any]],
) -> Dict[str, Any]:
    columns: Dict[str, Any] = {}
    if table_index is not None:
        for column in set(str(value) for value in binding.slots.values() if str(value)):
            profile = table_index.profiles.get(column)
            if profile is not None:
                columns[column] = compact_profile_semantics(profile)
    aggregation = ""
    for op in list(transform_ops or []):
        if str((op or {}).get("op") or "") == "groupby_agg":
            aggregation = str((op or {}).get("agg") or "")
            break
    return {
        "columns": columns,
        "aggregation": aggregation,
    }

def _should_aggregate_group_metric(source_df: Optional[pd.DataFrame], group: str, metric: str) -> bool:
    if not isinstance(source_df, pd.DataFrame) or source_df.empty:
        return False
    if group not in source_df.columns or metric not in source_df.columns:
        return False
    rows = int(source_df.shape[0])
    unique_groups = safe_nunique(source_df[group], dropna=False)
    if unique_groups <= 0:
        return False
    # 如果源表是一行一个类别，说明很可能已经是 compact stage_result；否则先聚合，避免 row-level bar flood。
    return bool(rows > unique_groups and rows >= 8)


def _encoding_slots(binding: TemplateBinding) -> Dict[str, str]:
    """把模板槽位转换成 renderer 需要的 x/y/group/value 槽位。"""

    slots = dict(binding.slots)
    if binding.template_id == "count_by_group":
        return {"x": str(slots.get("group") or ""), "y": "count"}
    if binding.template_id in {"comparison_bar", "distribution_box"}:
        return {"x": str(slots.get("group") or ""), "y": str(slots.get("metric") or "")}
    if binding.template_id == "trend_line":
        return {"x": str(slots.get("time") or ""), "y": str(slots.get("metric") or "")}
    if binding.template_id == "relation_scatter":
        return {"x": str(slots.get("x_metric") or ""), "y": str(slots.get("y_metric") or "")}
    return {key: str(value) for key, value in slots.items()}


def _plan_title(binding: TemplateBinding) -> str:
    """生成可读标题。"""

    slots = dict(binding.slots)
    if binding.template_id == "count_by_group":
        return f"Count by {slots.get('group')}"
    if binding.template_id == "comparison_bar":
        return f"{slots.get('metric')} by {slots.get('group')}"
    if binding.template_id == "trend_line":
        return f"{slots.get('metric')} over {slots.get('time')}"
    if binding.template_id == "relation_scatter":
        return f"{slots.get('y_metric')} vs {slots.get('x_metric')}"
    if binding.template_id == "distribution_box":
        return f"Distribution of {slots.get('metric')} by {slots.get('group')}"
    return binding.template_id


def _deduplicate_and_limit_bindings(bindings: Sequence[TemplateBinding], limit: int) -> List[TemplateBinding]:
    """去掉重复绑定，并限制每张表的候选数量。

    每个模板在单表内最多保留 3 个绑定。这个数字比旧版略宽，
    主要是为了让 bar/scatter 等候选不要在供给侧过早消失。
    """

    out: List[TemplateBinding] = []
    seen = set()
    per_template: Dict[str, int] = defaultdict(int)
    for binding in list(bindings or []):
        key = (binding.template_id, tuple(sorted((str(k), str(v)) for k, v in binding.slots.items())))
        if key in seen:
            continue
        if per_template[binding.template_id] >= 3:
            continue
        seen.add(key)
        per_template[binding.template_id] += 1
        out.append(binding)
        if len(out) >= limit:
            break
    return out


def _limit_plans_global(plans: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """全局限流，并尽量保持模板/图型供给均衡。

    旧版是全局排序后顺序截断，容易让高分模板先占满候选池。
    本版先去重，再按 template_id 分组，最后轮转取候选：
    - 每个模板仍按 source priority 和 binding score 排序；
    - 全局输出时每轮从不同模板各取一个；
    - 这样不改变模板定义和 gate 逻辑，只让更多图型有机会进入 L1/L2/L3。
    """

    def key(plan: Mapping[str, Any]) -> tuple:
        candidate_source = dict(plan.get("candidate_source") or {})
        binding = dict(plan.get("binding") or {})
        return (
            -float(candidate_source.get("priority") or 0.0),
            -float(binding.get("score") or 0.0),
            str(plan.get("template_id") or ""),
            str(plan.get("plan_id") or ""),
        )

    # 先做全局去重，并给每个模板保留 top candidates。
    seen = set()
    grouped: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for plan in sorted([dict(item or {}) for item in list(plans or [])], key=key):
        template_id = str(plan.get("template_id") or "unknown")
        slots = dict((dict(plan.get("encoding") or {}).get("slots") or {}))
        safe_slots = json.dumps(slots, sort_keys=True, default=str, ensure_ascii=False)
        dedupe_key = (template_id, str(plan.get("source_tid") or ""), safe_slots)
        if dedupe_key in seen:
            continue
        if len(grouped[template_id]) >= MAX_PLANS_PER_TEMPLATE:
            continue
        seen.add(dedupe_key)
        grouped[template_id].append(plan)

    if not grouped:
        return []

    # 模板顺序按各自最佳候选排序；随后轮转取数，避免某一模板淹没候选池。
    template_order = sorted(grouped, key=lambda template_id: key(grouped[template_id][0]))
    out: List[Dict[str, Any]] = []
    while len(out) < MAX_TOTAL_PLANS:
        added_this_round = False
        for template_id in template_order:
            bucket = grouped.get(template_id) or []
            if not bucket:
                continue
            out.append(bucket.pop(0))
            added_this_round = True
            if len(out) >= MAX_TOTAL_PLANS:
                break
        if not added_this_round:
            break
    return out


def _short_binding_hash(tid: str, binding: TemplateBinding) -> str:
    """用短 hash 避免 plan_id 过长且保证相同绑定可复现。"""

    raw = f"{tid}|{binding.template_id}|{sorted(binding.slots.items())}"
    return hashlib.md5(raw.encode("utf-8")).hexdigest()[:6]


def _source_event_ids(veg: Mapping[str, Any], tid: str) -> List[int]:
    """返回直接生成或读取该 tid 的 transform id，用于记录计划来源。"""

    ids: List[int] = []
    for transform in list((dict(veg or {}).get("transforms") or [])):
        item = dict(transform or {})
        event_id = item.get("id")
        if event_id is None:
            continue
        if str(item.get("output") or "") == str(tid):
            ids.append(int(event_id))
            continue
        if str(tid) in [str(input_tid) for input_tid in list(item.get("inputs") or [])]:
            ids.append(int(event_id))
    return ids[:8]
