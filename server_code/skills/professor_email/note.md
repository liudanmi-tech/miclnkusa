# Note: Emailing Professors

## About This Skill
Use when: reaching out to a professor for the first time, asking for help, requesting a recommendation letter, following up after an exam, or navigating a sensitive academic conversation.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `email_purpose` | Purpose | ✅ | Ask a question / request a rec letter / clarify grade / discuss research / ask for extension |
| `relationship_with_prof` | Relationship | ✅ | Never spoken / attended a few times / office hours regular / research contact |
| `course_name` | Course/Context | ✅ | Which class or context this is about |
| `tone_needed` | Tone | ❌ | Formal / semi-formal / casual (depends on the professor) |
| `urgency` | Urgency | ❌ | Deadline or time-sensitivity involved |

---

## AI Onboarding Script

**Opening:**
> "Emailing a professor can feel stressful — let me help you get the tone and content right. Tell me a bit about the situation."

**Questions (only for missing fields):**
1. `email_purpose` missing: "What do you need to reach out about? A question about the material, asking for a recommendation, something about your grade, or research?"
2. `relationship_with_prof` missing: "Have you talked to this professor before — during office hours, after class, or through a research context?"
3. `course_name` missing: "Which class or project is this for?"
4. `urgency` missing: "Is there a deadline involved, or are you just trying to make a good impression?"

---

## Sample baseline_text

```
Purpose: Request a recommendation letter for a summer research program
Relationship: Took their PSYC 302 class last semester — went to office hours twice
Course: PSYC 302 — Research Methods
Tone: Semi-formal (professor seems approachable)
Urgency: Deadline is 3 weeks away
```

---

## Update Triggers

- Sent the email, waiting for a response
- Professor replied — follow-up needed
- Request was completed (letter submitted, meeting scheduled)
- New email needed for a different professor or purpose
