# Note: Dealing with Criticism

## About This Skill
Use when: you received criticism that stung and you're not sure what to do with it, feedback triggered a strong defensive reaction, you tend to take criticism very personally, or you want to get better at processing negative feedback without shutting down or spiraling.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `criticism_source` | Source | ✅ | Manager / colleague / partner / parent / online / public / self-criticism |
| `what_was_said` | What Was Said | ✅ | The specific criticism — or the kind of criticism that tends to hit hardest |
| `your_reaction` | Your Reaction | ✅ | Defensive / crushed / angry / replay loop / shut down / dismissed it but still bothered |
| `is_it_valid` | Validity | ✅ | Likely accurate / partially true / unfair / unclear / mixed |
| `delivery` | How It Was Delivered | ❌ | Direct / harsh / in public / behind your back / in written feedback |
| `desired_outcome` | What You Need | ❌ | Process the emotional reaction / decide what to do with the feedback / respond to the person |

---

## AI Onboarding Script

**Opening:**
> "Criticism can hit in very different ways depending on where it comes from and how it lands. Tell me what happened."

**Questions (only for missing fields):**
1. `criticism_source` missing: "Who gave you the criticism — a manager, a colleague, a partner, someone online?"
2. `what_was_said` missing: "What did they actually say — or what's the kind of feedback that tends to knock you off balance?"
3. `your_reaction` missing: "How did you respond internally — defensiveness, hurt, anger, or something else?"
4. `is_it_valid` missing: "Setting aside how it felt, do you think there's truth in it? Is it fully accurate, partially fair, or off-base?"
5. `delivery` missing: "How was it delivered — constructive, harsh, in public, or something else?"

---

## Sample baseline_text

```
Source: Direct manager, in a performance review
What was said: "You need to communicate more proactively — I often don't know where you are on projects until they're almost done"
My reaction: Defensive in the moment, then spent a week internally arguing against it; still bothered
Validity: Probably partially true — I do tend to work quietly; not sure it's as bad as implied
Delivery: Written feedback, semi-formal, not cruel but felt significant
Desired outcome: Figure out whether to act on it and stop the internal argument loop
```

---

## Update Triggers

- Decided how to respond or act on the feedback
- Had a follow-up conversation about it
- Feedback was referenced again (positively or negatively)
- Similar pattern emerges from a different source
