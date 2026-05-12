#!/bin/bash
# v0.4 部署执行脚本 - 在服务器上运行
# 使用方法: 在服务器终端执行此脚本

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
PROJECT_DIR="$HOME/gemini-audio-service"
LOG_FILE="$HOME/v0.4-deployment-$(date +%Y%m%d-%H%M%S).log"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1" | tee -a "$LOG_FILE"
}

# 检查是否在项目目录
if [ ! -f "$PROJECT_DIR/main.py" ]; then
    log_error "项目目录不存在或main.py不存在: $PROJECT_DIR"
    exit 1
fi

cd "$PROJECT_DIR" || exit 1

log_info "=========================================="
log_info "v0.4 部署脚本"
log_info "=========================================="
log_info "项目目录: $PROJECT_DIR"
log_info "日志文件: $LOG_FILE"
log_info "当前用户: $(whoami)"
log_info "当前时间: $(date)"
log_info ""

# 步骤1: 检查虚拟环境
log_step "步骤1/7: 检查虚拟环境..."
if [ -z "$VIRTUAL_ENV" ]; then
    if [ -d "$PROJECT_DIR/venv" ]; then
        log_info "激活虚拟环境..."
        source "$PROJECT_DIR/venv/bin/activate"
        log_info "✅ 虚拟环境已激活: $VIRTUAL_ENV"
    else
        log_warn "⚠️ 未检测到虚拟环境，建议先创建: python3 -m venv venv"
        log_warn "继续执行，但可能缺少依赖..."
    fi
else
    log_info "✅ 虚拟环境已激活: $VIRTUAL_ENV"
fi

# 步骤2: 验证代码结构
log_step "步骤2/7: 验证代码结构..."
if [ -f "$PROJECT_DIR/测试v0.4架构.sh" ]; then
    log_info "运行架构验证..."
    bash "$PROJECT_DIR/测试v0.4架构.sh" 2>&1 | tee -a "$LOG_FILE" || {
        log_warn "架构验证脚本执行失败，但继续执行..."
    }
else
    log_warn "验证脚本不存在，跳过验证"
fi

# 步骤3: 执行数据库迁移
log_step "步骤3/7: 执行数据库迁移..."
if [ -f "$PROJECT_DIR/database/migrations/run_migration_v0.4.py" ]; then
    log_info "运行数据库迁移脚本..."
    python3 "$PROJECT_DIR/database/migrations/run_migration_v0.4.py" 2>&1 | tee -a "$LOG_FILE"
    MIGRATION_STATUS=$?
    if [ $MIGRATION_STATUS -eq 0 ]; then
        log_info "✅ 数据库迁移成功"
    else
        log_error "❌ 数据库迁移失败，退出码: $MIGRATION_STATUS"
        log_error "请检查日志文件: $LOG_FILE"
        exit 1
    fi
else
    log_error "迁移脚本不存在: database/migrations/run_migration_v0.4.py"
    exit 1
fi

# 步骤4: 注册技能到数据库
log_step "步骤4/7: 注册技能到数据库..."
if [ -f "$PROJECT_DIR/注册技能到数据库.py" ]; then
    log_info "运行技能注册脚本..."
    python3 "$PROJECT_DIR/注册技能到数据库.py" 2>&1 | tee -a "$LOG_FILE"
    REGISTER_STATUS=$?
    if [ $REGISTER_STATUS -eq 0 ]; then
        log_info "✅ 技能注册成功"
    else
        log_error "❌ 技能注册失败，退出码: $REGISTER_STATUS"
        log_error "请检查日志文件: $LOG_FILE"
        exit 1
    fi
else
    log_error "注册脚本不存在: 注册技能到数据库.py"
    exit 1
fi

# 步骤5: 验证技能注册
log_step "步骤5/7: 验证技能注册..."
log_info "查询数据库中的技能..."
python3 << 'PYEOF' 2>&1 | tee -a "$LOG_FILE"
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
                print(f"  - {skill['skill_id']}: {skill.get('name')} (category: {skill.get('category')}, priority: {skill.get('priority', 0)})")
            if len(skills) == 0:
                print("⚠️ 警告: 数据库中没有技能，请检查技能注册是否成功")
    except Exception as e:
        print(f"❌ 验证失败: {e}")
        import traceback
        traceback.print_exc()

asyncio.run(verify())
PYEOF

# 步骤6: 停止旧服务
log_step "步骤6/7: 停止旧服务..."
if pgrep -f 'python.*main.py' > /dev/null; then
    log_info "找到运行中的服务进程，正在停止..."
    OLD_PIDS=$(pgrep -f 'python.*main.py')
    log_info "旧服务PID: $OLD_PIDS"
    pkill -f 'python.*main.py' || true
    sleep 2
    if pgrep -f 'python.*main.py' > /dev/null; then
        log_warn "服务进程仍在运行，尝试强制停止..."
        pkill -9 -f 'python.*main.py' || true
        sleep 1
    fi
    log_info "✅ 旧服务已停止"
else
    log_info "未发现运行中的服务"
fi

# 步骤7: 启动新服务
log_step "步骤7/7: 启动新服务..."
if [ -f "$PROJECT_DIR/main.py" ]; then
    log_info "启动服务（后台运行）..."
    nohup python3 "$PROJECT_DIR/main.py" > "$HOME/gemini-audio-service.log" 2>&1 &
    SERVICE_PID=$!
    log_info "服务PID: $SERVICE_PID"
    sleep 5
    
    # 检查服务是否启动成功
    if ps -p $SERVICE_PID > /dev/null 2>&1; then
        log_info "✅ 服务进程运行中，PID: $SERVICE_PID"
    else
        log_error "❌ 服务进程不存在，可能启动失败"
        log_error "检查日志: $HOME/gemini-audio-service.log"
        tail -50 "$HOME/gemini-audio-service.log" | tail -20
        exit 1
    fi
    
    # 检查服务日志
    log_info "检查服务启动日志..."
    sleep 2
    if tail -100 "$HOME/gemini-audio-service.log" 2>/dev/null | grep -q "Uvicorn running\|Application startup complete"; then
        log_info "✅ 服务启动成功（从日志判断）"
    else
        log_warn "⚠️ 未在日志中发现启动成功信息，但进程存在"
        log_warn "查看最近日志:"
        tail -30 "$HOME/gemini-audio-service.log" 2>/dev/null | tail -10 || echo "日志文件不存在或为空"
    fi
else
    log_error "main.py 不存在"
    exit 1
fi

# 完成
log_info ""
log_info "=========================================="
log_info "✅ v0.4 部署完成"
log_info "=========================================="
log_info ""
log_info "部署日志: $LOG_FILE"
log_info "服务日志: $HOME/gemini-audio-service.log"
log_info "服务PID: $SERVICE_PID"
log_info ""
log_info "下一步验证:"
log_info "1. 检查服务状态: ps aux | grep '[p]ython.*main.py'"
log_info "2. 查看服务日志: tail -f $HOME/gemini-audio-service.log"
log_info "3. 测试健康检查: curl http://localhost:8001/health"
log_info "4. 测试技能API: curl -X GET 'http://localhost:8001/api/v1/skills' -H 'Authorization: Bearer YOUR_TOKEN'"
log_info "5. 运行功能测试: python3 测试v0.4功能.py"
log_info ""
