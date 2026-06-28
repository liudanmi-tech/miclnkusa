# Note: Partner Communication

## About This Skill
Use when: you and your partner keep having the same argument, something important isn't being said, communication has gotten cold or defensive, or you want to get better at navigating conflict without it turning into a fight.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `relationship_length` | Relationship Length | ✅ | How long you've been together |
| `main_issue` | Main Issue | ✅ | The core communication problem — avoidance / recurring argument / shutting down / different needs |
| `conflict_pattern` | Conflict Pattern | ✅ | What usually happens when things go wrong — who withdraws, who escalates |
| `living_situation` | Living Together | ❌ | Whether you live together affects frequency and intensity |
| `previous_attempts` | What You've Tried | ❌ | Have you talked about this before? What happened? |
| `desired_outcome` | What You Want | ❌ | Resolve a specific issue / improve patterns long-term / decide on next steps |

---

## AI Onboarding Script

**Opening:**
> "Every couple has communication patterns — some that work and some that don't. Tell me what's going on and let's figure out what's actually happening and what might help."

**Questions (only for missing fields):**
1. `relationship_length` missing: "How long have you two been together?"
2. `main_issue` missing: "What's the core thing that's not working in how you communicate? A specific recurring argument, or more of a general disconnect?"
3. `conflict_pattern` missing: "When things go sideways between you, what usually happens — does one of you shut down, does it escalate, or does it just never get resolved?"
4. `previous_attempts` missing: "Have you tried talking about this directly with your partner? How did that go?"
5. `desired_outcome` missing: "What are you hoping for here — to get through a specific conversation, or to change the dynamic longer term?"

---

## Sample baseline_text

```
Relationship length: 2 years
Main issue: Recurring argument about quality time vs. independence — never fully resolved
Conflict pattern: I tend to push, they shut down and go quiet for hours
Living situation: Don't live together — see each other 2–3x a week
Previous attempts: Have raised it a few times, usually ends in apologies but nothing changes
Desired outcome: Break the cycle, not just patch it each time
```

---

## Update Triggers

- Had the conversation — want to debrief
- Pattern shifted (better or worse)
- Relationship status changes
- New major conflict arises
