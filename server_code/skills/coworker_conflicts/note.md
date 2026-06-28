# Note: Coworker Conflicts

## About This Skill
Use when: you have friction with a colleague, someone took credit for your work, there's a backstabbing dynamic, communication has broken down, or a project collaboration has created tension.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `conflict_description` | Conflict Description | ✅ | What the core friction is and what happened |
| `relationship_type` | Relationship Type | ✅ | Peer / collaborator from another team / rival / former colleague |
| `conflict_duration` | Duration | ✅ | Single incident vs. ongoing pattern |
| `desired_outcome` | Desired Outcome | ❌ | Repair relationship, solve the problem, or keep distance |
| `escalation_considered` | Considering Escalation | ❌ | Whether you're thinking of involving a manager or HR |

---

## AI Onboarding Script

**Opening:**
> "Workplace relationships are complicated — tell me what happened, and let's figure out how to handle it."

**Questions (only for missing fields):**
1. `conflict_description` missing: "Can you walk me through specifically what happened?"
2. `relationship_type` missing: "What's your relationship with this person? Direct peer, someone from another team you collaborate with, or is there some competition between you?"
3. `conflict_duration` missing: "Was this a one-time thing, or has it been building for a while?"
4. `desired_outcome` missing: "How do you want this to end up? Do you want to repair things with them, or just resolve the immediate issue and create some distance?"

---

## Sample baseline_text

```
Conflict: Colleague presented my proposal in the debrief as if it were their idea — manager praised them for it
Relationship: Peer, same project team
Duration: Second time it's happened — let the first one go, can't let this one slide
Desired outcome: Let them know this isn't okay, repair the working relationship, avoid public confrontation
Escalation: Not yet — want to try direct conversation first
```

---

## Update Triggers

- Conflict resolved or escalated
- Person leaves the team or company
- New collaboration begins
- Fresh friction with the same person
