#!/bin/bash

# 在服务器上执行数据库索引优化
# 使用方法: bash 在服务器上执行索引优化.sh

set -e

echo "=========================================="
echo "    执行数据库索引优化"
echo "=========================================="
echo ""

# 步骤1: 检查psql是否安装
echo "【步骤1】检查PostgreSQL客户端..."
if ! command -v psql &> /dev/null; then
    echo "❌ psql未安装，正在安装..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y postgresql-client
    elif command -v yum &> /dev/null; then
        sudo yum install -y postgresql
    else
        echo "❌ 无法自动安装psql，请手动安装"
        exit 1
    fi
fi
echo "✅ psql已安装"
echo ""

# 步骤2: 读取数据库配置
echo "【步骤2】读取数据库配置..."
cd ~/gemini-audio-service 2>/dev/null || {
    echo "❌ 无法进入项目目录"
    exit 1
}

if [ -f .env ]; then
    DATABASE_URL=$(grep "^DATABASE_URL=" .env | cut -d '=' -f2- | tr -d '"' | tr -d "'")
    if [ -z "$DATABASE_URL" ]; then
        echo "⚠️  未找到DATABASE_URL，使用默认配置"
        DB_HOST="localhost"
        DB_USER="postgres"
        DB_NAME="gemini_audio_db"
        DB_PORT="5432"
    else
        # 解析DATABASE_URL: postgresql+asyncpg://user:pass@host:port/dbname
        # 提取信息
        DB_INFO=$(echo "$DATABASE_URL" | sed 's|postgresql+asyncpg://||' | sed 's|postgresql://||')
        DB_USER_PASS=$(echo "$DB_INFO" | cut -d '@' -f1)
        DB_USER=$(echo "$DB_USER_PASS" | cut -d ':' -f1)
        DB_PASS=$(echo "$DB_USER_PASS" | cut -d ':' -f2)
        DB_HOST_PORT=$(echo "$DB_INFO" | cut -d '@' -f2 | cut -d '/' -f1)
        DB_HOST=$(echo "$DB_HOST_PORT" | cut -d ':' -f1)
        DB_PORT=$(echo "$DB_HOST_PORT" | cut -d ':' -f2)
        DB_NAME=$(echo "$DB_INFO" | cut -d '/' -f2)
        
        # 如果端口为空，使用默认端口
        if [ -z "$DB_PORT" ]; then
            DB_PORT="5432"
        fi
    fi
else
    echo "⚠️  未找到.env文件，使用默认配置"
    DB_HOST="localhost"
    DB_USER="postgres"
    DB_NAME="gemini_audio_db"
    DB_PORT="5432"
fi

echo "数据库配置:"
echo "  主机: $DB_HOST"
echo "  端口: $DB_PORT"
echo "  用户: $DB_USER"
echo "  数据库: $DB_NAME"
echo ""

# 步骤3: 检查SQL文件是否存在
echo "【步骤3】检查SQL文件..."
SQL_FILE="执行数据库索引优化.sql"
if [ ! -f "$SQL_FILE" ]; then
    echo "❌ SQL文件不存在: $SQL_FILE"
    echo "请先上传SQL文件到服务器"
    exit 1
fi
echo "✅ SQL文件存在: $SQL_FILE"
echo ""

# 步骤4: 测试数据库连接
echo "【步骤4】测试数据库连接..."
if [ -n "$DB_PASS" ]; then
    export PGPASSWORD="$DB_PASS"
fi

if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✅ 数据库连接成功"
else
    echo "❌ 数据库连接失败"
    echo "请检查:"
    echo "  1. 数据库服务是否运行"
    echo "  2. 连接信息是否正确"
    echo "  3. 防火墙是否允许连接"
    echo ""
    echo "手动连接测试:"
    echo "  psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"
    exit 1
fi
echo ""

# 步骤5: 执行索引创建
echo "【步骤5】执行索引创建..."
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE"; then
    echo "✅ 索引创建成功"
else
    echo "❌ 索引创建失败"
    exit 1
fi
echo ""

# 步骤6: 验证索引
echo "【步骤6】验证索引是否创建成功..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
SELECT 
    schemaname,
    tablename,
    indexname
FROM pg_indexes
WHERE tablename IN ('sessions', 'profiles', 'skills')
AND indexname LIKE 'idx_%'
ORDER BY tablename, indexname;
"
echo ""

echo "=========================================="
echo "    索引优化完成"
echo "=========================================="
echo ""
echo "✅ 数据库索引已创建"
echo "✅ 可以继续部署代码并重启服务"
echo ""
