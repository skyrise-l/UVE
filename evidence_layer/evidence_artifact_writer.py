"""evidence_artifact_writer.py
-----------------------------
证据层最小落盘工具。

过去的批量日志工具会在每轮写出大量中间 JSON。正常运行只保留
``round_{i}_selected_visual_plan_scores.json``；VEG 仅在 ``chart.save_veg=true``
时作为定向调试产物写出。

本模块不参与算法决策；写入失败也不应该影响主流程。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class EvidenceArtifactWriter:
    """只保存必要证据产物的轻量 writer。"""

    def __init__(self, output_dir: str | Path) -> None:
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)

    def write_veg(self, round_index: int, veg: Any) -> None:
        self._write(round_index, "veg", veg)

    def write_selected_plan_scores(self, round_index: int, payload: Any) -> None:
        self._write(round_index, "selected_visual_plan_scores", payload)

    def _write(self, round_index: int, name: str, payload: Any) -> None:
        path = self.output_dir / f"round_{round_index}_{name}.json"
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
