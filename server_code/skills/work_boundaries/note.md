# Note: Work Boundaries

## About This Skill
Use when: work is bleeding into personal time, you're being piled with extra tasks, you can't say no to unreasonable requests, or you're running on emotional empty.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `main_boundary_issue` | Main Boundary Problem | ✅ | The most obvious boundary violation you're experiencing |
| `current_work_hours` | Actual Hours Worked | ✅ | Average daily/weekly hours |
| `company_culture` | Overtime Culture | ✅ | Mandated overtime / unspoken pressure / relatively flexible |
| `desired_boundary` | Boundary You Want | ❌ | The one thing you most want to change |
| `fear_of_consequence` | Concerns | ❌ | What you're afraid will happen if you set limits |

---

## AI Onboarding Script

**Opening:**
> "Before we work on setting boundaries, I want to understand your current situation and the main pressure points."

**Questions (only for missing fields):**
1. `main_boundary_issue` missing: "What's the most boundary-crossing thing happening right now? After-hours messages, getting buried under extra tasks, or something else?"
2. `current_work_hours` missing: "How many hours are you typically working per day? Do you have a regular end time?"
3. `company_culture` missing: "Is the overtime culture an actual requirement at your company, or are some people just choosing to grind harder?"
4. `desired_boundary` missing: "If you could change just one thing, what would it be?"
5. `fear_of_consequence` missing: "What's your biggest fear about setting a boundary? Hurting your promotion chances, or people seeing you as not committed?"

---

## Sample baseline_text

```
Main problem: Frequent messages after hours, pulled into urgent requests on weekends
Actual hours: Average 12 hours/day, basically always working on weekends
Company culture: No official requirement to stay late, but people who don't get passed over for promotions
Desired boundary: No work messages in the 2 hours after work, fully off on weekends
Concerns: Worried about being seen as having a bad attitude, affecting year-end review
```

---

## Update Triggers

- Working hours change significantly (more or less)
- Role or department change
- Successfully set (or failed to set) a boundary
- Career goals shift (desire for promotion increases or decreases)
