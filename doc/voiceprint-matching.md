# Live 模式声纹匹配方案

> 状态：待实现
> 更新时间：2026-06-09

---

## 一、背景与目标

Deepgram Nova-3 实时转录已能区分说话人（Speaker_1、Speaker_2…），但不知道这些标签对应谁。本方案在此基础上，通过与用户「档案」中预存的声纹样本比对，自动识别出对话中每个 speaker 是哪个人。

**核心目标：**
- Session 开始后，尽快（5–15s 内）自动识别各说话人
- 优先识别「自己」（用户本人）
- 识别结果写入 `live_speaker_mappings`，通过 SSE 实时推给 iOS

---

## 二、前提：声纹注册

档案必须有 `audio_url`（用户已选音频片段）才能参与匹配。

**注册时机：** 用户在档案页选择/更新音频片段后，后台异步触发注册。

**注册流程：**
```
profiles.audio_url 写入
  → 后台异步任务（fire-and-forget）
    → 从 R2 下载音频
    → ffmpeg 转换为 16kHz 16-bit mono WAV
    → Resemblyzer 计算 256 维 d-vector embedding
    → 存入 profiles.voice_embedding（FLOAT[] 列）
    → 更新 profiles.voice_embedding_updated_at
```

注册一次性完成，后续所有 live session 直接读取 embedding。

---

## 三、实时匹配：每条 Turn 独立处理

### 为什么不积累多条 Turn 再合并

三人对话中，Deepgram 的 speaker 标签跨 `is_final` 边界**不保证完全一致**：某条 turn 的 Speaker_2 可能实际是第三个人的声音被误标。若将多条 turn 的 PCM 拼接后计算 embedding，混入其他说话人会导致 embedding 失真，识别准确率显著下降。

**结论：每条 turn 独立提取音频、独立计算 embedding，不跨 turn 拼接。**

---

### 服务端 PCM 滚动缓冲

iOS 发来的 PCM 帧（16kHz 16-bit mono）在转发给 Deepgram 的同时，也写入服务端内存缓冲。

```
固定保留最近 30 秒 PCM（960KB）
写入：每帧 PCM 到达时追加到 bytearray
裁剪：超出 30s 时丢弃头部
提取：按绝对流时间戳 [start_sec, end_sec] 切片
```

**偏移量计算：**
- 维护 `total_written_bytes`（从 stream 开始的累计字节数）
- 提取时：`rel_start = int(start_sec * 32000) - (total_written - len(buf))`

缓冲按 session_id 隔离，会话结束时立刻释放。

---

### TranscribedTurn 扩展

Deepgram 每个 word 对象自带 `start`/`end` 时间戳（秒，相对 stream 起点）。将其透传到 TranscribedTurn：

```python
class TranscribedTurn(NamedTuple):
    speaker_label: str
    text: str
    turn_index: int
    start_sec: float   # 第一个 word 的 start
    end_sec: float     # 最后一个 word 的 end
    # duration = end_sec - start_sec
```

---

### 匹配流程（每条 Turn 触发）

```
新 Turn 到达（speaker_label, start_sec, end_sec）
  │
  ├─ 该 speaker 已被确认识别 → 跳过
  │
  ├─ duration < 1.5s → 跳过（音频太短，embedding 不可靠）
  │
  └─ duration >= 1.5s：
       从 PCM 缓冲提取 [start_sec, end_sec] 的音频
       计算单条 turn 的 Resemblyzer embedding
       │
       ▼
     ┌──────────────────────────────────────────────────────┐
     │  Stage 1：是否是我（1:1 比对，每条符合条件的 turn 都跑）│
     └──────────────────────────────────────────────────────┘
       self profile 有 voice_embedding？
         → NO：跳过 Stage 1，进 Stage 2
         → YES：
             cosine(turn_emb, self_emb)
             │
             ≥ 0.75 → ✅ 确认是自己
                       写 live_speaker_mappings（confidence=0.92, method=voiceprint）
                       SSE 推 speaker_identified
                       该 speaker 标记为已识别，后续 turn 跳过
             │
             < 0.50 → ❌ 确认不是自己，进 Stage 2
             │
             0.50–0.75 → 不确定，此 turn 不投票，等下一条
       │
       ▼（Stage 1 结果为「不是我」，且 duration >= 2.0s）
     ┌──────────────────────────────────────────────────────┐
     │  Stage 2：是哪个人（1:N 比对 + 投票确认）             │
     └──────────────────────────────────────────────────────┘
       与所有非 self 档案逐一 cosine 比对
       best_match = 最高分的档案

       best_cosine >= 0.78：
         → ✅ 单 turn 强匹配，立刻确认
            写 live_speaker_mappings（confidence=best_cosine, method=voiceprint）
            SSE 推 speaker_identified

       0.65 <= best_cosine < 0.78
       AND (best_cosine - second_best_cosine) >= 0.05：
         → 记录候选投票：vote[speaker_label][profile_id] += 1
         → 同一 profile 累计 2 票 → ✅ 确认匹配
            写 live_speaker_mappings（confidence=avg_cosine, method=voiceprint）
            SSE 推 speaker_identified

       best_cosine < 0.65 OR margin < 0.05：
         → 此 turn 不可信，丢弃，不投票
```

---

### 投票机制说明

- 每条 turn 独立跑，天然隔离跨说话人污染
- 若 Deepgram 偶尔误标（Speaker_3 被标为 Speaker_2），该 turn 的 embedding 与档案差距大，得分 < 0.65，直接丢弃，不影响正常投票
- 连续 2 条 turn 稳定指向同一档案 → 可信

---

### 时间线示意（3 人对话）

```
0s    Session 开始，各 speaker 陆续出现
2.5s  Speaker_1 第一条 turn（3s）→ Stage 1 → 确认是自己（+0.2s）
      iOS 显示用户名字

5s    Speaker_2 第一条 turn（2.5s）→ Stage 1（不是我）→ Stage 2（0.71，投票 1）
9s    Speaker_2 第二条 turn（3s）  → Stage 1（不是我）→ Stage 2（0.74，投票 2）
      投票达 2 → 确认是「张总」
      iOS 显示「张总」

7s    Speaker_3 第一条 turn（4s）→ Stage 1（不是我）→ Stage 2（0.82，强匹配）
      立刻确认是「李姐」
      iOS 显示「李姐」
```

---

## 四、准确率预期

| 场景 | 准确率 |
|------|--------|
| Stage 1 自我识别（1.5s turn） | ~85% |
| Stage 1 自我识别（3s turn） | ~92% |
| Stage 2 单 turn 强匹配（>= 2s，cosine >= 0.78） | ~85–90% |
| Stage 2 投票确认（2 票） | ~90–95% |

误判保护：`cosine < 0.65` 或 `margin < 0.05` 时不输出结果，宁可显示 Speaker_X 也不误判。

已有 `user_confirmed`（confidence=1.0）的记录不会被 voiceprint 结果覆盖。

---

## 五、SSE 新事件

```json
{
  "type": "speaker_identified",
  "speaker_label": "Speaker_2",
  "profile_id": "uuid...",
  "profile_name": "张总",
  "confidence": 0.85,
  "method": "voiceprint"
}
```

iOS 收到后更新对话气泡头像/名字（复用现有 SpeakerConfirmation UI）。

---

## 六、DB 变更

```sql
ALTER TABLE profiles
    ADD COLUMN voice_embedding FLOAT[] NULL,
    ADD COLUMN voice_embedding_updated_at TIMESTAMPTZ NULL;
```

---

## 七、文件清单

| 文件 | 改动类型 | 内容 |
|------|---------|------|
| `database/migrations/add_voice_embedding.sql` | 新增 | profiles 加 voice_embedding 列 |
| `server_code/services/deepgram_live.py` | 改动 | TranscribedTurn 加 start_sec / end_sec |
| `server_code/services/voiceprint_service.py` | 重写 | Resemblyzer：compute_embedding()、cosine_similarity() |
| `server_code/services/voiceprint_matcher.py` | 新增 | PCMBuffer、投票逻辑、Stage 1/2 匹配逻辑 |
| `server_code/api/live_audio.py` | 改动 | _ios_to_gemini 同时写 PCM 缓冲；turn 落库后 fire-and-forget 触发 matcher |
| `server_code/api/profiles.py` | 改动 | 创建/更新档案时后台触发声纹注册 |

---

## 八、降级策略

| 情况 | 行为 |
|------|------|
| 档案无 audio_url | 跳过声纹注册，保持 Speaker_X 显示 |
| voice_embedding 未计算 | 跳过声纹匹配，静默降级 |
| Resemblyzer 未安装 | 服务启动时警告，跳过所有声纹功能 |
| PCM 缓冲中数据已被裁剪 | 跳过该 turn 的识别 |
| 已有 user_confirmed 记录 | 不覆盖 |

---

## 九、安装依赖

```bash
# 在测试服/正式服执行
cd /opt/gemini-audio-service
source .venv/bin/activate
pip install resemblyzer
```

Resemblyzer 依赖：numpy、scipy、webrtcvad，约 50MB，无需 GPU，无需 HuggingFace token。
