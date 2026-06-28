# Note: Friendship Conflicts

## About This Skill
Use when: a friendship has hit a rough patch, someone you're close to said or did something hurtful, there's a drift you want to address, or you're dealing with a toxic dynamic and not sure what to do.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `conflict_type` | Type of Conflict | ✅ | Single incident / ongoing pattern / slow drift / toxic dynamic / one-sided effort |
| `friendship_length` | Friendship Length | ✅ | How long you've been friends |
| `what_happened` | What Happened | ✅ | Specific incident or pattern that's at the center of this |
| `current_status` | Current Status | ✅ | Still talking normally / awkward tension / not speaking |
| `desired_outcome` | What You Want | ✅ | Repair it / set limits / end it / understand it |
| `have_you_said_anything` | Have You Said Anything | ❌ | Whether you've brought it up, and how it went |

---

## AI Onboarding Script

**Opening:**
> "Friendship conflicts can be harder than romantic ones — sometimes even harder to talk about. Tell me what's going on."

**Questions (only for missing fields):**
1. `conflict_type` missing: "Is this about something specific that happened, or is it more of a pattern that's been building?"
2. `friendship_length` missing: "How long have you known each other?"
3. `what_happened` missing: "What actually happened — or what's the pattern that's making you feel like something needs to change?"
4. `current_status` missing: "Where are things between you right now — still acting normal on the surface, or is there obvious tension?"
5. `desired_outcome` missing: "What do you want here — to fix it, to say something for yourself even if nothing changes, to pull back, or to end it?"

---

## Sample baseline_text

```
Conflict type: Single incident that revealed a pattern
Friendship length: 4 years — close friends, see each other weekly
What happened: At a party, they made a dismissive joke about my anxiety in front of other people. Later apologized, but said "you're too sensitive" when I tried to explain why it hurt
Current status: Talking, but I've pulled back — they haven't seemed to notice
Desired outcome: I want to address it properly and not just let it fester — but I also want to be heard, not talked out of my feelings again
Have I said anything: Yes — the initial conversation went badly
```

---

## Update Triggers

- Had the conversation — want to debrief
- Friendship status changed (repaired, ended, or still drifting)
- New incident with the same person
- Realized you want something different from what you first said
