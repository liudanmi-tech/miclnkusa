#!/bin/bash
# 诊断任务超时问题

SESSION_ID="82ab9960-b2ef-4c82-b107-7c23bc131e43"

echo "========== 诊断任务超时问题 =========="
echo "Session ID: $SESSION_ID"
echo ""

echo "=== 1. 检查服务状态 ==="
ps aux | grep '[p]ython.*main.py' || echo "❌ 服务未运行"
echo ""

echo "=== 2. 检查最近的错误日志 ==="
tail -100 ~/gemini-audio-service.log | grep -E "ERROR|错误|异常|Exception|Traceback" | tail -30
echo ""

echo "=== 3. 检查该任务的相关日志 ==="
grep "$SESSION_ID" ~/gemini-audio-service.log | tail -50
echo ""

echo "=== 4. 检查场景识别相关日志 ==="
grep -E "场景识别|场景分类|classify_scene" ~/gemini-audio-service.log | tail -20
echo ""

echo "=== 5. 检查技能匹配相关日志 ==="
grep -E "技能匹配|match_skills|技能执行" ~/gemini-audio-service.log | tail -20
echo ""

echo "=== 6. 检查策略分析相关日志 ==="
grep -E "策略分析|generate_strategies|策略生成" ~/gemini-audio-service.log | tail -20
echo ""

echo "=== 7. 检查数据库中的任务状态 ==="
cd ~/gemini-audio-service
source venv/bin/activate
python3 << EOF
import asyncio
import sys
from pathlib import Path
sys.path.insert(0, str(Path.home() / "gemini-audio-service"))
from database.connection import AsyncSessionLocal
from database.models import Session, AnalysisResult, StrategyAnalysis
from sqlalchemy import select
import uuid

async def check_task():
    async with AsyncSessionLocal() as db:
        session_id = uuid.UUID("$SESSION_ID")
        
        # 检查任务
        result = await db.execute(
            select(Session).where(Session.id == session_id)
        )
        task = result.scalar_one_or_none()
        if task:
            print(f"✅ 任务存在: {task.id}")
            print(f"  - 状态: {task.status}")
            print(f"  - 标题: {task.title}")
            print(f"  - 创建时间: {task.created_at}")
        else:
            print(f"❌ 任务不存在: {session_id}")
        
        # 检查分析结果
        result = await db.execute(
            select(AnalysisResult).where(AnalysisResult.session_id == session_id)
        )
        analysis = result.scalar_one_or_none()
        if analysis:
            print(f"✅ 分析结果存在")
            print(f"  - 对话数量: {len(analysis.dialogues) if isinstance(analysis.dialogues, list) else 0}")
            print(f"  - 风险数量: {len(analysis.risks) if analysis.risks else 0}")
        else:
            print(f"❌ 分析结果不存在")
        
        # 检查策略分析
        result = await db.execute(
            select(StrategyAnalysis).where(StrategyAnalysis.session_id == session_id)
        )
        strategy = result.scalar_one_or_none()
        if strategy:
            print(f"✅ 策略分析存在")
            print(f"  - 使用的技能: {strategy.applied_skills}")
            print(f"  - 场景类别: {strategy.scene_category}")
            print(f"  - 场景置信度: {strategy.scene_confidence}")
        else:
            print(f"❌ 策略分析不存在")

asyncio.run(check_task())
EOF

echo ""
echo "=== 8. 测试任务详情 API ==="
curl -X GET "http://localhost:8001/api/v1/tasks/sessions/$SESSION_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(python3 << 'PYEOF'
import asyncio
import sys
from pathlib import Path
sys.path.insert(0, str(Path.home() / "gemini-audio-service"))
from auth.verification import VerificationService
from database.connection import AsyncSessionLocal
from auth.jwt_handler import create_access_token

async def get_token():
    async with AsyncSessionLocal() as db:
        service = VerificationService(db)
        # 先发送验证码
        await service.send_code("13800138000")
        # 使用固定验证码登录
        user_id = await service.verify_code("13800138000", "123456")
        if user_id:
            token = create_access_token(str(user_id))
            print(token)
            return
    print("")

asyncio.run(get_token())
PYEOF
)" -w "\nHTTP状态码: %{http_code}\n时间: %{time_total}秒\n" --max-time 10

echo ""
echo "========== 诊断完成 =========="
