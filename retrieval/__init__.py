"""任务级表列检索与检索驱动 frontier 构建。

``GoalSchemaRetriever`` 是主程序和 ``python -m retrieval.run`` 共用的唯一检索入口：
它优先加载数据集级缓存，缺失任务才执行两次 LLM 检索。``RetrievalFrontierBuilder``
在每个分析批次结束后，把尚未实际探索的检索列组合成少量可执行 frontier 候选。
检索结果不进入 root、QEP 或当前问题回答，也不把未执行方向当作事实证据。
"""

from retrieval.frontier import RetrievalFrontierBuilder
from retrieval.retriever import GoalSchemaRetriever

__all__ = ["GoalSchemaRetriever", "RetrievalFrontierBuilder"]
