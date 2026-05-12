#!/bin/bash

# 在服务器上执行：重启服务
# 使用方法: 在服务器上执行 bash 服务器上执行-重启服务.sh

set -e

REMOTE_DIR="/home/admin/gemini-audio-service"
SERVICE_LOG="${REMOTE_DIR}/logs/service.log"

echo "=========================================="
echo "    重启服务"
echo "=========================================="
echo ""

# 步骤1: 停止旧服务
echo "【步骤1】停止旧服务..."
pkill -9 -f 'python3 main.py' 2>/dev/null && echo "✅ 已停止旧服务" || echo "✅ 没有运行中的服务"
sleep 3
echo ""

# 步骤2: 释放端口
echo "【步骤2】释放端口8001..."
lsof -ti:8001 | xargs kill -9 2>/dev/null && echo "✅ 端口已释放" || echo "✅ 端口已空闲"
sleep 2
echo ""

# 步骤3: 确保logs目录存在
echo "【步骤3】确保logs目录存在..."
mkdir -p logs && echo "✅ logs目录已创建"
echo ""

# 步骤4: 启动服务
echo "【步骤4】启动服务..."
cd "$REMOTE_DIR" || exit 1
source venv/bin/activate

nohup python3 main.py > "$SERVICE_LOG" 2>&1 &
SERVICE_PID=$!
echo "服务启动中，PID: $SERVICE_PID"
sleep 15
echo ""

# 步骤5: 验证服务状态
echo "【步骤5】验证服务状态..."
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

# 步骤6: 测试服务连接
echo "【步骤6】测试服务连接..."
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
echo "    服务重启完成"
echo "=========================================="
echo ""
echo "✅ 服务已重启"
echo "📝 查看服务日志: tail -f $SERVICE_LOG"
echo ""
