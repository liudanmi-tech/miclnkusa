#!/bin/bash
# v0.4 部署脚本 - 直接在服务器终端执行此脚本
# 使用方法: 复制此脚本内容到服务器终端执行，或运行: bash <(cat 在服务器上执行.sh)

set -e

echo "=========================================="
echo "v0.4 部署脚本"
echo "=========================================="
echo ""

# 步骤1: 验证环境
echo "========== 步骤1/7: 验证环境 =========="
cd ~/gemini-audio-service
pwd
echo ""

# 激活虚拟环境
if [ -d "venv" ]; then
    source venv/bin/activate
    echo "✅ 虚拟环境已激活: $VIRTUAL_ENV"
else
    echo "⚠️ 虚拟环境不存在"
fi
echo ""

# 检查技能目录
echo "检查技能目录..."
ls -la skills/ | head -10
echo ""

# 步骤2: 执行数据库迁移
echo "========== 步骤2/7: 执行数据库迁移 =========="
if [ -f "database/migrations/run_migration_v0.4.py" ]; then
    python3 database/migrations/run_migration_v0.4.py
    echo "✅ 数据库迁移完成"
else
    echo "❌ 迁移脚本不存在"
    exit 1
fi
echo ""

# 步骤3: 注册技能到数据库
echo "========== 步骤3/7: 注册技能到数据库 =========="
if [ -f "注册技能到数据库.py" ]; then
    python3 注册技能到数据库.py
    echo "✅ 技能注册完成"
else
    echo "❌ 注册脚本不存在"
    exit 1
fi
echo ""

# 步骤4: 验证技能注册
echo "========== 步骤4/7: 验证技能注册 =========="
python3 << 'PYEOF'
import asyncio
import sys
from pathlib import Path
project_root = Path.home() / "gemini-audio-service"
sys.path.insert(0, str(project_root))
from database.connection import AsyncSessionLocal
from skills.registry import list_skills

async def verify():
    try:
        async with AsyncSessionLocal() as db:
            skills = await list_skills(db, enabled=None)
            print(f"✅ 数据库中共有 {len(skills)} 个技能:")
            for skill in skills:
                print(f"  - {skill['skill_id']}: {skill.get('name')} (category: {skill.get('category')})")
    except Exception as e:
        print(f"❌ 验证失败: {e}")
        import traceback
        traceback.print_exc()

asyncio.run(verify())
PYEOF
echo ""

# 步骤5: 停止旧服务
echo "========== 步骤5/7: 停止旧服务 =========="
if pgrep -f 'python.*main.py' > /dev/null; then
    OLD_PIDS=$(pgrep -f 'python.*main.py')
    echo "找到运行中的服务进程: $OLD_PIDS"
    pkill -f 'python.*main.py' || true
    sleep 2
    if pgrep -f 'python.*main.py' > /dev/null; then
        echo "强制停止服务..."
        pkill -9 -f 'python.*main.py' || true
        sleep 1
    fi
    echo "✅ 旧服务已停止"
else
    echo "未发现运行中的服务"
fi
echo ""

# 步骤6: 启动新服务
echo "========== 步骤6/7: 启动新服务 =========="
nohup python3 main.py > ~/gemini-audio-service.log 2>&1 &
SERVICE_PID=$!
echo "服务PID: $SERVICE_PID"
sleep 5

if ps -p $SERVICE_PID > /dev/null 2>&1; then
    echo "✅ 服务进程运行中"
else
    echo "❌ 服务进程不存在，检查日志..."
    tail -50 ~/gemini-audio-service.log | tail -20
    exit 1
fi

echo "检查服务日志..."
tail -100 ~/gemini-audio-service.log | grep -E "启动|Uvicorn|Application startup|ERROR" | tail -10
echo ""

# 步骤7: 运行测试（可选）
echo "========== 步骤7/7: 运行测试（可选）=========="
if [ -f "测试v0.4功能.py" ]; then
    echo "运行功能测试（可能需要网络连接）..."
    python3 测试v0.4功能.py || echo "⚠️ 测试失败（可能是网络问题）"
else
    echo "测试脚本不存在，跳过"
fi
echo ""

echo "=========================================="
echo "✅ 部署完成"
echo "=========================================="
echo ""
echo "验证步骤:"
echo "1. 检查服务: ps aux | grep '[p]ython.*main.py'"
echo "2. 查看日志: tail -f ~/gemini-audio-service.log"
echo "3. 健康检查: curl http://localhost:8001/health"
