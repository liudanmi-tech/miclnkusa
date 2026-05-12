#!/bin/bash
# v0.4 部署后验证脚本
# 使用方法: 在服务器上执行此脚本

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========== v0.4 部署后验证 ==========${NC}"
echo ""

# 1. 检查服务进程
echo -e "${YELLOW}1. 检查服务进程...${NC}"
if ps aux | grep '[p]ython.*main.py' > /dev/null; then
    echo -e "${GREEN}✅ 服务进程运行中${NC}"
    ps aux | grep '[p]ython.*main.py' | head -1
else
    echo -e "${RED}❌ 服务进程未运行${NC}"
fi
echo ""

# 2. 检查端口
echo -e "${YELLOW}2. 检查端口...${NC}"
if (netstat -tlnp 2>/dev/null | grep -q ":8001") || (ss -tlnp 2>/dev/null | grep -q ":8001"); then
    echo -e "${GREEN}✅ 端口8001正在监听${NC}"
    netstat -tlnp 2>/dev/null | grep ":8001" || ss -tlnp 2>/dev/null | grep ":8001"
else
    echo -e "${RED}❌ 端口8001未监听${NC}"
fi
echo ""

# 3. 检查服务日志
echo -e "${YELLOW}3. 检查服务日志...${NC}"
if tail -100 ~/gemini-audio-service.log 2>/dev/null | grep -q "Uvicorn running\|Application startup complete"; then
    echo -e "${GREEN}✅ 服务启动成功${NC}"
    echo "最近的启动日志:"
    tail -100 ~/gemini-audio-service.log 2>/dev/null | grep -E "Uvicorn|Application startup" | tail -3
else
    echo -e "${YELLOW}⚠️ 未在日志中发现启动成功信息${NC}"
    echo "最近的日志:"
    tail -20 ~/gemini-audio-service.log 2>/dev/null | tail -5 || echo "日志文件不存在或为空"
fi
echo ""

# 4. 健康检查
echo -e "${YELLOW}4. 健康检查...${NC}"
if curl -s http://localhost:8001/ > /dev/null 2>&1; then
    echo -e "${GREEN}✅ 服务响应正常${NC}"
    echo "服务信息:"
    curl -s http://localhost:8001/ | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8001/
else
    echo -e "${RED}❌ 服务无响应${NC}"
fi
echo ""

# 5. 验证技能注册
echo -e "${YELLOW}5. 验证技能注册...${NC}"
python3 << 'EOF'
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
            if len(skills) > 0:
                print(f"✅ 数据库中共有 {len(skills)} 个技能:")
                for skill in skills:
                    print(f"  - {skill['skill_id']}: {skill.get('name')} (category: {skill.get('category')})")
            else:
                print("❌ 数据库中没有技能")
            if len(skills) != 4:
                print(f"⚠️ 警告: 应该注册4个技能，但只找到 {len(skills)} 个")
    except Exception as e:
        print(f"❌ 验证失败: {e}")
        import traceback
        traceback.print_exc()

asyncio.run(verify())
EOF

echo ""

# 6. 测试API认证（可选）
echo -e "${YELLOW}6. 测试API认证（可选）...${NC}"
echo "测试登录接口..."
LOGIN_RESPONSE=$(curl -s -X POST "http://localhost:8001/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"phone": "13800138000", "code": "123456"}')

if echo "$LOGIN_RESPONSE" | grep -q "token"; then
    echo -e "${GREEN}✅ 登录接口正常${NC}"
    TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', {}).get('token', ''))" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
        echo "测试获取技能列表..."
        SKILLS_RESPONSE=$(curl -s -X GET "http://localhost:8001/api/v1/skills" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json")
        if echo "$SKILLS_RESPONSE" | grep -q "skill_id\|workplace_jungle"; then
            echo -e "${GREEN}✅ 技能列表API正常${NC}"
            SKILL_COUNT=$(echo "$SKILLS_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data.get('data', []) if isinstance(data.get('data'), list) else []))" 2>/dev/null || echo "0")
            echo "  技能数量: $SKILL_COUNT"
        else
            echo -e "${YELLOW}⚠️ 技能列表API可能有问题${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠️ 登录接口可能有问题或需要先发送验证码${NC}"
fi
echo ""

echo -e "${BLUE}========== 验证完成 ==========${NC}"
echo ""
echo "如果所有检查都通过（✅），部署成功！"
echo "如果有问题（❌或⚠️），请查看上述输出和日志文件: ~/gemini-audio-service.log"
echo ""
