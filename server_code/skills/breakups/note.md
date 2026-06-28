# Note: Breakups

## About This Skill
Use when: you're going through a breakup (fresh or ongoing), thinking about ending a relationship, or still processing something that ended a while ago and hasn't fully healed.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `breakup_status` | Status | ✅ | Just happened / happened a while ago / considering breaking up / they broke up with me |
| `relationship_length` | Relationship Length | ✅ | How long you were together |
| `reason` | What Ended It | ✅ | Mutual / fell out of love / cheating / long distance / incompatibility / external pressure |
| `your_state` | Your Current State | ✅ | Devastated / relieved / angry / numb / cycling through all of them |
| `contact_situation` | Contact | ❌ | Still in contact / no contact / have to see them (school, work) |
| `what_you_need` | What You Need | ❌ | Process the feelings / figure out how to move on / understand what happened / cope day-to-day |

---

## AI Onboarding Script

**Opening:**
> "Breakups are genuinely one of the hardest things. There's no timeline you're supposed to be on. Tell me where you are."

**Questions (only for missing fields):**
1. `breakup_status` missing: "Did this just happen, or has it been a while? And were you the one who ended it, or did they?"
2. `relationship_length` missing: "How long were you together?"
3. `reason` missing: "What ended it — or what's making you consider ending it?"
4. `your_state` missing: "How are you doing right now, honestly?"
5. `contact_situation` missing: "Are you still in contact with them, or have you cut things off?"
6. `what_you_need` missing: "What would be most helpful right now — talking through your feelings, figuring out a practical plan, or something else?"

---

## Sample baseline_text

```
Status: They broke up with me 2 weeks ago
Relationship length: 1.5 years
Reason: They said they'd grown apart — said they weren't in love anymore
My state: Devastated, can't stop thinking about it, feel blindsided
Contact: Texted twice after, they responded briefly but said they need space — currently no contact
What I need: Stop the constant ruminating, figure out how to get through the next few weeks
```

---

## Update Triggers

- Significant improvement or setback in how you're processing it
- Contact resumed (they reached out, or you did)
- Considering getting back together
- Starting to feel genuinely ready to move on
