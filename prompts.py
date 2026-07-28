"""项目主流程提示词。

本文件集中保存 root 规划、持续分析会话、局部续问、全局新角度生成与问题选择、
代码生成和证据解释提示。提示词是实验设计的一部分：frontier 只作为可选线索，
问题仍需综合原始目标、Schema、既有执行结果和会话上下文。
"""

from __future__ import annotations

import json
from typing import Any, Dict, List

from data_loader import InsightBenchTask
from analysis_tendency import ANALYSIS_TENDENCY_TYPES


# =============================================================================
# (0) 共享辅助函数
# =============================================================================


def _json_block(payload: Any) -> str:
    """把 prompt 中需要展示的结构化信息稳定序列化。"""
    return json.dumps(payload, ensure_ascii=False, indent=2, default=str)


def _task_metadata(task: Any) -> Dict[str, Any]:
    return dict(getattr(task, "metadata", {}) or {})


def _benchmark_name(task: Any = None) -> str:
    """返回稳定的数据集名称；可接收 Task 或数据集名称字符串。"""
    if isinstance(task, str) and task.strip():
        return task.strip().lower()
    metadata = _task_metadata(task)
    benchmark = metadata.get("benchmark") or metadata.get("source")
    if benchmark:
        return str(benchmark).strip().lower()
    if str(getattr(task, "table_relationships", "") or "").strip():
        return "bird"
    return "insightbench"


def _is_bird(task: Any = None) -> bool:
    return _benchmark_name(task) == "bird"


def get_task_benchmark(task: Any) -> str:
    """供调用层传递最小 benchmark 参数。"""
    return _benchmark_name(task)


def get_task_context(task: InsightBenchTask) -> str:
    """返回任务上下文；若数据集未提供则使用通用说明。"""
    metadata = _task_metadata(task)
    context = (
        metadata.get("context")
        or metadata.get("dataset_description")
        or metadata.get("description")
    )
    if context:
        return str(context)
    return "This is a dataset that could potentially consist of interesting insights"


def get_task_goal(task: InsightBenchTask) -> str:
    """返回 InsightBench 或 BIRD 任务目标。"""
    metadata = _task_metadata(task)
    return metadata.get("goal") or "I want to find interesting trends in this dataset"


def _table_relationships_text(task: Any) -> str:
    """返回 BIRD 数据库级英文连接关系；其他任务为空。"""
    return str(getattr(task, "table_relationships", "") or "").strip()


def format_task_schema(task: InsightBenchTask) -> str:
    """返回数据集 schema，并在 BIRD 中附加数据库级连接关系。"""
    try:
        tables = [table.to_prompt_dict() for table in task.all_tables()]
    except Exception:
        tables = (
            getattr(task, "schema", None)
            or getattr(task, "table_schemas", None)
            or getattr(task, "tables", None)
            or {}
        )

    relationships = _table_relationships_text(task)
    if relationships:
        return _json_block({
            "tables": tables,
            "table_relationships": relationships,
        })
    return _json_block(tables)


def _json_schema_text(schema: Dict[str, Any]) -> str:
    return _json_block(schema)


def _root_question_policy(task: Any) -> str:
    if _is_bird(task):
        return """
* Keep each question focused on one analytical claim, with only the supporting measures needed to establish it.
* Across candidates, cover the main outcome and distinct natural dimensions or declared relationship paths; do not repeat the same path with a different final attribute.
* Use observable comparisons and avoid arbitrary thresholds unless the goal defines them.
""".strip()
    return """
* Make every question independently executable; do not depend on an unknown winner from another question.
* Cover the main outcome and distinct explanatory dimensions rather than repeated drill-downs into one subgroup.
* Ask for descriptive differences, associations, composition, or patterns—not unsupported causes.
""".strip()


def _root_selection_policy(task: Any = None) -> str:
    rules = """
* Maximize coverage of the original goal, not wording diversity.
* Include a direct baseline or main-outcome question before narrow drill-downs.
* Prefer distinct factors or relationships; treat questions with the same population, outcome, grouping, and relationship as duplicates.
""".strip()
    if _is_bird(task):
        return rules + "\n* Do not favor a question merely because it uses more tables or a longer join path."
    return rules


def _supplemental_question_policy(task: Any = None) -> str:
    if _is_bird(task):
        return """
* Treat an unexecuted join route as a possibility, not a finding.
* Prefer an unanswered part of the original goal over another narrow drill-down into a supplemental subgroup.
* A genuinely new angle changes the main measure, grouping, safe grain, or declared path.
""".strip()
    return """
* Prefer a previously untested goal-level relationship over another drill-down into the same subgroup.
* A genuinely new angle changes the main explanatory dimension or analytical relationship.
""".strip()


def _qep_policy(task: Any) -> str:
    if _is_bird(task):
        return """
* State the reporting grain and preserve numerator, denominator, and valid group size for rates, shares, or margins.
* Keep natural comparison groups; do not invent thresholds unless the question requires them.
""".strip()
    return """
* Schema top_values are examples, not a filter list.
* Do not add a business filter, subgroup, threshold, or proxy absent from the question; only remove invalid values when computation requires it.
""".strip()




# =============================================================================
# (1) Root Question 生成提示
# =============================================================================

# 本阶段使用官方 AgentPoirot 的 manager 角色 system message。
GET_QUESTIONS_SYSTEM_MESSAGE = """
You the manager of a data science team whose goal is to help stakeholders within your company extract actionable insights from their data.
You have access to a team of highly skilled data scientists that can answer complex questions about the data.
You call the shots and they do the work.
You need to produce data analysis insights with clear data support based on their results.
""".strip()


# 当前项目的 JSON 输出阶段统一复用这个 system prompt。
COMPARISON_SYSTEM_PROMPT = (
    GET_QUESTIONS_SYSTEM_MESSAGE
    + "\nWhen JSON is requested, return valid JSON only and satisfy the requested schema."
)


def build_root_question_candidates_prompt(
    task: InsightBenchTask,
    *,
    candidate_count: int,
    join_opportunities: str = "",
) -> str:
    """生成 root question 候选的提示。

    输入：task 的 context、goal、schema，以及候选数量。
    输出：先给出目标是否能被当前 schema 支撑的整体判断；只有当整体可回答时，
    才生成简单的 id/question 候选列表。

    设计原因：no-answer 任务的核心不是让模型“故意生成不可回答问题”，而是
    先判断原始目标与 schema 是否有关、是否缺少必要证据。若明显缺列、缺 join
    key、缺时间字段、缺标签或缺因果证据，则应直接标记 answerability=false，
    说明缺失证据，避免绕到 proxy question。
    """
    output_schema = {
        "answerability": {
            "can_answer": "boolean; false when the original goal/query is not answerable from the provided schema",
            "reason": "short reason; when false, explicitly name the missing required columns/evidence",
        },
        "questions": [
            {
                "id": "Q1",
                "question": "one root question"
            }
        ],
    }
    candidate_n = int(candidate_count)
    join_text = str(join_opportunities or "").strip()
    join_section = ""
    if join_text:
        join_section = f"""
Optional schema-grounded join routes:
{join_text}

How to use the optional join opportunities:
* These represent a possible analytical path for this exploratory question, but whether to use them is up to you.
* Multi-table joins are often important in this benchmark, but use them only when they materially help answer the question; a longer Join path is not valuable by itself.
* Phrase questions as analytical questions. If necessary, you can specify the tables or join operations involved, but do not simply state table joins as instructions.
""".strip()
    return f"""
### Instruction:

Context:

{get_task_context(task)}

Goal:
{get_task_goal(task)}

Schema:
{format_task_schema(task)}

{join_section}

Before generating any root questions, perform a schema-grounded answerability analysis for the original goal/query.

Rules for answerability:
* If the original goal/query is unrelated to the provided schema, or cannot be answered because required evidence is missing, set `answerability.can_answer` to false.
* Missing evidence includes required tables and columns that the goal depends on.
* When `answerability.can_answer` is false, clearly explain which required evidence is missing and why this prevents answering the original goal/query. In that case, return an empty `questions` list.
* Do not invent proxy columns, proxy values or causal assumptions to make an unanswerable goal look answerable.

When, and only when, you determine the original goal/query is answerable from the current schema, generate exactly {candidate_n} candidate root questions.

Rules for root questions:
* Each item should contain only `id` and `question`.
* Use ids Q1, Q2, ..., Q{candidate_n}.
* Each question must be strongly related to the overall goal and directly answer it, but usually needs to be analyzed from different perspectives.
* Prioritize analysis from different table columns, then consider analysis at different levels of the same table column.
* If necessary, you can add a description of the expected analysis for this question in the question to help the subsequent analyzer better understand your question.

{_root_question_policy(task)}

Return JSON in this schema:

{_json_schema_text(output_schema)}

### Response:
""".strip()



def build_select_root_questions_prompt(
    *,
    select_count: int,
    benchmark_name: str = "insightbench",
) -> str:
    """在同一 conversation 中筛选 root questions 的提示。

    输入：不再重复 context/goal/schema，只依赖同一 conversation 中上一条 assistant
    已经给出的 id/question 候选，并补充本轮筛选目标。
    输出：selected_indices，表示优先执行哪些候选。

    设计原因：候选生成和候选筛选需要分成两次请求，让第二次请求专注于
    “选择”这一任务；但二者处于同一 conversation，避免在第二次 user message
    中重复发送大段 schema/context。
    """
    output_schema = {"selected_indices": [0, 1, 2]}
    select_n = int(select_count)
    return f"""
Now select exactly {select_n} root questions from the candidate list you just generated in the previous assistant message.

Selection rules:
* Select by zero-based candidate index from the previous candidate list.
* Keep the selected set tightly connected to the original goal.
* Select diverse questions, not near-duplicate rewrites of the same computation.
* Priority is given to questions that answer directly to the target, but from different angles of analysis.
{_root_selection_policy(benchmark_name)}
* Return JSON only.

Return JSON in this schema:

{_json_schema_text(output_schema)}

### Response:
""".strip()


def build_local_next_question_prompt(
    *,
    current_question: str,
    current_insight: str,
    selected_exploration_evidence: str = "",
) -> str:
    """让同一分析会话提出一个自然的后续问题。

    该提示依赖会话中已经存在的目标、Schema、QEP、代码和执行证据，
    因此只重述当前结论与少量可选探索线索。frontier 是参考，不是硬约束。
    """
    output_schema = {
        "question": "one concrete next question that extends the current line of analysis",
        "trigger_evidence_ids": [
            "optional exact IDs of exploration cues that directly support this question"
        ],
    }
    exploration_text = str(selected_exploration_evidence or "").strip() or "None"
    return f"""
The current analysis question has been completed. Generate exactly one concrete next question for this analysis line.

Current question:
{current_question}

Current insight:
{current_insight or "No reliable insight was produced."}

Optional exploration cues from the executed result:
{exploration_text}

The next question should add materially new evidence for the original goal. It may quantify or verify the current finding, test an important interaction, examine a nearby pattern suggested by the result, or resolve a clear limitation.

Rules:
* Use the original goal, schema, accumulated conversation, executed result, and current insight together.
* The optional exploration cues are suggestions rather than the only basis for the next question. Do not treat an unexecuted direction as a finding.
* Do not restate the current question, repeat evidence already established, or make the next question narrower without a clear analytical reason.
* Keep the question answerable from the available data and centered on one main computation or comparison.
* In `trigger_evidence_ids`, include only exact cue IDs shown above that directly support the proposed question.
* Return JSON only.

Return JSON in this schema:
{_json_schema_text(output_schema)}

### Response:
""".strip()


def build_global_new_angle_questions_prompt(
    *,
    benchmark_name: str = "insightbench",
    analysis_history: str,
    continuation_candidates: List[Dict[str, Any]],
    selected_exploration_evidence: str = "",
    max_questions: int = 2,
    generation_index: int = 1,
) -> str:
    """让中央管理器补充一到两个尚未覆盖的新分析角度。

    输入只包含自上次全局回顾后新完成的 Question--Insight 记录、各分析会话
    当前提出的下一问，以及少量全局 frontier。更早的分析记录已经保留在同一
    manager conversation 中，不在每轮重复序列化。提示只要求发现缺失角度，
    不承担预算与执行调度。
    """
    output_schema = {
        "questions": [
            {
                "question": "one concrete question that opens a materially different analytical angle",
                "trigger_evidence_ids": [
                    "optional exact IDs of exploration cues that directly support this question"
                ],
            }
        ]
    }
    history_text = str(analysis_history or "").strip() or "None"
    continuation_text = _json_block(continuation_candidates) if continuation_candidates else "None"
    exploration_text = str(selected_exploration_evidence or "").strip() or "None"
    return f"""
Review the analysis completed so far and generate {int(max_questions)} concrete questions that open new analytical angles for the original goal. The original context, goal, and full schema are already available earlier in this conversation.

Planning pass: {int(generation_index)}

Newly completed Question--Insight records since the previous planning pass:
{history_text}

Suggested continuation questions from the completed analyses:
{continuation_text}

Optional exploration cues:
{exploration_text}

Each question must open a materially different, goal-relevant analytical angle and should complement rather than duplicate the suggested continuations.

Rules:
* Use the original goal, schema, all earlier planning context in this conversation, the newly completed results above, and suggested continuations together.
* A different angle should change the main analytical relationship, outcome, comparison, grain, or declared table path—not merely add a narrower filter.
* Keep every question answerable from the available schema and centered on one main computation or comparison.
* Optional exploration cues may motivate a question, but they are not the only basis for planning and unexecuted directions are not findings.
* Do not repeat evidence already established in the completed Insights.
* In `trigger_evidence_ids`, include only exact cue IDs shown above that directly support the proposed question.
{_supplemental_question_policy(benchmark_name)}
* Return JSON only.

Return JSON in this schema:
{_json_schema_text(output_schema)}

### Response:
""".strip()


def build_select_next_questions_prompt(
    *,
    candidates: List[Dict[str, Any]],
    max_selected: int = 2,
) -> str:
    """从现有续问和新角度候选中选择下一组互补问题。

    预算、会话创建和两轮保护均由代码处理，不暴露给模型。模型只判断
    哪些问题最可能为原始目标增加新证据。
    """
    output_schema = {
        "selected_ids": ["candidate id"],
    }
    return f"""
Choose {int(max_selected)} questions for the next analysis step from the candidate list below.

Candidate questions:
{_json_block(candidates)}

Selection rules:
* Select questions that are directly relevant to the original goal and likely to add material evidence beyond the completed work.
* Prefer a complementary set rather than two questions that repeat the same population, measure, grouping, or relationship.
* A promising continuation is valuable when it meaningfully extends or verifies an existing result. A different-angle question is valuable when it covers an important part of the goal that remains underexplored.
* Do not select a question merely because it mentions more tables, a longer join path, or an optional exploration cue.
* Select only IDs from the candidate list.
* Return JSON only.

Return JSON in this schema:
{_json_schema_text(output_schema)}

### Response:
""".strip()


# =============================================================================
# (3.5) Question Evidence Profile + Stage Code 提示
# =============================================================================

# 单个问题分支使用同一会话完成：证据画像 -> 代码生成/修复 -> 证据解释。
# Schema 只在画像请求中发送一次，后续请求依赖同一会话上下文，避免重复长 Schema。
ANALYSIS_BRANCH_SYSTEM_PROMPT = (
    "You are a data scientist responsible for one coherent line of exploratory analysis. "
    "Work on one selected question at a time, preserve continuity with earlier results in this conversation, "
    "and keep every conclusion grounded in the supplied schema and executed evidence. "
    "When asked for a next question, treat optional exploration cues as suggestions rather than instructions. "
    "Follow every requested JSON or Python output format exactly."
)


def _question_evidence_profile_schema() -> Dict[str, Any]:
    """Question Evidence Profile 的最小输出结构。

    QEP 只描述代码执行前的证据契约，不承担可回答性拦截，也不生成执行计划。
    - evidence_focus：stage_result 应保留的证据要求；
    - analysis_tendency：仅用于视觉候选排序的辅助偏好；不得用于过滤、阈值调整或证据授权。

    round_question 由调用代码注入，不再要求模型复制输入问题。
    """
    return {
        "evidence_focus": [
            (
                "one to four concrete evidence requirements for stage_result. "
                "Each item should specify the metric or quantity, grouping/comparison, "
                "denominator or baseline, grain, event/time anchor, and exact entity/value anchors to preserve when relevant. "
                "Do not invent results before code execution."
            )
        ],
        "analysis_tendency": [
            {
                "type": "one allowed analysis tendency type",
                "strength": "number from 0 to 1",
                "reason": "short reason based on the question",
            }
        ],
    }


def build_question_evidence_profile_prompt(
    task: InsightBenchTask,
    fixed_question: str,
    round_index: int,
    trigger_evidence: List[Dict[str, Any]],
    *,
    include_schema: bool = True,
) -> str:
    """为当前问题生成轻量证据画像。

    新分析会话的第一个问题包含任务 Context、完整目标与 Schema；同一会话中的
    后续问题直接复用已有上下文，避免重复发送长 Schema。
    """
    trigger_text = _json_block(trigger_evidence) if trigger_evidence else "None"
    if include_schema:
        context_section = f"""
Context:
{get_task_context(task)}

Goal:
{get_task_goal(task)}

Schema and declared relationships:
{format_task_schema(task)}
""".strip()
    else:
        context_section = (
            "Use the original goal, schema, declared relationships, and prior executed results "
            "already established in this conversation."
        )

    return f"""
{context_section}

Selected question for round {int(round_index)}:
"{fixed_question}"

Optional trigger evidence:
{trigger_text}

Create a short Question Evidence Profile before writing code. The profile defines the evidence contract for this question; it is not a pandas procedure.

Requirements:
* Return JSON only.
* In `evidence_focus`, provide one to four concrete evidence requirements for `stage_result`. Include the metric or quantity, grouping or comparison, denominator or baseline, grain, event/time anchor, and entity/value anchors when they matter.
* Do not prescribe low-level pandas operations. The code step chooses the implementation.
* Use earlier results in this conversation only as context. The current question still requires its own executed evidence.
* If trigger evidence is provided, use it only to clarify the selected question. Do not broaden the evidence contract to unrelated patterns and do not treat an unexecuted direction as a finding.
* `analysis_tendency` is only a soft prior for later visual evidence selection. It is not evidence and must not contain results.
* Return one primary analysis tendency and at most two supporting tendencies.
* `analysis_tendency` may use only these types: {ANALYSIS_TENDENCY_TYPES}

{_qep_policy(task)}

Return JSON in this schema:
{_json_schema_text(_question_evidence_profile_schema())}

### Response:
""".strip()


def _stage_code_contract(task: Any = None) -> List[str]:
    """代码生成的稳定执行契约。"""
    contract = [
        "Return executable Python code only.",
        "Use the runtime mapping tables: dict[str, pandas.DataFrame]; access a source table as tables[\"table_name\"]. Do not read files.",
        "At the end, set stage_result = {'stat': list}.",
        "Each stat item must include name, description, and value.",
        "Each stat item must contain computed evidence for the selected question.",
        "Return compact evidence that preserves concrete entities, values, comparison groups, and denominators when they matter.",
        
        "If value is a DataFrame, keep only evidence rows and columns, never a full raw table.",
        "Do not draw charts or terminate the process.",
    ]
    if _table_relationships_text(task):
        contract.append("For joins, use declared relationships and every column pair in a composite key.")
    return contract


def build_stage_code_prompt(task: InsightBenchTask) -> str:
    """Request code using the QEP and schema already present in the branch conversation."""
    return f"""
Write the Python analysis for the selected question using the established schema, relationships, and Question Evidence Profile.


Execution contract:
```json
{_json_block(_stage_code_contract(task))}
```

Return code only.
""".strip()



def build_stage_repair_prompt(
    task: InsightBenchTask,
    error_message: str,
    *,
    evidence_profile: Dict[str, Any],
    failed_code: str,
) -> str:
    """请求修复当前分支代码，但不重复发送完整 Schema。

    当前分析会话在首问已经获得完整 Schema 和声明关系。修复阶段只补充当前
    Question Evidence Profile、失败代码和错误信息，并明确要求继续遵循会话中
    已建立的 Schema。这样既保留修复所需上下文，也避免每次重发多表 Schema。
    """
    profile = dict(evidence_profile or {})
    question = str(profile.get("round_question") or "").strip()
    latest_code = str(failed_code or "").strip()
    latest_error = str(error_message or "").strip()

    return f"""
The latest code for this analysis question failed. Return a complete executable replacement.

Continue to follow the exact table names, source column names, and declared relationships already established earlier in this conversation. Do not invent a table or source column that was not present in that schema.

Original selected question:
{question or "Not separately available; use the Question Evidence Profile below."}

Question Evidence Profile:
{_json_block(profile)}

Failed code:
```python
{latest_code}
```

Execution error:
{latest_error}

Execution contract:
{_json_block(_stage_code_contract(task))}

Repair instructions:
1. Do not change the analytical target merely to avoid the error.
2. Return a complete replacement and rebuild the failing computation as simply as possible; do not stack defensive patches around an incorrect pipeline.
3. Check how each merge, join, aggregation, reset_index, and rename changes the columns that are actually available at the failing line. In particular, handle duplicate-column suffixes explicitly or rename/select columns before merging instead of assuming the original source name survives unchanged.
4. Explicitly create every derived column before using it and do not rely on a derived column from the failed attempt.
5. Preserve the required `stage_result` contract and return only executable Python code, with no explanation outside the code.
""".strip()


# =============================================================================
# (6) 证据解释提示
# =============================================================================

def _interpret_analysis_payload(evidence_payload: Dict[str, Any]) -> Dict[str, Any]:
    """提取解释阶段实际需要的新证据；问题上下文已保存在当前会话中。"""
    answer_evidence = dict((evidence_payload or {}).get("answer_evidence") or {})
    stage_result = dict(answer_evidence.get("stage_result", {}) or {})
    return {
        "evidence_brief": dict((evidence_payload or {}).get("evidence_brief") or {}),
        "supporting_stage_result": stage_result,
        "supporting_evidence_cards": str((evidence_payload or {}).get("answer_evidence_cards") or ""),
    }


def build_insightbench_interpret_evidence_prompt(
    *,
    question: str,
    evidence_payload: Dict[str, Any],
) -> str:
    """使用 InsightBench 官方风格的 answer / insight / justification 三元组。"""
    output_schema = {
        "answer": "single-sentence answer to the question",
        "insight": "one concise, non-trivial, grounded insight in layman's terms",
        "justification": "evidence-based justification with concrete numbers",
    }
    analysis_payload = _interpret_analysis_payload(evidence_payload)

    return f"""
The code has finished. Interpret the evidence below for the same selected question:
"{question}"

Analysis evidence:
```json
{_json_block(analysis_payload)}
```

Instructions:
* If `supporting_stage_result.answerable` is false, or the payload is only a runtime diagnostic, do not invent proxy evidence or unsupported quantitative findings. State the limitation directly.
* The answer should be a single sentence that directly answers the selected question and includes the key details supported by the evidence.
* The insight should be one interesting, goal-relevant, grounded, informative, non-trivial, and concise conclusion in layman's terms.
* Make the insight quantitative when quantitative evidence exists, but keep detailed supporting numbers in the justification rather than overloading the insight.
* The justification should explain the evidence with concrete numbers and the comparison, denominator, sample size, or time scope needed to verify the finding.

Return JSON in this schema:
{_json_schema_text(output_schema)}

### Response:
""".strip()


def build_bird_interpret_evidence_prompt(
    *,
    question: str,
    evidence_payload: Dict[str, Any],
) -> str:
    """保留 BIRD-EDA 当前的 evidence-anchored insight-only 提示。"""
    output_schema = {
        "insight": "one concise question-level finding with the exact evidence anchors needed to verify it",
    }
    analysis_payload = _interpret_analysis_payload(evidence_payload)

    return f"""
The code has finished. Interpret the evidence for the selected question:
"{question}"

Analysis evidence:
```json
{_json_block(analysis_payload)}
```

Instructions:
* Return one interesting, goal-relevant, grounded, informative, non-trivial, and concise finding.
* Put the exact evidence anchors needed to verify the finding directly in `insight`: concrete numbers, entities, comparison groups, denominators, valid sample sizes, and time ranges when available.
* If the evidence is insufficient or only diagnostic, state the limitation directly instead of inventing a proxy result.
* Do not refer to a separate answer or justification field; this output schema contains only `insight`.

Return JSON in this schema:
{_json_schema_text(output_schema)}

### Response:
""".strip()


def build_interpret_evidence_prompt(
    *,
    question: str,
    evidence_payload: Dict[str, Any],
    benchmark_name: str = "insightbench",
) -> str:
    """按数据集选择解释提示；调用链和会话形式保持不变。"""
    if _is_bird(benchmark_name):
        return build_bird_interpret_evidence_prompt(
            question=question,
            evidence_payload=evidence_payload,
        )
    return build_insightbench_interpret_evidence_prompt(
        question=question,
        evidence_payload=evidence_payload,
    )


# =============================================================================
# (7) 最终 Summary 提示：merge insights -> write summary
# =============================================================================

# Summary 阶段不再复用旧的 question-answer history prompt；正式主流程直接消费
# 已生成的 predicted_insights，先合并相同含义 / 相互支撑的 insight，再整合成最终 summary。
SUMMARY_SYSTEM_PROMPT = """You are a careful InsightBench final-summary editor.
Your job is to integrate existing insights into goal-aligned conclusions and a final summary.
Always return valid JSON."""


def _format_summary_insights(insights: List[str]) -> str:
    lines: List[str] = []
    for index, insight in enumerate(insights, start=1):
        text = str(insight or "").strip()
        if text:
            lines.append(f"I{index}: {text}")
    return "\n".join(lines)


def _format_merged_conclusions(conclusions: List[str]) -> str:
    lines: List[str] = []
    for index, conclusion in enumerate(conclusions, start=1):
        text = str(conclusion or "").strip()
        if text:
            lines.append(f"C{index}: {text}")
    return "\n".join(lines)


def build_merge_insights_prompt(task: InsightBenchTask, insights: List[str]) -> str:
    """把已有 predicted insights 合并为若干不同结论。"""
    insights_text = _format_summary_insights(insights)
    return f"""Task goal:
{get_task_goal(task)}

Available table schema:
{format_task_schema(task)}

Existing insights with IDs:
{insights_text}

Merge the existing insights into a small set of distinct conclusions.

What this step is for:
- Some insights may express the same meaning, use different evidence for the same finding, or point to a common conclusion.
- Those should be merged into one conclusion rather than treated as competing separate findings.
- Distinct conclusions should remain separate; do not over-generalize them into a vague statement.

Rules:
- Insight importance is NOT determined by order. I1 is not automatically more important than later insights.
- Read all insights before deciding what to merge.
- Preserve important numbers, entities, comparisons, and limitations from the source insights.
- Prefer goal-relevant conclusions over merely surprising local details.
- Do not merge insights that use incompatible populations, denominators, time ranges, filters, or analytical grains.
* If the provided insight list is non-empty, return at least one conclusion; never return an empty conclusions list.

Return JSON exactly in this format:
{{
  "conclusions": [
    {{
      "conclusion_id": "C1",
      "conclusion": "one concise integrated conclusion"
    }}
  ]
}}"""


def build_write_summary_from_conclusions_prompt(task: InsightBenchTask, conclusions: List[str]) -> str:
    """根据合并后的结论整合生成最终 benchmark summary。"""
    conclusions_text = _format_merged_conclusions(conclusions)
    return f"""Task goal:
{get_task_goal(task)}

Merged conclusions:
{conclusions_text}

Write the final benchmark summary from these merged conclusions.

What this step is for:
- Integrate the conclusions into a coherent final summary.
- Do not simply compress everything into a vague overview.
- Preserve concrete, distinct conclusions that matter for the goal.

Rules:
- The summary should directly answer the original goal.
- Keep the important different conclusions, numbers, entities, and limitations.
- Avoid over-emphasizing a narrow local detail if a broader goal-level conclusion is available.

Return JSON exactly in this format:
{{
  "summary": "..."
}}"""


# =============================================================================
# (8) JSON 重试提示：对齐官方 RETRY_TEMPLATE 风格
# =============================================================================


def build_json_retry_prompt(*, original_prompt: str, previous_response: str, error_message: str) -> str:
    return f"""
You failed.

Instructions:
-------------
{original_prompt}
-------------

Completion:
-------------
{previous_response}
-------------

Above, the Completion did not satisfy the constraints given in the Instructions.
Error:
-------------
{error_message}
-------------

Please try again. Do not apologize. Please only respond with a JSON object that satisfies the constraints laid out in the Instructions.
""".strip()
