"""
data_loader/loader.py
--------------------
数据集加载入口。

本文件提供 InsightBench 与 BIRD EDA 的数据加载逻辑。两类数据最终都转成
TableData + Task 对象，后续 agent 统一面对 tables: dict[str, DataFrame]。
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Tuple

import numpy as np
import pandas as pd
from dateutil.parser import parse as parse_datetime

from .metadata_enricher import MetadataEnrichmentConfig, build_table_metadata
from .models import BirdEDATask, InsightBenchTask, TableData

_TASK_NAME_RE = re.compile(r"flag-(\d+)\.json$")
_SCHEMA_METADATA_VERSION = 10
_SUPPORTED_TABLE_SUFFIXES = {".csv", ".dta"}
_BIRD_SUPPORTED_DATA_FORMATS = {"text", "integer", "real", "date", "datetime", "boolean"}
_BIRD_NULL_STRINGS = {"", "NULL", "NA", "N/A"}


_INSIGHTBENCH_DATETIME_SUFFIXES = (
    "_at",
    "_on",
    "_date",
    "_datetime",
    "_timestamp",
)
_INSIGHTBENCH_DATETIME_PREFIXES = (
    "date_",
    "datetime_",
    "timestamp_",
)


def _insightbench_datetime_name_hint(column_name: Any) -> bool:
    """Conservatively identify columns whose names explicitly indicate timestamps."""
    normalized = re.sub(r"[^a-z0-9]+", "_", str(column_name or "").strip().lower()).strip("_")
    if not normalized:
        return False
    if normalized in {"date", "datetime", "timestamp", "time"}:
        return True
    return normalized.endswith(_INSIGHTBENCH_DATETIME_SUFFIXES) or normalized.startswith(
        _INSIGHTBENCH_DATETIME_PREFIXES
    )


def _coerce_datetime(values: pd.Series) -> pd.Series:
    """Parse mixed date strings while remaining compatible with older pandas versions."""
    try:
        return pd.to_datetime(values, errors="coerce", format="mixed")
    except (TypeError, ValueError):
        return pd.to_datetime(values, errors="coerce")


def _normalize_insightbench_runtime_types(dataframe: pd.DataFrame) -> pd.DataFrame:
    """Normalize only high-confidence date-like string columns for InsightBench.

    The previous implementation labeled an object column as datetime from its first
    parseable value but kept the runtime Series as strings. This function makes the
    runtime dtype and prompt schema agree. Columns without a strong name hint or a
    high parse success rate are left unchanged and therefore appear as `str`.
    """
    for column_name in list(dataframe.columns):
        series = dataframe[column_name]
        if not (series.dtype == object or pd.api.types.is_string_dtype(series)):
            continue
        if not _insightbench_datetime_name_hint(column_name):
            continue

        non_empty = series.dropna().astype("string").str.strip()
        non_empty = non_empty.loc[non_empty != ""]
        if len(non_empty) < 3:
            continue

        sample = non_empty.head(100)
        # Avoid converting numeric IDs or year-like codes solely because pandas can
        # interpret them as nanosecond offsets.
        numeric_ratio = float(pd.to_numeric(sample, errors="coerce").notna().mean())
        if numeric_ratio >= 0.9:
            continue

        parsed_sample = _coerce_datetime(sample)
        if float(parsed_sample.notna().mean()) < 0.9:
            continue

        parsed_full = _coerce_datetime(series)
        valid_ratio = float(parsed_full.loc[non_empty.index].notna().mean())
        if valid_ratio < 0.9:
            continue
        dataframe[column_name] = parsed_full
    return dataframe



def _read_json(path: Path) -> Dict[str, Any]:
    """读取 json 文件，兼容常见编码。"""
    last_error: Optional[Exception] = None
    for encoding in ("utf-8", "utf-8-sig", "cp1252", "latin1"):
        try:
            with path.open("r", encoding=encoding) as handle:
                return json.load(handle)
        except UnicodeDecodeError as exc:
            last_error = exc
            continue
    raise UnicodeDecodeError(
        "utf-8",
        b"",
        0,
        1,
        f"无法用 utf-8/utf-8-sig/cp1252/latin1 读取 json: {path}; last_error={last_error}",
    )


def _task_sort_key(path: Path) -> tuple[int, str]:
    """按 flag 序号自然排序。"""
    match = _TASK_NAME_RE.search(path.name)
    if match:
        return int(match.group(1)), path.name
    return 10**9, path.name


def list_task_jsons(data_root: str | Path) -> List[Path]:
    """返回全部 InsightBench 任务 json 路径。

    官方 InsightBench 默认结构是 ``<data_root>/json/flag-*.json``。为了本地调试方便，
    如果传入的目录本身就是 json 目录，也允许直接读取其中的 flag 文件。
    """
    root = Path(data_root)
    json_dirs = [root / "json", root]
    task_files: List[Path] = []
    for json_dir in json_dirs:
        if not json_dir.exists():
            continue
        task_files.extend(
            path
            for path in json_dir.glob("flag-*.json")
            if path.is_file() and path.name != "sample.json"
        )
    return sorted(set(task_files), key=_task_sort_key)


def _read_csv_table(path: Path) -> pd.DataFrame:
    """读取 InsightBench CSV，并使运行时 dtype 与 prompt schema 保持一致。"""
    dataframe = pd.read_csv(path)
    dataframe = dataframe.dropna(axis=1, how="all")
    return _normalize_insightbench_runtime_types(dataframe)


def _read_table_file(path: Path) -> pd.DataFrame:
    """读取表格文件。

    InsightBench 默认使用 csv；这里保留 dta 读取能力，方便后续本地表格调试。
    """
    suffix = path.suffix.lower()
    if suffix == ".csv":
        return _read_csv_table(path)
    if suffix == ".dta":
        dataframe = pd.read_stata(path)
        return dataframe.dropna(axis=1, how="all")
    raise ValueError(f"不支持的表格格式: {path}")


def _build_cache_key(
    table_path: Path,
    config: MetadataEnrichmentConfig,
    *,
    cache_key_extra: str = "",
) -> str:
    """根据表路径、文件状态和配置生成缓存键。"""
    stat = table_path.stat()
    raw = {
        "path": str(table_path.resolve()),
        "mtime_ns": int(stat.st_mtime_ns),
        "size": int(stat.st_size),
        "config": config.to_dict(),
        "metadata_version": _SCHEMA_METADATA_VERSION,
        "cache_key_extra": str(cache_key_extra or ""),
    }
    digest = hashlib.md5(json.dumps(raw, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    return digest


def _cache_file_path(
    table_path: Path,
    cache_dir: Path,
    config: MetadataEnrichmentConfig,
    *,
    cache_key_extra: str = "",
) -> Path:
    """返回当前表对应的缓存文件路径。"""
    return cache_dir / (
        f"{table_path.stem}_"
        f"{_build_cache_key(table_path, config, cache_key_extra=cache_key_extra)}.json"
    )


def _load_cached_metadata(
    table_path: Path,
    cache_dir: Optional[Path],
    config: MetadataEnrichmentConfig,
    *,
    cache_key_extra: str = "",
) -> Optional[Dict[str, Any]]:
    """读取缓存的表 metadata；未命中时返回 None。"""
    if cache_dir is None:
        return None
    cache_file = _cache_file_path(
        table_path,
        cache_dir,
        config,
        cache_key_extra=cache_key_extra,
    )
    if not cache_file.exists():
        return None
    return _read_json(cache_file)


def _save_metadata_cache(
    table_path: Path,
    metadata: Dict[str, Any],
    cache_dir: Optional[Path],
    config: MetadataEnrichmentConfig,
    *,
    cache_key_extra: str = "",
) -> None:
    """把表 metadata 写入缓存。"""
    if cache_dir is None:
        return
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file = _cache_file_path(
        table_path,
        cache_dir,
        config,
        cache_key_extra=cache_key_extra,
    )
    with cache_file.open("w", encoding="utf-8") as handle:
        json.dump(metadata, handle, ensure_ascii=False, indent=2)


def _resolve_dataset_path(raw_path: str | Path, *, data_root: Path, json_path: Path) -> Path:
    """把 InsightBench json 里的相对路径解析成当前本地真实路径。

    官方 json 常见写法类似：
    - data/notebooks/csvs/flag-1.csv

    但你当前本地目录是：
    - <data_root>/notebooks/csvs/flag-1.csv

    因此这里做两层兜底：
    1. 原样绝对/相对解析；
    2. 若以 `data/` 开头，则映射到 `data_root` 下。
    """
    text = str(raw_path or "").strip()
    if not text:
        raise ValueError(f"任务 {json_path} 缺少数据表路径")

    candidate = Path(text)
    if candidate.is_absolute() and candidate.exists():
        return candidate.resolve()

    relative_to_json = (json_path.parent / candidate).resolve()
    if relative_to_json.exists():
        return relative_to_json

    normalized_text = text.replace("\\", "/")
    if normalized_text.startswith("data/"):
        remapped = (data_root / normalized_text[len("data/") :]).resolve()
        if remapped.exists():
            return remapped

    relative_to_root = (data_root / normalized_text).resolve()
    if relative_to_root.exists():
        return relative_to_root

    raise FileNotFoundError(
        f"无法解析数据表路径: raw_path={text}, json={json_path}, data_root={data_root}"
    )


def _load_table(
    table_path: Path,
    enrichment_config: MetadataEnrichmentConfig,
    metadata_cache_dir: Optional[Path],
    table_name: Optional[str] = None,
) -> TableData:
    """读取一张表，并补充轻量 metadata。

    table_name 用于控制运行时 tables 字典里的键；InsightBench 默认使用文件 stem。
    """
    dataframe = _read_table_file(table_path)
    metadata = _load_cached_metadata(
        table_path=table_path,
        cache_dir=metadata_cache_dir,
        config=enrichment_config,
    )
    if metadata is None:
        metadata = build_table_metadata(dataframe=dataframe, config=enrichment_config)
        _save_metadata_cache(
            table_path=table_path,
            metadata=metadata,
            cache_dir=metadata_cache_dir,
            config=enrichment_config,
        )


    return TableData(
        name=table_name or table_path.stem,
        path=table_path,
        dataframe=dataframe,
        metadata=metadata,
    )


def load_task(
    json_path: str | Path,
    data_root: Optional[str | Path] = None,
    enrichment_config: Optional[MetadataEnrichmentConfig] = None,
    metadata_cache_dir: Optional[str | Path] = None,
) -> InsightBenchTask:
    """读取单个 InsightBench 任务。"""
    json_path = Path(json_path)
    if not json_path.exists():
        raise FileNotFoundError(f"找不到任务 json: {json_path}")

    resolved_config = enrichment_config or MetadataEnrichmentConfig()
    cache_dir = Path(metadata_cache_dir) if metadata_cache_dir else None
    root = Path(data_root) if data_root is not None else json_path.parent.parent

    payload = _read_json(json_path)
    metadata = dict(payload.get("metadata") or {})
    metadata.setdefault("task_id", json_path.stem)

    primary_table_path = _resolve_dataset_path(
        payload.get("dataset_csv_path") or "",
        data_root=root,
        json_path=json_path,
    )
    primary_table = _load_table(
        table_path=primary_table_path,
        enrichment_config=resolved_config,
        metadata_cache_dir=cache_dir,
    )

    extra_tables: List[TableData] = []
    user_dataset_csv_path = payload.get("user_dataset_csv_path")
    if user_dataset_csv_path:
        extra_table_path = _resolve_dataset_path(
            user_dataset_csv_path,
            data_root=root,
            json_path=json_path,
        )
        extra_tables.append(
            _load_table(
                table_path=extra_table_path,
                enrichment_config=resolved_config,
                metadata_cache_dir=cache_dir,
            )
        )

    return InsightBenchTask(
        json_path=json_path,
        metadata=metadata,
        primary_table=primary_table,
        extra_tables=extra_tables,
        gold_insights=[str(item) for item in (payload.get("insights") or [])],
        gold_summary=str(payload.get("summary") or ""),
        insight_items=[dict(item) for item in (payload.get("insight_list") or []) if isinstance(item, dict)],
    )


def load_tasks(
    data_root: str | Path,
    limit: Optional[int] = None,
    enrichment_config: Optional[MetadataEnrichmentConfig] = None,
    metadata_cache_dir: Optional[str | Path] = None,
) -> List[InsightBenchTask]:
    """批量读取 InsightBench 任务。"""
    root = Path(data_root)
    json_files = list_task_jsons(root)

    if limit is not None:
        json_files = json_files[: max(0, int(limit))]

    return [
        load_task(
            path,
            data_root=root,
            enrichment_config=enrichment_config,
            metadata_cache_dir=metadata_cache_dir,
        )
        for path in json_files
    ]


# ---------------------------------------------------------------------------
# BIRD CSV EDA loader
# ---------------------------------------------------------------------------

_DESCRIPTION_MAX_LEN = 600


def _read_jsonl(path: Path) -> List[Dict[str, Any]]:
    """读取 JSONL，每行一个 task。"""
    if not path.exists():
        raise FileNotFoundError(f"找不到 BIRD task_jsonl: {path}")
    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                payload = json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(f"BIRD task_jsonl 第 {line_no} 行不是合法 JSON: {path}") from exc
            if not isinstance(payload, dict):
                raise ValueError(f"BIRD task_jsonl 第 {line_no} 行必须是 JSON object: {path}")
            rows.append(payload)
    return rows


def _normalize_column_key(value: Any) -> str:
    """列名归一化，用于匹配 database_description 与 CSV 表头。"""
    text = str(value or "").strip().lower()
    return re.sub(r"[^a-z0-9]+", "", text)


def _clean_description_text(value: Any, max_len: int = _DESCRIPTION_MAX_LEN) -> str:
    """清理 description / value_description，避免 prompt 中混入 NaN 或超长文本。"""
    text = str(value or "").strip()
    if not text or text.lower() == "nan":
        return ""
    text = re.sub(r"\s+", " ", text)
    if len(text) > max_len:
        return text[:max_len].rstrip() + "..."
    return text


def _load_bird_description_map(description_dir: Path) -> Dict[str, Dict[str, Any]]:
    """读取 BIRD database_description 下的表级 CSV。 

    database_description 是 BIRD 表字段类型的唯一来源。返回结构同时保留严格列顺序、
    data_format 和描述信息，供 CSV 类型转换与 prompt schema 共同使用。
    """
    if not description_dir.exists() or not description_dir.is_dir():
        return {}

    result: Dict[str, Dict[str, Any]] = {}
    for desc_csv in sorted(description_dir.glob("*.csv")):
        if desc_csv.name.startswith("._"):
            continue
        table_name = desc_csv.stem
        try:
            desc_df = pd.read_csv(desc_csv, dtype=str, keep_default_na=False)
        except Exception as exc:
            raise ValueError(f"无法读取 BIRD database_description: {desc_csv}") from exc

        required_columns = {
            "original_column_name",
            "column_name",
            "column_description",
            "data_format",
            "value_description",
        }
        missing_columns = sorted(required_columns.difference(map(str, desc_df.columns)))
        if missing_columns:
            raise ValueError(f"{desc_csv} 缺少字段: {missing_columns}")

        table_map: Dict[str, Dict[str, Any]] = {}
        table_by_name: Dict[str, Dict[str, Any]] = {}
        ambiguous_normalized_keys: set[str] = set()
        ordered_columns: List[Dict[str, str]] = []
        seen_columns: set[str] = set()
        for row_number, (_, row) in enumerate(desc_df.iterrows(), start=2):
            original_name = str(row.get("original_column_name") or "").strip()
            column_name = str(row.get("column_name") or "").strip()
            if not original_name:
                raise ValueError(f"{desc_csv}:{row_number} original_column_name 为空")
            if column_name != original_name:
                raise ValueError(
                    f"{desc_csv}:{row_number} column_name={column_name!r} 与 "
                    f"original_column_name={original_name!r} 不一致"
                )
            if original_name in seen_columns:
                raise ValueError(f"{desc_csv}:{row_number} 重复列: {original_name!r}")
            seen_columns.add(original_name)

            data_format = str(row.get("data_format") or "").strip().lower()
            if data_format not in _BIRD_SUPPORTED_DATA_FORMATS:
                raise ValueError(
                    f"{desc_csv}:{row_number} 不支持的 data_format: {data_format!r}"
                )
            column_description = _clean_description_text(row.get("column_description"))
            value_description = _clean_description_text(row.get("value_description"))

            payload: Dict[str, str] = {
                "name": original_name,
                "data_format": data_format,
            }
            if column_description:
                payload["description"] = column_description
            if value_description:
                payload["value_description"] = value_description

            key = _normalize_column_key(original_name)
            if key and key not in ambiguous_normalized_keys:
                if key in table_map:
                    table_map.pop(key, None)
                    ambiguous_normalized_keys.add(key)
                else:
                    table_map[key] = dict(payload)
            table_by_name[original_name] = dict(payload)
            ordered_columns.append(dict(payload))

        if not ordered_columns:
            raise ValueError(f"{desc_csv} 没有列定义")
        result[table_name] = {
            "columns": ordered_columns,
            "by_key": table_map,
            "by_name": table_by_name,
            "description_path": str(desc_csv),
        }
    return result


def _find_bird_table_spec(
    description_map: Dict[str, Dict[str, Any]],
    table_name: str,
) -> Optional[Dict[str, Any]]:
    """按精确名称或唯一归一化名称查找表 schema。"""
    if table_name in description_map:
        return description_map[table_name]
    normalized = _normalize_identifier(table_name)
    matches = [
        spec
        for name, spec in description_map.items()
        if _normalize_identifier(name) == normalized
    ]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ValueError(f"BIRD database_description 表名匹配不唯一: {table_name!r}")
    return None


def _parse_bird_datetime(series: pd.Series) -> pd.Series:
    """解析 BIRD date/datetime，并保留 pandas 纳秒范围之外的历史日期。"""
    source = series.astype("string")
    raw_values = source.fillna("NaT").to_numpy(dtype=str)
    try:
        values = np.array(raw_values, dtype="datetime64[us]")
        return pd.Series(values, index=series.index, name=series.name)
    except (TypeError, ValueError):
        parsed_values: List[np.datetime64] = []
        for value in source:
            if pd.isna(value):
                parsed_values.append(np.datetime64("NaT", "us"))
                continue
            try:
                parsed = parse_datetime(str(value))
                if parsed.tzinfo is not None:
                    parsed = parsed.replace(tzinfo=None)
                parsed_values.append(np.datetime64(parsed, "us"))
            except (TypeError, ValueError, OverflowError):
                parsed_values.append(np.datetime64("NaT", "us"))
        return pd.Series(
            np.array(parsed_values, dtype="datetime64[us]"),
            index=series.index,
            name=series.name,
        )


def _convert_bird_series(
    series: pd.Series,
    *,
    data_format: str,
    table_path: Path,
) -> pd.Series:
    """按 database_description 的声明类型严格转换一列。"""
    if data_format == "text":
        return series.astype("string")

    source = series.astype("string")
    trimmed = source.str.strip().mask(source.str.strip().eq(""), pd.NA)

    if data_format == "integer":
        numeric = pd.to_numeric(trimmed, errors="coerce")
        fractional = numeric.notna() & (numeric % 1 != 0)
        converted = numeric.mask(fractional).astype("Int64")
    elif data_format == "real":
        converted = pd.to_numeric(trimmed, errors="coerce").astype("Float64")
    elif data_format in {"date", "datetime"}:
        converted = _parse_bird_datetime(trimmed)
        if data_format == "date":
            converted = converted.dt.normalize()
    elif data_format == "boolean":
        normalized = trimmed.str.lower()
        mapping = {
            "true": True,
            "false": False,
            "1": True,
            "0": False,
            "yes": True,
            "no": False,
            "y": True,
            "n": False,
            "t": True,
            "f": False,
        }
        converted = normalized.map(mapping).astype("boolean")
    else:  # pragma: no cover - 在 description 加载阶段已经验证。
        raise ValueError(f"不支持的 BIRD data_format: {data_format}")

    invalid_mask = trimmed.notna() & converted.isna()
    if bool(invalid_mask.any()):
        samples = source.loc[invalid_mask].drop_duplicates().head(5).tolist()
        raise ValueError(
            f"BIRD 类型转换失败: table={table_path}, column={series.name!r}, "
            f"data_format={data_format}, invalid_count={int(invalid_mask.sum())}, samples={samples}"
        )
    return converted


def _read_bird_csv_table(
    *,
    table_path: Path,
    table_spec: Dict[str, Any],
) -> pd.DataFrame:
    """以字符串读取 BIRD CSV，再按声明 schema 校验表头并严格转换。"""
    raw = pd.read_csv(
        table_path,
        dtype=str,
        keep_default_na=False,
        na_values=sorted(_BIRD_NULL_STRINGS),
    )
    column_specs = [dict(item) for item in list(table_spec.get("columns") or [])]
    expected_columns = [str(item.get("name") or "") for item in column_specs]
    actual_columns = [str(column) for column in raw.columns]
    if actual_columns != expected_columns:
        missing = [column for column in expected_columns if column not in actual_columns]
        extra = [column for column in actual_columns if column not in expected_columns]
        raise ValueError(
            f"BIRD CSV/database_description 表头不一致: table={table_path}, "
            f"missing={missing}, extra={extra}, csv_order={actual_columns}, "
            f"description_order={expected_columns}"
        )

    converted = pd.DataFrame(index=raw.index)
    for column_spec in column_specs:
        column_name = str(column_spec.get("name") or "")
        converted[column_name] = _convert_bird_series(
            raw[column_name],
            data_format=str(column_spec.get("data_format") or "").lower(),
            table_path=table_path,
        )
    return converted


def _merge_bird_description_into_metadata(
    metadata: Dict[str, Any],
    *,
    table_name: str,
    db_id: str,
    description_map: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    """把 BIRD column_description / value_description 合入表 metadata。"""
    merged = dict(metadata or {})
    merged["source"] = "bird"
    merged["db_id"] = db_id
    merged["description"] = f"BIRD CSV table `{table_name}` from database `{db_id}`."

    table_spec = _find_bird_table_spec(description_map, table_name) or {}
    table_desc = dict(table_spec.get("by_key") or {})
    table_desc_by_name = dict(table_spec.get("by_name") or {})
    if not table_desc and not table_desc_by_name:
        return merged

    columns: List[Dict[str, Any]] = []
    for column in list(merged.get("columns") or []):
        entry = dict(column)
        column_name = str(entry.get("name") or "")
        desc = table_desc_by_name.get(column_name) or table_desc.get(_normalize_column_key(column_name))
        if desc:
            if desc.get("data_format"):
                entry["data_format"] = desc["data_format"]
            if desc.get("description"):
                entry["description"] = desc["description"]
            if desc.get("value_description"):
                entry["value_description"] = desc["value_description"]
        columns.append(entry)
    merged["columns"] = columns
    return merged



def _load_bird_constraints(db_dir: Path) -> Dict[str, Dict[str, Any]]:
    """Load machine-readable BIRD primary/foreign-key constraints when available."""
    path = db_dir / "table_constraints.json"
    if not path.is_file():
        return {}
    payload = _read_json(path)
    raw_tables = dict(payload.get("tables") or {})
    result: Dict[str, Dict[str, Any]] = {}
    for table_name, raw in raw_tables.items():
        item = dict(raw or {})
        primary_keys: List[List[str]] = []
        for raw_key in list(item.get("primary_keys") or []):
            key_columns = [str(column) for column in list(raw_key or []) if str(column)]
            if key_columns:
                primary_keys.append(key_columns)
        foreign_keys: List[Dict[str, Any]] = []
        for raw_fk in list(item.get("foreign_keys") or []):
            fk = dict(raw_fk or {})
            columns = [str(column) for column in list(fk.get("columns") or []) if str(column)]
            ref_columns = [
                str(column) for column in list(fk.get("references_columns") or []) if str(column)
            ]
            ref_table = str(fk.get("references_table") or "").strip()
            if columns and ref_table and len(columns) == len(ref_columns):
                foreign_keys.append({
                    "columns": columns,
                    "references_table": ref_table,
                    "references_columns": ref_columns,
                })
        result[str(table_name)] = {
            "primary_keys": primary_keys,
            "foreign_keys": foreign_keys,
        }
    return result


def _find_bird_table_constraints(
    constraints_map: Dict[str, Dict[str, Any]],
    table_name: str,
) -> Dict[str, Any]:
    if table_name in constraints_map:
        return dict(constraints_map[table_name] or {})
    normalized = _normalize_identifier(table_name)
    matches = [
        dict(spec or {})
        for name, spec in constraints_map.items()
        if _normalize_identifier(name) == normalized
    ]
    return matches[0] if len(matches) == 1 else {}


def _merge_bird_constraints_into_metadata(
    metadata: Dict[str, Any],
    *,
    table_name: str,
    constraints_map: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    merged = dict(metadata or {})
    constraints = _find_bird_table_constraints(constraints_map, table_name)
    if constraints:
        merged["constraints"] = constraints
    return merged

def _load_bird_relationship_text(db_dir: Path, loaded_table_names: List[str]) -> str:
    """读取表关系说明，并移除涉及未加载表的关系。"""
    path = db_dir / "table_relationships.txt"
    if not path.is_file():
        return ""
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return ""

    bullet_lines = [line for line in text.splitlines() if line.lstrip().startswith("-")]
    if not bullet_lines:
        return text

    loaded = set(map(str, loaded_table_names))
    pattern = re.compile(r"(?:Composite join|Join)\s+`([^`]+)`\s+with\s+`([^`]+)`", re.I)
    kept: List[str] = []
    for line in bullet_lines:
        match = pattern.search(line)
        if not match or {match.group(1), match.group(2)}.issubset(loaded):
            kept.append(line.strip())
    if not kept:
        return ""

    header = [
        "Table relationships:",
        "Use these declared relationships when joining tables. For a composite join, use all listed column pairs together.",
        "",
    ]
    return "\n".join(header + kept).strip()


def _resolve_bird_task_jsonl(*, data_root: Path, task_jsonl: Optional[str | Path]) -> Path:
    """解析 BIRD task.jsonl 路径。"""
    if task_jsonl:
        path = Path(task_jsonl).expanduser()
        return path if path.is_absolute() else (Path.cwd() / path).resolve()

    candidates = [
        data_root / "task.jsonl",
        data_root.parent / "task.jsonl",
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise FileNotFoundError(
        "未提供 dataset.task_jsonl，且无法从 data_root/task.jsonl 或 data_root.parent/task.jsonl 推断。"
    )


def _resolve_bird_db_dir(data_root: Path, db_id: str) -> Path:
    """只根据 db_id 解析当前 task 的 CSV 数据库目录。"""
    db_id = str(db_id or "").strip()
    if not db_id:
        raise ValueError("BIRD task 缺少 target_dataset.db_id")

    candidates = [
        data_root / db_id,
        data_root,
    ]
    for candidate in candidates:
        if not candidate.exists() or not candidate.is_dir():
            continue
        if (candidate / "tables").is_dir() or any(candidate.glob("*.csv")):
            if candidate.name == db_id or candidate == data_root / db_id:
                return candidate.resolve()
    raise FileNotFoundError(f"无法根据 db_id={db_id} 定位 BIRD CSV 数据库目录: data_root={data_root}")


def _normalize_identifier(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(value or "").lower())


def _match_bird_table_name(requested: str, available: List[str]) -> Optional[str]:
    """把 gold table 名称匹配到唯一的实际 CSV stem，不做模糊猜测。"""
    if requested in available:
        return requested
    normalized = _normalize_identifier(requested)
    matches = [name for name in available if _normalize_identifier(name) == normalized]
    return matches[0] if len(matches) == 1 else None


def _normalize_bird_table_selection(value: Any) -> str:
    selection = str(value or "gold_tables").strip().lower()
    if selection not in {"all", "gold_tables"}:
        raise ValueError("BIRD table_selection 必须是 'all' 或 'gold_tables'")
    return selection


def _discover_bird_csv_tables(
    db_dir: Path,
    *,
    table_selection: str,
    gold_tables: List[str],
    task_id: str,
) -> List[Path]:
    """按 all 或 gold_tables 模式选择当前任务可用的 CSV 表。"""
    table_dir = db_dir / "tables"
    search_dir = table_dir if table_dir.is_dir() else db_dir
    csv_files = sorted(
        path for path in search_dir.glob("*.csv")
        if path.is_file() and not path.name.startswith("._")
    )
    if not csv_files:
        raise FileNotFoundError(f"BIRD 数据库目录下没有 CSV 表: {db_dir}")

    selection = _normalize_bird_table_selection(table_selection)
    if selection == "all":
        return csv_files

    requested = [
        Path(str(name).strip()).stem
        for name in gold_tables
        if str(name).strip()
    ]
    if not requested:
        raise ValueError(
            f"BIRD task {task_id} 未提供 gold_tables，但 table_selection='gold_tables'"
        )

    available_paths = {path.stem: path for path in csv_files}
    available_names = list(available_paths)
    selected: List[Path] = []
    missing: List[str] = []
    seen: set[str] = set()
    for name in requested:
        matched = _match_bird_table_name(name, available_names)
        if matched is None:
            missing.append(name)
            continue
        if matched in seen:
            continue
        seen.add(matched)
        selected.append(available_paths[matched])

    if missing:
        raise FileNotFoundError(
            f"BIRD task {task_id} 的 gold_tables 缺失或匹配不唯一: {missing}; "
            f"available={available_names}"
        )
    if not selected:
        raise ValueError(f"BIRD task {task_id} 没有可加载的 gold tables")
    return selected


def _load_bird_csv_table(
    *,
    table_path: Path,
    db_id: str,
    description_map: Dict[str, Dict[str, Any]],
    constraints_map: Dict[str, Dict[str, Any]],
    enrichment_config: MetadataEnrichmentConfig,
    metadata_cache_dir: Optional[Path],
) -> TableData:
    """读取一张 BIRD CSV 表，并按 database_description 的类型契约转换。"""
    table_spec = _find_bird_table_spec(description_map, table_path.stem)
    if not table_spec:
        raise FileNotFoundError(
            f"BIRD 表缺少 database_description: table={table_path.stem}, path={table_path}"
        )
    dataframe = _read_bird_csv_table(table_path=table_path, table_spec=table_spec)
    schema_signature = json.dumps(
        {
            "columns": [
                [str(item.get("name") or ""), str(item.get("data_format") or "")]
                for item in list(table_spec.get("columns") or [])
            ],
            "constraints": _find_bird_table_constraints(constraints_map, table_path.stem),
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    metadata = _load_cached_metadata(
        table_path=table_path,
        cache_dir=metadata_cache_dir,
        config=enrichment_config,
        cache_key_extra=schema_signature,
    )
    if metadata is None:
        metadata = build_table_metadata(dataframe=dataframe, config=enrichment_config)
        _save_metadata_cache(
            table_path=table_path,
            metadata=metadata,
            cache_dir=metadata_cache_dir,
            config=enrichment_config,
            cache_key_extra=schema_signature,
        )
    table = TableData(
        name=table_path.stem,
        path=table_path,
        dataframe=dataframe,
        metadata=metadata,
    )
    table.metadata = _merge_bird_description_into_metadata(
        table.metadata,
        table_name=table.name,
        db_id=db_id,
        description_map=description_map,
    )
    table.metadata = _merge_bird_constraints_into_metadata(
        table.metadata,
        table_name=table.name,
        constraints_map=constraints_map,
    )
    return table


def _bird_db_id_from_payload(payload: Dict[str, Any]) -> str:
    target_dataset = dict(payload.get("target_dataset") or {})
    db_id = str(target_dataset.get("db_id") or payload.get("db_id") or "").strip()
    if not db_id:
        raise ValueError("BIRD task 缺少 target_dataset.db_id / db_id")
    return db_id


def _bird_gold_insight_claims(payload: Dict[str, Any]) -> List[str]:
    """把 gold_insights 中的 claim 转成 evaluator 使用的字符串列表。"""
    result: List[str] = []
    for item in payload.get("gold_insights") or []:
        if isinstance(item, dict):
            claim = str(item.get("claim") or "").strip()
            if claim:
                result.append(claim)
        else:
            text = str(item or "").strip()
            if text:
                result.append(text)
    return result


def load_bird_task(
    *,
    payload: Dict[str, Any],
    jsonl_path: Path,
    line_index: int,
    data_root: str | Path,
    enrichment_config: Optional[MetadataEnrichmentConfig] = None,
    metadata_cache_dir: Optional[str | Path] = None,
    db_table_cache: Optional[Dict[str, List[TableData]]] = None,
    table_selection: str = "gold_tables",
) -> BirdEDATask:
    """读取单条自建 BIRD EDA JSONL task。"""
    root = Path(data_root).expanduser().resolve()
    resolved_config = enrichment_config or MetadataEnrichmentConfig()
    cache_dir = Path(metadata_cache_dir).expanduser().resolve() if metadata_cache_dir else None

    db_id = _bird_db_id_from_payload(payload)
    db_dir = _resolve_bird_db_dir(root, db_id)
    description_dir = db_dir / "database_description"
    description_map = _load_bird_description_map(description_dir)
    constraints_map = _load_bird_constraints(db_dir)
    resolved_selection = _normalize_bird_table_selection(table_selection)
    gold_table_names = [str(item) for item in (payload.get("gold_tables") or [])]
    selected_paths = _discover_bird_csv_tables(
        db_dir,
        table_selection=resolved_selection,
        gold_tables=gold_table_names,
        task_id=str(payload.get("task_id") or f"bird_{line_index + 1}"),
    )
    loaded_table_names = [path.stem for path in selected_paths]
    table_relationships = _load_bird_relationship_text(db_dir, loaded_table_names)

    cache_key = "|".join([
        str(db_dir.resolve()),
        resolved_selection,
        ",".join(loaded_table_names),
    ])
    if db_table_cache is not None and cache_key in db_table_cache:
        tables = db_table_cache[cache_key]
    else:
        tables = []
        for table_path in selected_paths:
            tables.append(
                _load_bird_csv_table(
                    table_path=table_path,
                    db_id=db_id,
                    description_map=description_map,
                    constraints_map=constraints_map,
                    enrichment_config=resolved_config,
                    metadata_cache_dir=cache_dir,
                )
            )
        if db_table_cache is not None:
            db_table_cache[cache_key] = tables

    target_dataset = dict(payload.get("target_dataset") or {})
    target_dataset.setdefault("db_id", db_id)
    target_dataset["csv_database_dir"] = str(db_dir)
    target_dataset["csv_tables_dir"] = str((db_dir / "tables") if (db_dir / "tables").is_dir() else db_dir)
    if description_dir.exists():
        target_dataset["csv_description_dir"] = str(description_dir)
    constraints_path = db_dir / "table_constraints.json"
    if constraints_path.is_file():
        target_dataset["table_constraints_path"] = str(constraints_path)
    target_dataset["table_selection"] = resolved_selection
    target_dataset["loaded_table_names"] = list(loaded_table_names)

    gold_claims = _bird_gold_insight_claims(payload)

    return BirdEDATask(
        jsonl_path=jsonl_path,
        line_index=line_index,
        raw_payload=dict(payload),
        task_id_value=str(payload.get("task_id") or f"bird_{line_index + 1}"),
        query=str(payload.get("query") or "").strip(),
        query_zh=str(payload.get("query_zh") or "").strip(),
        db_id=db_id,
        target_dataset=target_dataset,
        tables=tables,
        table_relationships=table_relationships,
        table_selection=resolved_selection,
        gold_tables=gold_table_names,
        gold_insights=gold_claims,
        insight_items=[dict(item) for item in (payload.get("gold_insights") or []) if isinstance(item, dict)],
    )


def _select_bird_task_payloads(
    *,
    data_root: str | Path,
    task_jsonl: Optional[str | Path],
    limit: Optional[int],
    offset: int,
) -> Tuple[Path, Path, List[Tuple[int, Dict[str, Any]]]]:
    """Resolve and select BIRD JSONL rows without loading any CSV table."""
    root = Path(data_root).expanduser().resolve()
    jsonl_path = _resolve_bird_task_jsonl(data_root=root, task_jsonl=task_jsonl)
    payloads = _read_jsonl(jsonl_path)

    start = max(0, int(offset or 0))
    selected = payloads[start:]
    if limit is not None:
        selected = selected[: max(0, int(limit))]
    indexed = [(index, payload) for index, payload in enumerate(selected, start=start)]
    return root, jsonl_path, indexed


class BirdTaskStream:
    """Re-iterable BIRD task stream that keeps only one database in memory.

    BIRD tasks are grouped by database in the frozen task file. When the db_id changes,
    the previous database table cache is released before the next database is loaded.
    If a future task file revisits an earlier database, that database is loaded again;
    this is preferable to retaining every large database for the whole experiment.
    """

    def __init__(
        self,
        *,
        root: Path,
        jsonl_path: Path,
        indexed_payloads: List[Tuple[int, Dict[str, Any]]],
        enrichment_config: Optional[MetadataEnrichmentConfig],
        metadata_cache_dir: Optional[str | Path],
        table_selection: str,
    ) -> None:
        self.root = root
        self.jsonl_path = jsonl_path
        self.indexed_payloads = list(indexed_payloads)
        self.enrichment_config = enrichment_config
        self.metadata_cache_dir = metadata_cache_dir
        self.table_selection = _normalize_bird_table_selection(table_selection)

    def __len__(self) -> int:
        return len(self.indexed_payloads)

    def __iter__(self) -> Iterator[BirdEDATask]:
        current_db_id = ""
        db_table_cache: Dict[str, List[TableData]] = {}
        for line_index, payload in self.indexed_payloads:
            db_id = _bird_db_id_from_payload(payload)
            if current_db_id and db_id != current_db_id:
                db_table_cache.clear()
            current_db_id = db_id
            yield load_bird_task(
                payload=payload,
                jsonl_path=self.jsonl_path,
                line_index=line_index,
                data_root=self.root,
                enrichment_config=self.enrichment_config,
                metadata_cache_dir=self.metadata_cache_dir,
                db_table_cache=db_table_cache,
                table_selection=self.table_selection,
            )


def stream_bird_tasks(
    *,
    data_root: str | Path,
    task_jsonl: Optional[str | Path] = None,
    limit: Optional[int] = None,
    offset: int = 0,
    enrichment_config: Optional[MetadataEnrichmentConfig] = None,
    metadata_cache_dir: Optional[str | Path] = None,
    table_selection: str = "gold_tables",
) -> BirdTaskStream:
    """Return a length-aware BIRD task stream with one-database-at-a-time loading."""
    root, jsonl_path, indexed_payloads = _select_bird_task_payloads(
        data_root=data_root,
        task_jsonl=task_jsonl,
        limit=limit,
        offset=offset,
    )
    return BirdTaskStream(
        root=root,
        jsonl_path=jsonl_path,
        indexed_payloads=indexed_payloads,
        enrichment_config=enrichment_config,
        metadata_cache_dir=metadata_cache_dir,
        table_selection=table_selection,
    )


def load_bird_tasks(
    *,
    data_root: str | Path,
    task_jsonl: Optional[str | Path] = None,
    limit: Optional[int] = None,
    offset: int = 0,
    enrichment_config: Optional[MetadataEnrichmentConfig] = None,
    metadata_cache_dir: Optional[str | Path] = None,
    table_selection: str = "gold_tables",
) -> List[BirdEDATask]:
    """Load selected BIRD tasks eagerly.

    Prefer :func:`stream_bird_tasks` in the full experiment runner so only one database
    is retained in memory. This eager helper remains useful for small tests and tools.
    """
    return list(
        stream_bird_tasks(
            data_root=data_root,
            task_jsonl=task_jsonl,
            limit=limit,
            offset=offset,
            enrichment_config=enrichment_config,
            metadata_cache_dir=metadata_cache_dir,
            table_selection=table_selection,
        )
    )


def load_bird_evaluation_tasks(
    *,
    data_root: str | Path,
    task_jsonl: Optional[str | Path] = None,
    limit: Optional[int] = None,
    offset: int = 0,
) -> List[BirdEDATask]:
    """Load only BIRD gold metadata for evaluation-only runs; do not read CSV tables."""
    _root, jsonl_path, indexed_payloads = _select_bird_task_payloads(
        data_root=data_root,
        task_jsonl=task_jsonl,
        limit=limit,
        offset=offset,
    )
    tasks: List[BirdEDATask] = []
    for line_index, payload in indexed_payloads:
        db_id = _bird_db_id_from_payload(payload)
        target_dataset = dict(payload.get("target_dataset") or {})
        target_dataset.setdefault("db_id", db_id)
        tasks.append(
            BirdEDATask(
                jsonl_path=jsonl_path,
                line_index=line_index,
                raw_payload=dict(payload),
                task_id_value=str(payload.get("task_id") or f"bird_{line_index + 1}"),
                query=str(payload.get("query") or "").strip(),
                query_zh=str(payload.get("query_zh") or "").strip(),
                db_id=db_id,
                target_dataset=target_dataset,
                tables=[],
                table_relationships="",
                table_selection="evaluation_only",
                gold_tables=[str(item) for item in (payload.get("gold_tables") or [])],
                gold_insights=_bird_gold_insight_claims(payload),
                insight_items=[
                    dict(item)
                    for item in (payload.get("gold_insights") or [])
                    if isinstance(item, dict)
                ],
            )
        )
    return tasks
