# Note: Burnout Recovery

## About This Skill
Use when: you've been running on empty for too long, lost the ability to find meaning or energy in work that used to matter, feel exhausted in a way that sleep doesn't fix, or are somewhere in the process of recovering from burnout.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `burnout_stage` | Stage | ✅ | Still in it and overwhelmed / beginning to come out / in recovery / preventing recurrence |
| `burnout_source` | Source | ✅ | Overwork / misaligned work / lack of control / poor recognition / values conflict / relationship drain |
| `current_symptoms` | Symptoms | ✅ | Physical exhaustion / emotional numbness / cynicism / inability to concentrate / detachment from things you used to care about |
| `life_context` | Life Context | ✅ | Working full-time / on leave / changed jobs / still in the same environment |
| `recovery_resources` | Recovery Resources | ❌ | Time off / therapy / support network / financial runway to make changes |
| `desired_outcome` | What You Need | ❌ | Get through the next week / build a recovery plan / understand what happened / prevent it next time |

---

## AI Onboarding Script

**Opening:**
> "Burnout is not weakness — it's what happens when the demands on you consistently exceed what you have to give, for too long. Tell me where you are right now."

**Questions (only for missing fields):**
1. `burnout_stage` missing: "Where are you in this — still deep in it, starting to come up for air, or somewhere in recovery?"
2. `burnout_source` missing: "What do you think burned you out — pure overwork, something about the work not feeling right, lack of control, or something else?"
3. `current_symptoms` missing: "How is it showing up right now — physical exhaustion, emotional flatness, cynicism, not being able to concentrate?"
4. `life_context` missing: "Are you still in the same job and environment, or has something changed?"
5. `recovery_resources` missing: "What do you have available to support recovery — time off, any financial flexibility, people around you?"

---

## Sample baseline_text

```
Burnout stage: Still in it — took a week off but came back to the same situation
Burnout source: 18 months of overwork + no autonomy + a manager who doesn't recognize effort
Symptoms: Waking up dreading the day, emotionally numb most of the time, doing work on autopilot
Life context: Still in the same job — changing isn't currently an option
Recovery resources: Some savings; therapist every 2 weeks; partner is supportive
Desired outcome: Survive the next 3 months while actively looking for something new
```

---

## Update Triggers

- Situation changes (job change, leave of absence, new manager)
- Symptoms significantly improve or worsen
- Decision made about next steps
- Returning to work after time off
