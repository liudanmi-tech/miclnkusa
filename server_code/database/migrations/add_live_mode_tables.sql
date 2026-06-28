-- ============================================================
-- Live Mode 数据库迁移
-- 版本: v1.0-live-mode
-- 日期: 2026-06-08
-- 依赖: sessions、profiles 表已存在
-- 对应功能: Meta 眼镜实时录音模式
-- ============================================================

-- ============================================================
-- Step 1: ALTER sessions 表 - 添加 Live Mode 字段
-- ============================================================
ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS session_type            VARCHAR(20)  DEFAULT 'review',
    ADD COLUMN IF NOT EXISTS card_title              VARCHAR(100),
    ADD COLUMN IF NOT EXISTS live_summary            TEXT,
    ADD COLUMN IF NOT EXISTS summary_status          VARCHAR(20),
    ADD COLUMN IF NOT EXISTS image_status            VARCHAR(20),
    ADD COLUMN IF NOT EXISTS skills_status           VARCHAR(20),
    ADD COLUMN IF NOT EXISTS cover_image_url         TEXT,
    ADD COLUMN IF NOT EXISTS total_images_expected   INTEGER      DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_images_completed  INTEGER      DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_images_failed     INTEGER      DEFAULT 0,
    ADD COLUMN IF NOT EXISTS gemini_token            TEXT,
    ADD COLUMN IF NOT EXISTS gemini_token_updated    TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS ws_disconnected_at      TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS ended_at                TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS abandon_reason          VARCHAR(100);

-- session_type 取值: 'review'（线上录音复盘）| 'live'（眼镜实时模式）
-- card_title: Gemini 生成的 30 字标题（post-processing 完成后写入）
-- live_summary: Gemini 生成的 200 字总结（聚合各 Segment running_context）
-- summary_status: 'processing' | 'completed' | 'failed'
-- image_status: 'processing' | 'partial' | 'completed' | 'failed'
-- skills_status: 'processing' | 'completed'
-- cover_image_url: 第一张成功生成的图片 URL
-- gemini_token: Gemini Live 续期 token（H-4 原子切换）
-- ws_disconnected_at: iOS WS 断连时间戳（H-3 孤儿 Session 检测）
-- abandon_reason: 'timeout' | 'new_session' | 'manual'

CREATE INDEX IF NOT EXISTS idx_sessions_session_type
    ON sessions(session_type);

CREATE INDEX IF NOT EXISTS idx_sessions_summary_status
    ON sessions(summary_status)
    WHERE session_type = 'live';

CREATE INDEX IF NOT EXISTS idx_sessions_ws_disconnected
    ON sessions(ws_disconnected_at)
    WHERE session_type = 'live' AND status = 'active';

-- ============================================================
-- Step 2: CREATE live_segments 表（先建，live_turns 依赖它）
-- ============================================================
CREATE TABLE IF NOT EXISTS live_segments (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id       UUID         NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    segment_index    INTEGER      NOT NULL,
    start_turn_index INTEGER      NOT NULL DEFAULT 0,
    end_turn_index   INTEGER,
    running_context  TEXT,
    scene_title      VARCHAR(200),
    status           VARCHAR(20)  NOT NULL DEFAULT 'active',
    split_reason     VARCHAR(50),
    image_urls       JSONB        NOT NULL DEFAULT '[]',
    skill_results    JSONB        NOT NULL DEFAULT '[]',
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    closed_at        TIMESTAMPTZ,
    UNIQUE(session_id, segment_index)
);

-- end_turn_index: NULL = 当前活跃 Segment
-- running_context: Task A 每 10 turns 重写的摘要（~300 token）
-- scene_title: 该 Segment 话题标题，用于 Detail 页技能分组展示
-- status: 'active' | 'closed'
-- split_reason: 'silence' | 'speaker_change' | 'background' | 'manual'
-- image_urls: 本 Segment 最终生成的图片 URL 列表（来自 live_panel_batches）
-- skill_results: 本 Segment 的技能匹配结果，格式与线上 skill_cards 一致

CREATE INDEX IF NOT EXISTS idx_live_segments_session_id
    ON live_segments(session_id);

CREATE INDEX IF NOT EXISTS idx_live_segments_active
    ON live_segments(session_id, status)
    WHERE status = 'active';

-- ============================================================
-- Step 3: CREATE live_turns 表
-- ============================================================
CREATE TABLE IF NOT EXISTS live_turns (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id     UUID         NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    turn_index     INTEGER      NOT NULL,
    speaker        VARCHAR(20)  NOT NULL,
    speaker_label  VARCHAR(50),
    text           TEXT         NOT NULL,
    timestamp_ms   BIGINT,
    segment_id     UUID         REFERENCES live_segments(id) ON DELETE SET NULL,
    matched_skills JSONB        NOT NULL DEFAULT '[]',
    suggestion     TEXT,
    context_3b     TEXT,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE(session_id, turn_index)
);

-- speaker: 'user' | 'other'（iOS 上报）
-- speaker_label: 'Speaker_1', 'Speaker_2'（Gemini Diarization 输出，S-2）
-- UNIQUE(session_id, turn_index): 幂等写入，ON CONFLICT DO UPDATE（S-2）
-- matched_skills: [{skill_id, skill_name, category, confidence}, ...]
-- suggestion: 本 turn 的 Gemini 实时建议文字
-- context_3b: 注入的 3B 历史事件片段（Task B 检索结果）

CREATE INDEX IF NOT EXISTS idx_live_turns_session_id
    ON live_turns(session_id);

CREATE INDEX IF NOT EXISTS idx_live_turns_segment_id
    ON live_turns(segment_id);

CREATE INDEX IF NOT EXISTS idx_live_turns_speaker_label
    ON live_turns(session_id, speaker_label)
    WHERE speaker_label IS NOT NULL;

-- ============================================================
-- Step 4: CREATE live_events 表（SSE 事件持久化，H-1 断线重放）
-- ============================================================
CREATE TABLE IF NOT EXISTS live_events (
    id          BIGSERIAL    PRIMARY KEY,
    session_id  UUID         NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    event_type  VARCHAR(50)  NOT NULL,
    payload     JSONB        NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- id: BIGSERIAL，对应 SSE "id:" 字段，Last-Event-ID 重放用
-- event_type: 'suggestion' | 'skill_match' | 'speaker_result' |
--             'segment_split' | 'warning' | 'session_renewed' | 'ping'
-- 重放窗口：10 分钟（created_at > NOW() - INTERVAL '10 minutes'）
-- ping 事件不写入此表，不参与重放

CREATE INDEX IF NOT EXISTS idx_live_events_session_id_id
    ON live_events(session_id, id);

CREATE INDEX IF NOT EXISTS idx_live_events_created_at
    ON live_events(created_at);

-- ============================================================
-- Step 5: CREATE live_speaker_mappings 表（M-2 Speaker 持久化）
-- ============================================================
CREATE TABLE IF NOT EXISTS live_speaker_mappings (
    session_id    UUID         NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    speaker_label VARCHAR(50)  NOT NULL,
    profile_id    UUID         REFERENCES profiles(id) ON DELETE SET NULL,
    confidence    FLOAT        NOT NULL DEFAULT 0.0,
    method        VARCHAR(30)  NOT NULL DEFAULT 'llm',
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY(session_id, speaker_label)
);

-- confidence 取值范围（method 对应）:
--   user_confirmed: 1.0（Step 2 用户手动确认，最高优先级）
--   rule:           0.95（规则推断，如只有一个 "other" speaker）
--   voiceprint:     ~0.90（声纹比对，未来功能）
--   llm:            0.60-0.85（Gemini 推断）
-- ON CONFLICT DO UPDATE 时：仅当新 confidence >= 现有 confidence 时才覆盖

CREATE INDEX IF NOT EXISTS idx_live_speaker_mappings_session_id
    ON live_speaker_mappings(session_id);

CREATE INDEX IF NOT EXISTS idx_live_speaker_mappings_profile_id
    ON live_speaker_mappings(profile_id)
    WHERE profile_id IS NOT NULL;

-- ============================================================
-- Step 6: CREATE live_summary_tasks 表（H-2 后台任务持久化）
-- ============================================================
CREATE TABLE IF NOT EXISTS live_summary_tasks (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID         NOT NULL UNIQUE REFERENCES sessions(id) ON DELETE CASCADE,
    status      VARCHAR(20)  NOT NULL DEFAULT 'pending',
    started_at  TIMESTAMPTZ,
    heartbeat   TIMESTAMPTZ,
    retry_count INTEGER      NOT NULL DEFAULT 0,
    error_msg   TEXT,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- status: 'pending' | 'running' | 'completed' | 'failed'
-- heartbeat: 任务运行时每 30s 更新；heartbeat < NOW() - INTERVAL '5 minutes'
--            且 status='running' → 视为 stale，触发恢复（最多重试 3 次）
-- 覆盖范围: Task 1 Summary 汇总（Task 2/3 通过 live_panel_batches + sessions 字段追踪）

CREATE INDEX IF NOT EXISTS idx_live_summary_tasks_status
    ON live_summary_tasks(status);

CREATE INDEX IF NOT EXISTS idx_live_summary_tasks_heartbeat
    ON live_summary_tasks(heartbeat)
    WHERE status = 'running';

-- ============================================================
-- Step 7: CREATE live_panel_batches 表（H-2 图片生成任务追踪）
-- ============================================================
CREATE TABLE IF NOT EXISTS live_panel_batches (
    id                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id        UUID         NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    segment_id        UUID         REFERENCES live_segments(id) ON DELETE CASCADE,
    scene_index       INTEGER      NOT NULL DEFAULT 0,
    scene_description TEXT,
    status            VARCHAR(20)  NOT NULL DEFAULT 'pending',
    image_url         TEXT,
    task_started_at   TIMESTAMPTZ,
    task_heartbeat    TIMESTAMPTZ,
    retry_count       INTEGER      NOT NULL DEFAULT 0,
    error_msg         TEXT,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- scene_index: 全局排序后该 scene 在最终 5 张中的位置（0-based）
-- scene_description: Gemini 提取的场景描述（用于 generate_image_from_prompt）
-- status: 'pending' | 'running' | 'completed' | 'failed' | 'skipped'
-- image_url: 生成成功后写入此字段，同时更新 sessions.cover_image_url（首张）
--            和 live_segments.image_urls（按 segment_id 分组写入）
-- task_heartbeat: 每 30s 更新，stale > 5min → 重试（最多 3 次），超过标记 'failed'

CREATE INDEX IF NOT EXISTS idx_live_panel_batches_session_id
    ON live_panel_batches(session_id);

CREATE INDEX IF NOT EXISTS idx_live_panel_batches_segment_id
    ON live_panel_batches(segment_id);

CREATE INDEX IF NOT EXISTS idx_live_panel_batches_pending
    ON live_panel_batches(status)
    WHERE status IN ('pending', 'running');

-- ============================================================
-- Step 8: ALTER profiles 表 - 添加声纹录入意愿字段
-- ============================================================
ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS voiceprint_intent    BOOLEAN      DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS voiceprint_intent_at TIMESTAMPTZ;

-- voiceprint_intent: 用户在 Step 2 弹窗点击「录入声纹」按钮后置为 TRUE
-- voiceprint_intent_at: 记录意愿时间
-- 实际声纹采集为未来功能，当前仅记录意愿

-- ============================================================
-- 验证查询（可选，迁移后执行确认）
-- ============================================================
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_name = 'sessions'
-- AND column_name IN ('session_type','card_title','live_summary','summary_status',
--                     'image_status','skills_status','cover_image_url','gemini_token',
--                     'ws_disconnected_at','ended_at','abandon_reason');

-- SELECT table_name FROM information_schema.tables
-- WHERE table_schema = 'public'
-- AND table_name IN ('live_turns','live_segments','live_events',
--                    'live_speaker_mappings','live_summary_tasks','live_panel_batches');
