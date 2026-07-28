
from __future__ import annotations

"""
Pandas 关键数据操作追踪器（重构版）
=================================

设计目标
--------
1. 修复原始版本对 ``inplace=True`` / ``None`` 返回值处理不一致的问题。
2. 扩展到常见的数据分析 API，而不是只覆盖极少数 DataFrame 方法。
3. 将 patch 逻辑拆成“注册 + 专项处理 + 通用辅助函数”，降低后续维护成本。
4. 用轻量表达式元数据（expression metadata）增强列依赖识别能力。

定位
----
这不是一个试图穷尽 pandas 全部语义的“完整血缘引擎”，而是一个：
- 偏用户层
- 面向常见分析场景
- 能提供可读、可维护 trace 的追踪器

当前重点覆盖
------------
- DataFrame：
  copy / [] / []= / loc / iloc / merge / join / concat / groupby / assign /
  rename / set_index / reset_index / sort_values / sort_index / drop / dropna /
  drop_duplicates / fillna / replace / astype / where / mask / query / eval /
  pivot / pivot_table / melt / explode / stack / unstack / apply
- GroupBy：
  agg / aggregate / mean / sum / count / size / max / min / median /
  nunique / first / last / std / var / apply / transform
- Top level：
  pd.merge / pd.concat / read_csv / read_excel / read_json / read_parquet
- Sink：
  to_csv / to_excel / to_json / to_parquet
- Series 表达式元数据：
  常见比较 / 算术 / 布尔组合 / fillna / astype / map / replace / where /
  mask / isin / between / clip / round / abs

已知边界
--------
- 不尝试完整还原任意 Python lambda / UDF 的真实列级依赖。
- 对 ``assign(lambda df: ...)``、``apply``、``transform`` 之类高自由度 API，
  会给出保守追踪，而不是完美追踪。
- 建议单个 Python 进程只启用一个 patcher 实例。
"""

from dataclasses import dataclass, field
import inspect
import re
import threading
import weakref
from contextlib import contextmanager
from functools import wraps
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple

import numpy as np
import pandas as pd

try:  # pragma: no cover - 兼容不同 pandas 版本
    from pandas.core.groupby.generic import DataFrameGroupBy, SeriesGroupBy
except Exception:  # pragma: no cover
    DataFrameGroupBy = None
    SeriesGroupBy = None

try:  # pragma: no cover - 兼容不同 pandas 版本
    from pandas.core.indexing import _LocIndexer, _iLocIndexer
except Exception:  # pragma: no cover
    _LocIndexer = None
    _iLocIndexer = None

try:  # pragma: no cover - 兼容不同 pandas 版本
    from pandas.core.strings.accessor import StringMethods
except Exception:  # pragma: no cover
    StringMethods = None


ReadMap = Dict[str, List[str]]
InternalReadMap = Dict[str, Set[str]]

COMMON_GROUPBY_REDUCTIONS = [
    "mean",
    "sum",
    "count",
    "size",
    "max",
    "min",
    "median",
    "nunique",
    "first",
    "last",
    "std",
    "var",
]

SERIES_BINARY_OPS = [
    "__add__",
    "__sub__",
    "__mul__",
    "__truediv__",
    "__floordiv__",
    "__mod__",
    "__pow__",
    "__eq__",
    "__ne__",
    "__gt__",
    "__ge__",
    "__lt__",
    "__le__",
    "__and__",
    "__or__",
    "__xor__",
]

SERIES_UNARY_META_METHODS = [
    "fillna",
    "astype",
    "map",
    "replace",
    "where",
    "mask",
    "isin",
    "between",
    "clip",
    "round",
    "abs",
]

SERIES_LINEAGE_METHODS = ["diff", "shift", "pct_change", "value_counts"]
SERIES_SCALAR_REDUCTIONS = ["idxmax", "idxmin", "max", "min", "mean", "median", "sum", "count", "nunique"]
SERIES_BINARY_OP_LABELS = {
    "__add__": "add",
    "__sub__": "sub",
    "__mul__": "mul",
    "__truediv__": "truediv",
    "__floordiv__": "floordiv",
    "__mod__": "mod",
    "__pow__": "pow",
    "__eq__": "eq",
    "__ne__": "ne",
    "__gt__": "gt",
    "__ge__": "ge",
    "__lt__": "lt",
    "__le__": "le",
    "__and__": "and",
    "__or__": "or",
    "__xor__": "xor",
}

PANDAS_READERS = ["read_csv", "read_excel", "read_json", "read_parquet"]
DATAFRAME_WRITERS = ["to_csv", "to_excel", "to_json", "to_parquet"]

# Nested pandas calls triggered inside one already-traced operation are implementation
# details, not independent user-level dataflow nodes.
_NESTED_UNTRACKED_TID = "__nested_untracked__"


@dataclass
class ExpressionMeta:
    """Series 派生表达式的轻量元数据。"""

    read: InternalReadMap = field(default_factory=dict)
    description: Optional[str] = None


class PandasTracePatcher:
    """记录 pandas 常见用户层数据操作。"""

    def __init__(self) -> None:
        self.events: List[Dict[str, Any]] = []
        self.table_registry: Dict[str, Dict[str, Any]] = {}

        self._patched = False
        self._lock = threading.RLock()
        self._originals: Dict[str, Any] = {}

        # 对象 -> 当前 table id
        self._obj_to_tid: Dict[int, str] = {}
        self._finalizers: Dict[int, Any] = {}
        self._tid_to_obj_ref: Dict[str, Any] = {}

        # table id -> 用户可读名称；obj id -> 最新绑定名称
        self._labels: Dict[str, str] = {}
        self._obj_aliases: Dict[int, str] = {}

        # Series 等表达式对象的依赖元数据
        self._expr_meta: Dict[int, ExpressionMeta] = {}
        self._expr_finalizers: Dict[int, Any] = {}

        # output tid -> 该节点可追溯到的上游读列（root-level read hint）
        self._result_lineage: Dict[str, InternalReadMap] = {}

        self._next_event_id = 1
        self._next_table_id = 1

        # Conservative defaults keep traces useful while preventing loops/UDFs from
        # creating hundreds of thousands of nodes in memory.
        self.max_trace_tables = 2000
        self.max_trace_events = 5000
        self.max_trace_columns = 200
        self._dropped_table_count = 0
        self._dropped_event_count = 0
        self._nested_suppressed_table_count = 0
        self._columns_truncated_table_count = 0

        self._local = threading.local()

    # ------------------------------------------------------------------
    # 对外接口
    # ------------------------------------------------------------------

    def clear(self) -> None:
        """清空 trace 状态。"""
        with self._lock:
            self.events.clear()
            self.table_registry.clear()
            self._obj_to_tid.clear()
            self._finalizers.clear()
            self._tid_to_obj_ref.clear()
            self._labels.clear()
            self._obj_aliases.clear()
            self._expr_meta.clear()
            self._expr_finalizers.clear()
            self._result_lineage.clear()
            self._next_event_id = 1
            self._next_table_id = 1
            self._dropped_table_count = 0
            self._dropped_event_count = 0
            self._nested_suppressed_table_count = 0
            self._columns_truncated_table_count = 0

    def configure(
        self,
        *,
        max_tables: Optional[int] = None,
        max_events: Optional[int] = None,
        max_columns: Optional[int] = None,
    ) -> None:
        """Configure bounded trace collection for the next execution rounds."""
        with self._lock:
            if max_tables is not None:
                self.max_trace_tables = max(10, int(max_tables))
            if max_events is not None:
                self.max_trace_events = max(10, int(max_events))
            if max_columns is not None:
                self.max_trace_columns = max(10, int(max_columns))

    def bind_name(self, obj: Any, name: str) -> str:
        """给对象绑定一个稳定、可读的名字。"""
        tid = self._ensure_table(obj, force=True)
        with self._lock:
            obj_id = id(obj)
            self._obj_aliases[obj_id] = name
            self._labels[tid] = name
            if tid in self.table_registry:
                self.table_registry[tid]["name"] = name
        return tid

    def get_events(self) -> List[Dict[str, Any]]:
        with self._lock:
            return [dict(item) for item in self.events]

    def get_table_registry(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self.table_registry.items()}

    def export_trace(self) -> Dict[str, Any]:
        with self._lock:
            stats = {
                "table_count": len(self.table_registry),
                "event_count": len(self.events),
                "dropped_table_count": int(self._dropped_table_count),
                "dropped_event_count": int(self._dropped_event_count),
                "nested_suppressed_table_count": int(self._nested_suppressed_table_count),
                "columns_truncated_table_count": int(self._columns_truncated_table_count),
                "truncated": bool(self._dropped_table_count or self._dropped_event_count),
                "limits": {
                    "max_tables": int(self.max_trace_tables),
                    "max_events": int(self.max_trace_events),
                    "max_columns": int(self.max_trace_columns),
                },
            }
        return {
            "tables": self.get_table_registry(),
            "events": self.get_events(),
            "trace_stats": stats,
        }

    def export_live_artifacts(self) -> Dict[str, Any]:
        """导出当前仍然存活的表状对象。

        说明：
        - 只返回 DataFrame / Series；
        - 只用于当前进程内后续模块消费，不写入磁盘；
        - 学术 demo 里，这比重新回放代码去找 anchor 对应对象更简单直接。
        """
        out: Dict[str, Any] = {}
        with self._lock:
            for tid, ref in list(self._tid_to_obj_ref.items()):
                try:
                    obj = ref() if callable(ref) else None
                except Exception:
                    obj = None
                if not isinstance(obj, (pd.DataFrame, pd.Series)):
                    continue
                # Historical inplace-version tids point to the same mutated object and
                # cannot be materialized faithfully. Export only the object's current tid.
                if self._obj_to_tid.get(id(obj)) != str(tid):
                    continue
                out[str(tid)] = obj
        return out

    
    def describe_value_refs(self, value: Any, path: str = "value") -> List[Dict[str, Any]]:
        """
        递归描述一个 Python 值里，哪些部分能在当前 trace 中对齐到已追踪对象。

        说明：
        - 对已经被 trace 过的对象（包括 DataFrame / Series / 通过索引得到的标量）
          直接复用已有 tid；
        - 对 DataFrame / Series，如果尚未登记，则补登记一次；
        - 对普通 Python 标量，不主动新建 tid，避免把无关值塞进 trace。

        这个接口主要给 `stage_result` 做 sink 对齐。
        """

        refs: List[Dict[str, Any]] = []
        seen: Set[int] = set()

        def walk(obj: Any, obj_path: str) -> None:
            obj_id = id(obj)
            if obj_id in seen:
                return
            seen.add(obj_id)

            with self._lock:
                existing_tid = self._obj_to_tid.get(obj_id)

            if existing_tid is None and isinstance(obj, (pd.DataFrame, pd.Series)):
                try:
                    existing_tid = self._ensure_table(obj, force=True)
                except Exception:
                    existing_tid = None

            if existing_tid is not None:
                info = dict(self.table_registry.get(existing_tid) or {})
                refs.append(
                    {
                        "path": obj_path,
                        "tid": existing_tid,
                        "kind": str(info.get("kind") or self._kind(obj)),
                        "columns": [str(col) for col in list(info.get("columns") or [])],
                    }
                )
                return

            if isinstance(obj, Mapping):
                for key, item in obj.items():
                    walk(item, f"{obj_path}.{key}")
                return

            if isinstance(obj, (list, tuple)):
                for index, item in enumerate(obj):
                    walk(item, f"{obj_path}[{index}]")
                return

        walk(value, path)
        return refs

    def patch_all(self) -> None:
        """安装全部 patch。"""
        with self._lock:
            if self._patched:
                return

            self._patch_dataframe_methods()
            self._patch_top_level_functions()
            self._patch_indexers()
            self._patch_groupby_methods()
            self._patch_series_expression_methods()

            self._patched = True

    def unpatch_all(self) -> None:
        """恢复原始 pandas 方法。"""
        with self._lock:
            if not self._patched:
                return

            for key, value in self._originals.items():
                owner_label, attr = key.split("::", 1)
                owner = self._owner_from_label(owner_label)
                if owner is not None:
                    setattr(owner, attr, value)

            self._originals.clear()
            self._patched = False

    # ------------------------------------------------------------------
    # Patch 安装结构
    # ------------------------------------------------------------------

    def _patch_dataframe_methods(self) -> None:
        self._patch_dataframe_copy()
        self._patch_dataframe_getitem()
        self._patch_dataframe_setitem()
        self._patch_dataframe_merge()
        self._patch_dataframe_join()
        self._patch_dataframe_groupby()
        self._patch_dataframe_assign()
        self._patch_dataframe_rename()
        self._patch_dataframe_set_index()
        self._patch_dataframe_reset_index()
        self._patch_dataframe_sort_values()
        self._patch_dataframe_sort_index()
        self._patch_dataframe_drop()
        self._patch_dataframe_dropna()
        self._patch_dataframe_drop_duplicates()
        self._patch_dataframe_fillna()
        self._patch_dataframe_replace()
        self._patch_dataframe_astype()
        self._patch_dataframe_where_like("where")
        self._patch_dataframe_where_like("mask")
        self._patch_dataframe_query()
        self._patch_dataframe_eval()
        self._patch_dataframe_pivot()
        self._patch_dataframe_pivot_table()
        self._patch_dataframe_melt()
        self._patch_dataframe_explode()
        self._patch_dataframe_stack()
        self._patch_dataframe_unstack()
        self._patch_dataframe_apply()

    def _patch_top_level_functions(self) -> None:
        self._patch_top_level_merge()
        self._patch_top_level_concat()

    def _patch_indexers(self) -> None:
        if _LocIndexer is not None:
            self._patch_indexer_getitem(_LocIndexer, "LocIndexer", "loc")
            self._patch_indexer_setitem(_LocIndexer, "LocIndexer", "loc")
        if _iLocIndexer is not None:
            self._patch_indexer_getitem(_iLocIndexer, "ILocIndexer", "iloc")
            self._patch_indexer_setitem(_iLocIndexer, "ILocIndexer", "iloc")

    def _patch_groupby_methods(self) -> None:
        if DataFrameGroupBy is not None:
            self._patch_groupby_getitem()
            self._patch_groupby_agg(DataFrameGroupBy, "DataFrameGroupBy")
            self._patch_groupby_agg_alias(DataFrameGroupBy, "DataFrameGroupBy", "aggregate")
            for name in COMMON_GROUPBY_REDUCTIONS:
                self._patch_groupby_named_agg(DataFrameGroupBy, "DataFrameGroupBy", name)
            self._patch_groupby_apply(DataFrameGroupBy, "DataFrameGroupBy")
            self._patch_groupby_transform(DataFrameGroupBy, "DataFrameGroupBy")

        if SeriesGroupBy is not None:
            self._patch_groupby_agg(SeriesGroupBy, "SeriesGroupBy")
            self._patch_groupby_agg_alias(SeriesGroupBy, "SeriesGroupBy", "aggregate")
            for name in COMMON_GROUPBY_REDUCTIONS:
                self._patch_groupby_named_agg(SeriesGroupBy, "SeriesGroupBy", name)
            self._patch_groupby_apply(SeriesGroupBy, "SeriesGroupBy")
            self._patch_groupby_transform(SeriesGroupBy, "SeriesGroupBy")

    def _patch_series_expression_methods(self) -> None:
        self._patch_series_getitem()
        self._patch_series_unary_op("__invert__")
        for name in SERIES_BINARY_OPS:
            self._patch_series_binary_op(name)
        for name in SERIES_UNARY_META_METHODS:
            self._patch_series_unary_meta_method(name)
        for name in SERIES_LINEAGE_METHODS:
            self._patch_series_lineage_method(name)
        for name in SERIES_SCALAR_REDUCTIONS:
            self._patch_series_scalar_reduction(name)
        self._patch_series_unique()
        self._patch_series_corr()
        self._patch_series_to_frame()
        self._patch_string_extract()

    # ------------------------------------------------------------------
    # 通用 patch 基础设施
    # ------------------------------------------------------------------

    def _owner_from_label(self, owner_label: str) -> Any:
        if owner_label == "DataFrame":
            return pd.DataFrame
        if owner_label == "Series":
            return pd.Series
        if owner_label == "Pandas":
            return pd
        if owner_label == "DataFrameGroupBy" and DataFrameGroupBy is not None:
            return DataFrameGroupBy
        if owner_label == "SeriesGroupBy" and SeriesGroupBy is not None:
            return SeriesGroupBy
        if owner_label == "LocIndexer" and _LocIndexer is not None:
            return _LocIndexer
        if owner_label == "ILocIndexer" and _iLocIndexer is not None:
            return _iLocIndexer
        if owner_label == "StringMethods" and StringMethods is not None:
            return StringMethods
        return None

    def _remember_original(self, owner_label: str, attr: str, value: Any) -> None:
        key = f"{owner_label}::{attr}"
        if key not in self._originals:
            self._originals[key] = value

    def _register_patch(self, owner_label: str, owner: Any, attr: str, wrapped: Any) -> None:
        original = getattr(owner, attr, None)
        if original is None:
            return
        self._remember_original(owner_label, attr, original)
        setattr(owner, attr, wrapped)

    def _depth(self) -> int:
        return int(getattr(self._local, "depth", 0))

    @contextmanager
    def _boundary(self):
        depth = self._depth()
        self._local.depth = depth + 1
        try:
            yield
        finally:
            self._local.depth = depth

    def _is_outermost(self) -> bool:
        return self._depth() == 0

    # ------------------------------------------------------------------
    # 元数据 / 归一化工具
    # ------------------------------------------------------------------

    def _normalize_simple(self, value: Any) -> Any:
        """尽量把复杂参数压缩成可读且不会过度膨胀的结构。"""
        if value is None:
            return None
        if isinstance(value, (str, int, float, bool)):
            return value
        if isinstance(value, np.generic):
            return value.item()
        if isinstance(value, (pd.Timestamp, pd.Timedelta)):
            return str(value)
        if isinstance(value, slice):
            return {"slice": [value.start, value.stop, value.step]}
        if callable(value):
            return {
                "type": "callable",
                "name": getattr(value, "__name__", value.__class__.__name__),
            }
        if isinstance(value, pd.DataFrame):
            return {
                "type": "dataframe",
                "shape": list(value.shape),
                "columns": [str(c) for c in list(value.columns)[:20]],
            }
        if isinstance(value, pd.Series):
            meta = self._get_expr_meta(value)
            return {
                "type": "bool_series" if self._is_bool_series(value) else "series",
                "name": str(value.name),
                "len": int(len(value)),
                "reads": self._canonicalize_read_map(meta.read) if meta else {},
            }
        if isinstance(value, pd.Index):
            values = list(value)
            return [self._normalize_simple(v) for v in values[:20]]
        if isinstance(value, Mapping):
            out: Dict[str, Any] = {}
            for idx, (k, v) in enumerate(value.items()):
                if idx >= 20:
                    out["..."] = f"{len(value) - 20} more"
                    break
                out[str(k)] = self._normalize_simple(v)
            return out
        if isinstance(value, (list, tuple, set)):
            seq = list(value)
            normalized = [self._normalize_simple(v) for v in seq[:20]]
            if len(seq) > 20:
                normalized.append(f"... {len(seq) - 20} more")
            return normalized
        return repr(value)

    def _bind_call_args(
        self,
        func: Any,
        *call_args,
        drop_names: Optional[Sequence[str]] = None,
        **call_kwargs,
    ) -> Dict[str, Any]:
        """按原函数签名采集调用参数，保留原始对象供语义推断使用。"""
        drop_names = set(drop_names or [])
        try:
            sig = inspect.signature(func)
            bound = sig.bind_partial(*call_args, **call_kwargs)
            bound.apply_defaults()
            return {
                name: value
                for name, value in bound.arguments.items()
                if name not in drop_names
            }
        except Exception:
            return {str(k): v for k, v in call_kwargs.items() if k not in drop_names}

    def _capture_call_args(
        self,
        func: Any,
        *call_args,
        drop_names: Optional[Sequence[str]] = None,
        **call_kwargs,
    ) -> Dict[str, Any]:
        """按原函数签名采集调用参数，并做轻量归一化。"""
        raw_args = self._bind_call_args(func, *call_args, drop_names=drop_names, **call_kwargs)
        return {str(name): self._normalize_simple(value) for name, value in raw_args.items()}

    def _safe_columns(self, obj: Any) -> List[str]:
        """Return a bounded column preview rather than serializing ultra-wide schemas."""
        if isinstance(obj, pd.DataFrame):
            try:
                limit = int(self.max_trace_columns)
                return [str(c) for c in list(obj.columns[:limit])]
            except Exception:
                return []
        if isinstance(obj, pd.Series):
            try:
                return [str(obj.name)] if obj.name is not None else []
            except Exception:
                return []
        return []

    def _safe_column_count(self, obj: Any) -> int:
        try:
            if isinstance(obj, pd.DataFrame):
                return int(obj.shape[1])
            if isinstance(obj, pd.Series):
                return 1 if obj.name is not None else 0
        except Exception:
            pass
        return 0

    def _safe_shape(self, obj: Any) -> List[int]:
        if isinstance(obj, (pd.DataFrame, pd.Series, np.ndarray)):
            try:
                return list(obj.shape)
            except Exception:
                return []
        return []

    def _safe_index_names(self, obj: Any) -> List[str]:
        try:
            if isinstance(obj, (pd.DataFrame, pd.Series)):
                return [str(v) if v is not None else "<unnamed>" for v in list(obj.index.names)]
        except Exception:
            pass
        return []

    def _kind(self, obj: Any) -> str:
        if isinstance(obj, pd.DataFrame):
            return "dataframe"
        if isinstance(obj, pd.Series):
            return "series"
        if isinstance(obj, (str, int, float, bool, np.generic)):
            return "scalar"
        return type(obj).__name__.lower()

    def _friendly_label_for_obj(self, obj: Any, tid: str, previous_tid: Optional[str] = None) -> str:
        obj_id = id(obj)
        if obj_id in self._obj_aliases:
            return self._obj_aliases[obj_id]
        if previous_tid:
            previous_label = self._labels.get(previous_tid)
            if previous_label and previous_label != previous_tid:
                return previous_label
        return self._labels.get(tid, tid)

    def _cleanup_obj(self, obj_id: int) -> None:
        with self._lock:
            self._obj_to_tid.pop(obj_id, None)
            self._finalizers.pop(obj_id, None)
            self._obj_aliases.pop(obj_id, None)

    def _cleanup_expr(self, obj_id: int) -> None:
        with self._lock:
            self._expr_meta.pop(obj_id, None)
            self._expr_finalizers.pop(obj_id, None)

    def _remember_live_artifact(self, tid: str, obj: Any) -> None:
        """记录当前 tid 对应的活对象引用。

        这里只追踪 DataFrame / Series，供 visual anchor / evidence layer 在内存里取回。
        """
        if not isinstance(obj, (pd.DataFrame, pd.Series)):
            return
        try:
            self._tid_to_obj_ref[str(tid)] = weakref.ref(obj)
        except Exception:
            pass

    def _update_table_registry(self, tid: str, obj: Any, previous_tid: Optional[str] = None) -> None:
        self._remember_live_artifact(tid, obj)
        label = self._friendly_label_for_obj(obj, tid, previous_tid=previous_tid)
        self._labels[tid] = label
        columns = self._safe_columns(obj)
        column_count = self._safe_column_count(obj)
        columns_truncated = column_count > len(columns)
        previous = dict(self.table_registry.get(tid) or {})
        if columns_truncated and not previous.get("columns_truncated"):
            self._columns_truncated_table_count += 1
        self.table_registry[tid] = {
            "name": label,
            "kind": self._kind(obj),
            "columns": columns,
            "column_count": column_count,
            "columns_truncated": columns_truncated,
            "shape": self._safe_shape(obj),
            "index_names": self._safe_index_names(obj),
        }

    def _ensure_table(self, obj: Any, *, force: bool = False) -> str:
        """为对象分配稳定 table id，并抑制嵌套实现细节与超限节点。"""
        if obj is None:
            raise ValueError("obj cannot be None")

        obj_id = id(obj)
        with self._lock:
            existing_tid = self._obj_to_tid.get(obj_id)
            if existing_tid is not None:
                # Nested pandas internals may touch the same source object thousands of
                # times. Reuse its id without repeatedly refreshing metadata.
                if force or self._depth() <= 1:
                    self._update_table_registry(existing_tid, obj)
                return existing_tid

            if self._depth() > 1 and not force:
                self._nested_suppressed_table_count += 1
                return _NESTED_UNTRACKED_TID

            if len(self.table_registry) >= self.max_trace_tables and not force:
                self._dropped_table_count += 1
                return _NESTED_UNTRACKED_TID

            tid = f"t{self._next_table_id}"
            self._next_table_id += 1
            self._obj_to_tid[obj_id] = tid
            try:
                self._finalizers[obj_id] = weakref.finalize(obj, self._cleanup_obj, obj_id)
            except Exception:
                pass
            self._update_table_registry(tid, obj)
            return tid

    def _snapshot_table(self, obj: Any, previous_tid: Optional[str] = None, *, force: bool = False) -> str:
        """Create a new version node unless this is nested or the trace is full."""
        if obj is None:
            raise ValueError("obj cannot be None")

        obj_id = id(obj)
        with self._lock:
            if self._depth() > 1 and not force:
                self._nested_suppressed_table_count += 1
                return _NESTED_UNTRACKED_TID
            if len(self.table_registry) >= self.max_trace_tables and not force:
                self._dropped_table_count += 1
                return _NESTED_UNTRACKED_TID
            tid = f"t{self._next_table_id}"
            self._next_table_id += 1
            self._obj_to_tid[obj_id] = tid
            self._update_table_registry(tid, obj, previous_tid=previous_tid)
            return tid

    def _new_value_node(self, value: Any, *, force: bool = False) -> str:
        """为 scalar / ndarray 等非 pandas 返回值创建一次性节点。"""
        with self._lock:
            if self._depth() > 1 and not force:
                self._nested_suppressed_table_count += 1
                return _NESTED_UNTRACKED_TID
            if len(self.table_registry) >= self.max_trace_tables and not force:
                self._dropped_table_count += 1
                return _NESTED_UNTRACKED_TID
            tid = f"t{self._next_table_id}"
            self._next_table_id += 1
            self.table_registry[tid] = {
                "name": tid,
                "kind": self._kind(value),
                "columns": [],
                "column_count": 0,
                "columns_truncated": False,
                "shape": self._safe_shape(value),
                "index_names": [],
            }
            return tid

    def _ensure_result_node(self, value: Any) -> str:
        if isinstance(value, (pd.DataFrame, pd.Series)):
            return self._ensure_table(value)
        return self._new_value_node(value)

    def _fresh_output_node(self, value: Any) -> str:
        """为一次新的产出分配 fresh tid，避免 pandas item cache 导致多个事件共享同一 output。"""
        if isinstance(value, (pd.DataFrame, pd.Series)):
            previous_tid = self._obj_to_tid.get(id(value))
            return self._snapshot_table(value, previous_tid=previous_tid)
        return self._new_value_node(value)

    def _record(
        self,
        op: str,
        inputs: List[str],
        output: str,
        read: Optional[ReadMap | InternalReadMap] = None,
        write: Optional[Sequence[str]] = None,
        args: Optional[Dict[str, Any]] = None,
    ) -> None:
        canonical_read = self._canonicalize_read_map(read or {})
        canonical_write = [str(v) for v in write or [] if v is not None]
        canonical_write = list(dict.fromkeys(canonical_write))[: self.max_trace_columns]
        args = args or {}

        with self._lock:
            if self._depth() != 0:
                self._dropped_event_count += 1
                return
            clean_inputs = [str(tid) for tid in inputs if tid and str(tid) != _NESTED_UNTRACKED_TID]
            if not output or str(output) == _NESTED_UNTRACKED_TID:
                self._dropped_event_count += 1
                return
            if len(self.events) >= self.max_trace_events:
                self._dropped_event_count += 1
                return
            self.events.append(
                {
                    "id": self._next_event_id,
                    "op": op,
                    "inputs": clean_inputs,
                    "output": output,
                    "read": canonical_read,
                    "write": canonical_write,
                    "args": args,
                }
            )
            self._result_lineage[str(output)] = self._merge_read_maps(canonical_read)
            self._next_event_id += 1

    def _canonicalize_read_map(self, read: ReadMap | InternalReadMap) -> ReadMap:
        out: ReadMap = {}
        for tid, cols in dict(read).items():
            tid_text = str(tid or "")
            if not cols or not tid_text or tid_text == _NESTED_UNTRACKED_TID:
                continue
            unique_cols: List[str] = []
            seen = set()
            for col in cols:
                if col is None:
                    continue
                text = str(col)
                if text in seen:
                    continue
                seen.add(text)
                unique_cols.append(text)
                if len(unique_cols) >= self.max_trace_columns:
                    break
            if unique_cols:
                out[tid_text] = sorted(unique_cols)
        return out

    def _merge_read_maps(self, *maps: Optional[ReadMap | InternalReadMap]) -> InternalReadMap:
        merged: InternalReadMap = {}
        for mapping in maps:
            if not mapping:
                continue
            for tid, cols in dict(mapping).items():
                bucket = merged.setdefault(str(tid), set())
                bucket.update(str(col) for col in cols if col is not None)
        return merged

    def _read_map(self, tid: str, cols: Sequence[str]) -> InternalReadMap:
        cols = [str(c) for c in cols if c is not None]
        return {tid: set(cols)} if cols else {}

    def _lineage_for_tid(self, tid: Optional[str]) -> InternalReadMap:
        if tid is None:
            return {}
        with self._lock:
            lineage = self._result_lineage.get(str(tid))
        return self._merge_read_maps(lineage)

    def _normalize_cols(self, value: Any) -> List[str]:
        if value is None:
            return []
        if isinstance(value, str):
            return [value]
        if isinstance(value, pd.Index):
            return [str(v) for v in list(value[: self.max_trace_columns])]
        if isinstance(value, (list, tuple, set)):
            return [str(v) for v in list(value)[: self.max_trace_columns]]
        return [str(value)]

    def _normalize_axis(self, axis: Any) -> Any:
        if axis in (None, 0, "index"):
            return 0
        if axis in (1, "columns"):
            return 1
        return axis

    def _is_bool_series(self, value: Any) -> bool:
        return isinstance(value, pd.Series) and bool(getattr(value.dtype, "kind", None) == "b")

    def _is_bool_like_indexer(self, value: Any) -> bool:
        if isinstance(value, pd.Series):
            return self._is_bool_series(value)
        if isinstance(value, np.ndarray):
            return value.dtype == bool
        if isinstance(value, (list, tuple, pd.Index)):
            try:
                return len(value) > 0 and all(isinstance(v, (bool, np.bool_)) for v in list(value))
            except Exception:
                return False
        return False

    def _is_full_slice(self, value: Any) -> bool:
        return value is None or value is Ellipsis or (isinstance(value, slice) and value.start is None and value.stop is None and value.step is None)

    def _selected_columns_from_position(self, df: pd.DataFrame, selector: Any) -> List[str]:
        cols = list(df.columns)
        if selector is None:
            return []
        if isinstance(selector, (int, np.integer)):
            idx = int(selector)
            if -len(cols) <= idx < len(cols):
                return [str(cols[idx])]
            return []
        if isinstance(selector, slice):
            return [str(v) for v in cols[selector]]
        if isinstance(selector, (list, tuple, np.ndarray, pd.Index)):
            seq = list(selector)
            if seq and all(isinstance(v, (bool, np.bool_)) for v in seq):
                return [str(c) for c, flag in zip(cols, seq) if flag]
            out: List[str] = []
            for v in seq:
                if isinstance(v, (int, np.integer)):
                    idx = int(v)
                    if -len(cols) <= idx < len(cols):
                        out.append(str(cols[idx]))
            return out
        return []

    def _selected_columns_from_label(self, df: pd.DataFrame, selector: Any) -> List[str]:
        cols = [str(v) for v in list(df.columns)]
        raw_cols = list(df.columns)
        if selector is None:
            return []
        if isinstance(selector, str):
            return [selector] if selector in cols else []
        if isinstance(selector, pd.Index):
            return [str(v) for v in list(selector) if str(v) in cols]
        if isinstance(selector, slice):
            try:
                start = 0 if selector.start is None else raw_cols.index(selector.start)
                stop = len(raw_cols) - 1 if selector.stop is None else raw_cols.index(selector.stop)
                subset = raw_cols[start : stop + 1]
                return [str(v) for v in subset]
            except Exception:
                return cols
        if isinstance(selector, (list, tuple, set)):
            seq = list(selector)
            if seq and all(isinstance(v, (bool, np.bool_)) for v in seq):
                return [str(c) for c, flag in zip(raw_cols, seq) if flag]
            return [str(v) for v in seq if str(v) in cols]
        return []

    def _split_indexer_key(self, key: Any) -> Tuple[Any, Any]:
        if isinstance(key, tuple):
            if len(key) == 1:
                return key[0], None
            return key[0], key[1]
        return key, None

    def _extract_columns_from_selector(self, df: pd.DataFrame, selector: Any, positional: bool) -> List[str]:
        if positional:
            return self._selected_columns_from_position(df, selector)
        return self._selected_columns_from_label(df, selector)

    def _extract_drop_columns(self, args_map: Dict[str, Any]) -> List[str]:
        axis = self._normalize_axis(args_map.get("axis"))
        columns = self._normalize_cols(args_map.get("columns"))
        labels = self._normalize_cols(args_map.get("labels"))
        if columns:
            return columns
        if axis == 1:
            return labels
        return []

    def _extract_rename_columns(self, args_map: Dict[str, Any]) -> Tuple[List[str], List[str]]:
        columns_arg = args_map.get("columns")
        if isinstance(columns_arg, dict):
            return [str(k) for k in columns_arg.keys()], [str(v) for v in columns_arg.values()]

        mapper = args_map.get("mapper")
        axis = self._normalize_axis(args_map.get("axis"))
        if isinstance(mapper, dict) and axis == 1:
            return [str(k) for k in mapper.keys()], [str(v) for v in mapper.values()]
        return [], []

    def _extract_eval_assignment_target(self, expr: Any) -> Optional[str]:
        if not isinstance(expr, str):
            return None
        match = re.match(r"^\s*(`[^`]+`|[A-Za-z_]\w*)\s*=(?!=)", expr)
        if not match:
            return None
        target = match.group(1)
        if target.startswith("`") and target.endswith("`"):
            target = target[1:-1]
        return target

    def _extract_columns_from_expression(self, df: pd.DataFrame, expr: Any) -> List[str]:
        if not isinstance(expr, str):
            return []
        columns = [str(v) for v in list(df.columns)]
        found: List[str] = []

        # 先提取 `带空格列名`
        for match in re.findall(r"`([^`]+)`", expr):
            if str(match) in columns:
                found.append(str(match))

        # 再提取普通标识符
        plain_expr = re.sub(r"`[^`]+`", " ", expr)
        identifiers = re.findall(r"\b[A-Za-z_]\w*\b", plain_expr)
        reserved = {
            "and",
            "or",
            "not",
            "in",
            "True",
            "False",
            "None",
        }
        for token in identifiers:
            if token in reserved or token.startswith("@"):
                continue
            if token in columns:
                found.append(token)

        return list(dict.fromkeys(found))

    def _build_merge_trace(
        self,
        left_tid: str,
        right_tid: str,
        left: pd.DataFrame,
        right: pd.DataFrame,
        raw_args: Dict[str, Any],
        result: pd.DataFrame,
    ) -> Tuple[InternalReadMap, Dict[str, Any]]:
        left_cols = self._all_columns(left)
        right_cols = self._all_columns(right)
        on_cols = self._normalize_cols(raw_args.get("on"))
        left_on = self._normalize_cols(raw_args.get("left_on")) or list(on_cols)
        right_on = self._normalize_cols(raw_args.get("right_on")) or list(on_cols)
        read: InternalReadMap = {}
        if left_cols:
            read[left_tid] = set(left_cols)
        if right_cols:
            read[right_tid] = set(right_cols)
        extras = {
            "key_cols": on_cols,
            "left_key_cols": left_on,
            "right_key_cols": right_on,
            "left_value_cols": [col for col in left_cols if col not in set(left_on)],
            "right_value_cols": [col for col in right_cols if col not in set(right_on)],
            "output_cols": self._safe_columns(result),
        }
        return read, extras

    def _build_concat_trace(self, input_tids: Sequence[str], objects: Sequence[Any], result: Any) -> Tuple[InternalReadMap, Dict[str, Any]]:
        read: InternalReadMap = {}
        input_columns: Dict[str, List[str]] = {}
        for tid, obj in zip(input_tids, objects):
            cols = self._all_columns(obj)
            if cols:
                read[str(tid)] = set(cols)
                input_columns[str(tid)] = cols
        return read, {"input_columns": input_columns, "output_cols": self._safe_columns(result)}

    def _resolve_result_table(
        self,
        input_obj: Any,
        input_tid: str,
        result: Any,
        *,
        inplace_flag: bool = False,
    ) -> Tuple[Any, str]:
        """
        统一处理 inplace / 返回 None / 返回新对象 三类情况。
        """
        if inplace_flag or result is None:
            output_tid = self._snapshot_table(input_obj, previous_tid=input_tid)
            return input_obj, output_tid
        output_tid = self._ensure_table(result)
        return result, output_tid

    def _all_columns(self, obj: Any) -> List[str]:
        return self._safe_columns(obj)

    # ------------------------------------------------------------------
    # 表达式元数据
    # ------------------------------------------------------------------

    def _get_expr_meta(self, obj: Any) -> Optional[ExpressionMeta]:
        with self._lock:
            return self._expr_meta.get(id(obj))

    def _set_expr_meta(
        self,
        obj: Any,
        read: Optional[ReadMap | InternalReadMap],
        *,
        description: Optional[str] = None,
    ) -> None:
        if obj is None or read is None:
            return
        obj_id = id(obj)
        read_map = self._merge_read_maps(read)
        if not read_map:
            return
        with self._lock:
            self._expr_meta[obj_id] = ExpressionMeta(read=read_map, description=description)
            try:
                self._expr_finalizers[obj_id] = weakref.finalize(obj, self._cleanup_expr, obj_id)
            except Exception:
                pass

    def _infer_read_from_value(
        self,
        value: Any,
        *,
        default_tid: Optional[str] = None,
        default_cols: Optional[Sequence[str]] = None,
    ) -> InternalReadMap:
        if value is None:
            return {}

        meta = self._get_expr_meta(value)
        if meta is not None:
            return self._merge_read_maps(meta.read)

        if isinstance(value, pd.Series):
            try:
                tid = self._ensure_table(value)
            except Exception:
                tid = None
            lineage = self._lineage_for_tid(tid)
            if lineage:
                return lineage
            if value.name is not None:
                if default_tid is not None:
                    return self._read_map(default_tid, [str(value.name)])
                if tid is not None:
                    return self._read_map(tid, [str(value.name)])
            return {}

        if isinstance(value, pd.DataFrame):
            try:
                tid = self._ensure_table(value)
            except Exception:
                tid = None
            lineage = self._lineage_for_tid(tid)
            if lineage:
                return lineage
            if tid is not None:
                return self._read_map(tid, self._safe_columns(value))
            return {}

        if isinstance(value, Mapping):
            keys = [str(k) for k in value.keys()]
            if default_tid is not None and keys:
                return self._read_map(default_tid, keys)

        if default_tid is not None and default_cols:
            return self._read_map(default_tid, [str(v) for v in default_cols])
        return {}

    def _set_series_expr_from_source(self, series: pd.Series, source_tid: str, cols: Sequence[str], *, description: Optional[str] = None) -> None:
        self._set_expr_meta(series, self._read_map(source_tid, cols), description=description)

    # ------------------------------------------------------------------
    # GroupBy 元数据
    # ------------------------------------------------------------------

    def _group_meta(self, gb: Any) -> Dict[str, Any]:
        return dict(getattr(gb, "_trace_meta", {}) or {})

    def _set_group_meta(self, gb: Any, meta: Dict[str, Any]) -> None:
        try:
            setattr(gb, "_trace_meta", meta)
        except Exception:
            pass

    def _parse_groupby_output_columns(self, result: Any) -> List[str]:
        if isinstance(result, pd.DataFrame):
            return [str(v) for v in list(result.columns)]
        if isinstance(result, pd.Series):
            return [str(result.name)] if result.name is not None else []
        return []

    def _parse_groupby_read_write(
        self,
        source_tid: str,
        groupby_args: Dict[str, Any],
        selected_cols: Sequence[str],
        result: Any,
        *,
        agg_args: Optional[Tuple[Tuple[Any, ...], Dict[str, Any]]] = None,
        reduction_name: Optional[str] = None,
    ) -> Tuple[InternalReadMap, List[str]]:
        group_cols = self._normalize_cols(groupby_args.get("by"))
        read_cols: List[str] = list(group_cols)
        write_cols: List[str] = []

        if selected_cols:
            read_cols.extend(str(v) for v in selected_cols)

        if agg_args is not None:
            raw_args, raw_kwargs = agg_args
            if raw_kwargs:
                # named aggregation: out_col=("src_col", "mean")
                for out_col, spec in raw_kwargs.items():
                    if isinstance(spec, tuple) and len(spec) >= 1:
                        read_cols.append(str(spec[0]))
                        write_cols.append(str(out_col))

            if raw_args:
                first = raw_args[0]
                if isinstance(first, dict):
                    for src_col in first.keys():
                        read_cols.append(str(src_col))
                    if not write_cols:
                        write_cols.extend(str(k) for k in first.keys())

        if reduction_name == "size":
            # size 不依赖某个具体 value 列，但依赖分组键
            pass

        output_cols = self._parse_groupby_output_columns(result)
        if not write_cols:
            write_cols = [c for c in output_cols if c not in group_cols]
            if not write_cols and output_cols:
                write_cols = output_cols

        read_cols = list(dict.fromkeys([str(c) for c in read_cols if c is not None]))
        return self._read_map(source_tid, read_cols), write_cols

    # ------------------------------------------------------------------
    # DataFrame patch
    # ------------------------------------------------------------------

    def _patch_dataframe_copy(self) -> None:
        original = pd.DataFrame.copy
        self._remember_original("DataFrame", "copy", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)
            if outermost:
                patcher._record(
                    op="copy",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, patcher._all_columns(df)),
                    write=patcher._all_columns(result),
                    args=patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.copy = wrapped

    def _patch_dataframe_getitem(self) -> None:
        original = pd.DataFrame.__getitem__
        self._remember_original("DataFrame", "__getitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(df, key):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, key)

                if isinstance(result, pd.Series):
                    read_cols = patcher._normalize_cols(key)
                    if read_cols:
                        patcher._set_series_expr_from_source(result, input_tid, read_cols, description="dataframe_getitem")

            if not outermost:
                return result

            args = {"key": patcher._normalize_simple(key)}
            if isinstance(key, pd.DataFrame):
                read = patcher._read_map(input_tid, patcher._safe_columns(key))
                output_tid = patcher._fresh_output_node(result)
                patcher._record(
                    op="where",
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args=args,
                )
                return result

            if patcher._is_bool_like_indexer(key):
                predicate_read = patcher._infer_read_from_value(key, default_tid=input_tid)
                output_tid = patcher._fresh_output_node(result)
                patcher._record(
                    op="filter",
                    inputs=[input_tid],
                    output=output_tid,
                    read=predicate_read,
                    write=[],
                    args=args,
                )
                return result

            if isinstance(key, slice):
                output_tid = patcher._fresh_output_node(result)
                patcher._record(
                    op="slice_rows",
                    inputs=[input_tid],
                    output=output_tid,
                    read={},
                    write=[],
                    args=args,
                )
                return result

            output_tid = patcher._fresh_output_node(result)
            read_cols = patcher._normalize_cols(key)
            if isinstance(result, pd.Series):
                patcher._record(
                    op="select_series",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=args,
                )
                return result

            patcher._record(
                op="select",
                inputs=[input_tid],
                output=output_tid,
                read=patcher._read_map(input_tid, read_cols),
                write=[],
                args=args,
            )
            return result

        pd.DataFrame.__getitem__ = wrapped

    def _patch_dataframe_setitem(self) -> None:
        original = pd.DataFrame.__setitem__
        self._remember_original("DataFrame", "__setitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(df, key, value):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                before_cols = [str(c) for c in df.columns]
                result = original(df, key, value)
                after_cols = [str(c) for c in df.columns]
                output_tid = patcher._snapshot_table(df, previous_tid=input_tid)

            if not outermost:
                return result

            target_cols = patcher._normalize_cols(key)
            new_columns = [c for c in after_cols if c not in before_cols]
            write_cols = new_columns or target_cols or after_cols
            read_map = patcher._infer_read_from_value(value, default_tid=input_tid)
            patcher._record(
                op="derive" if new_columns else "update_column",
                inputs=[input_tid],
                output=output_tid,
                read=read_map,
                write=write_cols,
                args=patcher._capture_call_args(original, df, key, value, drop_names=["self"]),
            )
            return result

        pd.DataFrame.__setitem__ = wrapped

    def _patch_dataframe_merge(self) -> None:
        original = pd.DataFrame.merge
        self._remember_original("DataFrame", "merge", original)
        patcher = self

        @wraps(original)
        def wrapped(left, right, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                left_tid = patcher._ensure_table(left)
                right_tid = patcher._ensure_table(right)
                result = original(left, right, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                raw_args = patcher._bind_call_args(original, left, right, *args, **kwargs, drop_names=["self"])
                args_map = patcher._capture_call_args(original, left, right, *args, **kwargs, drop_names=["self"])
                read, extras = patcher._build_merge_trace(left_tid, right_tid, left, right, raw_args, result)
                patcher._record(
                    op="join",
                    inputs=[left_tid, right_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={**args_map, **extras},
                )
            return result

        pd.DataFrame.merge = wrapped

    def _patch_dataframe_join(self) -> None:
        original = pd.DataFrame.join
        self._remember_original("DataFrame", "join", original)
        patcher = self

        @wraps(original)
        def wrapped(left, other, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                left_tid = patcher._ensure_table(left)
                other_objects = list(other) if isinstance(other, (list, tuple)) else [other]
                right_tids = [patcher._ensure_table(obj) for obj in other_objects if isinstance(obj, pd.DataFrame)]
                result = original(left, other, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                args_map = patcher._capture_call_args(original, left, other, *args, **kwargs, drop_names=["self"])
                read: InternalReadMap = {}
                left_cols = patcher._all_columns(left)
                input_columns: Dict[str, List[str]] = {}
                if left_cols:
                    read[left_tid] = set(left_cols)
                    input_columns[left_tid] = left_cols
                for tid, obj in zip(right_tids, [obj for obj in other_objects if isinstance(obj, pd.DataFrame)]):
                    cols = patcher._all_columns(obj)
                    if cols:
                        read[tid] = set(cols)
                        input_columns[tid] = cols
                patcher._record(
                    op="join",
                    inputs=[left_tid] + right_tids,
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={
                        **args_map,
                        "key_cols": patcher._normalize_cols(args_map.get("on")),
                        "input_columns": input_columns,
                        "output_cols": patcher._safe_columns(result),
                    },
                )
            return result

        pd.DataFrame.join = wrapped

    def _patch_top_level_merge(self) -> None:
        original = pd.merge
        self._remember_original("Pandas", "merge", original)
        patcher = self

        @wraps(original)
        def wrapped(left, right, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                left_tid = patcher._ensure_table(left)
                right_tid = patcher._ensure_table(right)
                result = original(left, right, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                raw_args = patcher._bind_call_args(original, left, right, *args, **kwargs)
                args_map = patcher._capture_call_args(original, left, right, *args, **kwargs)
                read, extras = patcher._build_merge_trace(left_tid, right_tid, left, right, raw_args, result)
                patcher._record(
                    op="join",
                    inputs=[left_tid, right_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={**args_map, **extras},
                )
            return result

        pd.merge = wrapped

    def _materialize_concat_input(self, objs: Any) -> Tuple[Any, List[Any]]:
        if isinstance(objs, Mapping):
            materialized = dict(objs)
            return materialized, list(materialized.values())
        materialized_list = list(objs)
        return materialized_list, materialized_list

    def _patch_top_level_concat(self) -> None:
        original = pd.concat
        self._remember_original("Pandas", "concat", original)
        patcher = self

        @wraps(original)
        def wrapped(objs, *args, **kwargs):
            outermost = patcher._is_outermost()
            materialized, objects = patcher._materialize_concat_input(objs)
            with patcher._boundary():
                input_tids = [patcher._ensure_table(obj) for obj in objects if isinstance(obj, (pd.DataFrame, pd.Series))]
                result = original(materialized, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                args_map = patcher._capture_call_args(original, materialized, *args, **kwargs)
                traced_objects = [obj for obj in objects if isinstance(obj, (pd.DataFrame, pd.Series))]
                read, extras = patcher._build_concat_trace(input_tids, traced_objects, result)
                patcher._record(
                    op="concat",
                    inputs=input_tids,
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={**args_map, **extras},
                )
            return result

        pd.concat = wrapped

    def _patch_dataframe_groupby(self) -> None:
        original = pd.DataFrame.groupby
        self._remember_original("DataFrame", "groupby", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                gb = original(df, *args, **kwargs)
            meta = {
                "source_tid": input_tid,
                "groupby_args": patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
            }
            patcher._set_group_meta(gb, meta)
            return gb

        pd.DataFrame.groupby = wrapped

    def _patch_dataframe_assign(self) -> None:
        original = pd.DataFrame.assign
        self._remember_original("DataFrame", "assign", original)
        patcher = self

        @wraps(original)
        def wrapped(df, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                read = {}
                for value in kwargs.values():
                    read = patcher._merge_read_maps(read, patcher._infer_read_from_value(value, default_tid=input_tid))
                patcher._record(
                    op="derive",
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=[str(k) for k in kwargs.keys()],
                    args=patcher._capture_call_args(original, df, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.assign = wrapped

    def _patch_dataframe_rename(self) -> None:
        original = pd.DataFrame.rename
        self._remember_original("DataFrame", "rename", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                read_cols, write_cols = patcher._extract_rename_columns(args_map)
                patcher._record(
                    op="rename",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=write_cols,
                    args=args_map,
                )
            return result

        pd.DataFrame.rename = wrapped

    def _patch_dataframe_set_index(self) -> None:
        original = pd.DataFrame.set_index
        self._remember_original("DataFrame", "set_index", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                read_cols = patcher._normalize_cols(args_map.get("keys"))
                patcher._record(
                    op="set_index",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.set_index = wrapped

    def _patch_dataframe_reset_index(self) -> None:
        original = pd.DataFrame.reset_index
        self._remember_original("DataFrame", "reset_index", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            before_cols = [str(v) for v in list(df.columns)]
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                output_obj, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                after_cols = [str(v) for v in list(output_obj.columns)] if isinstance(output_obj, pd.DataFrame) else []
                write_cols = [c for c in after_cols if c not in before_cols]
                patcher._record(
                    op="reset_index",
                    inputs=[input_tid],
                    output=output_tid,
                    read={},
                    write=write_cols,
                    args=patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.reset_index = wrapped

    def _patch_dataframe_sort_values(self) -> None:
        original = pd.DataFrame.sort_values
        self._remember_original("DataFrame", "sort_values", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                by_cols = patcher._normalize_cols(args_map.get("by"))
                patcher._record(
                    op="sort",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, by_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.sort_values = wrapped

    def _patch_dataframe_sort_index(self) -> None:
        original = pd.DataFrame.sort_index
        self._remember_original("DataFrame", "sort_index", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                patcher._record(
                    op="sort_index",
                    inputs=[input_tid],
                    output=output_tid,
                    read={},
                    write=[],
                    args=patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.sort_index = wrapped

    def _patch_dataframe_drop(self) -> None:
        original = pd.DataFrame.drop
        self._remember_original("DataFrame", "drop", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                patcher._record(
                    op="drop",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, patcher._extract_drop_columns(args_map)),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.drop = wrapped

    def _patch_dataframe_dropna(self) -> None:
        original = pd.DataFrame.dropna
        self._remember_original("DataFrame", "dropna", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                subset_cols = patcher._normalize_cols(args_map.get("subset")) or patcher._all_columns(df)
                patcher._record(
                    op="dropna",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, subset_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.dropna = wrapped

    def _patch_dataframe_drop_duplicates(self) -> None:
        original = pd.DataFrame.drop_duplicates
        self._remember_original("DataFrame", "drop_duplicates", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                subset_cols = patcher._normalize_cols(args_map.get("subset")) or patcher._all_columns(df)
                patcher._record(
                    op="drop_duplicates",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, subset_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.drop_duplicates = wrapped

    def _patch_dataframe_fillna(self) -> None:
        original = pd.DataFrame.fillna
        self._remember_original("DataFrame", "fillna", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                raw_args = patcher._bind_call_args(original, df, *args, **kwargs, drop_names=["self"])
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                value_arg = raw_args.get("value")
                write_cols = patcher._all_columns(df)
                if isinstance(value_arg, Mapping):
                    write_cols = [str(k) for k in value_arg.keys()]
                read = patcher._merge_read_maps(
                    patcher._infer_read_from_value(df, default_tid=input_tid, default_cols=write_cols),
                    patcher._infer_read_from_value(value_arg, default_tid=input_tid),
                )
                patcher._record(
                    op="fillna",
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=write_cols,
                    args=args_map,
                )
            return result

        pd.DataFrame.fillna = wrapped

    def _patch_dataframe_replace(self) -> None:
        original = pd.DataFrame.replace
        self._remember_original("DataFrame", "replace", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                raw_args = patcher._bind_call_args(original, df, *args, **kwargs, drop_names=["self"])
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                to_replace = raw_args.get("to_replace")
                write_cols = patcher._all_columns(df)
                if isinstance(to_replace, Mapping):
                    write_cols = [str(k) for k in to_replace.keys()]
                patcher._record(
                    op="replace",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._infer_read_from_value(df, default_tid=input_tid, default_cols=write_cols),
                    write=write_cols,
                    args=args_map,
                )
            return result

        pd.DataFrame.replace = wrapped

    def _patch_dataframe_astype(self) -> None:
        original = pd.DataFrame.astype
        self._remember_original("DataFrame", "astype", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                raw_args = patcher._bind_call_args(original, df, *args, **kwargs, drop_names=["self"])
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                dtype_arg = raw_args.get("dtype")
                write_cols = patcher._all_columns(df)
                if isinstance(dtype_arg, Mapping):
                    write_cols = [str(k) for k in dtype_arg.keys()]
                patcher._record(
                    op="astype",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._infer_read_from_value(df, default_tid=input_tid, default_cols=write_cols),
                    write=write_cols,
                    args=args_map,
                )
            return result

        pd.DataFrame.astype = wrapped

    def _patch_dataframe_where_like(self, method_name: str) -> None:
        original = getattr(pd.DataFrame, method_name)
        self._remember_original("DataFrame", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(df, cond, other=np.nan, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, cond, other=other, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                read = patcher._merge_read_maps(
                    patcher._infer_read_from_value(cond, default_tid=input_tid, default_cols=patcher._all_columns(df)),
                    patcher._infer_read_from_value(other, default_tid=input_tid),
                )
                patcher._record(
                    op=method_name,
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._all_columns(df),
                    args=patcher._capture_call_args(original, df, cond, other=other, *args, **kwargs, drop_names=["self"]),
                )
            return result

        setattr(pd.DataFrame, method_name, wrapped)

    def _patch_dataframe_query(self) -> None:
        original = pd.DataFrame.query
        self._remember_original("DataFrame", "query", original)
        patcher = self

        @wraps(original)
        def wrapped(df, expr, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, expr, *args, **kwargs)
                inplace = bool(kwargs.get("inplace", False))
                _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                read_cols = patcher._extract_columns_from_expression(df, expr)
                patcher._record(
                    op="filter",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=patcher._capture_call_args(original, df, expr, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.query = wrapped

    def _patch_dataframe_eval(self) -> None:
        original = pd.DataFrame.eval
        self._remember_original("DataFrame", "eval", original)
        patcher = self

        @wraps(original)
        def wrapped(df, expr, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, expr, *args, **kwargs)

                inplace = bool(kwargs.get("inplace", False))
                if isinstance(result, pd.Series):
                    output_tid = patcher._ensure_table(result)
                    patcher._set_expr_meta(
                        result,
                        patcher._read_map(input_tid, patcher._extract_columns_from_expression(df, expr)),
                        description="dataframe_eval",
                    )
                else:
                    _, output_tid = patcher._resolve_result_table(df, input_tid, result, inplace_flag=inplace)

            if outermost:
                read_cols = patcher._extract_columns_from_expression(df, expr)
                write_cols = []
                target = patcher._extract_eval_assignment_target(expr)
                if target:
                    write_cols = [target]
                patcher._record(
                    op="eval",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=write_cols,
                    args=patcher._capture_call_args(original, df, expr, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.eval = wrapped

    def _patch_dataframe_pivot(self) -> None:
        original = pd.DataFrame.pivot
        self._remember_original("DataFrame", "pivot", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                read_cols: List[str] = []
                for key in ("index", "columns", "values"):
                    read_cols.extend(patcher._normalize_cols(args_map.get(key)))
                patcher._record(
                    op="reshape",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.pivot = wrapped

    def _patch_dataframe_pivot_table(self) -> None:
        original = pd.DataFrame.pivot_table
        self._remember_original("DataFrame", "pivot_table", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                read_cols: List[str] = []
                for key in ("index", "columns", "values"):
                    read_cols.extend(patcher._normalize_cols(args_map.get(key)))
                patcher._record(
                    op="reshape",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.pivot_table = wrapped

    def _patch_dataframe_melt(self) -> None:
        original = pd.DataFrame.melt
        self._remember_original("DataFrame", "melt", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                args_map = patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"])
                read_cols: List[str] = []
                for key in ("id_vars", "value_vars"):
                    read_cols.extend(patcher._normalize_cols(args_map.get(key)))
                patcher._record(
                    op="reshape",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=[],
                    args=args_map,
                )
            return result

        pd.DataFrame.melt = wrapped

    def _patch_dataframe_explode(self) -> None:
        original = pd.DataFrame.explode
        self._remember_original("DataFrame", "explode", original)
        patcher = self

        @wraps(original)
        def wrapped(df, column, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, column, *args, **kwargs)
                ignore_index = bool(kwargs.get("ignore_index", False))
                output_tid = patcher._ensure_table(result)

            if outermost:
                read_cols = patcher._normalize_cols(column)
                patcher._record(
                    op="explode",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=read_cols,
                    args=patcher._capture_call_args(original, df, column, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.explode = wrapped

    def _patch_dataframe_stack(self) -> None:
        original = pd.DataFrame.stack
        self._remember_original("DataFrame", "stack", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                patcher._record(
                    op="stack",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, patcher._all_columns(df)),
                    write=[],
                    args=patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.stack = wrapped

    def _patch_dataframe_unstack(self) -> None:
        original = pd.DataFrame.unstack
        self._remember_original("DataFrame", "unstack", original)
        patcher = self

        @wraps(original)
        def wrapped(df, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                patcher._record(
                    op="unstack",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, patcher._all_columns(df)),
                    write=[],
                    args=patcher._capture_call_args(original, df, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.unstack = wrapped

    def _patch_dataframe_apply(self) -> None:
        original = pd.DataFrame.apply
        self._remember_original("DataFrame", "apply", original)
        patcher = self

        @wraps(original)
        def wrapped(df, func, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(df)
                result = original(df, func, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

                if isinstance(result, pd.Series):
                    patcher._set_expr_meta(result, patcher._read_map(input_tid, patcher._all_columns(df)), description="dataframe_apply")

            if outermost:
                axis = kwargs.get("axis", 0)
                read_cols = patcher._all_columns(df)
                patcher._record(
                    op="apply",
                    inputs=[input_tid],
                    output=output_tid,
                    read=patcher._read_map(input_tid, read_cols),
                    write=patcher._safe_columns(result),
                    args=patcher._capture_call_args(original, df, func, *args, **kwargs, drop_names=["self"]),
                )
            return result

        pd.DataFrame.apply = wrapped

    # ------------------------------------------------------------------
    # Indexer patch（loc / iloc）
    # ------------------------------------------------------------------

    def _patch_indexer_getitem(self, owner: Any, owner_label: str, mode: str) -> None:
        original = owner.__getitem__
        self._remember_original(owner_label, "__getitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(indexer, key):
            outermost = patcher._is_outermost()
            obj = getattr(indexer, "obj", None)
            with patcher._boundary():
                result = original(indexer, key)

                if isinstance(obj, pd.DataFrame) and isinstance(result, pd.Series):
                    row_key, col_key = patcher._split_indexer_key(key)
                    selected_cols = patcher._extract_columns_from_selector(obj, col_key, positional=(mode == "iloc"))
                    if not selected_cols and col_key is None and mode == "loc":
                        # df.loc[row_label] 返回整行 Series，保守地认为读了全部列
                        selected_cols = patcher._all_columns(obj)
                    if selected_cols:
                        source_tid = patcher._ensure_table(obj)
                        patcher._set_series_expr_from_source(result, source_tid, selected_cols, description=f"{mode}_getitem")
                elif isinstance(obj, pd.Series) and isinstance(result, pd.Series):
                    patcher._set_expr_meta(result, patcher._infer_read_from_value(obj), description=f"{mode}_getitem")

            if not outermost or not isinstance(obj, (pd.DataFrame, pd.Series)):
                return result

            input_tid = patcher._ensure_table(obj)
            output_tid = patcher._fresh_output_node(result)
            args = {"indexer": mode, "key": patcher._normalize_simple(key)}

            if isinstance(obj, pd.Series):
                read = patcher._infer_read_from_value(obj)
                if patcher._is_bool_like_indexer(key):
                    read = patcher._merge_read_maps(read, patcher._infer_read_from_value(key))
                    patcher._record(
                        op="filter",
                        inputs=patcher._direct_input_tids(obj, key) or [input_tid],
                        output=output_tid,
                        read=read,
                        write=patcher._series_write_cols(result),
                        args=args,
                    )
                    return result
                if isinstance(key, slice):
                    patcher._record(
                        op="slice_rows",
                        inputs=[input_tid],
                        output=output_tid,
                        read=read,
                        write=patcher._series_write_cols(result),
                        args=args,
                    )
                    return result
                patcher._record(
                    op="select",
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._series_write_cols(result),
                    args=args,
                )
                return result

            row_key, col_key = patcher._split_indexer_key(key)
            selected_cols = patcher._extract_columns_from_selector(obj, col_key, positional=(mode == "iloc"))
            predicate_read = patcher._infer_read_from_value(row_key, default_tid=input_tid)

            if patcher._is_bool_like_indexer(row_key):
                read = patcher._merge_read_maps(predicate_read, patcher._read_map(input_tid, selected_cols))
                patcher._record(
                    op="filter",
                    inputs=patcher._direct_input_tids(obj, row_key) or [input_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result) if isinstance(result, pd.DataFrame) else [],
                    args=args,
                )
                return result

            if col_key is not None:
                op = "select_series" if isinstance(result, pd.Series) else "select"
                read = patcher._read_map(input_tid, selected_cols or patcher._safe_columns(result))
                patcher._record(
                    op=op,
                    inputs=[input_tid],
                    output=output_tid,
                    read=read,
                    write=[],
                    args=args,
                )
                return result

            read_cols = patcher._all_columns(obj) if isinstance(result, pd.Series) else []
            patcher._record(
                op="slice_rows",
                inputs=[input_tid],
                output=output_tid,
                read=patcher._read_map(input_tid, read_cols),
                write=patcher._safe_columns(result) if isinstance(result, pd.DataFrame) else [],
                args=args,
            )
            return result

        setattr(owner, "__getitem__", wrapped)

    def _patch_indexer_setitem(self, owner: Any, owner_label: str, mode: str) -> None:
        original = owner.__setitem__
        self._remember_original(owner_label, "__setitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(indexer, key, value):
            outermost = patcher._is_outermost()
            df = getattr(indexer, "obj", None)
            with patcher._boundary():
                if isinstance(df, pd.DataFrame):
                    input_tid = patcher._ensure_table(df)
                else:
                    input_tid = None
                result = original(indexer, key, value)
                if isinstance(df, pd.DataFrame) and input_tid is not None:
                    output_tid = patcher._snapshot_table(df, previous_tid=input_tid)
                else:
                    output_tid = None

            if not outermost or not isinstance(df, pd.DataFrame) or input_tid is None or output_tid is None:
                return result

            row_key, col_key = patcher._split_indexer_key(key)
            write_cols = patcher._extract_columns_from_selector(df, col_key, positional=(mode == "iloc"))
            if not write_cols and col_key is None:
                write_cols = patcher._all_columns(df)
            read = patcher._merge_read_maps(
                patcher._infer_read_from_value(row_key, default_tid=input_tid),
                patcher._infer_read_from_value(value, default_tid=input_tid),
            )
            patcher._record(
                op="update_column" if write_cols else "update_values",
                inputs=[input_tid],
                output=output_tid,
                read=read,
                write=write_cols,
                args={
                    "indexer": mode,
                    "key": patcher._normalize_simple(key),
                    "value": patcher._normalize_simple(value),
                },
            )
            return result

        setattr(owner, "__setitem__", wrapped)

    # ------------------------------------------------------------------
    # GroupBy patch
    # ------------------------------------------------------------------

    def _patch_groupby_getitem(self) -> None:
        if DataFrameGroupBy is None:
            return

        original = DataFrameGroupBy.__getitem__
        self._remember_original("DataFrameGroupBy", "__getitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(gb, key):
            with patcher._boundary():
                result = original(gb, key)

            meta = patcher._group_meta(gb)
            selected_cols = patcher._normalize_cols(key)
            meta["select_key"] = selected_cols
            patcher._set_group_meta(result, meta)
            return result

        DataFrameGroupBy.__getitem__ = wrapped

    def _patch_groupby_agg(self, owner: Any, owner_label: str) -> None:
        original = getattr(owner, "agg", None)
        if original is None:
            return
        self._remember_original(owner_label, "agg", original)
        patcher = self

        @wraps(original)
        def wrapped(gb, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                meta = patcher._group_meta(gb)
                source_tid = meta.get("source_tid") or patcher._ensure_table(getattr(gb, "obj", gb))
                result = original(gb, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                groupby_args = dict(meta.get("groupby_args", {}) or {})
                selected_cols = meta.get("select_key") or []
                read, write = patcher._parse_groupby_read_write(
                    source_tid,
                    groupby_args,
                    selected_cols,
                    result,
                    agg_args=(args, kwargs),
                )
                patcher._record(
                    op="group_agg",
                    inputs=[source_tid],
                    output=output_tid,
                    read=read,
                    write=write,
                    args={
                        "groupby": groupby_args,
                        "agg": patcher._capture_call_args(original, gb, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        setattr(owner, "agg", wrapped)

    def _patch_groupby_agg_alias(self, owner: Any, owner_label: str, alias_name: str) -> None:
        original = getattr(owner, alias_name, None)
        if original is None:
            return
        self._remember_original(owner_label, alias_name, original)
        patcher = self

        @wraps(original)
        def wrapped(gb, *args, **kwargs):
            return getattr(owner, "agg")(gb, *args, **kwargs)

        setattr(owner, alias_name, wrapped)

    def _patch_groupby_named_agg(self, owner: Any, owner_label: str, method_name: str) -> None:
        original = getattr(owner, method_name, None)
        if original is None:
            return
        self._remember_original(owner_label, method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(gb, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                meta = patcher._group_meta(gb)
                source_tid = meta.get("source_tid") or patcher._ensure_table(getattr(gb, "obj", gb))
                result = original(gb, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                groupby_args = dict(meta.get("groupby_args", {}) or {})
                selected_cols = meta.get("select_key") or []
                read, write = patcher._parse_groupby_read_write(
                    source_tid,
                    groupby_args,
                    selected_cols,
                    result,
                    reduction_name=method_name,
                )
                patcher._record(
                    op="group_agg",
                    inputs=[source_tid],
                    output=output_tid,
                    read=read,
                    write=write,
                    args={
                        "groupby": groupby_args,
                        "agg": {"method": method_name, **patcher._capture_call_args(original, gb, *args, **kwargs, drop_names=["self"])},
                    },
                )
            return result

        setattr(owner, method_name, wrapped)

    def _patch_groupby_apply(self, owner: Any, owner_label: str) -> None:
        original = getattr(owner, "apply", None)
        if original is None:
            return
        self._remember_original(owner_label, "apply", original)
        patcher = self

        @wraps(original)
        def wrapped(gb, func, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                meta = patcher._group_meta(gb)
                source_tid = meta.get("source_tid") or patcher._ensure_table(getattr(gb, "obj", gb))
                result = original(gb, func, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

            if outermost:
                groupby_args = dict(meta.get("groupby_args", {}) or {})
                selected_cols = meta.get("select_key") or patcher._safe_columns(getattr(gb, "obj", gb))
                read = patcher._read_map(source_tid, patcher._normalize_cols(groupby_args.get("by")) + list(selected_cols))
                patcher._record(
                    op="group_apply",
                    inputs=[source_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={
                        "groupby": groupby_args,
                        "apply": patcher._capture_call_args(original, gb, func, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        setattr(owner, "apply", wrapped)

    def _patch_groupby_transform(self, owner: Any, owner_label: str) -> None:
        original = getattr(owner, "transform", None)
        if original is None:
            return
        self._remember_original(owner_label, "transform", original)
        patcher = self

        @wraps(original)
        def wrapped(gb, func, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                meta = patcher._group_meta(gb)
                source_tid = meta.get("source_tid") or patcher._ensure_table(getattr(gb, "obj", gb))
                result = original(gb, func, *args, **kwargs)
                output_tid = patcher._ensure_table(result)

                if isinstance(result, pd.Series):
                    selected_cols = meta.get("select_key") or [result.name] if getattr(result, "name", None) is not None else []
                    patcher._set_expr_meta(result, patcher._read_map(source_tid, selected_cols), description="groupby_transform")

            if outermost:
                groupby_args = dict(meta.get("groupby_args", {}) or {})
                selected_cols = meta.get("select_key") or patcher._safe_columns(getattr(gb, "obj", gb))
                read = patcher._read_map(source_tid, patcher._normalize_cols(groupby_args.get("by")) + list(selected_cols))
                patcher._record(
                    op="group_transform",
                    inputs=[source_tid],
                    output=output_tid,
                    read=read,
                    write=patcher._safe_columns(result),
                    args={
                        "groupby": groupby_args,
                        "transform": patcher._capture_call_args(original, gb, func, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        setattr(owner, "transform", wrapped)

    # ------------------------------------------------------------------
    # Series 表达式元数据 patch
    # ------------------------------------------------------------------

    def _direct_input_tids(self, *values: Any) -> List[str]:
        tids: List[str] = []
        for value in values:
            if isinstance(value, (pd.DataFrame, pd.Series)):
                try:
                    tid = self._ensure_table(value)
                    if tid != _NESTED_UNTRACKED_TID:
                        tids.append(tid)
                except Exception:
                    continue
        return list(dict.fromkeys(tids))

    def _series_write_cols(self, value: Any) -> List[str]:
        if isinstance(value, pd.Series) and value.name is not None:
            return [str(value.name)]
        return []

    def _patch_series_getitem(self) -> None:
        original = pd.Series.__getitem__
        self._remember_original("Series", "__getitem__", original)
        patcher = self

        @wraps(original)
        def wrapped(series, key):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(series)
                result = original(series, key)
                if isinstance(result, pd.Series):
                    read = patcher._merge_read_maps(
                        patcher._infer_read_from_value(series),
                        patcher._infer_read_from_value(key),
                    )
                    patcher._set_expr_meta(result, read, description="series_getitem")

            if not outermost:
                return result

            output_tid = patcher._fresh_output_node(result)
            args = {"key": patcher._normalize_simple(key)}
            inputs = [input_tid] + [tid for tid in patcher._direct_input_tids(key) if tid != input_tid]

            if patcher._is_bool_like_indexer(key):
                read = patcher._merge_read_maps(
                    patcher._infer_read_from_value(series),
                    patcher._infer_read_from_value(key),
                )
                patcher._record(
                    op="filter",
                    inputs=inputs,
                    output=output_tid,
                    read=read,
                    write=patcher._series_write_cols(result),
                    args=args,
                )
                return result

            if isinstance(key, slice):
                patcher._record(
                    op="slice_rows",
                    inputs=inputs,
                    output=output_tid,
                    read=patcher._infer_read_from_value(series),
                    write=patcher._series_write_cols(result),
                    args=args,
                )
                return result

            label_read = patcher._infer_read_from_value(series)
            if not isinstance(result, pd.Series):
                try:
                    if key in series.index:
                        label_read = patcher._read_map(input_tid, [str(key)])
                except Exception:
                    pass
            patcher._record(
                op="select",
                inputs=inputs,
                output=output_tid,
                read=label_read,
                write=patcher._series_write_cols(result),
                args=args,
            )
            return result

        pd.Series.__getitem__ = wrapped

    def _patch_series_binary_op(self, method_name: str) -> None:
        original = getattr(pd.Series, method_name, None)
        if original is None:
            return
        self._remember_original("Series", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(left, other):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                result = original(left, other)

            if isinstance(result, pd.Series):
                read = patcher._merge_read_maps(
                    patcher._infer_read_from_value(left),
                    patcher._infer_read_from_value(other),
                )
                patcher._set_expr_meta(result, read, description=method_name)

                if outermost:
                    patcher._record(
                        op="series_expr",
                        inputs=patcher._direct_input_tids(left, other),
                        output=patcher._fresh_output_node(result),
                        read=read,
                        write=patcher._series_write_cols(result),
                        args={
                            "method": SERIES_BINARY_OP_LABELS.get(method_name, method_name),
                            "other": patcher._normalize_simple(other),
                        },
                    )
            return result

        setattr(pd.Series, method_name, wrapped)

    def _patch_series_unary_op(self, method_name: str) -> None:
        original = getattr(pd.Series, method_name, None)
        if original is None:
            return
        self._remember_original("Series", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                result = original(series, *args, **kwargs)

            if isinstance(result, pd.Series):
                read = patcher._infer_read_from_value(series)
                patcher._set_expr_meta(result, read, description=method_name)

                if outermost:
                    patcher._record(
                        op="series_expr",
                        inputs=patcher._direct_input_tids(series),
                        output=patcher._fresh_output_node(result),
                        read=read,
                        write=patcher._series_write_cols(result),
                        args={
                            "method": method_name.strip("_"),
                            **patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                        },
                    )
            return result

        setattr(pd.Series, method_name, wrapped)

    def _patch_series_unary_meta_method(self, method_name: str) -> None:
        original = getattr(pd.Series, method_name, None)
        if original is None:
            return
        self._remember_original("Series", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            raw_args = patcher._bind_call_args(original, series, *args, **kwargs, drop_names=["self"])
            with patcher._boundary():
                result = original(series, *args, **kwargs)

            if isinstance(result, pd.Series):
                read = patcher._infer_read_from_value(series)
                for value in raw_args.values():
                    read = patcher._merge_read_maps(read, patcher._infer_read_from_value(value))
                patcher._set_expr_meta(result, read, description=method_name)

                if outermost:
                    patcher._record(
                        op=method_name,
                        inputs=patcher._direct_input_tids(series, *raw_args.values()),
                        output=patcher._fresh_output_node(result),
                        read=read,
                        write=patcher._series_write_cols(result),
                        args=patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                    )
            return result

        setattr(pd.Series, method_name, wrapped)

    def _patch_series_lineage_method(self, method_name: str) -> None:
        original = getattr(pd.Series, method_name, None)
        if original is None:
            return
        self._remember_original("Series", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            raw_args = patcher._bind_call_args(original, series, *args, **kwargs, drop_names=["self"])
            with patcher._boundary():
                result = original(series, *args, **kwargs)

            if isinstance(result, pd.Series):
                read = patcher._infer_read_from_value(series)
                patcher._set_expr_meta(result, read, description=method_name)

                if outermost:
                    patcher._record(
                        op=method_name,
                        inputs=patcher._direct_input_tids(series),
                        output=patcher._fresh_output_node(result),
                        read=read,
                        write=patcher._series_write_cols(result),
                        args=patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                    )
            return result

        setattr(pd.Series, method_name, wrapped)

    def _patch_series_scalar_reduction(self, method_name: str) -> None:
        original = getattr(pd.Series, method_name, None)
        if original is None:
            return
        self._remember_original("Series", method_name, original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(series)
                result = original(series, *args, **kwargs)

            if outermost:
                patcher._record(
                    op="series_reduce",
                    inputs=[input_tid],
                    output=patcher._ensure_result_node(result),
                    read=patcher._infer_read_from_value(series),
                    write=[],
                    args={
                        "method": method_name,
                        **patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        setattr(pd.Series, method_name, wrapped)

    def _patch_series_unique(self) -> None:
        original = getattr(pd.Series, "unique", None)
        if original is None:
            return
        self._remember_original("Series", "unique", original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(series)
                result = original(series, *args, **kwargs)

            if outermost:
                patcher._record(
                    op="series_reduce",
                    inputs=[input_tid],
                    output=patcher._ensure_result_node(result),
                    read=patcher._infer_read_from_value(series),
                    write=[],
                    args={
                        "method": "unique",
                        **patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        pd.Series.unique = wrapped

    def _patch_series_corr(self) -> None:
        original = getattr(pd.Series, "corr", None)
        if original is None:
            return
        self._remember_original("Series", "corr", original)
        patcher = self

        @wraps(original)
        def wrapped(series, other, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                left_tid = patcher._ensure_table(series)
                result = original(series, other, *args, **kwargs)

            if outermost:
                read = patcher._merge_read_maps(
                    patcher._infer_read_from_value(series),
                    patcher._infer_read_from_value(other),
                )
                patcher._record(
                    op="series_reduce",
                    inputs=patcher._direct_input_tids(series, other) or [left_tid],
                    output=patcher._ensure_result_node(result),
                    read=read,
                    write=[],
                    args={
                        "method": "corr",
                        **patcher._capture_call_args(original, series, other, *args, **kwargs, drop_names=["self"]),
                    },
                )
            return result

        pd.Series.corr = wrapped

    def _patch_series_to_frame(self) -> None:
        original = pd.Series.to_frame
        self._remember_original("Series", "to_frame", original)
        patcher = self

        @wraps(original)
        def wrapped(series, *args, **kwargs):
            outermost = patcher._is_outermost()
            with patcher._boundary():
                input_tid = patcher._ensure_table(series)
                result = original(series, *args, **kwargs)

            if outermost:
                read = patcher._infer_read_from_value(series)
                if read:
                    output_tid = patcher._fresh_output_node(result)
                    patcher._record(
                        op="series_to_frame",
                        inputs=[input_tid],
                        output=output_tid,
                        read=read,
                        write=patcher._safe_columns(result),
                        args=patcher._capture_call_args(original, series, *args, **kwargs, drop_names=["self"]),
                    )
            return result

        pd.Series.to_frame = wrapped

    def _patch_string_extract(self) -> None:
        if StringMethods is None:
            return
        original = getattr(StringMethods, "extract", None)
        if original is None:
            return
        self._remember_original("StringMethods", "extract", original)
        patcher = self

        @wraps(original)
        def wrapped(accessor, *args, **kwargs):
            outermost = patcher._is_outermost()
            parent = getattr(accessor, "_parent", None)
            with patcher._boundary():
                if isinstance(parent, pd.Series):
                    input_tid = patcher._ensure_table(parent)
                else:
                    input_tid = None
                result = original(accessor, *args, **kwargs)

            if isinstance(parent, pd.Series) and isinstance(result, pd.Series):
                patcher._set_expr_meta(result, patcher._infer_read_from_value(parent), description="str_extract")

            if outermost and isinstance(parent, pd.Series) and input_tid is not None:
                patcher._record(
                    op="str_extract",
                    inputs=[input_tid],
                    output=patcher._ensure_result_node(result),
                    read=patcher._infer_read_from_value(parent),
                    write=patcher._safe_columns(result),
                    args=patcher._capture_call_args(original, accessor, *args, **kwargs, drop_names=["self"]),
                )
            return result

        StringMethods.extract = wrapped


TRACE_PATCHER = PandasTracePatcher()
