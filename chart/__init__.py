"""精简后的图表执行层。

不要在包初始化时主动导入 renderer。renderer 会加载 matplotlib，
会让只需要 profile 的模块也承担图形后端初始化成本。
"""

from .profile import build_table_profile, profile_column

__all__ = ["build_table_profile", "profile_column"]
