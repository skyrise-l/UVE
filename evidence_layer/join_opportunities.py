"""Schema-grounded join opportunities and conservative join probes for BIRD.

The module deliberately separates two concepts:

* join opportunities: unexecuted schema relationships that may help question generation;
* join probes: small, actually computed support tables used only for exploration evidence.

BIRD primary/foreign-key metadata is authoritative. InsightBench tasks do not use this
module and keep their existing runtime/schema inference behavior.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import re
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

import numpy as np
import pandas as pd
from pandas.api.types import is_numeric_dtype, is_string_dtype

from evidence_layer.visual_semantics import build_table_column_semantics, normalize_name
from vis_project_utils.dataframe_safety import safe_nunique
from vis_project_utils.utils import clip01, safe_to_numeric, truncate_text


_TOKEN_RE = re.compile(r"[a-z][a-z0-9]{2,}|[\u4e00-\u9fff]{2,}")
_STOPWORDS = {
    "the", "and", "for", "with", "from", "that", "this", "into", "over", "across",
    "which", "what", "where", "when", "how", "does", "are", "is", "to", "of", "in",
    "by", "on", "a", "an", "data", "table", "records", "record", "analysis", "analyze",
    "find", "identify", "explore", "compare", "relationship", "relationships",
}


def _config_value(mapping: Mapping[str, Any], key: str, default: Any) -> Any:
    """Return configured values without treating explicit zero as missing."""
    value = dict(mapping or {}).get(key, default)
    return default if value is None else value


@dataclass(frozen=True)
class JoinEdge:
    child_table: str
    child_columns: Tuple[str, ...]
    parent_table: str
    parent_columns: Tuple[str, ...]

    @property
    def composite(self) -> bool:
        return len(self.child_columns) > 1

    @property
    def signature(self) -> str:
        left = ",".join(self.child_columns)
        right = ",".join(self.parent_columns)
        return f"{self.child_table}({left})->{self.parent_table}({right})"


@dataclass(frozen=True)
class JoinPath:
    tables: Tuple[str, ...]
    edges: Tuple[JoinEdge, ...]

    @property
    def hops(self) -> int:
        return len(self.edges)

    @property
    def composite(self) -> bool:
        return any(edge.composite for edge in self.edges)

    @property
    def signature(self) -> str:
        parts = [edge.signature for edge in self.edges]
        forward = "|".join(parts)
        reverse = "|".join(reversed(parts))
        return min(forward, reverse)


@dataclass
class JoinProbe:
    tid: str
    dataframe: pd.DataFrame
    metadata: Dict[str, Any]
    path: JoinPath
    title: str
    evidence_note: str
    coverage: float
    signature: str
    context: Dict[str, Any] = field(default_factory=dict)


class JoinOpportunityEngine:
    """Build BIRD-only join opportunities and safe, small exploration probes."""

    def __init__(self, task: Any, config: Optional[Mapping[str, Any]] = None) -> None:
        self.task = task
        self.config = dict(config or {})
        join_config = dict(self.config.get("join_exploration") or {})
        self.enabled = bool(join_config.get("enabled", True)) and _is_bird_task(task)
        self.max_hops = max(1, min(2, int(_config_value(join_config, "max_hops", 2))))
        self.root_max_opportunities = max(0, int(_config_value(join_config, "root_max_opportunities", 3)))
        self.supplemental_max_opportunities = max(
            0, int(_config_value(join_config, "supplemental_max_opportunities", 1))
        )
        self.max_probe_paths = max(0, int(_config_value(join_config, "max_probe_paths", 2)))
        self.min_join_coverage = float(_config_value(join_config, "min_join_coverage", 0.20))
        self.max_probe_groups = max(4, int(_config_value(join_config, "max_probe_groups", 20)))
        self.max_grain_rows = max(1000, int(_config_value(join_config, "max_grain_rows", 1_500_000)))
        self.initialization_error = ""

        try:
            raw_tables = list(getattr(task, "all_tables", lambda: [])() or [])
        except Exception as exc:
            raw_tables = []
            self.initialization_error = f"table_enumeration_failed: {str(exc)[:800]}"
        self.tables = {
            str(getattr(table, "name", "") or ""): table
            for table in raw_tables
            if str(getattr(table, "name", "") or "")
        }
        try:
            self.edges = _build_edges(self.tables)
            self.adjacency = _build_adjacency(self.edges)
            self.table_terms = {name: _table_terms(table) for name, table in self.tables.items()}
        except Exception as exc:
            # Join exploration is optional; malformed metadata should disable it rather
            # than preventing the underlying EDA task from running.  Keep the reason so
            # the main audit can distinguish "no join available" from silent failure.
            self.edges = []
            self.adjacency = {}
            self.table_terms = {}
            detail = f"join_metadata_initialization_failed: {str(exc)[:800]}"
            self.initialization_error = "; ".join(
                value for value in (self.initialization_error, detail) if value
            )
        self.last_probe_audit: List[Dict[str, Any]] = []
        self._last_probe_failure_reason = ""

    def available(self) -> bool:
        return bool(self.enabled and self.edges and self.tables)

    def resolve_connection(self, table_names: Sequence[str]) -> Optional[Dict[str, Any]]:
        """为一组业务表返回最短且安全的声明连接上下文。

        输入是 retrieval frontier 已选中的真实表名；输出只保留下游生成卡片和
        中央管理器真正会使用的路径、粒度、键说明与安全边界。连接不可用或会形成
        明显不安全的 many-to-many 形状时返回 ``None``。
        """
        resolved = _resolve_table_names(table_names or [], self.tables)
        required = tuple(dict.fromkeys(resolved))
        if len(required) <= 1:
            return {}
        if not self.available() or len(required) > self.max_hops + 1:
            return None

        paths = _enumerate_paths(
            tables=set(self.tables),
            adjacency=self.adjacency,
            max_hops=self.max_hops,
            seed_tables=[required[0]],
        )
        required_set = set(required)
        candidates = [
            path
            for path in paths
            if required_set.issubset(set(path.tables))
            and (_safe_path_shape(path) or _is_shared_parent_sibling_path(path))
        ]
        if not candidates:
            return None
        candidates.sort(key=lambda path: (path.hops, path.signature))
        path = candidates[0]
        grain_plan = _path_grain_plan(path)
        if grain_plan is not None:
            grain_table = str(grain_plan[0])
        elif _is_shared_parent_sibling_path(path):
            # 两个明细表通过共同父表连接时，不能做原始行级 Join；先分别聚合到
            # 共同父表粒度后再比较。该形式正是 retrieval 跨表组合常见的安全用法。
            grain_table = str(path.tables[1])
        else:
            return None

        edge_summaries = [
            f"{edge.child_table}[{', '.join(edge.child_columns)}] -> "
            f"{edge.parent_table}[{', '.join(edge.parent_columns)}]"
            for edge in path.edges
        ]
        return {
            "status": "unexecuted",
            "signature": path.signature,
            "path_text": " -> ".join(path.tables),
            "hop_count": int(path.hops),
            "grain_table": grain_table,
            "edge_summaries": edge_summaries,
            "safe_use": _path_usage_note(path),
        }

    # ------------------------------------------------------------------
    # Root / supplemental opportunity cards
    # ------------------------------------------------------------------

    def root_opportunity_text(self, *, max_cards: Optional[int] = None) -> str:
        if not self.available():
            return ""
        limit = self.root_max_opportunities if max_cards is None else max(0, int(max_cards))
        if limit <= 0:
            return ""
        anchor = _task_anchor_text(self.task, None)
        paths = self.rank_paths(
            anchor_text=anchor,
            seed_tables=self._root_seed_tables(anchor),
            prefer_complex=True,
            purpose="root",
            max_paths=limit,
        )
        return "\n\n".join(self._format_opportunity(path, anchor, index + 1) for index, path in enumerate(paths))

    def supplemental_candidates(
        self,
        *,
        evidence_profile: Optional[Mapping[str, Any]],
        seed_tables: Sequence[str],
        exclude_signatures: Set[str] | None = None,
        max_cards: Optional[int] = None,
    ) -> List[Dict[str, Any]]:
        if not self.available():
            return []
        resolved_seeds = _resolve_table_names(seed_tables or [], self.tables)
        if not resolved_seeds:
            return []
        limit = self.supplemental_max_opportunities if max_cards is None else max(0, int(max_cards))
        if limit <= 0:
            return []
        anchor = _task_anchor_text(self.task, evidence_profile)
        paths = self.rank_paths(
            anchor_text=anchor,
            seed_tables=resolved_seeds,
            prefer_complex=True,
            purpose="supplemental",
            max_paths=max(limit * 3, limit),
        )
        excluded = set(exclude_signatures or set())
        result: List[Dict[str, Any]] = []
        for path in paths:
            if path.signature in excluded:
                continue
            text = self._format_opportunity(path, anchor, len(result) + 1)
            candidate_columns = self._candidate_columns(path, anchor)
            path_text = " -> ".join(path.tables)
            added_columns = self._newly_available_columns(
                path,
                anchor_text=anchor,
                seed_tables=resolved_seeds,
            )
            result.append({
                "id": f"join_opportunity_{_short_hash(path.signature)}",
                "kind": "join_opportunity",
                "title": "Schema-grounded join opportunity",
                "evidence": truncate_text(text, 1000),
                "available_direction": f"Test the declared join path {path_text}",
                "why_it_may_matter": (
                    "The related tables may add goal-relevant attributes that are absent "
                    "from the current table-level result."
                ),
                "concrete_analysis": (
                    f"Join {path_text} using every declared key column, preserve the seed-table grain, "
                    f"report match coverage, and then analyze {', '.join(added_columns) if added_columns else 'the non-key joined attributes'}. "
                    f"{_path_usage_note(path)}"
                ),
                "columns": candidate_columns,
                "join_context": self._path_context(
                    path,
                    anchor_text=anchor,
                    seed_tables=resolved_seeds,
                    added_columns=added_columns,
                    status="unexecuted",
                ),
                "utility": round(
                    0.30
                    + 0.25
                    * self.path_score(
                        path,
                        anchor_text=anchor,
                        seed_tables=resolved_seeds,
                        purpose="supplemental",
                    ),
                    6,
                ),
                "signature": path.signature,
            })
            if len(result) >= limit:
                break
        return result

    def _path_context(
        self,
        path: JoinPath,
        *,
        anchor_text: str,
        seed_tables: Sequence[str],
        added_columns: Optional[Sequence[str]] = None,
        status: str,
        coverage: Optional[float] = None,
        category_choices: Sequence[Tuple[str, str]] = (),
        metric_column: str = "",
    ) -> Dict[str, Any]:
        """Build compact structured metadata for downstream BIRD evidence formatting."""
        grain_plan = _path_grain_plan(path)
        grain_table = grain_plan[0] if grain_plan else ""
        dimension_tables = list(grain_plan[1]) if grain_plan else []
        resolved_seed = next((name for name in path.tables if name in set(seed_tables or [])), "")
        edge_summaries = []
        edges = []
        for edge in path.edges:
            child_cols = list(edge.child_columns)
            parent_cols = list(edge.parent_columns)
            edge_summaries.append(
                f"{edge.child_table}[{', '.join(child_cols)}] -> "
                f"{edge.parent_table}[{', '.join(parent_cols)}]"
            )
            edges.append({
                "child_table": edge.child_table,
                "child_columns": child_cols,
                "parent_table": edge.parent_table,
                "parent_columns": parent_cols,
                "composite": bool(edge.composite),
            })
        chosen_columns = [
            f"{table}.{column}" for table, column in list(category_choices or [])
        ]
        return {
            "status": str(status or ""),
            "signature": path.signature,
            "seed_table": resolved_seed,
            "path_tables": list(path.tables),
            "path_text": " -> ".join(path.tables),
            "hop_count": int(path.hops),
            "grain_table": grain_table,
            "dimension_tables": dimension_tables,
            "edge_summaries": edge_summaries,
            "edges": edges,
            "added_columns": list(added_columns or self._potential_columns(path, anchor_text))[:6],
            "selected_joined_dimensions": chosen_columns,
            "metric_column": str(metric_column or "joined_record_count"),
            "safe_use": _path_usage_note(path),
            **({"coverage": float(coverage)} if coverage is not None else {}),
        }

    def _format_opportunity(self, path: JoinPath, anchor_text: str, index: int) -> str:
        relation_lines = []
        for edge in path.edges:
            child = ", ".join(edge.child_columns)
            parent = ", ".join(edge.parent_columns)
            suffix = " (composite key; use every column together)" if edge.composite else ""
            relation_lines.append(
                f"- {edge.child_table}[{child}] references {edge.parent_table}[{parent}]{suffix}"
            )
        added_columns = self._potential_columns(path, anchor_text)
        complexity = []
        if path.hops == 2:
            complexity.append("two-hop")
        if path.composite:
            complexity.append("composite-key")
        complexity_text = ", ".join(complexity) or "direct"
        return "\n".join([
            f"[Join opportunity {index}] Path: {' -> '.join(path.tables)}",
            f"Structural note: {complexity_text} relationship selected because it may be easy to overlook.",
            "Declared relationships:",
            *relation_lines,
            f"Potentially useful non-key columns: {', '.join(added_columns) if added_columns else 'inspect the joined schemas'}",
            f"Safe-use note: {_path_usage_note(path)}",
            "Status: schema-grounded possibility only; it does not establish any empirical finding or guarantee relevance.",
        ])

    # ------------------------------------------------------------------
    # Path retrieval / ranking
    # ------------------------------------------------------------------

    def rank_paths(
        self,
        *,
        anchor_text: str,
        seed_tables: Optional[Sequence[str]],
        prefer_complex: bool,
        max_paths: int,
        purpose: str = "root",
        safe_only: bool = False,
    ) -> List[JoinPath]:
        if not self.available() or max_paths <= 0:
            return []
        seeds = _resolve_table_names(seed_tables or [], self.tables)
        paths = _enumerate_paths(
            tables=set(self.tables),
            adjacency=self.adjacency,
            max_hops=self.max_hops,
            seed_tables=seeds or None,
        )
        if safe_only:
            paths = [path for path in paths if _safe_path_shape(path)]
        # Root cards intentionally surface hard-to-discover paths first. Simple direct
        # joins are used only as fallback; the LLM already sees the full schema and
        # relationship text and can discover obvious joins itself.
        if prefer_complex:
            complex_paths = [path for path in paths if path.hops == 2 or path.composite]
            simple_paths = [path for path in paths if path not in complex_paths]
        else:
            complex_paths, simple_paths = paths, []

        ranked_complex = sorted(
            complex_paths,
            key=lambda path: (
                -self.path_score(
                    path,
                    anchor_text=anchor_text,
                    seed_tables=seeds,
                    purpose=purpose,
                ),
                path.signature,
            ),
        )
        ranked_simple = sorted(
            simple_paths,
            key=lambda path: (
                -self.path_score(
                    path,
                    anchor_text=anchor_text,
                    seed_tables=seeds,
                    purpose=purpose,
                ),
                path.signature,
            ),
        )

        # Structural strategy remains primary. Lexical retrieval only affects ranking;
        # it never acts as an authoritative filter because this project is not a
        # retrieval benchmark and schema wording can be incomplete.
        ordered = ranked_complex + ranked_simple

        deduped: List[JoinPath] = []
        seen_signatures: Set[str] = set()
        for path in ordered:
            if path.signature in seen_signatures:
                continue
            seen_signatures.add(path.signature)
            deduped.append(path)
            if len(deduped) >= max_paths:
                break
        return deduped

    def path_score(
        self,
        path: JoinPath,
        *,
        anchor_text: str,
        seed_tables: Sequence[str] | None = None,
        purpose: str = "root",
    ) -> float:
        anchor_terms = _terms(anchor_text)
        seeds = set(_resolve_table_names(seed_tables or [], self.tables))
        semantic = self._path_semantic_score(path, anchor_terms, seed_tables=seeds)
        seed_bonus = 0.10 if seeds and path.tables[0] in seeds else 0.0
        mode = str(purpose or "root").lower()

        if mode == "probe":
            # Executed probes should prefer safe, relevant and shorter paths.  Structural
            # complexity is useful for root hints, but it should not by itself make a
            # riskier two-hop probe outrank a direct declared relationship.
            structural = 0.18 if path.hops == 1 else 0.06
            if path.composite:
                structural += 0.08
            if _safe_path_shape(path):
                structural += 0.10
            return clip01(structural + 0.52 * semantic + seed_bonus)

        if mode == "supplemental":
            structural = 0.22 if path.hops == 2 else 0.08
            if path.composite:
                structural += 0.20
            if path.hops == 2 and len(set(path.tables)) == 3:
                structural += 0.05
            return clip01(structural + 0.36 * semantic + seed_bonus)

        # Root cards intentionally emphasize relationships that are easy to overlook.
        # Retrieval remains only a secondary tie-breaker.
        structural = 0.42 if path.hops == 2 else 0.12
        if path.composite:
            structural += 0.34
        if path.hops == 2 and len(set(path.tables)) == 3:
            structural += 0.08
        return clip01(structural + 0.24 * semantic + seed_bonus)

    def _root_seed_tables(self, anchor_text: str) -> List[str]:
        """Use lexical matching only to choose a few starting tables, not to decide value."""
        anchor_terms = _terms(anchor_text)
        if not anchor_terms:
            return []
        scored: List[Tuple[float, str]] = []
        for table_name, terms in self.table_terms.items():
            overlap = len(anchor_terms & terms)
            if overlap > 0:
                scored.append((float(overlap), table_name))
        scored.sort(key=lambda item: (-item[0], item[1]))
        return [table_name for _, table_name in scored[:4]]

    def _path_semantic_score(
        self,
        path: JoinPath,
        anchor_terms: Set[str],
        *,
        seed_tables: Set[str] | None = None,
    ) -> float:
        if not anchor_terms:
            return 0.0
        seeds = set(seed_tables or set())
        added_tables = [table_name for table_name in path.tables if table_name not in seeds]
        scored_tables = added_tables or list(path.tables)
        scores: List[float] = []
        for table_name in scored_tables:
            terms = self.table_terms.get(table_name, set())
            if not terms:
                continue
            scores.append(len(anchor_terms & terms) / max(1, min(len(anchor_terms), 12)))
        if not scores:
            return 0.0
        # A path is more useful when the newly introduced table contributes relevant
        # variables.  Using only the seed-table maximum made every adjacent path appear
        # equally relevant.
        return min(1.0, 0.70 * max(scores) + 0.30 * (sum(scores) / len(scores)))

    def _potential_columns(self, path: JoinPath, anchor_text: str) -> List[str]:
        anchor_terms = _terms(anchor_text)
        key_columns = _path_key_columns_by_table(path)
        candidates: List[Tuple[float, str]] = []
        for table_name in path.tables:
            table = self.tables.get(table_name)
            if table is None:
                continue
            semantics = build_table_column_semantics(getattr(table, "metadata", {}) or {})
            for column in list(getattr(table, "columns", []) or []):
                name = str((column or {}).get("name") or "")
                if not name or name in key_columns.get(table_name, set()):
                    continue
                semantic = dict(semantics.get(name) or {})
                if semantic.get("identifier"):
                    continue
                text = " ".join([
                    table_name,
                    name,
                    str((column or {}).get("description") or ""),
                    str((column or {}).get("value_description") or ""),
                ])
                overlap = len(anchor_terms & _terms(text))
                kind_bonus = 0.20 if semantic.get("kind") in {
                    "additive_measure", "numeric_measure", "nonadditive_statistic", "text", "boolean"
                } else 0.0
                candidates.append((float(overlap) + kind_bonus, f"{table_name}.{name}"))
        candidates.sort(key=lambda item: (-item[0], item[1]))
        return [name for _, name in candidates[:8]]

    def _candidate_columns(self, path: JoinPath, anchor_text: str) -> List[str]:
        """Return business columns first and key columns second for selection/de-dup."""
        values = [*self._potential_columns(path, anchor_text), *_path_columns(path)]
        result: List[str] = []
        for value in values:
            if value and value not in result:
                result.append(value)
        return result[:10]

    def _newly_available_columns(
        self,
        path: JoinPath,
        *,
        anchor_text: str,
        seed_tables: Sequence[str],
    ) -> List[str]:
        """Return non-key attributes introduced beyond the current seed tables."""
        seeds = set(_resolve_table_names(seed_tables or [], self.tables))
        potential = self._potential_columns(path, anchor_text)
        introduced = [
            value
            for value in potential
            if value.split(".", 1)[0] not in seeds
        ]
        return introduced or potential

    # ------------------------------------------------------------------
    # Computed join probes for visual frontier
    # ------------------------------------------------------------------

    def build_probes(
        self,
        *,
        evidence_profile: Optional[Mapping[str, Any]],
        seed_tables: Sequence[str],
        exclude_signatures: Set[str] | None = None,
        max_probes: Optional[int] = None,
    ) -> List[JoinProbe]:
        self.last_probe_audit = []
        self._last_probe_failure_reason = ""
        if not self.available():
            return []
        resolved_seeds = _resolve_table_names(seed_tables or [], self.tables)
        if not resolved_seeds:
            return []
        limit = self.max_probe_paths if max_probes is None else max(0, int(max_probes))
        if limit <= 0:
            return []
        anchor = _task_anchor_text(self.task, evidence_profile)
        paths = self.rank_paths(
            anchor_text=anchor,
            seed_tables=resolved_seeds,
            prefer_complex=False,
            purpose="probe",
            safe_only=True,
            max_paths=max(limit * 8, limit),
        )
        excluded = set(exclude_signatures or set())
        probes: List[JoinProbe] = []
        for path in paths:
            if path.signature in excluded:
                self.last_probe_audit.append({
                    "signature": path.signature,
                    "status": "excluded_seen",
                    "path": list(path.tables),
                })
                continue
            probe = self._build_probe(path, anchor_text=anchor)
            if probe is None:
                self.last_probe_audit.append({
                    "signature": path.signature,
                    "status": "probe_not_materialized",
                    "reason": self._last_probe_failure_reason or "unknown_materialization_failure",
                    "path": list(path.tables),
                })
                continue
            probes.append(probe)
            self.last_probe_audit.append({
                "signature": path.signature,
                "status": "probe_materialized",
                "path": list(path.tables),
                "coverage": round(float(probe.coverage), 6),
                "rows": int(probe.dataframe.shape[0]),
                "columns": int(probe.dataframe.shape[1]),
            })
            if len(probes) >= limit:
                break
        return probes

    def _build_probe(self, path: JoinPath, *, anchor_text: str) -> Optional[JoinProbe]:
        self._last_probe_failure_reason = ""
        plan = _path_grain_plan(path)
        if plan is None:
            return self._probe_failure("unsupported_path_shape")
        grain_table, dimension_tables = plan
        grain = self.tables.get(grain_table)
        if grain is None:
            return self._probe_failure("grain_table_missing")
        grain_df = getattr(grain, "dataframe", None)
        if not isinstance(grain_df, pd.DataFrame):
            return self._probe_failure("grain_dataframe_missing")
        if grain_df.empty:
            return self._probe_failure("grain_dataframe_empty")
        if len(grain_df) > self.max_grain_rows:
            return self._probe_failure("grain_row_budget_exceeded")

        category_choices = self._choose_dimension_categories(
            path=path,
            grain_table=grain_table,
            dimension_tables=dimension_tables,
            anchor_text=anchor_text,
        )
        if not category_choices:
            return self._probe_failure("no_legal_dimension_category")

        metric_choice = self._choose_grain_metric(grain_table, anchor_text)
        metric_column = metric_choice[0] if metric_choice else ""
        metric_semantic = metric_choice[1] if metric_choice else {}

        try:
            support, coverage, output_category = self._materialize_probe_support(
                path=path,
                grain_table=grain_table,
                category_choices=category_choices,
                metric_column=metric_column,
                metric_semantic=metric_semantic,
            )
        except Exception as exc:
            return self._probe_failure(f"materialization_exception:{type(exc).__name__}")
        if support is None or support.empty:
            return self._probe_failure("materialization_empty")
        if coverage < self.min_join_coverage:
            return self._probe_failure("coverage_below_threshold")
        if not output_category or output_category not in support.columns:
            return self._probe_failure("output_category_missing")
        if safe_nunique(support[output_category]) < 2:
            return self._probe_failure("insufficient_group_cardinality")

        category_signature = "|".join(f"{table}.{column}" for table, column in category_choices)
        tid = f"join_probe_{_short_hash(path.signature + '|' + category_signature + '|' + metric_column)}"
        metadata = _probe_metadata(
            tid=tid,
            dataframe=support,
            category_column=output_category,
            metric_column=metric_column,
            metric_semantic=metric_semantic,
            path=path,
        )
        metric_text = metric_column if metric_column else "joined record count"
        category_text = " × ".join(f"{table}.{column}" for table, column in category_choices)
        title = f"Join probe: {metric_text} by {category_text}"
        note = (
            f"Computed through declared path {' -> '.join(path.tables)}; "
            f"matched coverage={coverage:.1%}. This is an executed exploration probe, not a root-stage schema claim."
        )
        return JoinProbe(
            tid=tid,
            dataframe=support,
            metadata=metadata,
            path=path,
            title=title,
            evidence_note=note,
            coverage=float(coverage),
            signature=path.signature,
            context=self._path_context(
                path,
                anchor_text=anchor_text,
                seed_tables=[grain_table],
                added_columns=[
                    f"{table}.{column}" for table, column in category_choices
                ],
                status="executed_probe",
                coverage=float(coverage),
                category_choices=category_choices,
                metric_column=metric_column,
            ),
        )


    def _probe_failure(self, reason: str) -> None:
        """Record a stable reason code for the current probe attempt."""
        self._last_probe_failure_reason = str(reason or "unknown_materialization_failure")
        return None

    def _choose_dimension_categories(
        self,
        *,
        path: JoinPath,
        grain_table: str,
        dimension_tables: Sequence[str],
        anchor_text: str,
    ) -> List[Tuple[str, str]]:
        """Choose category columns that make the declared path analytically visible.

        For a bridge shape ``parent <- child -> parent``, one category is selected from
        each parent so the probe genuinely uses all three tables. For a chain where an
        intermediate table is only needed to reach a farther dimension, the farthest
        useful category is enough because the intermediate join is structurally required.
        """
        anchor_terms = _terms(anchor_text)
        path_position = {name: index for index, name in enumerate(path.tables)}

        def candidates_for(table_name: str) -> List[Tuple[float, str, str]]:
            table = self.tables.get(table_name)
            if table is None:
                return []
            df = getattr(table, "dataframe", None)
            if not isinstance(df, pd.DataFrame) or df.empty:
                return []
            semantics = build_table_column_semantics(getattr(table, "metadata", {}) or {})
            result: List[Tuple[float, str, str]] = []
            for column in list(df.columns):
                name = str(column)
                semantic = dict(semantics.get(name) or {})
                if semantic.get("identifier") or semantic.get("temporal"):
                    continue
                kind = str(semantic.get("kind") or "")
                if kind not in {"text", "boolean", "category_code", "unknown"} and not is_string_dtype(df[name]):
                    continue
                unique = safe_nunique(df[name])
                if unique < 2 or unique > 40:
                    continue
                text = f"{table_name} {name} {semantic.get('description', '')}"
                overlap = len(anchor_terms & _terms(text))
                distance_bonus = 0.12 * path_position.get(table_name, 0)
                cardinality_bonus = 0.15 if 2 <= unique <= 15 else 0.08
                result.append((float(overlap) + distance_bonus + cardinality_bonus, table_name, name))
            result.sort(key=lambda item: (-item[0], item[1], item[2]))
            return result

        # A middle grain table means the path is a bridge between two dimensions. Use
        # both ends; otherwise the alleged three-table probe would collapse to a direct
        # child-to-one-parent analysis.
        if len(path.tables) == 3 and grain_table == path.tables[1]:
            chosen: List[Tuple[str, str]] = []
            for table_name in (path.tables[0], path.tables[2]):
                table_candidates = candidates_for(table_name)
                if not table_candidates:
                    return []
                _, selected_table, selected_column = table_candidates[0]
                chosen.append((selected_table, selected_column))
            return chosen

        all_candidates: List[Tuple[float, str, str]] = []
        for table_name in dimension_tables:
            all_candidates.extend(candidates_for(table_name))
        if not all_candidates:
            return []
        all_candidates.sort(key=lambda item: (-item[0], -path_position.get(item[1], 0), item[1], item[2]))
        _, table_name, column = all_candidates[0]
        return [(table_name, column)]

    def _choose_grain_metric(self, grain_table: str, anchor_text: str) -> Optional[Tuple[str, Dict[str, Any]]]:
        table = self.tables.get(grain_table)
        if table is None:
            return None
        df = getattr(table, "dataframe", None)
        if not isinstance(df, pd.DataFrame) or df.empty:
            return None
        semantics = build_table_column_semantics(getattr(table, "metadata", {}) or {})
        anchor_terms = _terms(anchor_text)
        candidates: List[Tuple[float, int, str, Dict[str, Any]]] = []
        for column in list(df.columns):
            name = str(column)
            semantic = dict(semantics.get(name) or {})
            if semantic.get("identifier") or semantic.get("temporal"):
                continue
            if semantic.get("kind") in {"coordinate", "category_code", "boolean", "text"}:
                continue
            if not is_numeric_dtype(df[name]):
                continue
            if safe_nunique(df[name]) < 2:
                continue
            text = f"{grain_table} {name} {semantic.get('description', '')}"
            overlap = len(anchor_terms & _terms(text))
            kind_bonus = 0.18 if semantic.get("additive") is not None else 0.08
            candidates.append((float(overlap) + kind_bonus, overlap, name, semantic))
        if not candidates:
            return None
        candidates.sort(key=lambda item: (-item[0], item[2]))
        _, top_overlap, name, semantic = candidates[0]
        # If several unrelated numeric columns exist, using an arbitrary one can turn a
        # structurally valid join into a semantically random chart.  Falling back to a
        # joined-record count is safer.  A sole numeric measure remains usable.
        if top_overlap <= 0 and len(candidates) > 1:
            return None
        return name, semantic

    def _materialize_probe_support(
        self,
        *,
        path: JoinPath,
        grain_table: str,
        category_choices: Sequence[Tuple[str, str]],
        metric_column: str,
        metric_semantic: Mapping[str, Any],
    ) -> Tuple[Optional[pd.DataFrame], float, str]:
        ordered_edges = _edges_from_grain(path, grain_table)
        if ordered_edges is None:
            return None, 0.0, ""

        grain_df = self.tables[grain_table].dataframe
        first_edge, _, _ = ordered_edges[0]
        grain_join_columns = _columns_for_table(first_edge, grain_table)
        if not grain_join_columns or any(column not in grain_df.columns for column in grain_join_columns):
            return None, 0.0, ""

        # Keep every grain-side key needed by any path edge. This is necessary for
        # bridge shapes such as parent <- child -> another_parent.
        all_grain_keys: List[str] = []
        for edge, left_table, _ in ordered_edges:
            if left_table == grain_table:
                all_grain_keys.extend(_columns_for_table(edge, grain_table))
        grain_join_columns = list(dict.fromkeys(all_grain_keys or grain_join_columns))
        projection = list(dict.fromkeys([*grain_join_columns, metric_column] if metric_column else grain_join_columns))
        working = grain_df[projection].copy()
        working["__joined_record_count"] = 1
        original_weight = float(working["__joined_record_count"].sum())
        # SQL joins do not treat missing keys as equal. Drop incomplete key tuples before
        # grouping so pandas' null-matching behavior cannot create false relationships.
        working = working.dropna(subset=grain_join_columns)
        if working.empty or original_weight <= 0:
            return None, 0.0, ""
        if metric_column:
            numeric = safe_to_numeric(working[metric_column])
            working["__metric_sum"] = numeric.fillna(0.0)
            working["__metric_count"] = numeric.notna().astype("int64")
            working = working.drop(columns=[metric_column])
        agg_spec: Dict[str, str] = {"__joined_record_count": "sum"}
        if metric_column:
            agg_spec.update({"__metric_sum": "sum", "__metric_count": "sum"})
        working = working.groupby(grain_join_columns, dropna=False, as_index=False).agg(agg_spec)
        initial_weight = original_weight

        output_categories = {
            table_name: f"{normalize_name(table_name)}__{column_name}"
            for table_name, column_name in category_choices
        }
        for step_index, (edge, left_table, next_table) in enumerate(ordered_edges):
            left_columns = _columns_for_table(edge, left_table)
            right_columns = _columns_for_table(edge, next_table)
            if not left_columns or len(left_columns) != len(right_columns):
                return None, 0.0, ""
            next_df = self.tables[next_table].dataframe
            needed = list(right_columns)
            # Keep keys needed for the following edge and the selected category.
            if step_index + 1 < len(ordered_edges):
                next_edge, next_left_table, _ = ordered_edges[step_index + 1]
                if next_left_table == next_table:
                    needed.extend(_columns_for_table(next_edge, next_table))
            category_column = next((column for table_name, column in category_choices if table_name == next_table), "")
            if category_column:
                needed.append(category_column)
            needed = list(dict.fromkeys(needed))
            if any(column not in next_df.columns for column in needed):
                return None, 0.0, ""
            dimension = next_df[needed].dropna(subset=right_columns).copy()
            # A declared parent key must remain unique in the actual data. Check before
            # any row de-duplication: even byte-identical duplicate rows violate the
            # declared key and would otherwise conceal a fanout problem.
            if dimension.duplicated(subset=right_columns, keep=False).any():
                return None, 0.0, ""
            dimension = dimension.drop_duplicates().copy()
            if category_column and category_column in dimension.columns:
                dimension = dimension.rename(columns={category_column: output_categories[next_table]})
            working = working.dropna(subset=left_columns)
            working = working.merge(
                dimension,
                how="inner",
                left_on=left_columns,
                right_on=right_columns,
                suffixes=("", f"__{normalize_name(next_table)}"),
            )
            if working.empty:
                return None, 0.0, ""

        selected_output_categories = [output_categories[table_name] for table_name, _ in category_choices]
        if any(column not in working.columns for column in selected_output_categories):
            return None, 0.0, ""
        matched_weight = float(working["__joined_record_count"].sum())
        coverage = matched_weight / initial_weight if initial_weight else 0.0

        grouped = working.dropna(subset=selected_output_categories).groupby(selected_output_categories, dropna=False, as_index=False).agg({
            "__joined_record_count": "sum",
            **({"__metric_sum": "sum", "__metric_count": "sum"} if metric_column else {}),
        })
        grouped = grouped.rename(columns={"__joined_record_count": "joined_record_count"})
        grouped = grouped.sort_values("joined_record_count", ascending=False).head(self.max_probe_groups).reset_index(drop=True)
        if len(selected_output_categories) == 1:
            output_category = selected_output_categories[0]
        else:
            output_category = "joined_group"
            labels = []
            for _, row in grouped[selected_output_categories].iterrows():
                parts = []
                for (table_name, original_column), output_column in zip(category_choices, selected_output_categories):
                    parts.append(f"{table_name}.{original_column}={row[output_column]}")
                labels.append(" | ".join(parts))
            grouped[output_category] = labels
        if metric_column:
            if metric_semantic.get("additive") is True:
                output_name = f"{metric_column}_sum"
                grouped[output_name] = grouped["__metric_sum"]
            else:
                output_name = f"{metric_column}_mean"
                denominator = grouped["__metric_count"].replace(0, np.nan)
                grouped[output_name] = grouped["__metric_sum"] / denominator
            # Keep the probe focused on the task-related metric. Group sample counts are
            # used internally for coverage and weighting, but otherwise tend to win the
            # generic chart binding and hide the intended multi-table metric.
            grouped = grouped[[output_category, output_name]]
        else:
            grouped = grouped[[output_category, "joined_record_count"]]
        return grouped, float(coverage), output_category


# ----------------------------------------------------------------------
# Graph construction and path safety
# ----------------------------------------------------------------------


def _is_bird_task(task: Any) -> bool:
    metadata = dict(getattr(task, "metadata", {}) or {})
    return str(metadata.get("benchmark") or "").lower() == "bird"


def _build_edges(tables: Mapping[str, Any]) -> List[JoinEdge]:
    normalized_candidates: Dict[str, List[str]] = {}
    for name in tables:
        normalized_candidates.setdefault(normalize_name(name), []).append(name)
    edges: List[JoinEdge] = []
    seen: Set[str] = set()
    for table_name, table in tables.items():
        child_df = getattr(table, "dataframe", None)
        child_columns_available = set(str(column) for column in getattr(child_df, "columns", []))
        metadata = dict(getattr(table, "metadata", {}) or {})
        constraints = dict(metadata.get("constraints") or {})
        for raw_fk in list(constraints.get("foreign_keys") or []):
            fk = dict(raw_fk or {})
            child_columns = tuple(str(value) for value in list(fk.get("columns") or []) if str(value))
            parent_raw = str(fk.get("references_table") or "")
            parent_table = tables.get(parent_raw)
            normalized_matches = normalized_candidates.get(normalize_name(parent_raw), [])
            resolved_parent_name = (
                parent_raw
                if parent_table is not None
                else normalized_matches[0]
                if len(normalized_matches) == 1
                else ""
            )
            parent_columns = tuple(
                str(value) for value in list(fk.get("references_columns") or []) if str(value)
            )
            if not child_columns or not resolved_parent_name or len(child_columns) != len(parent_columns):
                continue
            resolved_parent = tables.get(resolved_parent_name)
            parent_df = getattr(resolved_parent, "dataframe", None)
            parent_columns_available = set(str(column) for column in getattr(parent_df, "columns", []))
            if (
                any(column not in child_columns_available for column in child_columns)
                or any(column not in parent_columns_available for column in parent_columns)
            ):
                continue
            edge = JoinEdge(
                child_table=table_name,
                child_columns=child_columns,
                parent_table=resolved_parent_name,
                parent_columns=parent_columns,
            )
            if edge.signature not in seen:
                seen.add(edge.signature)
                edges.append(edge)
    return edges


def _build_adjacency(edges: Sequence[JoinEdge]) -> Dict[str, List[Tuple[str, JoinEdge]]]:
    adjacency: Dict[str, List[Tuple[str, JoinEdge]]] = {}
    for edge in edges:
        adjacency.setdefault(edge.child_table, []).append((edge.parent_table, edge))
        adjacency.setdefault(edge.parent_table, []).append((edge.child_table, edge))
    return adjacency


def _enumerate_paths(
    *,
    tables: Set[str],
    adjacency: Mapping[str, Sequence[Tuple[str, JoinEdge]]],
    max_hops: int,
    seed_tables: Optional[Sequence[str]],
) -> List[JoinPath]:
    starts = list(seed_tables or sorted(tables))
    result: List[JoinPath] = []
    seen: Set[str] = set()
    for start in starts:
        if start not in tables:
            continue
        stack: List[Tuple[Tuple[str, ...], Tuple[JoinEdge, ...]]] = [((start,), tuple())]
        while stack:
            path_tables, path_edges = stack.pop()
            current = path_tables[-1]
            if path_edges:
                path = JoinPath(tables=path_tables, edges=path_edges)
                canonical = _canonical_path_signature(path)
                if canonical not in seen:
                    seen.add(canonical)
                    result.append(path)
            if len(path_edges) >= max_hops:
                continue
            for next_table, edge in adjacency.get(current, []):
                if next_table in path_tables:
                    continue
                stack.append((path_tables + (next_table,), path_edges + (edge,)))
    return result


def _canonical_path_signature(path: JoinPath) -> str:
    forward = "|".join(edge.signature for edge in path.edges)
    reverse = "|".join(edge.signature for edge in reversed(path.edges))
    return min(forward, reverse)


def _is_shared_parent_sibling_path(path: JoinPath) -> bool:
    """判断是否为两个明细表共享同一父表的两跳路径。

    该路径不能直接做行级 Join，但可以把两侧分别聚合到中间父表粒度后安全组合。
    """
    if len(path.tables) != 3 or len(path.edges) != 2:
        return False
    left, middle, right = path.tables
    first, second = path.edges
    return (
        first.child_table == left
        and first.parent_table == middle
        and second.parent_table == middle
        and second.child_table == right
    )


def _safe_path_shape(path: JoinPath) -> bool:
    """Allow all many-to-one paths or one initial expansion followed by contractions.

    This rejects child->parent->another-child sibling joins, which can silently create
    many-to-many multiplication. It accepts parent->child->parent, where the child is a
    clear grain table connected to two dimensions.
    """
    directions: List[str] = []
    for index, edge in enumerate(path.edges):
        current = path.tables[index]
        nxt = path.tables[index + 1]
        if current == edge.child_table and nxt == edge.parent_table:
            directions.append("up")
        elif current == edge.parent_table and nxt == edge.child_table:
            directions.append("down")
        else:
            return False
    if directions.count("down") > 1:
        return False
    if "down" in directions and directions[0] != "down":
        return False
    return True


def _path_usage_note(path: JoinPath) -> str:
    """Describe safe analytical use without claiming that the join has been executed."""
    directions: List[str] = []
    for index, edge in enumerate(path.edges):
        current = path.tables[index]
        nxt = path.tables[index + 1]
        if current == edge.child_table and nxt == edge.parent_table:
            directions.append("up")
        elif current == edge.parent_table and nxt == edge.child_table:
            directions.append("down")
        else:
            return "Verify the declared keys and choose an explicit analysis grain before joining."

    if directions and all(direction == "up" for direction in directions):
        return f"Keep {path.tables[0]} as the detail grain and attach parent attributes with many-to-one joins."
    if directions == ["down", "up"] and len(path.tables) == 3:
        return f"Use {path.tables[1]} as the bridge/detail grain and attach attributes from both endpoint tables."
    if directions == ["down"] and len(path.tables) == 2:
        return (
            f"Use {path.tables[1]} as the detail grain, or aggregate it to {path.tables[0]} before a parent-level comparison."
        )
    if directions == ["up", "down"] and len(path.tables) == 3:
        return (
            f"Do not raw-join the two detail tables through {path.tables[1]}; aggregate each side to the shared parent key first."
        )
    return "Define the final grain explicitly and pre-aggregate one-to-many detail tables before combining them."


def _path_grain_plan(path: JoinPath) -> Optional[Tuple[str, List[str]]]:
    if not _safe_path_shape(path):
        return None
    directions = []
    for index, edge in enumerate(path.edges):
        current = path.tables[index]
        nxt = path.tables[index + 1]
        directions.append("up" if current == edge.child_table and nxt == edge.parent_table else "down")
    if directions and directions[0] == "down":
        grain_table = path.tables[1]
    else:
        grain_table = path.tables[0]
    dimensions = [name for name in path.tables if name != grain_table]
    return grain_table, dimensions


def _edges_from_grain(path: JoinPath, grain_table: str) -> Optional[List[Tuple[JoinEdge, str, str]]]:
    # Return (edge, left_table_already_in_working, next_dimension_table).
    if grain_table == path.tables[0]:
        return [
            (path.edges[index], path.tables[index], path.tables[index + 1])
            for index in range(len(path.edges))
        ]
    if len(path.tables) == 2 and grain_table == path.tables[1]:
        return [(path.edges[0], grain_table, path.tables[0])]
    if len(path.tables) == 3 and grain_table == path.tables[1]:
        return [
            (path.edges[0], grain_table, path.tables[0]),
            (path.edges[1], grain_table, path.tables[2]),
        ]
    return None


def _columns_for_table(edge: JoinEdge, table_name: str) -> List[str]:
    if table_name == edge.child_table:
        return list(edge.child_columns)
    if table_name == edge.parent_table:
        return list(edge.parent_columns)
    return []


# ----------------------------------------------------------------------
# Formatting / metadata helpers
# ----------------------------------------------------------------------


def _probe_metadata(
    *,
    tid: str,
    dataframe: pd.DataFrame,
    category_column: str,
    metric_column: str,
    metric_semantic: Mapping[str, Any],
    path: JoinPath,
) -> Dict[str, Any]:
    columns: List[Dict[str, Any]] = []
    for column in dataframe.columns:
        name = str(column)
        if name == category_column:
            columns.append({"name": name, "data_format": "text", "description": "Joined category used by the exploration probe."})
        elif name == "joined_record_count":
            columns.append({"name": name, "data_format": "integer", "description": "Number of grain-table records matched through the declared join path."})
        else:
            data_format = "real"
            description = f"Join-probe aggregation derived from {metric_column}."
            if metric_semantic.get("additive") is True:
                description += " Additive sum."
            else:
                description += " Mean over matched grain records."
            columns.append({"name": name, "data_format": data_format, "description": description})
    return {
        "source": "bird_join_probe",
        "description": f"Computed join probe over {' -> '.join(path.tables)}.",
        "num_rows": int(dataframe.shape[0]),
        "num_columns": int(dataframe.shape[1]),
        "columns": columns,
        "join_path_signature": path.signature,
    }


def _path_columns(path: JoinPath) -> List[str]:
    result: List[str] = []
    for edge in path.edges:
        for table_name, columns in (
            (edge.child_table, edge.child_columns),
            (edge.parent_table, edge.parent_columns),
        ):
            for column in columns:
                text = f"{table_name}.{column}"
                if text not in result:
                    result.append(text)
    return result[:8]


def _path_key_columns_by_table(path: JoinPath) -> Dict[str, Set[str]]:
    result: Dict[str, Set[str]] = {}
    for edge in path.edges:
        result.setdefault(edge.child_table, set()).update(edge.child_columns)
        result.setdefault(edge.parent_table, set()).update(edge.parent_columns)
    return result


def _task_anchor_text(task: Any, evidence_profile: Optional[Mapping[str, Any]]) -> str:
    metadata = dict(getattr(task, "metadata", {}) or {})
    profile = dict(evidence_profile or {})
    focus = profile.get("evidence_focus")
    if isinstance(focus, str):
        focus = [focus]
    return " ".join(
        str(value or "")
        for value in [
            metadata.get("goal"), metadata.get("goal_zh"), metadata.get("dataset_description"),
            profile.get("round_question"), *list(focus or []),
        ]
        if str(value or "").strip()
    )


def _table_terms(table: Any) -> Set[str]:
    parts = [str(getattr(table, "name", "") or "")]
    metadata = dict(getattr(table, "metadata", {}) or {})
    parts.append(str(metadata.get("description") or ""))
    for column in list(getattr(table, "columns", []) or []):
        item = dict(column or {})
        parts.extend([
            str(item.get("name") or ""),
            str(item.get("description") or ""),
            str(item.get("value_description") or ""),
        ])
    return _terms(" ".join(parts))


def _terms(text: str) -> Set[str]:
    expanded = str(text or "").replace("_", " ").replace("-", " ").lower()
    return {token for token in _TOKEN_RE.findall(expanded) if token not in _STOPWORDS}


def _resolve_table_names(values: Sequence[str], tables: Mapping[str, Any]) -> List[str]:
    normalized: Dict[str, List[str]] = {}
    for name in tables:
        normalized.setdefault(normalize_name(name), []).append(name)
    result: List[str] = []
    for raw in values:
        text = str(raw or "")
        matches = normalized.get(normalize_name(text), [])
        resolved = text if text in tables else matches[0] if len(matches) == 1 else ""
        if resolved and resolved not in result:
            result.append(resolved)
    return result


def _short_hash(text: str) -> str:
    return hashlib.md5(str(text).encode("utf-8")).hexdigest()[:10]
