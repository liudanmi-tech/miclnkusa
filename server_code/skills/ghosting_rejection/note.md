# Note: Ghosting & Rejection

## About This Skill
Use when: someone stopped responding without explanation, you were rejected and are processing it, you're thinking about whether to reach out again, or you need to reject someone and don't know how.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `situation_type` | Situation | ✅ | Was ghosted / was rejected / need to ghost or reject someone |
| `context` | Context | ✅ | How long you'd been talking, how many dates, how serious it felt |
| `what_happened` | What Happened | ✅ | How communication stopped or how the rejection happened |
| `your_reaction` | Your Reaction | ✅ | Confused / hurt / angry / surprisingly fine / obsessing |
| `considering_reaching_out` | Considering Reaching Out | ❌ | Whether you're tempted to send a follow-up message |
| `desired_outcome` | What You Need | ❌ | Closure / process the feelings / figure out how to move on / practical advice on what to do next |

---

## AI Onboarding Script

**Opening:**
> "Getting ghosted or rejected genuinely hurts — there's nothing irrational about that. Tell me what happened."

**Questions (only for missing fields):**
1. `situation_type` missing: "Were you the one who got ghosted or rejected, or is this about a situation where you need to turn someone down?"
2. `context` missing: "How long had you been talking or seeing each other? Did it feel like something was building?"
3. `what_happened` missing: "What exactly happened — did they just stop replying, or was there an actual conversation where things ended?"
4. `your_reaction` missing: "How are you feeling about it right now?"
5. `considering_reaching_out` missing: "Are you thinking about reaching out to them again?"

---

## Sample baseline_text

```
Situation: Was ghosted
Context: Had been talking for 5 weeks, went on 3 dates — it felt like it was going somewhere
What happened: After the third date (which seemed to go fine), they just went quiet — no response to my last two messages over 10 days
My reaction: Confused and a bit hurt, keeps replaying the last date wondering what went wrong
Considering reaching out: Thinking about sending one more message — can't decide
Desired outcome: Figure out whether to reach out, and how to stop ruminating
```

---

## Update Triggers

- Decided to reach out (or not) — want to debrief outcome
- Got a response (closure or not)
- Feeling significantly better
- Similar situation happens again
