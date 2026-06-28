# Note: Job Interviews

## About This Skill
Use when: preparing for a job interview, doing mock practice, debriefing after an interview, or figuring out timing around an offer.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `target_role` | Target Role | ✅ | Job title + industry / company type |
| `years_experience` | Work Experience | ✅ | Total years + years in relevant field |
| `key_strengths` | Key Strengths | ✅ | 2–3 most standout skills or experiences |
| `known_weakness` | Known Weakness | ❌ | Blind spots likely to come up in the interview |
| `salary_range` | Salary Expectations | ❌ | Target range — helps with offer negotiation timing |
| `interview_stage` | Current Stage | ❌ | Round 1 / Round 2 / Final / Waiting / Have offer |

---

## AI Onboarding Script

**Opening:**
> "Let's get you ready for this interview! Tell me a bit about your situation so my advice is actually useful."

**Questions (only for missing fields):**
1. `target_role` missing: "What role are you interviewing for, and what kind of company is it?"
2. `years_experience` missing: "How many years have you been working? How long in this specific area?"
3. `key_strengths` missing: "What are 2–3 strengths you'd highlight about yourself?"
4. `known_weakness` missing: "Is there anything you're worried the interviewer might probe on?"
5. `interview_stage` missing: "Are you preparing for an upcoming interview, actively in the process, or already considering an offer?"

---

## Sample baseline_text

```
Target role: Backend Engineer (large tech company, payments/fintech)
Work experience: 5 years total (4 years backend, 2 years in payments)
Key strengths: Strong system design, real-world high-concurrency experience, reliable delivery
Known weakness: Algorithms are average — tend to get stuck on LeetCode Hard
Salary expectations: $170–200K, walk-away at $155K
Current stage: Passed round 1 at Company X, preparing for round 2
```

---

## Update Triggers

- Interview outcome (passed, rejected, received offer)
- Switched target companies or roles
- Salary expectations changed
- Post-interview debrief surfaces a new weakness
