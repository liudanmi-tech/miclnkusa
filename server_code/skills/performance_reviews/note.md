# Note: Performance Reviews

## About This Skill
Use when: preparing for a performance review, advocating for a strong rating, making your case for promotion, or debriefing a low evaluation.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `review_cycle` | Review Cycle | ✅ | How often, and when is the next one |
| `last_rating` | Last Rating | ✅ | A/B/C or equivalent description |
| `key_achievements` | Key Achievements | ✅ | 2–3 most significant things this cycle |
| `career_goal` | Career Goal | ✅ | What you want from this review (maintain / promote / raise) |
| `boss_expectation` | Manager's Expectations | ❌ | What your manager has explicitly said they want from you |
| `peer_perception` | Peer Perception | ❌ | Potential issues that might surface in 360 feedback |

---

## AI Onboarding Script

**Opening:**
> "To help you prepare for your performance review, I need to understand your work situation and what you're going for."

**Questions (only for missing fields):**
1. `review_cycle` missing: "How often does your company do performance reviews? When's the next one?"
2. `last_rating` missing: "What was your last performance result — rating or specific feedback?"
3. `key_achievements` missing: "What are the 2–3 things you're most proud of this cycle?"
4. `career_goal` missing: "What are you most hoping to get out of this review — protect your current rating, push for a promotion, or get a raise?"
5. `boss_expectation` missing: "Has your manager expressed any specific expectations or concerns about your performance?"

---

## Sample baseline_text

```
Review cycle: Every 6 months, next review: December
Last rating: B (Good) — aiming for B+ this cycle
Key achievements:
  1. Led payment system refactor — 3x QPS improvement
  2. Mentored 2 new hires, both passed probation successfully
  3. Drove cross-team collaboration, significantly reduced coordination overhead
Career goal: Aiming for L5 promotion this cycle; at minimum, targeting an A rating
Manager's expectations: Wants me to take on more cross-team projects and expand technical influence
```

---

## Update Triggers

- Review results come out (rating changes)
- Starting to prepare for a new review cycle
- Promotion outcome (success or failure)
- Manager's expectations shift
