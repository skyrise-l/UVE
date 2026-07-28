"""问题证据画像模块。

该包负责在单个分析问题执行前生成轻量的 Question Evidence Profile。
画像描述问题应如何解释、哪些证据最有价值以及需要注意的分析粒度，
但不编写伪代码步骤，也不预设中间变量。
"""

from .question_evidence_profile import QuestionEvidenceProfiler

__all__ = ["QuestionEvidenceProfiler"]
