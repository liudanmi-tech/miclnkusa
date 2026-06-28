# Note: Supporting a Friend in Crisis

## About This Skill
Use when: someone you care about is going through something serious — depression, a breakup, grief, a mental health episode, or a major life blow — and you want to show up for them without saying the wrong thing or burning yourself out in the process.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `what_theyre_going_through` | Their Situation | ✅ | What your friend is experiencing — loss / depression / anxiety / relationship crisis / health issue / trauma |
| `severity` | Severity | ✅ | Struggling but functioning / not coping well / in acute crisis / any safety concerns |
| `your_relationship` | Your Relationship | ✅ | Close friend / acquaintance / family-like / new friendship |
| `what_youve_done` | What You've Done | ✅ | Reached out / been there regularly / unsure what to do / said something that didn't land |
| `your_capacity` | Your Capacity | ❌ | Are you in a place to support someone right now, or is your own bandwidth limited? |
| `desired_outcome` | What You Need | ❌ | Know what to say / know what not to say / figure out how to support without losing yourself |

---

## AI Onboarding Script

**Opening:**
> "Wanting to show up for someone you care about is one of the most generous things. Tell me what's going on with them — and with you."

**Questions (only for missing fields):**
1. `what_theyre_going_through` missing: "What's your friend dealing with?"
2. `severity` missing: "How are they doing — struggling but getting through it, or is it more acute than that?"
3. `your_relationship` missing: "How close are you two — good friends, or someone you know but aren't super tight with?"
4. `what_youve_done` missing: "Have you been in contact with them through this? What have you said or done so far?"
5. `your_capacity` missing: "How are you doing right now? Do you have the bandwidth to support someone, or are you stretched thin yourself?"

---

## Sample baseline_text

```
Their situation: Close friend going through severe depression after a job loss + breakup in the same month
Severity: Not coping well — sleeping all day, barely leaving the apartment, declined therapy twice
My relationship: Best friend of 6 years
What I've done: Check in most days, brought food twice, but don't know what to say when she just says "I'm fine"
My capacity: Doing okay, but starting to feel helpless and a little drained
Desired outcome: Know how to actually help (not just be present) and how to gently encourage professional support
```

---

## Update Triggers

- Friend's situation changes (better, worse, seeks help)
- A specific conversation happened — want to debrief
- Your own capacity changes
- Safety concern arises
