"""
utils.py
--------
项目里的轻量通用工具函数。

设计目标：
1. 只保留整个实验流程都会用到的基础能力；
2. 不把业务逻辑塞进工具函数里，避免职责混杂；
3. 输出格式尽量简单，便于主流程直接使用。
"""

from __future__ import annotations

import csv
import json
import re
import time
import types
import copy
import pandas as pd
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional
import numpy as np
import math
import datetime as _dt
from decimal import Decimal

_JSON_BLOCK_RE = re.compile(r"\{.*\}|\[.*\]", re.DOTALL)
_CODE_BLOCK_RE = re.compile(r"```(?:python|py)?\s*(.*?)```", re.DOTALL | re.IGNORECASE)
_WORD_RE = re.compile(r"[a-z0-9]+")


_CANONICAL_RESULT_TYPES = {"table", "scalar", "text", "dict", "list"}

def clip01(x: Any) -> float:
    """Convert a scalar to a finite score in ``[0, 1]``.

    ``pd.NA`` and infinities previously leaked into visual scoring and could raise
    ``TypeError``/``ValueError`` in downstream ``float`` or truth-value checks.
    """
    try:
        if x is None or pd.isna(x):
            return 0.0
    except Exception:
        return 0.0
    try:
        value = float(x)
    except Exception:
        return 0.0
    if not math.isfinite(value):
        return 0.0
    return max(0.0, min(1.0, value))


def safe_to_numeric(series: pd.Series) -> pd.Series:
    """Return a float64 Series with missing/inf values normalized to ``NaN``.

    Pandas nullable numeric dtypes preserve ``pd.NA`` after ``to_numeric``.  A
    later ``float(pd.NA)`` then aborts the whole visual pipeline.  Converting to
    plain float64 at this shared boundary gives all downstream statistics the
    standard ``numpy.nan`` representation they already handle.
    """
    if series is None:
        return pd.Series(dtype="float64")
    try:
        converted = pd.to_numeric(series, errors="coerce")
        converted = pd.Series(converted, index=getattr(series, "index", None), name=getattr(series, "name", None))
        converted = converted.astype("float64")
        return converted.replace([np.inf, -np.inf], np.nan)
    except Exception:
        try:
            values = [safe_float(value, default=np.nan) for value in list(series)]
            return pd.Series(values, index=getattr(series, "index", None), name=getattr(series, "name", None), dtype="float64").replace([np.inf, -np.inf], np.nan)
        except Exception:
            return pd.Series(dtype="float64")


def safe_to_datetime(series: pd.Series) -> pd.Series:
    if series is None:
        return pd.Series(dtype="datetime64[ns, UTC]")

    try:
        if pd.api.types.is_datetime64_any_dtype(series):
            return pd.to_datetime(series, errors="coerce", utc=True)
    except Exception:
        pass

    try:
        return pd.to_datetime(series, errors="coerce", utc=True, format="mixed")
    except TypeError:
        return pd.to_datetime(series, errors="coerce", utc=True)


def sanitize_filename(name: str) -> str:
    return "".join(c if c.isalnum() or c in "_-" else "_" for c in str(name))


def shorten_label(label: Any, max_len: int = 30) -> str:
    text = str(label)
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."

def _json_cell(value):
    if value is None:
        return None
    try:
        if pd.isna(value):
            return None
    except Exception:
        pass
    if isinstance(value, pd.Timestamp):
        return value.isoformat()
    if isinstance(value, pd.Timedelta):
        return str(value)
    if isinstance(value, pd.Period):
        return str(value)
    if isinstance(value, np.generic):
        return _json_cell(value.item())
    if isinstance(value, (_dt.datetime, _dt.date, _dt.time)):
        return value.isoformat()
    return value

def preview_records(df: pd.DataFrame | None, max_rows: int = 5, max_cols: int = 10):
    if df is None or df.empty:
        return []
    safe = df.iloc[:max_rows, :max_cols].copy().astype(object)
    records = safe.to_dict(orient="records")
    return [{str(k): _json_cell(v) for k, v in r.items()} for r in records]

def ensure_dir(path: str | Path) -> Path:
    """确保目录存在，并返回 Path 对象。"""
    path_obj = Path(path)
    path_obj.mkdir(parents=True, exist_ok=True)
    return path_obj


def read_text_with_fallbacks(path: str | Path) -> str:
    """读取文本文件，并对常见编码做兜底。"""
    path_obj = Path(path)
    encodings = ["utf-8", "utf-8-sig", "latin1", "cp1252"]
    last_error: Optional[Exception] = None
    for encoding in encodings:
        try:
            return path_obj.read_text(encoding=encoding)
        except Exception as exc:  # pragma: no cover - 兜底逻辑
            last_error = exc
    raise RuntimeError(f"Failed to read text file: {path_obj}") from last_error


def read_json(path: str | Path) -> Any:
    """读取 JSON 文件，并兼容少量编码差异。"""
    return json.loads(read_text_with_fallbacks(path))

def to_jsonable(value: Any) -> Any:
    """递归转换为严格 JSON 可序列化对象。"""
    if value is None:
        return None

    if isinstance(value, float):
        return value if math.isfinite(value) else None

    if isinstance(value, (str, int, bool)):
        return value

    if isinstance(value, Decimal):
        return float(value)

    if isinstance(value, Path):
        return str(value)

    if isinstance(value, pd.Timestamp):
        return None if pd.isna(value) else value.isoformat()

    if isinstance(value, pd.Timedelta):
        return None if pd.isna(value) else str(value)

    if isinstance(value, pd.Period):
        return str(value)

    if isinstance(value, np.generic):
        return to_jsonable(value.item())

    if isinstance(value, (_dt.datetime, _dt.date, _dt.time)):
        return value.isoformat()

    if isinstance(value, pd.DataFrame):
        records = value.astype(object).where(pd.notna(value), None).to_dict(orient="records")
        return to_jsonable(records)

    if isinstance(value, pd.Series):
        return to_jsonable(value.astype(object).where(pd.notna(value), None).to_dict())

    if isinstance(value, np.ndarray):
        return to_jsonable(value.tolist())

    if isinstance(value, dict):
        return {str(to_jsonable(key)): to_jsonable(item) for key, item in value.items()}

    if isinstance(value, (list, tuple, set)):
        return [to_jsonable(item) for item in list(value)]

    try:
        if pd.isna(value):
            return None
    except Exception:
        pass

    return value


def _json_default(value: Any) -> Any:
    converted = to_jsonable(value)
    if converted is value:
        return str(value)
    return converted

def write_json(path: str | Path, data: Any, indent: int = 2) -> None:
    """以 UTF-8 编码原子写出 JSON，避免 Period/Timestamp 等对象写崩 result.json。"""
    path_obj = Path(path)
    ensure_dir(path_obj.parent)

    tmp_path = path_obj.with_name(path_obj.name + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as file:
        json.dump(
            to_jsonable(data),
            file,
            ensure_ascii=False,
            indent=indent,
            allow_nan=False,
            default=_json_default,
        )

    tmp_path.replace(path_obj)


def write_text(path: str | Path, text: str) -> None:
    """写出普通文本文件。"""
    path_obj = Path(path)
    ensure_dir(path_obj.parent)
    with path_obj.open("w", encoding="utf-8") as file:
        file.write(text)


def write_csv_rows(path: str | Path, rows: List[Dict[str, Any]]) -> None:
    """把若干字典行写成 CSV。

    这里不引入 pandas，避免主流程为了一个 summary 再增加依赖与样板代码。
    """
    path_obj = Path(path)
    ensure_dir(path_obj.parent)
    if not rows:
        with path_obj.open("w", encoding="utf-8", newline="") as file:
            file.write("")
        return

    fieldnames: List[str] = []
    seen = set()
    for row in rows:
        for key in row.keys():
            if key not in seen:
                seen.add(key)
                fieldnames.append(str(key))

    with path_obj.open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


@contextmanager
def timed_block() -> Iterator[Dict[str, float]]:
    """记录一个代码块的耗时。"""
    state = {"start": time.perf_counter(), "duration_sec": 0.0}
    try:
        yield state
    finally:
        state["duration_sec"] = round(time.perf_counter() - state["start"], 4)


def extract_json_like(text: str) -> Any:
    """从模型返回文本中尽量提取 JSON。"""
    candidate = (text or "").strip()
    if not candidate:
        raise ValueError("Empty model response")

    try:
        return json.loads(candidate)
    except json.JSONDecodeError:
        pass

    cleaned = candidate.replace("```json", "```")
    if "```" in cleaned:
        parts = cleaned.split("```")
        for part in parts:
            part = part.strip()
            if not part:
                continue
            try:
                return json.loads(part)
            except json.JSONDecodeError:
                continue

    match = _JSON_BLOCK_RE.search(candidate)
    if not match:
        raise ValueError("Could not locate JSON in model response")
    return json.loads(match.group(0))




def extract_python_code(text: str) -> str:
    """从模型回复中提取 Python 代码。

    允许三种形式：
    1. ```python ... ```
    2. ```py ... ```
    3. 直接返回裸代码

    有些模型会把语言标记 ``py`` / ``python`` 留成第一行。这里统一剥掉，
    避免执行时出现 ``NameError: name 'py' is not defined``。
    """
    candidate = (text or "").strip()
    if not candidate:
        raise ValueError("Empty model response")

    match = _CODE_BLOCK_RE.search(candidate)
    if match:
        code = match.group(1).strip()
    else:
        code = candidate
        if code.startswith("```") and code.endswith("```"):
            code = code.strip("`").strip()

    lines = code.splitlines()
    while lines and lines[0].strip().lower() in {"py", "python"}:
        lines = lines[1:]
    return "\n".join(lines).strip()


def normalize_key(text: str) -> str:
    """把字符串规范化成适合比较/拼路径的 key。"""
    return re.sub(r"[^a-z0-9]+", "_", (text or "").lower()).strip("_")


normalize_name = normalize_key


def text_tokens(text: str) -> List[str]:
    """提取英文数字 token，供轻量匹配和打分使用。"""
    return _WORD_RE.findall((text or "").lower())


def truncate_text(text: str, limit: int = 800) -> str:
    """按字符数截断文本，避免 prompt 过长。"""
    text = text or ""
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."



def first_not_none(*values: Any) -> Any:
    """返回第一个非 None 的值。"""
    for value in values:
        if value is not None:
            return value
    return None


def resolve_path(base_dir: Path, value: str | Path) -> Path:
    """把相对路径解析到项目根目录下。"""
    path = Path(value)
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def safe_float(value: Any, default: float = 0.0) -> float:
    """尽量把值转成有限 float；缺失、NaN、inf 时返回默认值。"""
    try:
        if value is None or pd.isna(value):
            return default
    except Exception:
        return default
    try:
        number = float(value)
    except Exception:
        return default
    return number if math.isfinite(number) else default


def maybe_int(value: Any) -> Optional[int]:
    """尽量把值转成 int；失败时返回 None。"""
    if value is None or value == "":
        return None
    try:
        return int(value)
    except Exception:
        return None


def merge_token_usage(*usage_items: Optional[Dict[str, Any]]) -> Dict[str, int]:
    """累加多次 LLM 调用的 token 使用量。"""
    total = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    for usage in usage_items:
        if not usage:
            continue
        total["prompt_tokens"] += int(usage.get("prompt_tokens") or 0)
        total["completion_tokens"] += int(usage.get("completion_tokens") or 0)
        total["total_tokens"] += int(usage.get("total_tokens") or 0)
    return total



def _clone_value(value: Any) -> Any:
    """尽量复制运行时值，避免失败执行污染上一轮状态。"""
    if isinstance(value, pd.DataFrame):
        return value.copy(deep=True)
    if isinstance(value, pd.Series):
        return value.copy(deep=True)
    if isinstance(value, dict):
        return {key: _clone_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_clone_value(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_clone_value(item) for item in value)
    if isinstance(value, set):
        return {_clone_value(item) for item in value}
    if isinstance(value, (str, int, float, bool, type(None), Path, np.generic)):
        return value
    if isinstance(value, (types.ModuleType, types.FunctionType, type)):
        return value
    try:
        return copy.deepcopy(value)
    except Exception:
        return value


_CANONICAL_RESULT_TYPES = {"table", "dict", "scalar", "list", "text"}


def _infer_stage_result_type(value: Any) -> str:
    if isinstance(value, pd.DataFrame):
        return "table"
    if isinstance(value, dict):
        return "dict"
    if isinstance(value, list):
        return "list"
    if isinstance(value, str):
        return "text"
    return "scalar"


def _normalize_stat_items(value: Any) -> List[Dict[str, Any]]:
    """把 stage_result['stat'] 统一成证据对象列表。"""
    if isinstance(value, list):
        raw_items = value
    elif isinstance(value, dict):
        raw_items = [value]
    else:
        raw_items = []

    items: List[Dict[str, Any]] = []
    for index, item in enumerate(raw_items):
        if not isinstance(item, dict):
            continue
        items.append({
            "name": str(item.get("name") or f"Evidence {index + 1}").strip(),
            "description": str(item.get("description") or "Computed evidence.").strip(),
            "value": item.get("value"),
        })
    return items


def _combine_stat_values(stat_items: List[Dict[str, Any]]) -> Any:
    """生成 evidence layer 使用的统一 value。"""
    if not stat_items:
        return None
    if len(stat_items) == 1:
        return stat_items[0].get("value")
    return {item.get("name") or f"evidence_{idx + 1}": item.get("value") for idx, item in enumerate(stat_items)}


def parse_stage_result(raw: Any) -> Dict[str, Any]:
    """Normalize an executed ``stage_result`` into the stat-only internal shape.

    Generated code must set ``stage_result = {"stat": [...]}``. This helper does
    not create or read an answerability field. If generated code cannot satisfy the
    stat contract after repair attempts, the branch ends as an execution error.
    """
    if isinstance(raw, dict):
        payload = dict(raw)
    else:
        payload = {
            "stat": [
                {
                    "name": _infer_stage_result_type(raw),
                    "description": "Computed evidence.",
                    "value": raw,
                }
            ],
        }

    stat_items = _normalize_stat_items(payload.get("stat"))
    value = _combine_stat_values(stat_items)
    result_type = _infer_stage_result_type(value)
    summary = " ".join(
        str(item.get("description") or item.get("name") or "").strip()
        for item in stat_items
        if str(item.get("description") or item.get("name") or "").strip()
    ).strip()
    if not summary and result_type == "table" and isinstance(value, pd.DataFrame):
        summary = f"table with {value.shape[0]} rows and {value.shape[1]} columns"

    return {
        "stat": stat_items,
        "type": result_type,
        "value": value,
        "summary": summary,
    }

def _safe_int(value: Any) -> Optional[int]:
    """安全转 int，失败时返回 None。"""

    if value is None:
        return None
    try:
        return int(value)
    except Exception:
        return None
