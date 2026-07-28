"""chart/renderer.py
-------------------

图表层唯一主入口：给定 evidence_layer 已选中的 VisualPlan，执行显式 transform 并渲染图像。
renderer 不参与计划生成、过滤或效用估计；任何异常都安全返回，不中断主流程。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict

import matplotlib.pyplot as plt
import pandas as pd

from .specs import is_supported_chart
from .transforms import apply_transform_ops
from vis_project_utils.utils import preview_records, sanitize_filename, shorten_label
from vis_project_utils.dataframe_safety import safe_hashable_dataframe


def render_visual_plan(plan: Dict[str, Any], source_df: pd.DataFrame, output_path: str | Path) -> Dict[str, Any]:
    """执行并渲染一个已选视觉计划。"""
    output_path = Path(output_path)
    try:
        chart_type = str((plan.get("encoding") or {}).get("chart_type") or "")
        if not is_supported_chart(chart_type):
            raise ValueError(f"unsupported chart_type: {chart_type}")
        support_df = apply_transform_ops(source_df, list((plan.get("transform") or {}).get("ops") or []))
        if support_df.empty:
            raise ValueError("support dataframe is empty after transforms")
        slots = dict((plan.get("encoding") or {}).get("slots") or {})
        output_path.parent.mkdir(parents=True, exist_ok=True)
        _render_chart(support_df, chart_type, slots, str(plan.get("title") or ""), output_path)
        return {
            "success": True,
            "chart_path": str(output_path),
            "support_shape": [int(support_df.shape[0]), int(support_df.shape[1])],
            "support_preview": preview_records(support_df, max_rows=8, max_cols=8),
            "render_metadata": {"chart_type": chart_type, "slots": slots},
            "error": "",
        }
    except Exception as exc:
        return {"success": False, "chart_path": "", "support_shape": [0, 0], "support_preview": [], "render_metadata": {}, "error": str(exc)}
    finally:
        plt.close("all")


def _render_chart(df: pd.DataFrame, chart_type: str, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    if chart_type == "bar":
        _render_bar(df, slots, title, output_path)
    elif chart_type == "line":
        _render_line(df, slots, title, output_path)
    elif chart_type == "scatter":
        _render_scatter(df, slots, title, output_path)
    elif chart_type == "boxplot":
        _render_boxplot(df, slots, title, output_path)
    elif chart_type == "heatmap":
        _render_heatmap(df, slots, title, output_path)
    else:
        raise ValueError(f"unsupported chart_type: {chart_type}")


def _render_bar(df: pd.DataFrame, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    _require_columns(df, [x, y])
    plot_df = df[[x, y]].dropna().copy()
    labels = [shorten_label(item) for item in plot_df[x].astype(str).tolist()]
    fig_width = max(6.5, min(12.0, 0.45 * max(1, len(plot_df)) + 4.5))
    fig, ax = plt.subplots(figsize=(fig_width, 4.8))
    ax.bar(labels, pd.to_numeric(plot_df[y], errors="coerce"))
    ax.set_xlabel(x)
    ax.set_ylabel(y)
    ax.set_title(title or f"{y} by {x}")
    ax.tick_params(axis="x", rotation=35)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160, bbox_inches="tight")


def _render_line(df: pd.DataFrame, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    group = str(slots.get("group") or "")
    _require_columns(df, [x, y])
    fig, ax = plt.subplots(figsize=(7.2, 4.8))
    plot_df = df[[col for col in [x, y, group] if col]].dropna(subset=[x, y]).copy()
    if group and group in plot_df.columns:
        grouped_df = safe_hashable_dataframe(plot_df, [group])
        for label, part in grouped_df.groupby(group, dropna=False):
            ax.plot(part[x].astype(str), pd.to_numeric(part[y], errors="coerce"), marker="o", label=shorten_label(label, 22))
        ax.legend(fontsize=8)
    else:
        ax.plot(plot_df[x].astype(str), pd.to_numeric(plot_df[y], errors="coerce"), marker="o")
    ax.set_xlabel(x)
    ax.set_ylabel(y)
    ax.set_title(title or f"{y} over {x}")
    ax.tick_params(axis="x", rotation=35)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160, bbox_inches="tight")


def _render_scatter(df: pd.DataFrame, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    _require_columns(df, [x, y])
    fig, ax = plt.subplots(figsize=(6.4, 4.8))
    ax.scatter(pd.to_numeric(df[x], errors="coerce"), pd.to_numeric(df[y], errors="coerce"), alpha=0.75)
    ax.set_xlabel(x)
    ax.set_ylabel(y)
    ax.set_title(title or f"{y} vs {x}")
    fig.tight_layout()
    fig.savefig(output_path, dpi=160, bbox_inches="tight")


def _render_boxplot(df: pd.DataFrame, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    _require_columns(df, [x, y])
    groups = []
    labels = []
    grouped_df = safe_hashable_dataframe(df, [x])
    for label, part in grouped_df.groupby(x, dropna=False):
        values = pd.to_numeric(part[y], errors="coerce").dropna()
        if len(values):
            groups.append(values)
            labels.append(shorten_label(label))
    if not groups:
        raise ValueError("no numeric data for boxplot")
    fig, ax = plt.subplots(figsize=(7.2, 4.8))
    ax.boxplot(groups, labels=labels)
    ax.set_xlabel(x)
    ax.set_ylabel(y)
    ax.set_title(title or f"Distribution of {y} by {x}")
    ax.tick_params(axis="x", rotation=35)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160, bbox_inches="tight")


def _render_heatmap(df: pd.DataFrame, slots: Dict[str, Any], title: str, output_path: Path) -> None:
    x = str(slots.get("x") or "")
    y = str(slots.get("y") or "")
    value = str(slots.get("value") or "")
    _require_columns(df, [x, y, value])
    pivot_df = safe_hashable_dataframe(df, [x, y])
    matrix = pivot_df.pivot_table(index=y, columns=x, values=value, aggfunc="mean")
    fig, ax = plt.subplots(figsize=(7.0, 5.2))
    im = ax.imshow(matrix.fillna(0).values, aspect="auto")
    ax.set_xticks(range(len(matrix.columns)))
    ax.set_yticks(range(len(matrix.index)))
    ax.set_xticklabels([shorten_label(item) for item in matrix.columns], rotation=35, ha="right")
    ax.set_yticklabels([shorten_label(item) for item in matrix.index])
    ax.set_title(title or f"{value} by {x} and {y}")
    fig.colorbar(im, ax=ax)
    fig.tight_layout()
    fig.savefig(output_path, dpi=160, bbox_inches="tight")


def _require_columns(df: pd.DataFrame, columns) -> None:
    missing = [col for col in columns if col and col not in df.columns]
    if missing:
        raise KeyError(f"missing columns for rendering: {missing}")
