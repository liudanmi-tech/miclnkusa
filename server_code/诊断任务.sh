#!/bin/bash
SESSION_ID="${1:-d12f253d-608e-442d-833b-92e874f1efc5}"

echo "========== 诊断任务状态 =========="
echo "Session ID: $SESSION_ID"
echo ""

# 登录获取Token
TOKEN=$(curl -s -X POST "http://localhost:8001/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"phone": "13800138000", "code": "123456"}' | \
  python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('data', {}).get('token', ''))" 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "❌ 登录失败"
    exit 1
fi

echo "✅ Token获取成功"
echo ""

# 检查任务状态
echo "=== 任务状态 ==="
curl -s -X GET "http://localhost:8001/api/v1/tasks/sessions/$SESSION_ID/status" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

echo ""
echo "=== 数据库中的任务 ==="
source venv/bin/activate
python3 << PYEOF
import sys
sys.path.insert(0, '.')
import asyncio
from database.connection import AsyncSessionLocal
from database.models import Session, AnalysisResult
from sqlalchemy import select
import uuid

async def check():
    async with AsyncSessionLocal() as session:
        session_id = uuid.UUID('$SESSION_ID')
        result = await session.execute(select(Session).where(Session.id == session_id))
        db_session = result.scalar_one_or_none()
        if db_session:
            print(f'状态: {db_session.status}')
            print(f'创建时间: {db_session.created_at}')
            print(f'更新时间: {db_session.updated_at}')
        else:
            print('未找到任务')

asyncio.run(check())
PYEOF

echo ""
echo "=== 相关日志（最近10行）==="
grep "$SESSION_ID" ~/gemini-audio-service.log | tail -10
