# Note: Situationship

## About This Skill
Use when: you're in something that feels like a relationship but has never been defined, you're not sure where you stand, the ambiguity is becoming painful, or you want to figure out how to either define it or exit it.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `duration` | How Long | ✅ | How long this situation has been going on |
| `what_you_do_together` | What It Looks Like | ✅ | Frequency of seeing each other, what you do, level of intimacy |
| `label_status` | Label Status | ✅ | Never discussed / discussed and avoided / one of you wants a label and the other doesn't |
| `your_feelings` | Your Feelings | ✅ | Comfortable with ambiguity / starting to want more / hurting / confused |
| `their_signals` | Their Signals | ✅ | Seems happy keeping it undefined / gives mixed signals / says they're "not ready" |
| `what_you_want` | What You Want | ❌ | Define it / end it / understand it / just need to process |

---

## AI Onboarding Script

**Opening:**
> "Situationships are one of the most emotionally exhausting things — you have all the feelings of a relationship without any of the security. Tell me what's going on."

**Questions (only for missing fields):**
1. `duration` missing: "How long has this been going on?"
2. `what_you_do_together` missing: "What does this actually look like day to day — how often do you see each other, are you exclusive in practice even if not in name?"
3. `label_status` missing: "Has the 'what are we' conversation ever come up between you?"
4. `your_feelings` missing: "How are you feeling about where things are right now — comfortable, or starting to want more than this?"
5. `their_signals` missing: "What signals are you getting from their side?"
6. `what_you_want` missing: "What do you actually want — to make it official, to end it, or just to understand what's happening?"

---

## Sample baseline_text

```
Duration: 4 months
What it looks like: See each other 2–3x a week, exclusive in practice, meet each other's friends
Label status: Brought it up once 6 weeks ago — they said they "aren't ready for something serious right now"
My feelings: Was okay with it at first, now starting to feel anxious and undervalued
Their signals: Warm and present in person, but pulls back whenever labels come up
What I want: Either make it real or I need to stop investing this much
```

---

## Update Triggers

- Had the DTR conversation — outcome to process
- Made a decision (staying in it vs. ending it)
- Their behavior changed significantly
- Your feelings shifted
