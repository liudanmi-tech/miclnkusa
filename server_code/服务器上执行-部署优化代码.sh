#!/bin/bash

# 在服务器上执行：部署优化代码并重启服务
# 使用方法: 在服务器上执行 bash 服务器上执行-部署优化代码.sh

set -e

REMOTE_DIR="/home/admin/gemini-audio-service"
SERVICE_LOG="${REMOTE_DIR}/logs/service.log"

echo "=========================================="
echo "    部署优化代码并重启服务"
echo "=========================================="
echo ""

# 步骤1: 备份当前代码
echo "【步骤1】备份当前代码..."
cd "$REMOTE_DIR" || exit 1
BACKUP_DIR="backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r api "$BACKUP_DIR/" 2>/dev/null || true
cp main.py "$BACKUP_DIR/" 2>/dev/null || true
cp database/connection.py "$BACKUP_DIR/" 2>/dev/null || true
echo "✅ 代码已备份到: $BACKUP_DIR"
echo ""

# 步骤2: 检查必要文件是否存在
echo "【步骤2】检查必要文件..."
MISSING_FILES=0

if [ ! -d "api" ]; then
    echo "❌ api/ 目录不存在，请先上传代码"
    MISSING_FILES=1
fi

if [ ! -d "utils" ]; then
    echo "❌ utils/ 目录不存在，请先上传代码"
    MISSING_FILES=1
fi

if [ ! -f "main.py" ]; then
    echo "❌ main.py 不存在，请先上传代码"
    MISSING_FILES=1
fi

if [ $MISSING_FILES -eq 1 ]; then
    echo ""
    echo "⚠️  请先在本地执行以下命令上传代码:"
    echo "  scp -r api/ utils/ admin@47.79.254.213:/home/admin/gemini-audio-service/"
    echo "  scp main.py database/connection.py skills/registry.py admin@47.79.254.213:/home/admin/gemini-audio-service/"
    exit 1
fi

echo "✅ 所有必要文件存在"
echo ""

# 步骤3: 验证代码语法
echo "【步骤3】验证代码语法..."
source venv/bin/activate

if python3 -m py_compile main.py api/skills.py api/profiles.py utils/cache.py database/connection.py 2>&1; then
    echo "✅ 语法检查通过"
else
    echo "❌ 语法检查失败"
    echo "查看错误信息:"
    python3 -m py_compile main.py api/skills.py api/profiles.py utils/cache.py database/connection.py 2>&1 || true
    exit 1
fi
echo ""

# 步骤4: 停止旧服务
echo "【步骤4】停止旧服务..."
pkill -9 -f 'python3 main.py' 2>/dev/null && echo "✅ 已停止旧服务" || echo "✅ 没有运行中的服务"
sleep 3
echo ""

# 步骤5: 释放端口
echo "【步骤5】释放端口8001..."
lsof -ti:8001 | xargs kill -9 2>/dev/null && echo "✅ 端口已释放" || echo "✅ 端口已空闲"
sleep 2
echo ""

# 步骤6: 确保logs目录存在
echo "【步骤6】确保logs目录存在..."
mkdir -p logs && echo "✅ logs目录已创建"
echo ""

# 步骤7: 启动服务
echo "【步骤7】启动服务..."
nohup python3 main.py > "$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
echo "服务启动中，PID: $SERVICE_PID"
sleep 10
echo ""

# 步骤8: 验证服务状态
echo "【步骤8】验证服务状态..."
if pgrep -f 'python3 main.py' > /dev/null; then
    PID=$(pgrep -f 'python3 main.py')
    echo "✅ 服务进程正在运行: PID $PID"
else
    echo "❌ 服务进程未运行"
    echo "查看启动日志:"
    tail -50 "$SERVICE_LOG" 2>/dev/null || echo "日志文件不存在"
    exit 1
fi

if ss -tlnp | grep ':8001' > /dev/null 2>&1 || netstat -tlnp 2>/dev/null | grep ':8001' > /dev/null; then
    echo "✅ 端口8001正在监听"
else
    echo "⚠️  端口8001未监听，等待5秒后重试..."
    sleep 5
    if ss -tlnp | grep ':8001' > /dev/null 2>&1 || netstat -tlnp 2>/dev/null | grep ':8001' > /dev/null; then
        echo "✅ 端口8001正在监听"
    else
        echo "❌ 端口8001仍未监听"
        echo "查看启动日志:"
        tail -50 "$SERVICE_LOG" 2>/dev/null || echo "日志文件不存在"
        exit 1
    fi
fi
echo ""

# 步骤9: 测试服务连接
echo "【步骤9】测试服务连接..."
sleep 3
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 http://127.0.0.1:8001/docs 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "✅ 服务响应正常，HTTP状态码: $HTTP_CODE"
else
    echo "⚠️  服务可能未完全启动，HTTP状态码: $HTTP_CODE"
    echo "查看启动日志:"
    tail -30 "$SERVICE_LOG" 2>/dev/null || echo "日志文件不存在"
fi
echo ""

echo "=========================================="
echo "    部署完成"
echo "=========================================="
echo ""
echo "✅ 优化代码已部署"
echo "✅ 服务已重启"
echo ""
echo "📊 优化内容:"
echo "  - 超时保护: 所有列表接口5秒超时"
echo "  - 连接池优化: 连接池大小50"
echo "  - 查询优化: 只选择必要字段"
echo "  - 缓存机制: 技能列表5分钟，档案列表1分钟"
echo "  - 分页支持: 档案列表支持分页"
echo ""
echo "🧪 测试建议:"
echo "  1. 测试任务列表接口: curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8001/api/v1/tasks/sessions?page=1&page_size=20"
echo "  2. 测试技能列表接口: curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8001/api/v1/skills?enabled=true"
echo "  3. 测试档案列表接口: curl -H 'Authorization: Bearer <token>' http://127.0.0.1:8001/api/v1/profiles?page=1&page_size=20"
echo ""
echo "📝 查看服务日志: tail -f $SERVICE_LOG"
echo ""
