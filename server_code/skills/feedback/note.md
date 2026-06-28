# Note: Giving and Receiving Feedback

## About This Skill
Use when: you need to give feedback to a manager, peer, or direct report — or you've received feedback and don't know how to respond — or you want to build a better feedback culture on your team.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `feedback_direction` | Direction | ✅ | Giving to manager / peer / direct report / receiving feedback |
| `main_issue` | Core Issue | ✅ | The specific behavior you need to address, or the specific feedback you received |
| `relationship_quality` | Relationship | ✅ | Strong / neutral / tense — shapes how you deliver it |
| `desired_outcome` | Desired Outcome | ❌ | What behavior change are you hoping for? |
| `previous_attempts` | Previous Attempts | ❌ | Have you tried before? How did it go? |

---

## AI Onboarding Script

**Opening:**
> "Feedback is subtle — *how* you say it matters more than *what* you say. Tell me the basics, and let's figure out the right approach."

**Questions (only for missing fields):**
1. `feedback_direction` missing: "Are you giving someone feedback, or did you receive feedback and you're not sure how to handle it? If you're giving it, is it to a manager, peer, or someone you manage?"
2. `main_issue` missing: "What specific behavior or situation makes you feel like this needs to be said?"
3. `relationship_quality` missing: "How's your relationship with this person day to day?"
4. `desired_outcome` missing: "After this conversation, what would you ideally see this person change?"

---

## Sample baseline_text

```
Direction: Giving feedback to a peer
Core issue: They keep interrupting me in meetings — it's happened 4–5 times
Relationship: Surface-level fine, but there's some competition between us
Desired outcome: Make them aware of the habit so they stop doing it
Previous attempts: Never formally addressed it — made a joke once, didn't help
```

---

## Update Triggers

- Feedback conversation outcome (accepted / pushed back / relationship changed)
- Person you're giving feedback to changes
- You receive significant new feedback yourself
