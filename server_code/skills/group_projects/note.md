# Note: Group Projects

## About This Skill
Use when: managing a group project, dealing with teammates who don't pull their weight, navigating conflict over direction or workload, or trying to make a team actually work.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `main_problem` | Main Problem | ✅ | Uneven workload / communication breakdown / conflict over direction / social loafing |
| `team_size` | Team Size | ✅ | Number of people, including you |
| `deadline` | Deadline | ✅ | When the project is due |
| `your_role` | Your Role | ✅ | Designated leader / informal leader / contributor / trying to avoid the mess |
| `course_stakes` | Stakes | ❌ | Weight of the project in your final grade |
| `professor_involvement` | Instructor Involvement | ❌ | Whether the instructor is aware or involved in team dynamics |

---

## AI Onboarding Script

**Opening:**
> "Group projects can be rough. Tell me what's going on and we'll figure out the best path forward."

**Questions (only for missing fields):**
1. `main_problem` missing: "What's the core issue — someone not doing their share, the group can't agree on direction, communication has fallen apart, or something else?"
2. `team_size` missing: "How many people are in the group?"
3. `deadline` missing: "When is this due?"
4. `your_role` missing: "Are you the official group lead, or has someone else taken charge? Or is no one really leading?"
5. `course_stakes` missing: "How much of your grade is this project worth?"

---

## Sample baseline_text

```
Main problem: One member hasn't contributed anything in 2 weeks, doesn't respond to messages
Team size: 4 people
Deadline: 3 weeks away
My role: Unofficial leader — coordinating, but no formal authority
Stakes: 40% of final grade
Instructor involvement: None so far — trying to handle internally first
```

---

## Update Triggers

- Project submitted
- Team conflict escalates (brought to instructor)
- Member drops the course or leaves the group
- Project direction changes significantly
