# Note: Academic Burnout

## About This Skill
Use when: you feel mentally exhausted from studying, lost your motivation completely, are going through the motions without actually learning, or feel like you're falling apart under academic pressure.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `burnout_symptoms` | Symptoms | ✅ | Exhaustion / loss of motivation / cynicism / inability to concentrate / physical symptoms |
| `main_stressor` | Main Stressor | ✅ | Course load / grades pressure / career anxiety / perfectionism / family expectations |
| `current_academic_status` | Current Status | ✅ | Keeping up / falling behind / already missed things / on academic probation |
| `support_available` | Support Available | ❌ | Do you have people to lean on? Counseling available? |
| `immediate_deadline` | Immediate Pressure | ❌ | Any urgent deadlines or exams in the next 2 weeks |

---

## AI Onboarding Script

**Opening:**
> "What you're feeling is real, and you're not alone in it. Tell me what's been going on — let's figure out what's piling up and where you need relief."

**Questions (only for missing fields):**
1. `burnout_symptoms` missing: "How is this showing up for you — total exhaustion, can't make yourself care, trouble focusing, or something physical like not sleeping?"
2. `main_stressor` missing: "If you had to point to the biggest source of pressure, what is it? Keeping up with coursework, grades anxiety, not knowing what you're doing it for?"
3. `current_academic_status` missing: "Are you more or less keeping up with your classes, or have things started slipping — missed assignments, skipped exams?"
4. `immediate_deadline` missing: "Is there anything due in the next couple of weeks that feels like it's hanging over you?"

---

## Sample baseline_text

```
Symptoms: Can't motivate myself to study, everything feels pointless, sleeping way too much
Main stressor: Pre-med pressure + fear that I chose the wrong path
Current status: Behind in two classes, missed one quiz
Support: Have a therapist at the campus counseling center (only every 3 weeks)
Immediate deadline: Midterm in 10 days
```

---

## Update Triggers

- Finished the acute high-pressure period (exams over)
- Sought additional support (counseling, accommodations)
- Major change in academic plans (drop a class, change major)
- Burnout symptoms significantly improving or worsening
