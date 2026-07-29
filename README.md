# Bird-EDA

Bird-EDA is an LLM-powered exploratory data analysis (EDA) project for relational datasets. It reads task definitions from a JSONL file together with the corresponding CSV tables, then automatically performs question decomposition, evidence retrieval, data analysis, insight generation, chart creation, and optional evaluation.

## Data Source

Bird-EDA uses data from the **official BIRD dataset** (BIRD-SQL, BIg Bench for LaRge-scale Database Grounded Text-to-SQL Evaluation). BIRD is a large-scale, cross-domain database benchmark containing real-world database content, database descriptions, and question-answering tasks.

- BIRD homepage: https://bird-bench.github.io/
- BIRD training set: https://bird-bench.oss-cn-beijing.aliyuncs.com/train.zip
- BIRD development set: https://bird-bench.oss-cn-beijing.aliyuncs.com/dev.zip
- BIRD source code: https://github.com/AlibabaResearch/DAMO-ConvAI/tree/main/bird

The `data/tasks_v2.jsonl` file in this repository contains Bird-EDA tasks derived from the BIRD dataset. It is not an official BIRD annotation file. Please follow BIRD's official data licensing and citation requirements. Committing the large original datasets directly to a Git repository is not recommended.

## Requirements

- Python 3.10 or later
- An LLM API compatible with the OpenAI `chat/completions` format

Using a virtual environment is recommended:

```bash
python -m venv .venv
source .venv/bin/activate
```

On Windows PowerShell:

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
```

Install the main project dependencies:

```bash
pip install pandas numpy matplotlib scipy statsmodels requests python-dateutil rouge-score
```

## Data Preparation

The project reads **BIRD databases in CSV format**. Each database directory must contain at least a `tables/` directory and a `database_description/` directory:

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
    │   ├── table_constraints.json      # Optional
    │   └── table_relationships.txt     # Optional
    └── <other_db_id>/
        └── ...
```

The databases in the official BIRD archives are typically provided in formats such as SQLite, while this project expects table data in CSV format. Export the tables you plan to use as CSV files and ensure that each database directory name matches the corresponding `db_id` in the task file. This repository does not currently include an automatic conversion script.

## Configuration

The main configuration file is `config_bird.json`. Update any local absolute paths to match your environment. For example:

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

Key configuration options:

- `system_llm.api_key_env`: Name of the environment variable that stores the API key.
- `system_llm.base_url`: Endpoint for OpenAI or an OpenAI-compatible service.
- `system_llm.model`: Name of the model to use.
- `dataset.data_root`: Root directory containing the CSV databases.
- `dataset.task_jsonl`: Path to the Bird-EDA task JSONL file.
- `dataset.output_dir`: Directory where results are written.
- `dataset.limit`: Maximum number of tasks to run. Set this to `1` for an initial test.
- `dataset.offset`: Zero-based task offset from which execution begins.
- `dataset.bird.table_selection`: Use `gold_tables` to load only the tables specified by each task, or `all` to load every CSV table in the current database.
- `evaluation.enabled`: Set this to `false` during initial debugging. When enabled, you must also configure the evaluation model and API key under `evaluation.llm`.

Store credentials in environment variables rather than writing real API keys directly into the configuration file:

```bash
export OPENAI_API_KEY="your-api-key"
```

On Windows PowerShell:

```powershell
$env:OPENAI_API_KEY="your-api-key"
```

## Running the Project

From the project root, run:

```bash
python main.py --config config_bird.json
```

For the first run, the following settings are recommended:

1. Set `dataset.limit` to `1`.
2. Set `evaluation.enabled` to `false`.
3. Verify that the CSV tables and `database_description` files for the target `db_id` are complete.
4. Verify that the model API is accessible.

Results are written to `dataset.output_dir` by default and typically include:

```text
results_bird/
├── overview.json
├── task_scores.json
└── <task_id>/
    ├── result.json
    ├── <task_id>_query_log.md
    ├── bird_evaluation_report.json   # Generated when evaluation is enabled
    └── ...                           # Analysis artifacts and generated charts
```
