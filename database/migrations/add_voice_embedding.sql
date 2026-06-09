-- 为 profiles 表添加声纹 embedding 列
-- 用于 Live 模式说话人自动识别（Resemblyzer 256维 d-vector）
ALTER TABLE profiles
    ADD COLUMN IF NOT EXISTS voice_embedding FLOAT[] NULL,
    ADD COLUMN IF NOT EXISTS voice_embedding_updated_at TIMESTAMPTZ NULL;

COMMENT ON COLUMN profiles.voice_embedding IS 'Resemblyzer 256维 d-vector，由档案音频片段计算所得';
COMMENT ON COLUMN profiles.voice_embedding_updated_at IS '声纹 embedding 最后更新时间';
