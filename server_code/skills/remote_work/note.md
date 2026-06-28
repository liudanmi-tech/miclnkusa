# Note: Remote Work

## About This Skill
Use when: dealing with communication efficiency, team collaboration, visibility, loneliness, or boundary management in a fully remote or hybrid setup.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `remote_type` | Remote Setup | ✅ | Fully remote / hybrid (how many days home vs. office) |
| `main_challenge` | Main Challenge | ✅ | Communication / visibility / focus / loneliness / work-life blur |
| `team_timezone` | Team Timezones | ✅ | Where teammates are located, any time differences |
| `communication_tools` | Communication Tools | ❌ | Slack / Teams / Zoom + async vs. sync preferences |
| `home_setup` | Work Environment | ❌ | Dedicated home office or not — affects focus recommendations |

---

## AI Onboarding Script

**Opening:**
> "Remote work challenges vary a lot depending on your setup and your team — tell me about your situation and I'll help you find what works best for you."

**Questions (only for missing fields):**
1. `remote_type` missing: "Are you fully remote, or do you have a hybrid schedule?"
2. `main_challenge` missing: "What's the main thing frustrating you right now? Communication issues, feeling invisible, work bleeding into personal time, or something else?"
3. `team_timezone` missing: "Where is your team mostly located? Are you dealing with any time zone gaps?"
4. `communication_tools` missing: "What tools does your team use? Are you more of a real-time or async culture?"

---

## Sample baseline_text

```
Remote setup: Fully remote (2 years)
Main challenge: Hard to stay visible, often feel overlooked; work-life boundaries are blurry
Team: All based in same city, no time zone difference
Tools: Slack — sync-heavy culture, lots of meetings, weak async habits
Home setup: Dedicated home office but easily distracted
```

---

## Update Triggers

- Remote policy changes (return to office, new flexibility options)
- New job with a different remote culture
- Relocate to a new city or time zone
- Team structure changes
