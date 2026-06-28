# Note: Managing a Difficult Boss

## About This Skill
Use when: your manager is controlling, volatile, plays favorites, over-promises and under-delivers, or creates a hostile work environment.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `boss_style` | Management Style | ✅ | Micromanager / domineering / volatile / avoidant / plays favorites |
| `main_issue` | Core Problem | ✅ | The single most pressing source of conflict right now |
| `relationship_history` | History | ❌ | Was it ever good? When did it turn? |
| `job_dependency` | Job Mobility | ❌ | Can you transfer or leave? Shapes strategy options |
| `escalation_risk` | Escalation Risk | ❌ | Is your performance rating or job security at risk? |

---

## AI Onboarding Script

**Opening:**
> "To help you navigate this, I need to understand your manager's style and the dynamics between you. I've pulled together a few things from what you've shared before — please confirm if they're accurate."

**Questions (only for missing fields):**
1. `boss_style` missing: "What's your manager's most notable style? Micromanages everything, blows up emotionally, plays favorites, or just generally unreliable?"
2. `main_issue` missing: "What's the one specific thing that's bothering you most right now?"
3. `job_dependency` missing: "If things don't improve, do you have the option to transfer or leave?"
4. `escalation_risk` missing: "Has this situation started affecting your performance ratings or job security?"

---

## Sample baseline_text

```
Manager style: Micromanager + volatile, publicly criticizes people under pressure
Core problem: Direction changes every debrief — work gets thrown out, very draining
Relationship history: First six months were fine, things soured after my promotion
Job mobility: Transfer is possible, but tied to current project — can't move for ~6 months
Escalation risk: Last review was a C — feeling vulnerable
```

---

## Update Triggers

- Manager changes (leaves, transfers, new manager arrives)
- Performance outcome updates (PIP, promotion, rating improvement)
- You transfer or leave the company
