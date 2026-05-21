//
//  SkillsRadarModels.swift
//  WorkSurvivalGuide
//
//  新版技能雷达数据模型（Level1=场景, Level2=用户选的子技能）
//

import Foundation
import SwiftUI

// MARK: - Scene Insight SSE Models

/// 单条 SSE event，对应后端 "data: {...}" 行
struct InsightSSEEvent: Decodable {
    let type: String
    let scene_id: String?
    let scene_label: String?
    let scene_emoji: String?
    let session_count: Int?
    let token: String?
    let skills: [RadarSkill]?
    let recommendations: [RadarRecommendation]?
    let message: String?
}

/// 单场景洞察结果（流式填充 + 最终数据，可 Codable 存缓存）
struct SceneInsightResult: Codable, Identifiable {
    let sceneId: String
    let sceneLabel: String
    let sceneEmoji: String
    let sessionCount: Int
    var insightText: String
    var skills: [RadarSkill]
    var recommendations: [RadarRecommendation]
    var id: String { sceneId }
}

/// UserDefaults 缓存结构
struct InsightCache: Codable {
    let cacheKey: String    // "startDate_endDate_totalSessions"
    let scenes: [SceneInsightResult]
    let generatedAt: Date
}

// MARK: - API Response Models

struct SkillsRadarResponse: Codable {
    let code: Int
    let message: String?
    let data: SkillsRadarData?
}

struct SkillsRadarData: Codable {
    let scenes: [RadarScene]
    let highlights: [RadarHighlight]
    let recap: RecapData?
}

struct RadarScene: Codable, Identifiable {
    let scene_id: String
    let scene_label: String
    let scene_emoji: String
    let session_count: Int
    let skills: [RadarSkill]
    let recommendations: [RadarRecommendation]

    var id: String { scene_id }

    /// 轴长比例 (0.2–1.0), 相对同期最大 session_count 归一化，由 ViewModel 计算
    var normalizedValue: Double = 1.0

    enum CodingKeys: String, CodingKey {
        case scene_id, scene_label, scene_emoji, session_count, skills, recommendations
    }
}

/// 高光时刻（跨场景，最多5条）
struct RadarHighlight: Codable, Identifiable {
    let session_id: String
    let session_title: String
    let session_date: String
    let skill_labels: [String]
    let cover_image_url: String?
    let scene_label: String
    let scene_emoji: String
    var id: String { session_id }
}

struct RadarRecommendation: Codable, Identifiable {
    let skill_id: String
    let skill_label: String
    let scene_count: Int
    let reason: String
    var id: String { skill_id }
}

struct RadarSkill: Codable, Identifiable {
    let skill_id: String
    let skill_label: String
    let hit_count: Int
    let level: String?       // "初探" | "练习中" | "熟悉" | "精通" | "驾轻就熟"
    let trend: String?       // "improving" | "stable" | "watch"
    let sparkline: [Int]     // 0/1 per session, max 8 points

    var id: String { skill_id }

    /// 5-pip level indicator count (1–5)
    var pipCount: Int {
        switch hit_count {
        case 0:         return 0
        case 1:         return 1
        case 2:         return 2
        case 3...4:     return 3
        case 5...7:     return 4
        default:        return 5
        }
    }

    /// Axis length ratio for Level 2 radar (0.2–1.0)
    var radarRatio: Double {
        switch hit_count {
        case 0:         return 0.0
        case 1:         return 0.2
        case 2:         return 0.4
        case 3...4:     return 0.6
        case 5...7:     return 0.8
        default:        return 1.0
        }
    }

    var trendColor: Color {
        switch trend {
        case "improving": return Color(hex: "#34D399")
        case "watch":     return Color(hex: "#FB923C")
        default:          return Color.white.opacity(0.4)
        }
    }

    var trendSymbol: String {
        switch trend {
        case "improving": return "↑"
        case "watch":     return "↓"
        default:          return "→"
        }
    }

    var trendLabel: String {
        switch trend {
        case "improving": return "提升中"
        case "watch":     return "可关注"
        default:          return "稳定"
        }
    }
}

// MARK: - Recap Models

struct RecapData: Codable {
    let page1: RecapPage1
    let page2: RecapPage2?
    let page3: RecapPage3?
    let page4: RecapPage4?
    let page5: RecapPage5?
}

struct RecapPage1: Codable {
    let totalSessions: Int
    let totalScenes: Int
    let totalSkillsHit: Int
    let topSceneEmoji: String
    let topSceneLabel: String
    let coverUrls: [String]
    enum CodingKeys: String, CodingKey {
        case totalSessions = "total_sessions"
        case totalScenes = "total_scenes"
        case totalSkillsHit = "total_skills_hit"
        case topSceneEmoji = "top_scene_emoji"
        case topSceneLabel = "top_scene_label"
        case coverUrls = "cover_urls"
    }
}

struct RecapPage2: Codable {
    let sessionId: String
    let sessionTitle: String
    let sessionDate: String
    let sceneLabel: String
    let sceneEmoji: String
    let coverImageUrl: String?
    let skillLabels: [String]
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionTitle = "session_title"
        case sessionDate = "session_date"
        case sceneLabel = "scene_label"
        case sceneEmoji = "scene_emoji"
        case coverImageUrl = "cover_image_url"
        case skillLabels = "skill_labels"
    }
}

struct RecapMoodItem: Codable {
    let date: String
    let moodState: String
    let moodEmoji: String
    enum CodingKeys: String, CodingKey {
        case date
        case moodState = "mood_state"
        case moodEmoji = "mood_emoji"
    }
}

struct RecapPage3: Codable {
    let dominantMood: String
    let dominantMoodEmoji: String
    let dominantMoodEmojiUrl: String?
    let sighTotal: Int
    let hahaTotal: Int
    let moodJourney: [RecapMoodItem]
    enum CodingKeys: String, CodingKey {
        case dominantMood = "dominant_mood"
        case dominantMoodEmoji = "dominant_mood_emoji"
        case dominantMoodEmojiUrl = "dominant_mood_emoji_url"
        case sighTotal = "sigh_total"
        case hahaTotal = "haha_total"
        case moodJourney = "mood_journey"
    }
}

struct RecapTopSkill: Codable, Identifiable {
    let skillId: String
    let skillLabel: String
    let hitCount: Int
    let level: String?
    let trend: String?
    var id: String { skillId }
    var trendSymbol: String {
        trend == "improving" ? "↑" : trend == "watch" ? "↓" : "→"
    }
    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case skillLabel = "skill_label"
        case hitCount = "hit_count"
        case level, trend
    }
}

struct RecapStrategyQuote: Codable {
    let text: String
    let sessionDate: String
    let sceneLabel: String
    enum CodingKeys: String, CodingKey {
        case text
        case sessionDate = "session_date"
        case sceneLabel = "scene_label"
    }
}

struct RecapPage4: Codable {
    let topSkills: [RecapTopSkill]
    let strategyQuote: RecapStrategyQuote?
    enum CodingKeys: String, CodingKey {
        case topSkills = "top_skills"
        case strategyQuote = "strategy_quote"
    }
}

struct RecapSkillRef: Codable {
    let skillId: String
    let skillLabel: String
    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case skillLabel = "skill_label"
    }
}

struct RecapRecommendation: Codable, Identifiable {
    let skillId: String
    let skillLabel: String
    let reason: String
    var id: String { skillId }
    enum CodingKeys: String, CodingKey {
        case skillId = "skill_id"
        case skillLabel = "skill_label"
        case reason
    }
}

struct RecapPage5: Codable {
    let improvingSkill: RecapSkillRef?
    let watchSkill: RecapSkillRef?
    let recommendations: [RecapRecommendation]
    enum CodingKeys: String, CodingKey {
        case improvingSkill = "improving_skill"
        case watchSkill = "watch_skill"
        case recommendations
    }
}
