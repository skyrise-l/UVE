# Bird-EDA

Bird-EDA 是一个面向关系型数据集的 LLM 驱动探索性数据分析（EDA）项目。项目读取任务 JSONL 和对应的多张 CSV 表，自动完成问题拆解、证据检索、数据分析、洞察生成、图表输出，并可选地运行评估。

## 数据来源

Bird-EDA 使用的数据来源于 **BIRD 官方数据集**（BIRD-SQL，BIg Bench for LaRge-scale Database Grounded Text-to-SQL Evaluation）。BIRD 是一个包含真实数据库内容、数据库描述和问答任务的大规模跨领域数据库基准。

- BIRD 官方主页：https://bird-bench.github.io/
- BIRD 官方 Train Set：https://bird-bench.oss-cn-beijing.aliyuncs.com/train.zip
- BIRD 官方 Dev Set：https://bird-bench.oss-cn-beijing.aliyuncs.com/dev.zip
- BIRD 官方代码：https://github.com/AlibabaResearch/DAMO-ConvAI/tree/main/bird

本仓库中的 `data/tasks_v2.jsonl` 是在 BIRD 数据基础上整理的 Bird-EDA 任务文件，并不是 BIRD 官方原始标注文件。请遵守 BIRD 官方的数据许可和引用要求；不建议将体积较大的原始数据直接提交到 Git 仓库。

## 环境要求

- Python 3.10 或更高版本
- 一个支持 OpenAI `chat/completions` 格式的 LLM API

建议使用虚拟环境：

```bash
python -m venv .venv
source .venv/bin/activate
```

Windows PowerShell：

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
```

安装项目使用的主要依赖：

```bash
pip install pandas numpy matplotlib scipy statsmodels requests python-dateutil rouge-score
```

## 数据准备

代码读取的是 **CSV 形式的 BIRD 数据库**。每个数据库目录至少需要包含 `tables/` 和 `database_description/`：

```text
data/
├── tasks_v2.jsonl
└── bird_csv/
    ├── superstore/
    │   ├── tables/
    │   │   ├── central_superstore.csv
    │   │   ├── east_superstore.csv
    │   │   └── ...
    │   ├── database_description/
    │   │   ├── central_superstore.csv
    │   │   ├── east_superstore.csv
    │   │   └── ...
    │   ├── table_constraints.json      # 可选
    │   └── table_relationships.txt     # 可选
    └── <其他 db_id>/
        └── ...
```

BIRD 官方压缩包中的数据库通常以 SQLite 等形式提供，而本项目要求表数据为 CSV。需要先将所使用的数据库表导出为 CSV，并保持数据库目录名与任务文件中的 `db_id` 一致。本仓库当前未包含自动转换脚本。

## 配置

主要使用 `config_bird.json`。首先将其中的本机绝对路径改成你自己的路径，例如：

```json
{
  "system_llm": {
    "api_key": "",
    "api_key_env": "OPENAI_API_KEY",
    "base_url": "https://api.openai.com/v1",
    "model": "your-model-name",
    "temperature": 0,
    "timeout_sec": 180,
    "force_json_mode": true
  },
  "dataset": {
    "benchmark": "bird",
    "data_root": "./data/bird_csv",
    "task_jsonl": "./data/tasks_v2.jsonl",
    "output_dir": "./results_bird",
    "limit": 10,
    "offset": 0,
    "metadata_cache_dir": "./cache/bird_metadata",
    "bird": {
      "table_selection": "gold_tables"
    }
  },
  "evaluation": {
    "enabled": false
  }
}
```

关键配置项：

- `system_llm.api_key_env`：读取 API Key 的环境变量名称。
- `system_llm.base_url`：OpenAI 或兼容服务的 API 地址。
- `system_llm.model`：实际使用的模型名称。
- `dataset.data_root`：CSV 数据库根目录。
- `dataset.task_jsonl`：Bird-EDA 任务 JSONL 路径。
- `dataset.output_dir`：结果输出目录。
- `dataset.limit`：本次最多运行的任务数量；建议首次测试设为 `1`。
- `dataset.offset`：从第几条任务开始运行。
- `dataset.bird.table_selection`：`gold_tables` 只加载任务指定表，`all` 加载当前数据库的所有 CSV 表。
- `evaluation.enabled`：首次调试建议设为 `false`；开启后还需要配置 `evaluation.llm` 对应的评估模型和 API Key。

推荐通过环境变量配置密钥，不要把真实 API Key 写入配置文件：

```bash
export OPENAI_API_KEY="your-api-key"
```

Windows PowerShell：

```powershell
$env:OPENAI_API_KEY="your-api-key"
```

## 运行

在项目根目录执行：

```bash
python main.py --config config_bird.json
```

首次运行建议：

1. 将 `dataset.limit` 设置为 `1`。
2. 将 `evaluation.enabled` 设置为 `false`。
3. 确认对应 `db_id` 的 CSV 表和 `database_description` 文件完整。
4. 确认模型 API 能正常访问。

运行结果默认保存在 `dataset.output_dir`，主要包括：

```text
results_bird/
├── overview.json
├── task_scores.json
└── <task_id>/
    ├── result.json
    ├── <task_id>_query_log.md
    ├── bird_evaluation_report.json   # 开启评估时生成
    └── ...                           # 分析过程和图表产物
```

已经成功完成的任务会被自动跳过；如需重新运行某个任务，可删除对应的 `results_bird/<task_id>/` 目录。

## 当前代码包注意事项

当前压缩包中的 `main.py` 引用了 `visual_policy_experiment.py`，但压缩包内没有该文件，因此直接运行时会出现：

```text
ModuleNotFoundError: No module named 'visual_policy_experiment'
```

运行前需要从原项目补回该文件。若你只使用默认的 `main` agent，也可以自行移除 `main.py` 中与 `VisualPolicyComparisonAgent` / `visual_policy_comparison` 有关的导入和分支逻辑。

## 新建 Git 项目并推送

先进入项目目录：

```bash
cd uve
```

初始化仓库并提交：

```bash
git init
git branch -M main
git add .
git commit -m "Initial commit: Bird-EDA"
```

然后在 GitHub、GitLab 或其他 Git 服务中新建一个空仓库。不要勾选自动创建 README、`.gitignore` 或 License，以免第一次推送时产生不必要的冲突。

复制远程仓库地址并执行：

```bash
git remote add origin https://github.com/<your-name>/<your-repo>.git
git push -u origin main
```

使用 SSH 时：

```bash
git remote add origin git@github.com:<your-name>/<your-repo>.git
git push -u origin main
```

后续更新代码：

```bash
git add .
git commit -m "Describe your changes"
git push
```

推送前请确认配置文件中没有真实 API Key，并避免提交大型 BIRD 数据、缓存和运行结果。
