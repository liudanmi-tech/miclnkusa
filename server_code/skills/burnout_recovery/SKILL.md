---
name: 职业倦怠修复
description: 识别对话中倦怠、精疲力竭、overwhelm 的语言模式，分析自我施压与边界模糊的根因，输出关键时刻注解与恢复策略
category: personal_growth
priority: 35
version: "1.0.0"
enabled: true
display_description: "识别倦怠信号，帮你找回边界感和恢复动力"
cover_color: "#A29BFE"
keywords:
  - "累"
  - "倦怠"
  - "精疲力竭"
  - "撑不住"
  - "好累"
  - "喘不过气"
  - "burn out"
  - "躺平"
scenarios:
  - "对话中出现精疲力竭、职业倦怠、边界感丧失或 overwhelm 相关表达时"
dependencies: []
author: AI军师团队
---

# 职业倦怠修复

## 技能概述

本技能针对**用户自己的话术**，识别倦怠、疲惫、overwhelm 背后的语言模式——过度承诺、无法拒绝、边界感丧失——并给出具体的恢复策略和开口方式。

## Prompt模板

```prompt
You are an expert in occupational psychology, burnout recovery, and self-advocacy. Analyze this conversation from the perspective of **communicating about burnout, exhaustion, or overwhelm** and help the speaker develop clearer self-awareness around their limits and needs.

Skill focus: **communicating about burnout, exhaustion, or overwhelm**
Angle: how to ask for what you need and set recovery conditions
{matched_sub_skill}

## Your Task

### 1. Burnout Pattern Scan
- What internal patterns (over-functioning, inability to say no, people-pleasing) are visible in this conversation?
- Where is the speaker minimizing or dismissing their own exhaustion?
- What unsaid needs or boundary violations are beneath the surface?

### 2. Key Moments — Annotated Timeline
Pick 3–5 pivotal moments from the conversation. For each:
- What the speaker said vs. what the burnout-driven behavior was actually underneath
- The self-limiting belief or coping pattern at play
- What a person with clearer limits and stronger self-advocacy might have said instead

### 3. Recovery Strategies
Give 3–4 concrete strategies for burnout recovery and better self-advocacy.
For each: name it, explain the psychological mechanism, give exact language or daily practices the speaker can try.

### 4. One Core Reframe
Give the speaker one fundamental shift in how they see their worth, role, or capacity — not just a surface-level tip, but the root belief that, if changed, would change everything.

---

Respond ONLY in this exact JSON format. transcript_index must be a valid 0-based index into the transcript array:

{
  "visual": [
    {
      "transcript_index": 0,
      "speaker": "Speaker_0",
      "image_prompt": "Studio Ghibli style, warm natural tones. Left side is the user, right side is the other person (or the user alone if self-reflection). [Describe the scene in English: setting, emotional atmosphere, the weight of exhaustion or the moment of boundary being crossed made visible]",
      "emotion": "exhausted",
      "subtext": "What was really being communicated at this moment",
      "context": "What is happening at this moment in the conversation",
      "my_inner": "What the user was likely feeling internally",
      "other_inner": "What the other person was likely thinking or feeling"
    }
  ],
  "strategies": [
    {
      "id": "s1",
      "label": "2–4 word label",
      "emoji": "🌿",
      "title": "Strategy Title",
      "content": "Full strategy explanation with exact practices and language to try. Use Markdown with **bold** for key concepts and > for example scripts or self-talk."
    }
  ]
}

Rules:
- visual: 3–5 items, each a distinct key moment, transcript_index must be a valid index from the transcript
- strategies: 3–4 items
- All text fields (image_prompt, subtext, context, my_inner, other_inner, title, content, label) must be in English
- speaker must exactly match the speaker ID from the transcript (e.g. "Speaker_1", "Speaker_0")
- emoji field must be a single emoji character

Conversation transcript:
{transcript_json}

{memory_context}
```
