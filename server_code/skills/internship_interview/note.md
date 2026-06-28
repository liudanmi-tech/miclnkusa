# Note: Internship Interviews

## About This Skill
Use when: preparing for an internship interview, doing mock practice, debriefing after a rejection, or navigating the campus recruiting process for the first time.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `target_role` | Target Role | ✅ | Type of internship and industry (e.g., software engineering, marketing, finance) |
| `year_in_school` | Year in School | ✅ | Freshman / sophomore / junior / senior — affects what experience is expected |
| `key_experience` | Relevant Experience | ✅ | Classes, projects, previous jobs, clubs — anything relevant to the role |
| `known_weakness` | Concern Areas | ❌ | What you're worried about being asked — limited experience, GPA, gaps |
| `interview_stage` | Stage | ❌ | Applied / screening / first round / final round / waiting |
| `company_type` | Company Type | ❌ | Big tech / startup / consulting / finance / government / nonprofit |

---

## AI Onboarding Script

**Opening:**
> "Internship recruiting can feel high-stakes, but it's also very learnable. Tell me about what you're going for and where you are in the process."

**Questions (only for missing fields):**
1. `target_role` missing: "What kind of internship are you going for — software, business, research, something else?"
2. `year_in_school` missing: "What year are you in school?"
3. `key_experience` missing: "What's the most relevant thing on your resume — a class project, a club, a previous job, anything that connects to this role?"
4. `known_weakness` missing: "What are you most worried the interviewer might ask about — limited experience, GPA, why this industry?"
5. `interview_stage` missing: "Have you applied, or do you already have an interview scheduled?"

---

## Sample baseline_text

```
Target role: Software engineering intern (big tech, summer)
Year: Junior
Relevant experience: Two class projects in Python/React, teaching assistant for intro CS, no previous internship
Concern: No prior internship experience — worried about "tell me about a time you..." behavioral questions
Stage: Have a phone screen next week with Company X
Company type: Large tech company
```

---

## Update Triggers

- Completed an interview — want to debrief
- Received or declined an offer
- Moved to the next round
- Switched target companies or roles
