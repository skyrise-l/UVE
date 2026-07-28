"""chart_extract/visual_fact_extractor.py
-----------------------------------------
渲染后视觉证据抽取与紧凑图卡构造层。

本文件只做一件事：把“已选图表计划 + 图表实际使用的 support_df”转成
answer / frontier prompt 能直接消费的短文本卡片。当前不向 LLM 传图，因此图的
价值必须在这里被压缩成少量关键事实和一条候选分析结论。

每张 answer 图卡只保留三类信息：
1. Chart setup：图画了什么，包含图型、核心轴和分组；
2. Key facts：最多两条由 support_df 计算出的关键事实；
3. Candidate local finding：最多一条局部证据发现，供 answer LLM 在问题级 insight 中取舍。

frontier 图卡不写 Candidate local finding，而写 Observed pattern / Goal link / Unresolved part，
把“已计算确认的模式”与“尚未解释的部分”分开，避免下一轮只换一种比例或差值重述同一结论。
这里不保存完整中间结果，也不返回低效调试字段，避免视觉信息挤占 prompt token。
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import re
import warnings
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import pandas as pd
from pandas.api.types import is_datetime64_any_dtype, is_numeric_dtype

from vis_project_utils.dataframe_safety import safe_hashable_dataframe
from vis_project_utils.utils import safe_to_numeric
from evidence_layer.visual_semantics import infer_column_semantics

from .common import (
    Plan,
    all_slots,
    chart_type_of,
    plan_score,
    source_tid,
    slot,
    template_family,
)

MaterializeFn = Callable[[Plan], Any]


@dataclass(frozen=True)
class Observation:
    """单条可写入 answer prompt 的辅助观察。"""

    text: str
    kind: str
    priority: float
    family: str = ""
    metric: str = ""
    scope: str = ""
    support_size: int = 0


@dataclass
class PlanContext:
    """单张图在事实提取阶段使用的上下文。"""

    plan: Plan
    df: pd.DataFrame
    family: str
    slots: Dict[str, Any]
    chart_type: str = ""
    score: float = 0.0
    source_id: Any = None


# 每张图卡最多写入 2 条关键事实。候选 insight 单独占一行，避免图卡变长。
MAX_KEY_FACTS_PER_CARD = 2


def build_visual_card_text(
    selected_plans: Iterable[Plan],
    materialize_df: MaterializeFn,
    *,
    card_prefix: str = "Chart",
) -> str:
    """把一组图表计划转换成紧凑图卡文本。

    输入：
    - selected_plans：已经被 answer/frontier selector 选中的图表计划；
    - materialize_df：根据 plan 取出图表实际 support_df 的函数；
    - card_prefix：卡片前缀，Chart 用于 answer，Visual Frontier 用于下一轮规划。

    输出：
    - 多张卡片拼接后的短文本。answer 卡片保留 setup、key facts、candidate local finding；
      frontier 卡片保留 observed pattern、goal link 和 unresolved part。

    关键修正：候选 insight 不再机械复述第一条 fact，而是根据图表族和底层数据
    判断 concentration / stable / uniform / weak relationship 等结论类型。
    """
    cards: List[str] = []
    seen_observations = set()
    prefix = str(card_prefix or "Chart").strip() or "Chart"
    is_frontier = "frontier" in prefix.lower()

    card_index = 0
    for plan in list(selected_plans or []):
        ctx = build_plan_context(plan, materialize_df)
        if ctx is None or _uses_internal_section_dimension(ctx):
            continue

        observation_items: List[Observation] = []
        for obs in _extract_observations_for_context(ctx):
            sentence = clean_sentence(obs.text)
            key = normalize_line(sentence)
            if not sentence or key in seen_observations:
                continue
            seen_observations.add(key)
            observation_items.append(obs)
            if len(observation_items) >= MAX_KEY_FACTS_PER_CARD + 1:
                break

        if not observation_items:
            continue

        card_index += 1
        card_id = f"{prefix} {card_index}"
        key_facts = [clean_sentence(obs.text) for obs in observation_items[:MAX_KEY_FACTS_PER_CARD]]
        candidate = _candidate_insight_sentence(ctx, observation_items)
        unresolved_part = _frontier_unresolved_part(ctx, key_facts) if is_frontier else ""

        lines = [
            f"[{card_id}]",
            f"Chart setup: {_chart_setup_sentence(ctx)}",
        ]
        if key_facts:
            lines.append("Key facts:")
            lines.extend(f"- {item}" for item in key_facts)
        if candidate:
            if is_frontier:
                lines.append(f"Observed pattern: {candidate}")
                lines.append("Goal link: Use this signal only if it helps answer, explain, validate, segment, or bound the original goal/query.")
            else:
                lines.append(f"Candidate local finding: {candidate}")
        if is_frontier and unresolved_part:
            lines.append(f"Unresolved part: {unresolved_part}")

        cards.append("\n".join(lines))

    return "\n\n".join(cards)


def _uses_internal_section_dimension(ctx: PlanContext) -> bool:
    """内部拼接字段 ``_section`` 不应被解释为业务维度。"""
    for key in ("x", "group", "category", "series", "facet", "hue", "row", "col"):
        value = ctx.slots.get(key)
        if str(value or "").strip().lower() == "_section":
            return True
    return False


def _chart_setup_sentence(ctx: PlanContext) -> str:
    """生成图卡第一行 setup，压缩图型、轴、分组和分析角色。"""
    role = _visual_role(ctx)
    encoding = _chart_encoding_sentence(ctx).rstrip("。.")
    purpose = _chart_purpose_sentence(ctx).rstrip("。.")
    if role:
        return f"{encoding}; role={role}; purpose={purpose}."
    return f"{encoding}; purpose={purpose}."


def _candidate_insight_sentence(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """从图表数据生成一条候选 insight。

    候选局部发现只描述当前图卡直接支持的事实模式，不承担最终问题级 insight 的角色。
    特别处理均匀分布、稳定趋势、弱关系等负向/稳定发现，避免 LLM 忽略这些
    benchmark 中常见的有效分析证据。
    """
    if ctx.family == "ranked_group_value":
        return _ranked_candidate_insight(ctx, observations)
    if ctx.family == "time_trend":
        return _trend_candidate_insight(ctx, observations)
    if ctx.family == "relationship":
        return _relationship_candidate_insight(ctx, observations)
    if ctx.family == "group_distribution":
        return _distribution_candidate_insight(ctx, observations)
    if ctx.family == "matrix_contrast":
        return _matrix_candidate_insight(ctx, observations)
    return clean_sentence(observations[0].text) if observations else ""


def _ranked_candidate_insight(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """为排序/柱状图生成 concentration 或 balanced 结论。"""
    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "group", "category")
    y = slot(slots, "y", "value", "metric", "count")
    if not x or not y or x not in df.columns or y not in df.columns:
        return clean_sentence(observations[0].text) if observations else ""

    work = df[[x, y]].copy()
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])
    if work.empty:
        return clean_sentence(observations[0].text) if observations else ""

    work = group_duplicate_categories(
        work, x, y, aggregation="sum" if _metric_is_additive(ctx, y) else "mean"
    ).sort_values(y, ascending=False).reset_index(drop=True)
    if work.empty or len(work) < 2:
        return ""

    values = [float(v) for v in work[y]]
    top = work.iloc[0]
    bottom = work.iloc[-1]
    gap = float(top[y]) - float(bottom[y])
    additive = _metric_is_additive(ctx, y)

    if len(work) >= 2 and abs(gap) <= 1e-9:
        return f"按 {x} 比较 {y} 时，{len(work)} 个类别的数值相同，分布呈均匀/均衡状态。"

    top_share = _dominant_share(values) if additive else None
    if top_share is not None:
        return f"{fmt_label(top[x])} 是 {x} 中最突出的类别，{y} 为 {fmt(top[y])}，约占总量 {fmt_pct(top_share * 100)}。"

    if len(work) >= 2:
        second = work.iloc[1]
        second_value = float(second[y])
        top_value = float(top[y])
        if abs(second_value) > 1e-12:
            ratio = top_value / second_value
            if ratio >= 1.2:
                return f"{fmt_label(top[x])} 的 {y} 最高，为 {fmt(top_value)}，约为第二位 {fmt_label(second[x])} 的 {fmt(ratio)} 倍。"
        if gap > 0:
            return f"{fmt_label(top[x])} 的 {y} 最高，为 {fmt(top_value)}，比最低的 {fmt_label(bottom[x])} 高 {fmt(gap)}。"

    return clean_sentence(observations[0].text) if observations else ""


def _trend_candidate_insight(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """为趋势图生成 trend 或 stable 结论。"""
    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "time", "date")
    y = slot(slots, "y", "value", "metric")
    if not x or not y or x not in df.columns or y not in df.columns:
        return clean_sentence(observations[0].text) if observations else ""

    work = df[[x, y]].copy()
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])
    if len(work) < 2:
        return clean_sentence(observations[0].text) if observations else ""

    parsed_time = safe_datetime_series(work[x])
    if parsed_time.notna().any():
        work = work.assign(_sort_time=parsed_time).sort_values(["_sort_time", x])
        sort_col = "_sort_time"
    else:
        work = work.sort_values(x)
        sort_col = x
    work = work.groupby(x, dropna=False, as_index=False).agg({y: "mean", sort_col: "first"}).sort_values(sort_col)
    if len(work) < 2:
        return ""

    start = float(work.iloc[0][y])
    end = float(work.iloc[-1][y])
    delta = end - start
    pct = relative_change(start, end)
    values = [float(value) for value in work[y].tolist()]
    turns = _direction_change_count(values)
    spread = max(values) - min(values) if values else 0.0

    if abs(delta) <= 1e-9 or (pct is not None and abs(pct) <= 0.05):
        if turns > 0 and spread > max(1e-9, abs(start) * 0.10):
            return f"{y} 在 {x} 覆盖的时间范围内首尾接近，但期间存在波动，并非持续稳定。"
        return f"{y} 在 {x} 覆盖的时间范围内没有明显净变化。"
    direction = "上升" if delta > 0 else "下降"
    fluctuation = "，但期间存在波动" if turns > 0 else ""
    if pct is not None:
        return f"{y} 在 {x} 覆盖的时间范围内净{direction}，从 {fmt(start)} 变为 {fmt(end)}，变化约 {fmt_pct(abs(pct) * 100)}{fluctuation}。"
    return f"{y} 在 {x} 覆盖的时间范围内净{direction}，从 {fmt(start)} 变为 {fmt(end)}{fluctuation}。"


def _direction_change_count(values: Sequence[float]) -> int:
    signs: List[int] = []
    for left, right in zip(values, values[1:]):
        diff = float(right) - float(left)
        if abs(diff) <= 1e-12:
            continue
        signs.append(1 if diff > 0 else -1)
    return sum(1 for left, right in zip(signs, signs[1:]) if left != right)


def _relationship_candidate_insight(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """为散点/关系图生成强关系或弱关系结论。"""
    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "x_metric")
    y = slot(slots, "y", "y_metric")
    if not x or not y or x not in df.columns or y not in df.columns:
        return clean_sentence(observations[0].text) if observations else ""

    work = df[[x, y]].copy()
    work[x] = numeric_series(work[x])
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])
    if len(work) < 3:
        return clean_sentence(observations[0].text) if observations else ""

    corr = work[x].corr(work[y], method="pearson")
    if corr is None or math.isnan(float(corr)):
        return ""
    direction = "正相关" if corr > 0 else "负相关"
    abs_corr = abs(float(corr))
    if abs_corr < 0.25:
        return f"{x} 与 {y} 的 Pearson 相关系数约为 {fmt(corr)}，没有明显线性关系。"
    strength = "较强" if abs_corr >= 0.7 else "中等"
    return f"{x} 与 {y} 呈{strength}{direction}关系，Pearson 相关系数约为 {fmt(corr)}。"


def _distribution_candidate_insight(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """为分组分布图生成组间差异或重叠结论。"""
    first = clean_sentence(observations[0].text) if observations else ""
    if any(obs.kind == "overlap" for obs in observations):
        return f"{first} 因此组间差异需要谨慎解释。"
    return first


def _matrix_candidate_insight(ctx: PlanContext, observations: Sequence[Observation]) -> str:
    """为二维矩阵/热力图生成主导组合结论。"""
    return clean_sentence(observations[0].text) if observations else ""


def _visual_role(ctx: PlanContext) -> str:
    """把图表族映射成下游可读的 insight role。"""
    if ctx.family == "time_trend":
        return "trend"
    if ctx.family == "relationship":
        return "relationship"
    if ctx.family == "matrix_contrast":
        return "matrix_contrast"
    if ctx.family == "group_distribution":
        return "distribution"
    if ctx.family == "ranked_group_value":
        return "topk_or_gap"
    return "general"

def build_auxiliary_observation_text(
    selected_plans: Iterable[Plan],
    materialize_df: MaterializeFn,
) -> str:
    """为 answer 分支构造视觉卡片。

    当前主流程的 answer 层只读取当前问题对应的图卡，因此这里直接调用
    ``build_visual_card_text(..., card_prefix='Chart')``。
    """
    return build_visual_card_text(
        selected_plans=selected_plans,
        materialize_df=materialize_df,
        card_prefix="Chart",
    )




def _frontier_unresolved_part(ctx: PlanContext, observations: Sequence[str]) -> str:
    """说明当前图已经确认模式，但还没有解释什么。

    真实 InsightBench 结果中，旧的图型模板会反复建议 share、gap、ratio，
    导致后续问题只是重参数化同一结论。这里改为暴露解释缺口，让 manager
    追查驱动因素、子群或上下文，而不是再计算一个同义数字。
    """
    _ = observations
    if ctx.family == "time_trend":
        return (
            "The temporal pattern is visible, but the chart does not identify which "
            "categories, entities, or events drive the changes."
        )
    if ctx.family == "relationship":
        return (
            "The association is visible, but the chart does not show whether it remains "
            "within meaningful subgroups or is driven by a few influential observations."
        )
    if ctx.family == "group_distribution":
        return (
            "The distribution difference is visible, but the chart does not identify "
            "which records, entities, or contextual dimensions explain it."
        )
    if ctx.family == "matrix_contrast":
        return (
            "The strongest cell contrasts are visible, but the chart does not explain "
            "why those combinations differ or whether another dimension accounts for them."
        )
    return (
        "The ranking or concentration is visible, but the chart does not identify which "
        "subgroups, entities, text patterns, or time periods drive it."
    )

def _chart_encoding_sentence(ctx: PlanContext) -> str:
    """生成一句可读的图表编码说明。"""
    slots = ctx.slots
    chart_type = (ctx.chart_type or "chart").strip().lower()
    chart_name = {
        "bar": "Bar chart",
        "line": "Line chart",
        "scatter": "Scatter plot",
        "boxplot": "Box plot",
        "heatmap": "Heatmap",
    }.get(chart_type, f"{chart_type.title()} chart")

    x = slot(slots, "x", "group", "category", "time", "date", "x_metric")
    y = slot(slots, "y", "value", "metric", "count", "y_metric")
    group = slot(slots, "series", "facet", "hue")

    parts: List[str] = []
    if x:
        parts.append(f"{x} on x-axis")
    if y:
        parts.append(f"{y} on y-axis")
    if group:
        parts.append(f"grouped by {group}")

    return f"{chart_name}: {', '.join(parts)}." if parts else f"{chart_name}."


def _chart_purpose_sentence(ctx: PlanContext) -> str:
    """根据图表族和槽位生成一句简短目的说明。"""
    slots = ctx.slots
    x = slot(slots, "x", "group", "category", "time", "date", "x_metric") or "groups"
    y = slot(slots, "y", "value", "metric", "count", "y_metric") or "values"

    if ctx.family == "ranked_group_value":
        return f"compare {y} across {x}."
    if ctx.family == "group_distribution":
        return f"compare the distribution of {y} across {x}."
    if ctx.family == "time_trend":
        return f"show how {y} changes over {x}."
    if ctx.family == "relationship":
        return f"inspect the relationship between {x} and {y}."
    if ctx.family == "matrix_contrast":
        value = slot(slots, "value", "metric", "count") or y
        return f"compare {value} across the two categorical dimensions."
    return f"summarize {y} by {x}."


def _relevant_columns(ctx: PlanContext) -> List[str]:
    """列出卡片中最关键的图表列，避免把完整 DataFrame schema 塞进 prompt。"""
    cols: List[str] = []
    for name in [
        slot(ctx.slots, "x", "group", "category", "time", "date", "x_metric"),
        slot(ctx.slots, "y", "value", "metric", "count", "y_metric"),
        slot(ctx.slots, "series", "facet", "hue"),
        slot(ctx.slots, "value"),
    ]:
        if name and name not in cols:
            cols.append(name)
    return cols


def _extract_observations_for_context(ctx: PlanContext) -> List[Observation]:
    """为单张图提取并排序辅助观察。"""
    extractor = EXTRACTORS.get(ctx.family)
    if extractor is None:
        return []

    try:
        observations = extractor(ctx)
    except Exception:
        # 单张图的事实抽取失败不应影响主回答链路。
        return []

    return rank_and_dedupe_observations(observations)


def build_plan_context(plan: Plan, materialize_df: MaterializeFn) -> Optional[PlanContext]:
    """把 plan 和 support_df 组装成 extractor 使用的上下文。"""
    df = to_dataframe(materialize_df(plan))
    if df is None or df.empty:
        return None

    family = template_family(plan)
    if not family:
        return None

    slots = infer_slots(df, family, all_slots(plan))
    return PlanContext(
        plan=plan,
        df=df,
        family=family,
        slots=slots,
        chart_type=chart_type_of(plan),
        score=plan_score(plan),
        source_id=source_tid(plan),
    )


def infer_slots(df: pd.DataFrame, family: str, slots: Mapping[str, Any]) -> Dict[str, Any]:
    """在槽位缺失时，从 dataframe 中保守推断 x/y/row/col/value。"""
    out = dict(slots)
    numeric_cols = [c for c in df.columns if numeric_series(df[c]).notna().mean() >= 0.8]
    categorical_cols = [c for c in df.columns if c not in numeric_cols]

    if family in {"ranked_group_value", "group_distribution"}:
        if "x" not in out and "group" not in out and categorical_cols:
            out["x"] = categorical_cols[0]
        if "y" not in out and "metric" not in out and numeric_cols:
            out["y"] = numeric_cols[0]

    elif family == "time_trend":
        if "x" not in out:
            # Do not reinterpret arbitrary numeric identifiers as nanosecond timestamps.
            # Numeric time columns are accepted only when their name/value range is
            # explicitly year-like; textual and declared datetime columns are parsed.
            time_like = [
                c for c in df.columns
                if _is_verified_time_series(df[c])
            ]
            out["x"] = time_like[0] if time_like else None
        if "y" not in out and numeric_cols:
            out["y"] = numeric_cols[0]

    elif family == "relationship":
        if "x" not in out and len(numeric_cols) >= 1:
            out["x"] = numeric_cols[0]
        if "y" not in out and len(numeric_cols) >= 2:
            out["y"] = numeric_cols[1]

    elif family == "matrix_contrast":
        if "x" not in out and len(categorical_cols) >= 1:
            out["x"] = categorical_cols[0]
        if "y" not in out and len(categorical_cols) >= 2:
            out["y"] = categorical_cols[1]
        if "value" not in out and numeric_cols:
            out["value"] = numeric_cols[0]

    return out


def to_dataframe(data: Any) -> Optional[pd.DataFrame]:
    """把 materialize_df 返回值规范化为 DataFrame。"""
    if data is None:
        return None
    if isinstance(data, pd.DataFrame):
        return data.copy()
    try:
        return pd.DataFrame(data)
    except Exception:
        return None


def emit(
    ctx: PlanContext,
    text: str,
    kind: str,
    priority: float,
    metric: Optional[str] = None,
    scope: str = "",
) -> Observation:
    """创建一条观察结果，并携带上下文元信息。"""

    return Observation(
        text=clean_sentence(text),
        kind=kind,
        priority=priority + min(max(ctx.score, 0.0), 1.0) * 0.05,
        family=ctx.family,
        metric=metric or slot(ctx.slots, "y", "metric", "value", "count") or "",
        scope=scope,
        support_size=len(ctx.df),
    )


def rank_and_dedupe_observations(observations: Iterable[Observation]) -> List[Observation]:
    """按优先级排序并去重，避免多个 extractor 生成重复文本。"""

    best: Dict[str, Observation] = {}

    for obs in observations:
        key = normalize_line(obs.text)
        if not key:
            continue
        if key not in best or obs.priority > best[key].priority:
            best[key] = obs

    return sorted(best.values(), key=lambda o: (-o.priority, o.family, o.kind, o.text))


def normalize_line(line: str) -> str:
    """把句子归一化为去重键。"""

    text = str(line).lower().strip()
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"[。.!！]+$", "", text)
    return text


def clean_sentence(line: str) -> str:
    """清理空白并补齐中文句末标点。"""

    text = re.sub(r"\s+", " ", str(line)).strip()
    if text and text[-1] not in "。.!！?？":
        text += "。"
    return text


# -----------------------------------------------------------------------------
# 通用统计工具
# -----------------------------------------------------------------------------

def is_number(x: Any) -> bool:
    """判断对象是否可转为非 NaN 数字。"""

    try:
        return not math.isnan(float(x))
    except Exception:
        return False


def safe_float(x: Any) -> Optional[float]:
    """把对象转成 float，失败或 NaN 时返回 None。"""

    try:
        value = float(x)
    except Exception:
        return None

    if math.isnan(value):
        return None

    return value


def numeric_series(series: pd.Series) -> pd.Series:
    """把 Series 转为 plain float64；pd.NA/inf 统一为 NaN。"""

    return safe_to_numeric(series)


def _is_verified_time_series(series: pd.Series) -> bool:
    """Return True only for columns with defensible temporal semantics."""
    if series is None or len(series) == 0:
        return False
    try:
        if is_datetime64_any_dtype(series):
            return True
    except Exception:
        pass

    name = str(getattr(series, "name", "") or "").lower()
    tokens = {part for part in re.split(r"[^a-z0-9]+", name) if part}
    time_hints = {"date", "time", "timestamp", "datetime", "year", "month", "day", "period", "created", "updated", "opened", "closed"}
    has_time_name = bool(tokens & time_hints)
    try:
        if is_numeric_dtype(series):
            if not has_time_name:
                return False
            values = safe_to_numeric(series).dropna()
            if values.empty:
                return False
            # Prevent ward/license/postal-like values from becoming timestamps.
            return bool(values.between(1800, 2200).mean() >= 0.8)
    except Exception:
        return False

    return bool(has_time_name and safe_datetime_series(series).notna().mean() >= 0.5)


def safe_datetime_series(series: pd.Series) -> pd.Series:
    """安静地尝试解析时间列。

    图事实提取会扫描多种候选列，如果直接对普通文本列调用 pd.to_datetime，
    pandas 会频繁输出格式推断 warning。这里显式使用 format="mixed"，并在旧版
    pandas 中屏蔽该 warning，保证日志干净且不影响无法解析的文本列。
    """
    if series is None:
        return pd.Series(dtype="datetime64[ns]")
    try:
        if is_datetime64_any_dtype(series):
            return pd.to_datetime(series, errors="coerce")
        if is_numeric_dtype(series):
            name = str(getattr(series, "name", "") or "").lower()
            tokens = {part for part in re.split(r"[^a-z0-9]+", name) if part}
            if not tokens & {"year", "date", "time", "month", "day", "period"}:
                return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
            values = safe_to_numeric(series)
            if values.dropna().empty or values.dropna().between(1800, 2200).mean() < 0.8:
                return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
            return pd.to_datetime(values.astype("Int64").astype(str), errors="coerce", format="%Y")
    except Exception:
        return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None), dtype="datetime64[ns]")
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Could not infer format.*", category=UserWarning)
        try:
            return pd.to_datetime(series, errors="coerce", format="mixed")
        except TypeError:
            return pd.to_datetime(series, errors="coerce")
        except Exception:
            return pd.Series([pd.NaT] * len(series), index=getattr(series, "index", None))


def fmt(x: Any) -> str:
    """把数值格式化为适合 prompt 的短文本。"""

    if x is None:
        return "NA"

    if isinstance(x, str):
        return x

    value = safe_float(x)
    if value is None:
        return str(x)

    if abs(value) >= 1000:
        return f"{value:,.0f}"
    if abs(value) >= 100:
        return f"{value:.0f}"
    if abs(value) >= 10:
        return f"{value:.1f}"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))

    return f"{value:.2f}"


def fmt_pct(x: float) -> str:
    """把百分比格式化为短文本。"""

    return f"{x:.1f}%" if abs(x) >= 10 else f"{x:.2f}%"


def fmt_label(x: Any) -> str:
    """格式化类别标签，避免数值标签出现过长小数。"""

    return fmt(x) if is_number(x) else str(x)


def gini(values: Sequence[float]) -> Optional[float]:
    """计算非负数列的 Gini 系数，用于识别集中度和长尾。"""

    vals = sorted(v for v in values if v >= 0 and math.isfinite(v))
    n = len(vals)
    total = sum(vals)

    if n == 0 or total <= 0:
        return None

    weighted = sum((i + 1) * v for i, v in enumerate(vals))
    return (2 * weighted) / (n * total) - (n + 1) / n


def relative_change(start: float, end: float) -> Optional[float]:
    """计算相对变化率；起点过小时返回 None。"""

    if abs(start) <= 1e-12:
        return None
    return (end - start) / abs(start)


def sign_text(value: float, up: str = "上升", down: str = "下降", flat: str = "基本不变") -> str:
    """根据数值正负生成方向描述。"""

    if abs(value) < 1e-9:
        return flat
    return up if value > 0 else down


def iqr_bounds(values: pd.Series) -> Tuple[Optional[float], Optional[float], Optional[float]]:
    """计算 IQR 及基于 1.5IQR 的异常值上下界。"""

    clean = numeric_series(values).dropna()
    if len(clean) < 4:
        return None, None, None

    q1 = float(clean.quantile(0.25))
    q3 = float(clean.quantile(0.75))
    iqr = q3 - q1

    return iqr, q1 - 1.5 * iqr, q3 + 1.5 * iqr



def _plan_column_semantic(ctx: PlanContext, column: str) -> Dict[str, Any]:
    semantics = dict((dict(ctx.plan.get("semantics") or {}).get("columns") or {}))
    if column in semantics:
        return dict(semantics[column] or {})
    return infer_column_semantics(str(column))


def _metric_is_additive(ctx: PlanContext, column: str) -> bool:
    if str(column) == "count":
        return True
    return _plan_column_semantic(ctx, column).get("additive") is True


def _dominant_share(values: Sequence[float]) -> Optional[float]:
    if len(values) < 2 or any(not math.isfinite(v) or v < 0 for v in values):
        return None
    ordered = sorted(values, reverse=True)
    total = float(sum(ordered))
    if total <= 0 or abs(ordered[0] - ordered[1]) <= 1e-9:
        return None
    share = ordered[0] / total
    threshold = max(0.35, 1.0 / len(ordered) + 0.10)
    return share if share >= threshold else None

def group_duplicate_categories(
    work: pd.DataFrame,
    x: str,
    y: str,
    *,
    aggregation: str = "mean",
) -> pd.DataFrame:
    """Aggregate duplicate categories without assuming every metric is additive."""

    safe_work = safe_hashable_dataframe(work, [x])
    if safe_work[x].duplicated().any():
        agg = "sum" if aggregation == "sum" else "mean"
        return safe_work.groupby(x, dropna=False, as_index=False)[y].agg(agg)
    return safe_work


# -----------------------------------------------------------------------------
# Extractor：排名 / 分组数值比较
# -----------------------------------------------------------------------------

def describe_ranked_group_value(ctx: PlanContext) -> List[Observation]:
    """提取柱状/排序类图表中的排序、差距、集中度和长尾信息。"""

    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "group", "category")
    y = slot(slots, "y", "value", "metric", "count")

    if not x or not y or x not in df.columns or y not in df.columns:
        return []

    work = df[[x, y]].copy()
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])

    if work.empty:
        return []

    work = group_duplicate_categories(
        work, x, y, aggregation="sum" if _metric_is_additive(ctx, y) else "mean"
    )
    work = work.sort_values(y, ascending=False).reset_index(drop=True)

    values = [float(v) for v in work[y]]
    additive = _metric_is_additive(ctx, y)
    total = float(sum(values)) if additive and all(value >= 0 for value in values) else 0.0
    top = work.iloc[0]
    bottom = work.iloc[-1]
    obs: List[Observation] = []

    if len(work) == 1:
        return [
            emit(
                ctx,
                f"结果只包含一个 {x} 类别 {fmt_label(top[x])}，其 {y} 为 {fmt(top[y])}",
                "single_category",
                0.62,
                y,
            )
        ]

    obs.append(
        emit(
            ctx,
            f"按 {x} 比较 {y} 时，共覆盖 {len(work)} 个类别；"
            f"{fmt_label(top[x])} 最高，为 {fmt(top[y])}；"
            f"{fmt_label(bottom[x])} 最低，为 {fmt(bottom[y])}",
            "extreme",
            0.96,
            y,
        )
    )

    if len(work) >= 2:
        second = work.iloc[1]
        gap = float(top[y]) - float(second[y])

        if abs(float(second[y])) > 1e-12:
            ratio = float(top[y]) / float(second[y])
            if ratio >= 1.2 or gap != 0:
                obs.append(
                    emit(
                        ctx,
                        f"{fmt_label(top[x])} 相比第二位 {fmt_label(second[x])} 高 {fmt(gap)}，"
                        f"约为其 {fmt(ratio)} 倍",
                        "rank_gap",
                        0.92 if ratio >= 1.5 else 0.78,
                        y,
                    )
                )
        elif gap > 0:
            obs.append(
                emit(
                    ctx,
                    f"{fmt_label(top[x])} 相比第二位 {fmt_label(second[x])} 高 {fmt(gap)}",
                    "rank_gap",
                    0.82,
                    y,
                )
            )

    if len(work) >= 2 and total > 0:
        top_share = _dominant_share(values)
        top3_share = sum(values[: min(3, len(values))]) / total

        if top_share is not None:
            obs.append(
                emit(
                    ctx,
                    f"{fmt_label(top[x])} 单项占总量约 {fmt_pct(top_share * 100)}，头部集中明显",
                    "concentration",
                    0.91,
                    y,
                )
            )

        if len(work) >= 4 and top3_share >= 0.70:
            obs.append(
                emit(
                    ctx,
                    f"前三个类别合计占总量约 {fmt_pct(top3_share * 100)}，其余类别贡献相对有限",
                    "head_tail",
                    0.87,
                    y,
                )
            )

    g = gini(values) if additive else None
    if g is not None and len(work) >= 5:
        if g >= 0.55:
            obs.append(
                emit(
                    ctx,
                    f"{y} 的类别分布 Gini 系数约为 {fmt(g)}，长尾差异较强",
                    "distribution_shape",
                    0.84,
                    y,
                )
            )
        elif g <= 0.20:
            obs.append(
                emit(
                    ctx,
                    f"{y} 的类别分布 Gini 系数约为 {fmt(g)}，类别之间相对均衡",
                    "distribution_shape",
                    0.72,
                    y,
                )
            )

    median_v = float(pd.Series(values).median()) if values else 0.0
    if median_v > 0 and len(work) >= 4:
        high = work[work[y] >= 2 * median_v]
        low = work[work[y] <= 0.5 * median_v]

        if len(high) >= 1:
            obs.append(
                emit(
                    ctx,
                    f"有 {len(high)} 个类别的 {y} 不低于中位数的 2 倍，代表相对突出的高值组",
                    "head_tail",
                    0.74,
                    y,
                )
            )

        if len(low) >= max(2, len(work) // 4):
            obs.append(
                emit(
                    ctx,
                    f"有 {len(low)} 个类别的 {y} 不超过中位数的一半，尾部类别较多",
                    "head_tail",
                    0.70,
                    y,
                )
            )

    zero_count = int((work[y] == 0).sum())
    if len(work) >= 4 and zero_count / len(work) >= 0.25:
        obs.append(
            emit(
                ctx,
                f"{x} 中有 {zero_count}/{len(work)} 个类别的 {y} 为 0，分布较稀疏",
                "sparsity",
                0.76,
                y,
            )
        )

    return obs


# -----------------------------------------------------------------------------
# Extractor：时间趋势
# -----------------------------------------------------------------------------

def describe_time_trend(ctx: PlanContext) -> List[Observation]:
    """提取折线/面积图中的方向、峰谷、突变、波动和近期变化。"""

    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "time", "date")
    y = slot(slots, "y", "value", "metric")

    if not x or not y or x not in df.columns or y not in df.columns:
        return []

    work = df[[x, y]].copy()
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])

    if len(work) < 2:
        return []

    work = safe_hashable_dataframe(work, [x])
    parsed_time = safe_datetime_series(work[x])
    if parsed_time.notna().any():
        work = work.assign(_sort_time=parsed_time).sort_values(["_sort_time", x])
        sort_col = "_sort_time"
    else:
        work = work.sort_values(x)
        sort_col = x

    work = (
        work.groupby(x, dropna=False, as_index=False)
        .agg({y: "mean", sort_col: "first"})
        .sort_values(sort_col)
    )

    if len(work) < 2:
        return []

    values = list(work[y].astype(float))
    diffs = [values[i] - values[i - 1] for i in range(1, len(values))]
    first, last = work.iloc[0], work.iloc[-1]
    start, end = float(first[y]), float(last[y])
    delta = end - start
    obs: List[Observation] = []

    pct = relative_change(start, end)
    if abs(delta) < 1e-9:
        obs.append(
            emit(
                ctx,
                f"沿 {x} 从 {fmt_label(first[x])} 到 {fmt_label(last[x])}，"
                f"{y} 基本不变，均为 {fmt(end)}",
                "endpoint_change",
                0.72,
                y,
            )
        )
    elif pct is not None:
        direction = "上升" if delta > 0 else "下降"
        obs.append(
            emit(
                ctx,
                f"沿 {x} 从 {fmt_label(first[x])} 到 {fmt_label(last[x])}，"
                f"{y} 从 {fmt(start)} 到 {fmt(end)}，整体{direction} {fmt_pct(abs(pct) * 100)}",
                "endpoint_change",
                0.93,
                y,
            )
        )
    else:
        direction = "上升" if delta > 0 else "下降"
        obs.append(
            emit(
                ctx,
                f"沿 {x} 从 {fmt_label(first[x])} 到 {fmt_label(last[x])}，"
                f"{y} 从 {fmt(start)} 到 {fmt(end)}，整体{direction} {fmt(abs(delta))}",
                "endpoint_change",
                0.88,
                y,
            )
        )

    peak = work.loc[work[y].idxmax()]
    trough = work.loc[work[y].idxmin()]
    if peak.name != trough.name:
        obs.append(
            emit(
                ctx,
                f"{y} 的峰值出现在 {x}={fmt_label(peak[x])}，为 {fmt(peak[y])}；"
                f"低点出现在 {x}={fmt_label(trough[x])}，为 {fmt(trough[y])}",
                "peak_trough",
                0.90,
                y,
            )
        )

    if len(values) >= 3:
        increasing = all(values[i] <= values[i + 1] for i in range(len(values) - 1))
        decreasing = all(values[i] >= values[i + 1] for i in range(len(values) - 1))

        if increasing and not decreasing:
            obs.append(emit(ctx, f"{y} 在该范围内呈单调上升，折线方向一致", "shape", 0.82, y))
        elif decreasing and not increasing:
            obs.append(emit(ctx, f"{y} 在该范围内呈单调下降，折线方向一致", "shape", 0.82, y))
        else:
            turns = sum(
                1
                for i in range(1, len(values) - 1)
                if (values[i] - values[i - 1]) * (values[i + 1] - values[i]) < 0
            )
            if turns:
                obs.append(
                    emit(
                        ctx,
                        f"{y} 在该范围内出现 {turns} 次方向转折，趋势并非稳定单调",
                        "turning",
                        0.80,
                        y,
                    )
                )

    if diffs:
        max_up = max(diffs)
        max_down = min(diffs)

        if max_up > 0:
            idx = diffs.index(max_up) + 1
            obs.append(
                emit(
                    ctx,
                    f"最大单步上升发生在 {fmt_label(work.iloc[idx - 1][x])} 到 "
                    f"{fmt_label(work.iloc[idx][x])}，增加 {fmt(max_up)}",
                    "step_change",
                    0.86,
                    y,
                )
            )

        if max_down < 0:
            idx = diffs.index(max_down) + 1
            obs.append(
                emit(
                    ctx,
                    f"最大单步下降发生在 {fmt_label(work.iloc[idx - 1][x])} 到 "
                    f"{fmt_label(work.iloc[idx][x])}，减少 {fmt(abs(max_down))}",
                    "step_change",
                    0.86,
                    y,
                )
            )

        latest = diffs[-1]
        if abs(latest) > 1e-9:
            obs.append(
                emit(
                    ctx,
                    f"最近一个时间步的 {y} {sign_text(latest)} {fmt(abs(latest))}",
                    "recent_change",
                    0.73,
                    y,
                )
            )

    mean_abs = sum(abs(v) for v in values) / len(values)
    value_range = max(values) - min(values)
    if mean_abs > 1e-9 and len(values) >= 4:
        rel_range = value_range / mean_abs

        if rel_range >= 1.0:
            obs.append(
                emit(
                    ctx,
                    f"{y} 的峰谷差为 {fmt(value_range)}，相对均值波动幅度较大",
                    "volatility",
                    0.78,
                    y,
                )
            )
        elif rel_range <= 0.10:
            obs.append(
                emit(
                    ctx,
                    f"{y} 的峰谷差为 {fmt(value_range)}，相对均值波动较小",
                    "volatility",
                    0.62,
                    y,
                )
            )

    return obs


# -----------------------------------------------------------------------------
# Extractor：双变量关系
# -----------------------------------------------------------------------------

def describe_relationship(ctx: PlanContext) -> List[Observation]:
    """提取散点图中的相关方向、强度、斜率、非线性迹象和残差异常点。"""

    df, slots = ctx.df, ctx.slots
    x = slot(slots, "x", "x_metric")
    y = slot(slots, "y", "y_metric")

    if not x or not y or x not in df.columns or y not in df.columns:
        return []

    work = df[[x, y]].copy()
    work[x] = numeric_series(work[x])
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[x, y])

    if len(work) < 3:
        return []

    pearson = work[x].corr(work[y], method="pearson")
    spearman = work[x].corr(work[y], method="spearman")

    if pearson is None or math.isnan(float(pearson)):
        return []

    abs_corr = abs(float(pearson))
    strength = "较强" if abs_corr >= 0.7 else "中等" if abs_corr >= 0.4 else "较弱"
    direction = "正相关" if pearson > 0 else "负相关"

    obs = [
        emit(
            ctx,
            f"{x} 与 {y} 呈{strength}{direction}关系，Pearson 相关系数约为 {fmt(pearson)}",
            "correlation",
            0.92 if abs_corr >= 0.4 else 0.70,
            y,
        )
    ]

    if spearman is not None and not math.isnan(float(spearman)):
        if abs(float(spearman) - float(pearson)) >= 0.25:
            obs.append(
                emit(
                    ctx,
                    f"Spearman 秩相关约为 {fmt(spearman)}，与 Pearson 差异较大，"
                    "可能存在非线性或极端值影响",
                    "nonlinear_signal",
                    0.82,
                    y,
                )
            )
        else:
            obs.append(
                emit(
                    ctx,
                    f"Spearman 秩相关约为 {fmt(spearman)}，方向与 Pearson 基本一致",
                    "correlation",
                    0.66,
                    y,
                )
            )

    xv = work[x].astype(float)
    yv = work[y].astype(float)
    x_var = float(xv.var(ddof=0))

    if x_var > 1e-12:
        slope = float(((xv - xv.mean()) * (yv - yv.mean())).mean() / x_var)
        intercept = float(yv.mean() - slope * xv.mean())
        obs.append(
            emit(
                ctx,
                f"简单线性拟合下，{x} 每增加 1 个单位，{y} 平均变化约 {fmt(slope)}",
                "slope",
                0.74,
                y,
            )
        )

        residuals = yv - (slope * xv + intercept)
        resid_std = float(residuals.std(ddof=0))
        if resid_std > 1e-12 and len(work) >= 8:
            outlier_count = int((residuals.abs() > 2.5 * resid_std).sum())
            if outlier_count:
                obs.append(
                    emit(
                        ctx,
                        f"按线性拟合残差看，有 {outlier_count} 个观测点偏离主趋势较明显",
                        "outlier",
                        0.76,
                        y,
                    )
                )

    top_y = work.loc[work[y].idxmax()]
    obs.append(
        emit(
            ctx,
            f"{y} 的最高观测值为 {fmt(top_y[y])}，对应 {x}={fmt_label(top_y[x])}",
            "extreme",
            0.68,
            y,
        )
    )

    return obs


# -----------------------------------------------------------------------------
# Extractor：分组分布
# -----------------------------------------------------------------------------

def describe_group_distribution(ctx: PlanContext) -> List[Observation]:
    """提取箱线/小提琴图中的组间差异、离散度、重叠和异常点。"""

    df, slots = ctx.df, ctx.slots
    group = slot(slots, "x", "group", "category")
    y = slot(slots, "y", "value", "metric")

    if not group or not y or group not in df.columns or y not in df.columns:
        return []

    work = df[[group, y]].copy()
    work[y] = numeric_series(work[y])
    work = work.dropna(subset=[group, y])

    if work.empty:
        return []

    safe_work = safe_hashable_dataframe(work, [group])
    summary = (
        safe_work.groupby(group)[y]
        .agg(["median", "mean", "count", "min", "max"])
        .sort_values("median", ascending=False)
    )

    if summary.empty:
        return []

    q1 = safe_work.groupby(group)[y].quantile(0.25)
    q3 = safe_work.groupby(group)[y].quantile(0.75)
    summary["q1"] = q1
    summary["q3"] = q3
    summary["iqr"] = summary["q3"] - summary["q1"]
    summary["range"] = summary["max"] - summary["min"]

    obs: List[Observation] = []

    if len(summary) == 1:
        only = summary.index[0]
        obs.append(
            emit(
                ctx,
                f"当前 support_df 中 {group} 只覆盖 {fmt_label(only)}，"
                f"其 {y} 中位数为 {fmt(summary.loc[only, 'median'])}，"
                f"IQR 为 {fmt(summary.loc[only, 'iqr'])}",
                "distribution",
                0.65,
                y,
            )
        )
    else:
        top = summary.index[0]
        bottom = summary.index[-1]
        gap = float(summary.iloc[0]["median"] - summary.iloc[-1]["median"])

        obs.append(
            emit(
                ctx,
                f"按 {group} 分组看 {y} 的分布，共覆盖 {len(summary)} 组；"
                f"{fmt_label(top)} 的中位数最高，为 {fmt(summary.loc[top, 'median'])}；"
                f"{fmt_label(bottom)} 最低，为 {fmt(summary.loc[bottom, 'median'])}",
                "median_contrast",
                0.94,
                y,
            )
        )

        obs.append(
            emit(
                ctx,
                f"最高组与最低组的 {y} 中位数差距为 {fmt(gap)}",
                "median_gap",
                0.82,
                y,
            )
        )

        if summary.loc[top, "q1"] > summary.loc[bottom, "q3"]:
            obs.append(
                emit(
                    ctx,
                    f"最高中位数组 {fmt_label(top)} 的下四分位数仍高于最低组 "
                    f"{fmt_label(bottom)} 的上四分位数，IQR 区间基本不重叠",
                    "separation",
                    0.88,
                    y,
                )
            )
        elif summary.loc[top, "q1"] <= summary.loc[bottom, "q3"]:
            obs.append(
                emit(
                    ctx,
                    "最高组与最低组的 IQR 区间存在重叠，组间差异需要结合离散程度理解",
                    "overlap",
                    0.66,
                    y,
                )
            )

    spread = summary["range"].sort_values(ascending=False)
    if not spread.empty and spread.iloc[0] > 0:
        sg = spread.index[0]
        obs.append(
            emit(
                ctx,
                f"{fmt_label(sg)} 组内 {y} 的范围最大，从 "
                f"{fmt(summary.loc[sg, 'min'])} 到 {fmt(summary.loc[sg, 'max'])}",
                "spread",
                0.80,
                y,
            )
        )

    iqr_rank = summary["iqr"].dropna().sort_values(ascending=False)
    if not iqr_rank.empty and iqr_rank.iloc[0] > 0:
        ig = iqr_rank.index[0]
        obs.append(
            emit(
                ctx,
                f"{fmt_label(ig)} 的 IQR 最大，约为 {fmt(summary.loc[ig, 'iqr'])}，组内离散程度最高",
                "spread",
                0.77,
                y,
            )
        )

    counts = summary["count"].sort_values(ascending=False)
    if len(counts) >= 2 and counts.iloc[-1] > 0 and counts.iloc[0] / counts.iloc[-1] >= 3:
        obs.append(
            emit(
                ctx,
                f"各组样本量不均衡：{fmt_label(counts.index[0])} 有 {fmt(counts.iloc[0])} 条，"
                f"{fmt_label(counts.index[-1])} 仅有 {fmt(counts.iloc[-1])} 条",
                "sample_balance",
                0.72,
                y,
            )
        )

    outlier_total = 0
    outlier_groups = []
    for group_value, sub in safe_work.groupby(group):
        iqr, low, high = iqr_bounds(sub[y])
        if iqr is None or low is None or high is None or iqr <= 0:
            continue

        n = int(((sub[y] < low) | (sub[y] > high)).sum())
        if n:
            outlier_total += n
            outlier_groups.append((group_value, n))

    if outlier_total:
        head = "、".join(f"{fmt_label(g)}({n})" for g, n in outlier_groups[:3])
        obs.append(
            emit(
                ctx,
                f"按 1.5IQR 规则，检测到 {outlier_total} 个潜在异常点，主要出现在 {head}",
                "outlier",
                0.76,
                y,
            )
        )

    return obs


# -----------------------------------------------------------------------------
# Extractor：矩阵 / 热力图
# -----------------------------------------------------------------------------

def describe_matrix_contrast(ctx: PlanContext) -> List[Observation]:
    """提取热力图/矩阵中的热点、行列主导和稀疏性。"""

    df, slots = ctx.df, ctx.slots
    row = slot(slots, "row", "y", "group")
    col = slot(slots, "col", "x", "category")
    value = slot(slots, "value", "metric", "count")

    if not row or not col or not value:
        return []
    if row not in df.columns or col not in df.columns or value not in df.columns:
        return []

    work = df[[row, col, value]].copy()
    work[value] = numeric_series(work[value])
    work = work.dropna(subset=[row, col, value])

    if work.empty:
        return []

    if work.duplicated(subset=[row, col]).any():
        safe_work = safe_hashable_dataframe(work, [row, col])
        work = safe_work.groupby([row, col], dropna=False, as_index=False)[value].sum()

    top = work.loc[work[value].idxmax()]
    bottom = work.loc[work[value].idxmin()]

    obs = [
        emit(
            ctx,
            f"在 {row} × {col} 的组合中，{fmt_label(top[row])} / {fmt_label(top[col])} 的 "
            f"{value} 最高，为 {fmt(top[value])}；"
            f"{fmt_label(bottom[row])} / {fmt_label(bottom[col])} 最低，为 {fmt(bottom[value])}",
            "hotspot",
            0.94,
            value,
        )
    ]

    total = float(work[value].sum())
    if total > 0:
        top_share = float(top[value]) / total

        if top_share >= 0.25:
            obs.append(
                emit(
                    ctx,
                    f"最高单元格占矩阵总量约 {fmt_pct(top_share * 100)}，局部集中度较高",
                    "concentration",
                    0.84,
                    value,
                )
            )

        safe_work = safe_hashable_dataframe(work, [row, col])
        row_sum = safe_work.groupby(row)[value].sum().sort_values(ascending=False)
        col_sum = safe_work.groupby(col)[value].sum().sort_values(ascending=False)

        if len(row_sum) >= 2:
            obs.append(
                emit(
                    ctx,
                    f"按 {row} 汇总，{fmt_label(row_sum.index[0])} 最高，为 {fmt(row_sum.iloc[0])}；"
                    f"{fmt_label(row_sum.index[-1])} 最低，为 {fmt(row_sum.iloc[-1])}",
                    "row_dominance",
                    0.80,
                    value,
                )
            )

        if len(col_sum) >= 2:
            obs.append(
                emit(
                    ctx,
                    f"按 {col} 汇总，{fmt_label(col_sum.index[0])} 最高，为 {fmt(col_sum.iloc[0])}；"
                    f"{fmt_label(col_sum.index[-1])} 最低，为 {fmt(col_sum.iloc[-1])}",
                    "column_dominance",
                    0.80,
                    value,
                )
            )

    zero_count = int((work[value] == 0).sum())
    if len(work) >= 6 and zero_count / len(work) >= 0.30:
        obs.append(
            emit(
                ctx,
                f"矩阵中有 {zero_count}/{len(work)} 个单元格为 0，组合分布较稀疏",
                "sparsity",
                0.74,
                value,
            )
        )

    return obs


EXTRACTORS = {
    "ranked_group_value": describe_ranked_group_value,
    "time_trend": describe_time_trend,
    "relationship": describe_relationship,
    "group_distribution": describe_group_distribution,
    "matrix_contrast": describe_matrix_contrast,
}
