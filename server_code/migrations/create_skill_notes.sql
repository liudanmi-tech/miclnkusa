-- Migration: create skill_notes table
-- 技能 Note 系统 — KG-Pointer 架构
-- Run: psql $DATABASE_URL -f create_skill_notes.sql

CREATE TABLE IF NOT EXISTS skill_notes (
    user_id           UUID        NOT NULL,
    skill_id          TEXT        NOT NULL,

    -- Tier 1: 基础信息（必现层）— 直接存文本，不依赖检索
    baseline_text     TEXT,
    baseline_complete BOOLEAN     NOT NULL DEFAULT FALSE,
    baseline_kg_ids   UUID[]      NOT NULL DEFAULT '{}',

    -- Tier 2: 动态 KG 引用（容错层）— embedding 检索后追加
    dynamic_kg_ids    UUID[]      NOT NULL DEFAULT '{}',

    -- 元信息
    user_stage        TEXT,
    last_updated      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (user_id, skill_id)
);

CREATE INDEX IF NOT EXISTS idx_skill_notes_user ON skill_notes (user_id);

-- 验证
SELECT 'skill_notes created' AS result,
       COUNT(*) AS row_count
FROM skill_notes;
