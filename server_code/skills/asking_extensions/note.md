# Note: Asking for Extensions

## About This Skill
Use when: you need more time on an assignment, missed a class or exam due to illness or a personal emergency, or need to negotiate a deadline with a professor or TA.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `reason` | Reason for Request | ✅ | Illness / family emergency / mental health / overloaded / poor time management |
| `assignment_type` | Assignment Type | ✅ | Paper / exam / lab report / presentation / homework |
| `original_deadline` | Original Deadline | ✅ | When it's due |
| `time_needed` | Time Needed | ✅ | How many extra days you're requesting |
| `relationship_with_prof` | Relationship | ❌ | First time asking / have spoken before / TA vs. professor |
| `documentation` | Documentation Available | ❌ | Doctor's note, official notice, or anything to back up the request |

---

## AI Onboarding Script

**Opening:**
> "Asking for an extension can feel uncomfortable, but professors handle these situations more often than you'd think. Let me help you frame it right."

**Questions (only for missing fields):**
1. `reason` missing: "What's the reason you need more time — illness, something that came up in your personal life, or you're just overextended right now?"
2. `assignment_type` missing: "What's the assignment you need more time on?"
3. `original_deadline` missing: "When is it due?"
4. `time_needed` missing: "How much extra time do you think you'd need?"
5. `documentation` missing: "Do you have any documentation — a doctor's note, a note from the dean of students office, or anything similar?"

---

## Sample baseline_text

```
Reason: Hospitalized for two days — just got discharged
Assignment: Research paper (10 pages)
Original deadline: This Friday
Time needed: One week extension
Relationship: Attended class regularly, went to office hours once
Documentation: Discharge summary from the hospital
```

---

## Update Triggers

- Extension granted — update deadline
- Submitted the assignment
- Need to ask again for the same course
- Similar situation with a different professor
