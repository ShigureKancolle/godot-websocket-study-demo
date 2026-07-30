# coding=utf-8
"""
文件: tools/sync_config.py
作用: 把 shared_config/ 下的 JSON 配置同步到 server/config/ 和 client/res/config/

============================================================================
 为什么需要这个脚本
============================================================================
双端共享配置采用「单数据源 + 复制」方案:
    - 单数据源在 shared_config/(只在这里改)
    - 服务端读 server/config/(运行时加载)
    - 客户端读 res://config/(Godot 导出时打包)

为什么不双端直接读 shared_config/?
    - 服务端 Python 能读任意路径,但客户端 Godot 只能读 res:// 下
    - 软链接在 Windows 不稳定,git submodule 太重
    - 复制脚本最简单,跑一次同步两份

使用方式:
    python tools/sync_config.py

工作流程:
    1. 扫描 shared_config/*.json
    2. 复制到 server/config/ 和 client/res/config/(覆盖)
    3. 打印同步结果

注意:
    - 脚本从项目根目录运行(根目录有 shared_config/ 和 server/ client/)
    - JSON 文件里的 _comment / _desc / _xxx 等下划线开头的字段是注释,
      loader 读取时跳过(不影响运行时)
"""

import os
import shutil
import sys
from pathlib import Path


def main():
    # 确定项目根目录(脚本位于 <root>/tools/sync_config.py)
    script_path = Path(__file__).resolve()
    project_root = script_path.parent.parent

    src_dir = project_root / "shared_config"
    dst_dirs = [
        project_root / "server" / "config",
        project_root / "client" / "res" / "config",
    ]

    # 检查源目录
    if not src_dir.exists():
        print(f"[ERROR] 源目录不存在: {src_dir}")
        sys.exit(1)

    # 收集要同步的 JSON 文件
    json_files = sorted(src_dir.glob("*.json"))
    if not json_files:
        print(f"[WARN] 源目录无 JSON 文件: {src_dir}")
        sys.exit(0)

    print(f"源目录: {src_dir}")
    print(f"待同步文件: {[f.name for f in json_files]}")
    print()

    # 同步到每个目标目录
    total_copied = 0
    for dst_dir in dst_dirs:
        # 创建目标目录(含父目录)
        dst_dir.mkdir(parents=True, exist_ok=True)

        print(f"同步到: {dst_dir}")
        for src_file in json_files:
            dst_file = dst_dir / src_file.name
            shutil.copy2(src_file, dst_file)
            print(f"  {src_file.name} -> {dst_file.relative_to(project_root)}")
            total_copied += 1
        print()

    print(f"同步完成,共复制 {total_copied} 个文件")
    print("提示: 客户端需在 Godot 编辑器里刷新(res://config 变更后才生效)")


if __name__ == "__main__":
    main()
