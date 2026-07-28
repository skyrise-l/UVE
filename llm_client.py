"""
llm_client.py
-------------
统一的 OpenAI-compatible LLM 调用层。

这版保留两类调用：
1. generate_json：用于 schema / plan / decision / eval 等结构化步骤；
2. generate_text：用于代码生成，直接返回原始文本。
"""

from __future__ import annotations
import mimetypes
import base64
import os
import random
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests
from requests import Response

from query_logger import QueryLogger
from vis_project_utils.utils import extract_json_like


@dataclass
class LLMConfig:
    api_key: str = ""
    api_key_env: str = "OPENAI_API_KEY"
    base_url: str = "https://api.openai.com/v1"
    model: str = "gpt-4.1-mini"
    temperature: Optional[float] = 0.2
    timeout_sec: int = 180
    force_json_mode: bool = True
    max_retries: int = 100
    retry_backoff_sec: float = 5.0
    retry_backoff_multiplier: float = 2.0
    max_retry_backoff_sec: float = 60.0

    reasoning_effort: Optional[str] = None
    disable_thinking: bool = True
    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "LLMConfig":
        """从配置字典生成 LLM 配置。

        如果配置里没有直接写 api_key，则从 api_key_env 指定的环境变量读取。
        这样仓库里不需要保存明文 key，也不影响本地自用运行。
        """
        data = dict(data or {})
        config = cls(**{key: value for key, value in data.items() if key in cls.__dataclass_fields__})
        if not config.api_key and config.api_key_env:
            config.api_key = os.getenv(str(config.api_key_env), "")
        return config

    def copy_with(self, **overrides: Any) -> "LLMConfig":
        payload = asdict(self)
        payload.update({key: value for key, value in overrides.items() if value is not None})
        return LLMConfig.from_dict(payload)


@dataclass
class LLMResponse:
    parsed: Any
    duration_sec: float
    usage: Dict[str, int]
    raw_content: str = ""


@dataclass
class LLMRawChatResponse:
    """低层 chat/completions 响应，用于需要 choice/logprobs 或多采样的场景。"""

    content: str
    choice: Dict[str, Any]
    usage: Dict[str, int]
    duration_sec: float
    choices: List[Dict[str, Any]] = field(default_factory=list)


@dataclass
class LLMConversation:
    """轻量连续对话容器。"""

    client: "OpenAICompatibleClient"
    system_prompt: str
    model: Optional[str] = None
    temperature: Optional[float] = None
    messages: List[Dict[str, Any]] = field(default_factory=list)

    def generate_json(
        self,
        step_name: str,
        user_prompt: str,
        image_paths: Optional[List[str]] = None,
        logger: Optional[QueryLogger] = None,
    ) -> LLMResponse:
        response, user_message = self.client._request_internal(
            step_name=step_name,
            system_prompt=self.system_prompt,
            user_prompt=user_prompt,
            image_paths=image_paths,
            model=self.model,
            temperature=self.temperature,
            logger=logger,
            message_history=self.messages,
            expect_json=True,
        )
        self.messages.append(user_message)
        self.messages.append({"role": "assistant", "content": response.raw_content})
        return response

    def generate_text(
        self,
        step_name: str,
        user_prompt: str,
        image_paths: Optional[List[str]] = None,
        logger: Optional[QueryLogger] = None,
    ) -> LLMResponse:
        response, user_message = self.client._request_internal(
            step_name=step_name,
            system_prompt=self.system_prompt,
            user_prompt=user_prompt,
            image_paths=image_paths,
            model=self.model,
            temperature=self.temperature,
            logger=logger,
            message_history=self.messages,
            expect_json=False,
        )
        self.messages.append(user_message)
        self.messages.append({"role": "assistant", "content": response.raw_content})
        return response

    def snapshot(self) -> List[Dict[str, Any]]:
        return [dict(message) for message in self.messages]


def chat_completions_endpoint(base_url: str) -> str:
    """Normalize an OpenAI-compatible base URL to the chat/completions endpoint."""
    endpoint = str(base_url or "").rstrip("/")
    if endpoint.endswith("/chat/completions"):
        return endpoint
    if endpoint.endswith("/v1"):
        return endpoint + "/chat/completions"
    return endpoint + "/chat/completions"


def _uses_reasoning_effort(model: Optional[str]) -> bool:
    """GPT-5 系列使用 OpenAI reasoning_effort；其他模型沿用原 thinking 开关。"""
    model_name = str(model or "").strip().lower()
    model_basename = model_name.rsplit("/", 1)[-1]
    return model_basename == "gpt-5" or model_basename.startswith("gpt-5-")


def _apply_thinking_control(payload: Dict[str, Any], config: LLMConfig) -> None:
    """根据模型类型二选一地加入思考控制参数，避免同时发送不兼容字段。"""
    if _uses_reasoning_effort(config.model):
        if config.reasoning_effort:
            payload["reasoning_effort"] = str(config.reasoning_effort)
        return

    if config.disable_thinking:
        payload["thinking"] = {"type": "disabled"}
        payload["chat_template_kwargs"] = {
            "enable_thinking": False
        }

def _compute_backoff_delay(config: LLMConfig, retry_index: int) -> float:
    """计算指数退避时间；429 使用本地计算，不依赖 API 的 Retry-After。"""
    base = max(float(config.retry_backoff_sec or 2.0), 0.1)
    multiplier = max(float(config.retry_backoff_multiplier or 2.0), 1.0)
    max_delay = min(max(float(config.max_retry_backoff_sec or 60.0), base), 60.0)

    delay = min(base * (multiplier ** max(0, retry_index - 1)), max_delay)

    # 加一点 jitter，避免多个请求同时醒来再次打爆接口。
    jitter = random.uniform(0.0, min(1.0, delay * 0.1))
    return min(delay + jitter, max_delay)

class OpenAICompatibleClient:
    """轻量 chat/completions 客户端。"""

    def __init__(self, config: LLMConfig):
        self.config = config

    def start_conversation(
        self,
        system_prompt: str,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
    ) -> LLMConversation:
        return LLMConversation(
            client=self,
            system_prompt=system_prompt,
            model=model,
            temperature=temperature,
        )
    
    def chat_completion_raw(
        self,
        *,
        step_name: str,
        messages: List[Dict[str, Any]],
        logger: Optional[QueryLogger] = None,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        top_p: Optional[float] = None,
        logprobs: bool = False,
        top_logprobs: Optional[int] = None,
        response_format_json: bool = False,
        frequency_penalty: Optional[float] = None,
        n: Optional[int] = None,
    ) -> LLMRawChatResponse:
        """统一的低层 OpenAI-compatible chat/completions 调用。

        用于评估等需要原始 choice、logprobs/top_logprobs 的场景。
        普通任务优先使用 generate_json / generate_text。
        """
        config = self.config.copy_with(model=model, temperature=temperature)
        if not config.api_key:
            raise RuntimeError(
                "LLM api_key is empty. 请在 config.json 中填写 api_key，或设置 api_key_env 指向的环境变量。"
            )

        payload: Dict[str, Any] = {
            "model": config.model,
            "messages": messages,
        }
        if config.temperature is not None:
            payload["temperature"] = float(config.temperature)
        if max_tokens is not None:
            payload["max_tokens"] = int(max_tokens)
        if top_p is not None:
            payload["top_p"] = float(top_p)
        if logprobs:
            payload["logprobs"] = True
        if top_logprobs is not None and int(top_logprobs) > 0:
            payload["top_logprobs"] = int(top_logprobs)
        if frequency_penalty is not None:
            payload["frequency_penalty"] = float(frequency_penalty)
        if n is not None and int(n) > 1:
            payload["n"] = int(n)
        if response_format_json:
            payload["response_format"] = {"type": "json_object"}

        _apply_thinking_control(payload, config)

        headers = {
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": "application/json",
        }

        usage: Dict[str, int] = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        content = ""
        choice: Dict[str, Any] = {}
        started = time.perf_counter()
        max_attempts = max(1, 1 + int(config.max_retries))
        backoff_sec = max(float(config.retry_backoff_sec), 0.0)
        attempt_errors: List[str] = []
        system_prompt = str((messages[0] or {}).get("content", "")) if messages else ""
        user_prompt = str((messages[-1] or {}).get("content", "")) if messages else ""

        attempt_index = 1
        while attempt_index <= max_attempts:
            response: Optional[Response] = None
            try:
                response = requests.post(
                    chat_completions_endpoint(config.base_url),
                    headers=headers,
                    json=payload,
                    timeout=config.timeout_sec,
                )
                response.raise_for_status()
                data = response.json()
                choices = data.get("choices") or [{}]
                choice = choices[0]
                content = str(((choice.get("message") or {}).get("content") or "")).strip()
                usage = data.get("usage") or usage
                duration_sec = round(time.perf_counter() - started, 4)
                if logger is not None:
                    logger.log_llm(
                        step_name=step_name,
                        system_prompt=system_prompt,
                        user_prompt=user_prompt,
                        response_content=content,
                        duration_sec=duration_sec,
                        usage=usage,
                    )
                return LLMRawChatResponse(
                    content=content,
                    choice=choice,
                    usage=usage,
                    duration_sec=duration_sec,
                    choices=list(choices),
                )
            except Exception as exc:
                attempt_errors.append(str(exc))
                if attempt_index >= max_attempts:
                    raise RuntimeError(f"LLM raw chat failed after {max_attempts} attempts: {exc}") from exc
                delay = _compute_backoff_delay(config, attempt_index)
                attempt_index += 1
                print(f"API error {exc}, sleep {delay}")
                time.sleep(delay)
        raise RuntimeError(f"LLM raw chat failed after {max_attempts} attempts: {'; '.join(attempt_errors[-3:])}")

    def guess_mime_type(self, image_path: str) -> str:
        """根据文件后缀猜测 MIME；猜不到时回退为 image/png"""
        mime, _ = mimetypes.guess_type(image_path)
        if mime and mime.startswith("image/"):
            return mime
        return "image/png"

    def _encode_image(self, image_path: str) -> str:
        with Path(image_path).open("rb") as file:
            return base64.b64encode(file.read()).decode("utf-8")

    def _build_user_content(self, text: str, image_paths: Optional[List[str]], config: LLMConfig) -> Any:
        if not image_paths:
            return text

        content: List[Dict[str, Any]] = [{"type": "text", "text": text}]
        for image_path in image_paths:
            mime_type = self.guess_mime_type(image_path)
            content.append(
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:{mime_type};base64,{self._encode_image(image_path)}"},
                }
            )
        return content

    def _request_internal(
        self,
        step_name: str,
        system_prompt: str,
        user_prompt: str,
        image_paths: Optional[List[str]] = None,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
        logger: Optional[QueryLogger] = None,
        message_history: Optional[List[Dict[str, Any]]] = None,
        expect_json: bool = True,
    ) -> Tuple[LLMResponse, Dict[str, Any]]:
        config = self.config.copy_with(model=model, temperature=temperature)
        if not config.api_key:
            raise RuntimeError(
                "LLM api_key is empty. 请在 config.json 中填写 api_key，或设置 api_key_env 指向的环境变量。"
            )

        endpoint = chat_completions_endpoint(config.base_url)
        user_message = {
            "role": "user",
            "content": self._build_user_content(user_prompt, image_paths=image_paths, config=config),
        }
        messages: List[Dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        if message_history:
            messages.extend(message_history)
        messages.append(user_message)

        payload: Dict[str, Any] = {
            "model": config.model,
            "messages": messages,
        }
        if config.temperature is not None:
            payload["temperature"] = float(config.temperature)
        if expect_json and config.force_json_mode:
            payload["response_format"] = {"type": "json_object"}

        _apply_thinking_control(payload, config)

        headers = {
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": "application/json",
        }

        content = ""
        parsed: Any = None
        usage: Dict[str, int] = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        started = time.perf_counter()
        max_attempts = max(1, 1 + int(config.max_retries))
        backoff_sec = max(float(config.retry_backoff_sec), 0.0)
        attempt_errors: List[str] = []

        attempt_index = 1
        while attempt_index <= max_attempts:
            response: Optional[Response] = None
            content = ""
            parsed = None
            try:
                print("开始请求")
                start_time = time.perf_counter()
                response = requests.post(endpoint, headers=headers, json=payload, timeout=config.timeout_sec)
                response.raise_for_status()
                data = response.json()
                
                end_time = time.perf_counter() - start_time
                print(f"结束请求 {end_time}")
                content = data["choices"][0]["message"]["content"]
                parsed = extract_json_like(content) if expect_json else None
                usage = data.get("usage") or {}
                duration_sec = round(time.perf_counter() - started, 4)
                if logger is not None:
                    logger.log_llm(
                        step_name=step_name,
                        system_prompt=system_prompt,
                        user_prompt=user_prompt,
                        response_content=content,
                        duration_sec=duration_sec,
                        usage=usage,
                        image_paths=image_paths,
                    )
                return LLMResponse(parsed=parsed, duration_sec=duration_sec, usage=usage, raw_content=content), user_message
            except Exception as exc:
                attempt_errors.append(str(exc))
                if attempt_index >= max_attempts:
                    raise RuntimeError(f"LLM request failed after {max_attempts} attempts: {exc}") from exc
                delay = _compute_backoff_delay(config, attempt_index)
                print(f"API error {exc}, sleep {delay}")
                attempt_index += 1
                time.sleep(delay)
        raise RuntimeError(f"LLM request failed after {max_attempts} attempts: {'; '.join(attempt_errors[-3:])}")
        
    def generate_json(
        self,
        step_name: str,
        system_prompt: str,
        user_prompt: str,
        image_paths: Optional[List[str]] = None,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
        logger: Optional[QueryLogger] = None,
        message_history: Optional[List[Dict[str, Any]]] = None,
    ) -> LLMResponse:
        response, _ = self._request_internal(
            step_name=step_name,
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            image_paths=image_paths,
            model=model,
            temperature=temperature,
            logger=logger,
            message_history=message_history,
            expect_json=True,
        )
        return response

    def generate_text(
        self,
        step_name: str,
        system_prompt: str,
        user_prompt: str,
        image_paths: Optional[List[str]] = None,
        model: Optional[str] = None,
        temperature: Optional[float] = None,
        logger: Optional[QueryLogger] = None,
        message_history: Optional[List[Dict[str, Any]]] = None,
    ) -> LLMResponse:
        response, _ = self._request_internal(
            step_name=step_name,
            system_prompt=system_prompt,
            user_prompt=user_prompt,
            image_paths=image_paths,
            model=model,
            temperature=temperature,
            logger=logger,
            message_history=message_history,
            expect_json=False,
        )
        return response
