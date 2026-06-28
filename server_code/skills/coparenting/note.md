# Note: Co-Parenting

## About This Skill
Use when: you're raising a child with someone you're no longer in a relationship with — navigating communication, disagreements, schedules, new partners, or trying to protect the child from adult conflict.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `separation_context` | Separation Context | ✅ | Divorce / never married / how long since separation / whether it was mutual |
| `custody_arrangement` | Custody | ✅ | Current legal or informal custody arrangement — shared / primary / long-distance |
| `co_parent_dynamic` | Co-Parent Dynamic | ✅ | Cooperative / tense / hostile / minimal contact / one-sided effort |
| `main_friction` | Main Friction | ✅ | Schedule / discipline consistency / communication style / new partners / child being put in the middle |
| `child_age` | Child's Age | ✅ | Age(s) of child(ren) — shapes what matters developmentally |
| `legal_situation` | Legal Situation | ❌ | Whether there's a formal agreement, pending disputes, or lawyers involved |

---

## AI Onboarding Script

**Opening:**
> "Co-parenting well is genuinely hard work — especially when the adult relationship is complicated. Tell me about your situation."

**Questions (only for missing fields):**
1. `separation_context` missing: "How long ago did you separate, and what did that look like — mutual decision, difficult split?"
2. `custody_arrangement` missing: "What does the custody arrangement look like right now — shared, primary with one parent, or something informal?"
3. `co_parent_dynamic` missing: "How would you describe the dynamic with your co-parent — working okay, tense, or openly hostile?"
4. `main_friction` missing: "What's the biggest source of friction right now?"
5. `child_age` missing: "How old is your child — or children?"

---

## Sample baseline_text

```
Separation context: Divorced 18 months ago after a 6-year marriage — not mutual, I initiated
Custody: Shared 50/50, week on / week off
Co-parent dynamic: Civil but tense — can communicate about logistics, but any deviation from routine causes conflict
Main friction: Different parenting styles (I'm more structured; they're permissive) + they've introduced a new partner after 4 months, which I have feelings about
Child's age: 7-year-old daughter
Legal situation: Formal custody agreement in place — no current disputes
```

---

## Update Triggers

- New conflict or change in dynamics with co-parent
- Child's needs shift (school issues, behavioral changes)
- Legal situation changes
- New partner introduced (yours or theirs)
- Custody arrangement changes
