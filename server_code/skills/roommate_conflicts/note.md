# Note: Roommate Conflicts

## About This Skill
Use when: dealing with friction over chores, noise, guests, shared spaces, sleep schedules, or any tension with a roommate in a dorm, apartment, or shared house.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `conflict_type` | Type of Conflict | ✅ | Chores / noise / guests / sleep schedule / shared costs / personal habits |
| `living_situation` | Living Situation | ✅ | Dorm / off-campus apartment / whether you chose to live together |
| `conflict_duration` | Duration | ✅ | Recent incident vs. ongoing pattern |
| `relationship_quality` | Current Relationship | ✅ | Friendly / neutral / tense / barely speaking |
| `desired_outcome` | Desired Outcome | ❌ | Resolve it / set clearer rules / just vent |
| `lease_situation` | Lease Situation | ❌ | When it ends, or whether moving out is an option |

---

## AI Onboarding Script

**Opening:**
> "Living with someone is never simple. Tell me what's going on and we'll figure out the best way to handle it."

**Questions (only for missing fields):**
1. `conflict_type` missing: "What's the main issue? Chores not getting done, noise at night, people coming over, money for shared expenses, or something else?"
2. `living_situation` missing: "Are you in a dorm or an off-campus place? Did you know this person before you moved in?"
3. `conflict_duration` missing: "Has this been a recurring problem, or did something specific happen recently?"
4. `relationship_quality` missing: "How are things between you two right now — still on speaking terms, or has it gotten cold?"
5. `desired_outcome` missing: "What would a good resolution look like to you? A clear agreement going forward, or just clearing the air?"

---

## Sample baseline_text

```
Conflict type: Roommate leaves dishes in the sink for days and plays games loudly after midnight
Living situation: Off-campus apartment, 2-person lease — didn't know them before, matched by the school
Duration: Been building for 2 months, had one awkward conversation that didn't really go anywhere
Relationship: Polite on the surface but tension underneath
Desired outcome: Set some ground rules, don't want things to blow up
Lease situation: Lease runs through May — moving out isn't realistic
```

---

## Update Triggers

- Conflict resolved or escalated (involved RA or property manager)
- One roommate moves out
- New roommate moves in
- Living situation changes (move off-campus, new lease)
