#!/bin/bash
# v0.4 架构验证和测试脚本
# 用于验证技能化架构的实现是否正确

set -e

echo "========== v0.4 架构验证 =========="

# 1. 检查技能目录和文件
echo ""
echo "1. 检查技能目录结构..."
skill_dirs=("workplace_jungle" "family_relationship" "education_communication" "brainstorm")
for skill_dir in "${skill_dirs[@]}"; do
    if [ -d "skills/$skill_dir" ]; then
        if [ -f "skills/$skill_dir/SKILL.md" ]; then
            echo "  ✅ $skill_dir: 目录和SKILL.md存在"
        else
            echo "  ❌ $skill_dir: SKILL.md缺失"
        fi
    else
        echo "  ❌ $skill_dir: 目录不存在"
    fi
done

# 2. 检查Python模块文件
echo ""
echo "2. 检查技能模块文件..."
skill_modules=("loader.py" "registry.py" "router.py" "executor.py" "composer.py")
for module in "${skill_modules[@]}"; do
    if [ -f "skills/$module" ]; then
        echo "  ✅ skills/$module 存在"
    else
        echo "  ❌ skills/$module 缺失"
    fi
done

# 3. 检查API文件
echo ""
echo "3. 检查API文件..."
if [ -f "api/skills.py" ]; then
    echo "  ✅ api/skills.py 存在"
else
    echo "  ❌ api/skills.py 缺失"
fi

# 4. 检查数据库模型
echo ""
echo "4. 检查数据库模型..."
if grep -q "class Skill" database/models.py; then
    echo "  ✅ Skill模型已定义"
else
    echo "  ❌ Skill模型未定义"
fi

if grep -q "class SkillExecution" database/models.py; then
    echo "  ✅ SkillExecution模型已定义"
else
    echo "  ❌ SkillExecution模型未定义"
fi

# 5. 检查main.py中的集成
echo ""
echo "5. 检查main.py集成..."
if grep -q "from skills.router import\|from skills.executor import\|from skills.composer import\|from skills.registry import" main.py; then
    echo "  ✅ main.py已导入技能模块"
else
    echo "  ⚠️ main.py可能未完全集成技能模块"
fi

if grep -q "classify-scene\|classify_scene" main.py; then
    echo "  ✅ 场景识别接口已添加"
else
    echo "  ⚠️ 场景识别接口可能未添加"
fi

# 6. 检查技能SKILL.md格式
echo ""
echo "6. 验证SKILL.md格式..."
for skill_dir in "${skill_dirs[@]}"; do
    if [ -f "skills/$skill_dir/SKILL.md" ]; then
        if grep -q "^---" "skills/$skill_dir/SKILL.md" && grep -q "category:" "skills/$skill_dir/SKILL.md" && grep -q "## Prompt模板" "skills/$skill_dir/SKILL.md"; then
            echo "  ✅ $skill_dir/SKILL.md 格式正确"
        else
            echo "  ⚠️ $skill_dir/SKILL.md 格式可能不完整"
        fi
    fi
done

# 7. 检查数据库迁移文件
echo ""
echo "7. 检查数据库迁移文件..."
if [ -f "database/migrations/add_skills_tables.sql" ]; then
    echo "  ✅ add_skills_tables.sql 存在"
else
    echo "  ❌ add_skills_tables.sql 缺失"
fi

echo ""
echo "========== 验证完成 =========="
echo ""
echo "如果所有检查都通过，可以在服务器上执行以下步骤："
echo "1. 运行数据库迁移: python3 database/migrations/run_migration_v0.4.py"
echo "2. 注册技能到数据库: 调用 POST /api/v1/skills/{skill_id}/reload"
echo "3. 测试场景识别: 调用 POST /api/v1/tasks/sessions/{session_id}/classify-scene"
