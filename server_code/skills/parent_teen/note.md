# Note: Parenting a Teenager

## About This Skill
Use when: communication with your teenager has broken down, you're dealing with defiance, withdrawal, risky behavior, or mental health concerns, or you're trying to stay connected during a period when they seem to be pushing you away.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `teen_age` | Teen's Age | ✅ | Age matters — early teens (13–14) vs. older teens (16–18) have different dynamics |
| `main_concern` | Main Concern | ✅ | Communication breakdown / defiance / risky behavior / mental health / academic struggles / withdrawal |
| `current_dynamic` | Current Dynamic | ✅ | Still talking but tense / complete shutdown / only fighting / surface-level only |
| `your_parenting_approach` | Your Approach | ✅ | More rules-focused / more connection-focused / unsure what's working |
| `recent_trigger` | Recent Trigger | ❌ | A specific incident or change that worsened things |
| `other_parent_situation` | Other Parent | ❌ | Single parent / co-parenting / partner involved — affects dynamic |

---

## AI Onboarding Script

**Opening:**
> "The teenage years can feel like losing the child you knew. Tell me what's going on — what's changed, and what are you most worried about?"

**Questions (only for missing fields):**
1. `teen_age` missing: "How old is your teenager?"
2. `main_concern` missing: "What's the main thing you're struggling with — communication, behavior, something you're worried about, or just the distance?"
3. `current_dynamic` missing: "How would you describe where things are between you right now?"
4. `your_parenting_approach` missing: "How would you describe your general approach — are you more focused on rules and accountability, or more on staying connected and keeping the door open?"
5. `recent_trigger` missing: "Did something specific happen recently that made things worse, or has this been building gradually?"

---

## Sample baseline_text

```
Teen's age: 16
Main concern: He's withdrawn completely — barely speaks at dinner, locks himself in his room, grades have dropped
Current dynamic: Not fighting, just... nothing. He's there but absent
My approach: Have been more rules-focused — curfews, screen time limits — but nothing seems to land
Recent trigger: Found out he'd been lying about where he was going; confronted him and it blew up
Other parent: Divorced; his dad is less involved but they seem to have an easier rapport
```

---

## Update Triggers

- Specific situation resolved or escalated
- Teen's behavior or mood shifts significantly
- New concern emerges (mental health, substances, relationships)
- Relationship dynamic improves or breaks down further
