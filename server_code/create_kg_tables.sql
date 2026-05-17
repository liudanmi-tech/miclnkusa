-- Knowledge Graph 建表迁移脚本
-- 执行：psql $DATABASE_URL -f create_kg_tables.sql

-- 人物节点
CREATE TABLE IF NOT EXISTS kg_persons (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    name       VARCHAR(100) NOT NULL,
    rel_type   VARCHAR(50),
    rel_desc   TEXT,
    intimacy   INTEGER CHECK (intimacy BETWEEN 1 AND 10),
    friction   INTEGER CHECK (friction BETWEEN 1 AND 10),
    power      VARCHAR(20),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_kg_person UNIQUE (user_id, name)
);
CREATE INDEX IF NOT EXISTS idx_kg_persons_user ON kg_persons (user_id);

-- 事件节点
CREATE TABLE IF NOT EXISTS kg_events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    event_date VARCHAR(20),
    summary    TEXT NOT NULL,
    sentiment  VARCHAR(20),
    outcome    VARCHAR(20),
    location   VARCHAR(100),
    session_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_kg_events_user ON kg_events (user_id);
CREATE INDEX IF NOT EXISTS idx_kg_events_created ON kg_events (created_at DESC);

-- 人物↔事件 多对多
CREATE TABLE IF NOT EXISTS kg_event_persons (
    event_id  UUID REFERENCES kg_events(id)  ON DELETE CASCADE,
    person_id UUID REFERENCES kg_persons(id) ON DELETE CASCADE,
    PRIMARY KEY (event_id, person_id)
);

-- 目标节点
CREATE TABLE IF NOT EXISTS kg_goals (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL,
    description TEXT NOT NULL,
    status      VARCHAR(20) DEFAULT 'in_progress',
    person_id   UUID REFERENCES kg_persons(id) ON DELETE SET NULL,
    session_id  UUID,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_kg_goals_user ON kg_goals (user_id);
CREATE INDEX IF NOT EXISTS idx_kg_goals_person ON kg_goals (person_id);

-- 技能应用记录
CREATE TABLE IF NOT EXISTS kg_skills (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL,
    session_id     UUID,
    skill_id       VARCHAR(100) NOT NULL,
    skill_name     VARCHAR(200),
    skill_category VARCHAR(50),
    person_ids     UUID[],
    summary        TEXT,
    applied_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_kg_skills_user ON kg_skills (user_id);
CREATE INDEX IF NOT EXISTS idx_kg_skills_applied ON kg_skills (applied_at DESC);

-- 验证
SELECT 'kg_persons'     AS tbl, COUNT(*) FROM kg_persons     UNION ALL
SELECT 'kg_events'      AS tbl, COUNT(*) FROM kg_events      UNION ALL
SELECT 'kg_event_persons' AS tbl, COUNT(*) FROM kg_event_persons UNION ALL
SELECT 'kg_goals'       AS tbl, COUNT(*) FROM kg_goals       UNION ALL
SELECT 'kg_skills'      AS tbl, COUNT(*) FROM kg_skills;
