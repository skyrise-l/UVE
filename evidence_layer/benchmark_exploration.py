"""Benchmark-specific hooks for next-question exploration evidence.

The default policy is deliberately inert so single-table InsightBench behavior remains
unchanged.  BIRD loads a separate policy module that can enrich and select multi-table
Join evidence without spreading benchmark checks through the generic evidence pipeline.
"""

from __future__ import annotations

from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence

from evidence_layer.evidence_contracts import task_benchmark


SelectPool = Callable[..., List[Dict[str, Any]]]


class DefaultExplorationPolicy:
    """No-op policy used by InsightBench and unknown compatible benchmarks."""

    benchmark = "default"

    def enrich_candidate(self, candidate: Mapping[str, Any]) -> Dict[str, Any]:
        return dict(candidate or {})

    def select_global(
        self,
        pool: Sequence[Mapping[str, Any]],
        *,
        max_candidates: int,
        select_pool: SelectPool,
    ) -> Optional[List[Dict[str, Any]]]:
        return None

    def format_extra_lines(self, candidate: Mapping[str, Any]) -> List[str]:
        return []

    def prompt_guidance(self, candidates: Sequence[Mapping[str, Any]]) -> str:
        return ""


def build_benchmark_exploration_policy(
    *,
    task: Any = None,
    config: Optional[Mapping[str, Any]] = None,
    benchmark: str = "",
):
    """Return a benchmark plug-in while keeping the generic pipeline dependency-light."""
    resolved = str(benchmark or task_benchmark(task)).strip().lower()
    if resolved == "bird":
        from evidence_layer.bird_exploration import BirdExplorationPolicy

        return BirdExplorationPolicy(config=config)
    return DefaultExplorationPolicy()
