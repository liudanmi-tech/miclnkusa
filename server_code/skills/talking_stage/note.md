# Note: The Talking Stage

## About This Skill
Use when: you're in that early ambiguous phase of texting/talking with someone you like, unsure how they feel, not sure how to move things forward, or anxious about saying or doing the wrong thing.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `how_you_met` | How You Met | ✅ | App / mutual friends / class / work / other — context shapes dynamics |
| `duration` | How Long | ✅ | How long you've been in this talking stage |
| `interaction_frequency` | Frequency | ✅ | Daily texting / occasional / seen in person / only online |
| `your_interest_level` | Your Interest Level | ✅ | Very into them / cautiously interested / not sure yet |
| `their_signals` | Their Signals | ✅ | Consistently warm / hot and cold / hard to read / seems interested but hasn't made a move |
| `what_you_want` | What You Want | ❌ | Want to define things / just enjoy it for now / move toward dating / figure out if it's mutual |

---

## AI Onboarding Script

**Opening:**
> "The talking stage is one of the most exciting — and most anxiety-inducing — parts of dating. Tell me where things are at."

**Questions (only for missing fields):**
1. `how_you_met` missing: "How did you two meet?"
2. `duration` missing: "How long have you been in this in-between phase?"
3. `interaction_frequency` missing: "Are you talking every day, or is it more sporadic? Have you hung out in person yet?"
4. `your_interest_level` missing: "How into this person are you right now?"
5. `their_signals` missing: "How do they seem to you — consistently into it, or hard to read?"
6. `what_you_want` missing: "What are you hoping for — to make things more official, to just keep enjoying it, or to figure out if they feel the same way?"

---

## Sample baseline_text

```
How we met: Matched on Hinge 3 weeks ago
Duration: 3 weeks of daily texting, met for coffee once (went well)
Frequency: Text most days, had one in-person date
My interest: Pretty into them — starting to catch real feelings
Their signals: Warm and responsive over text, initiated the coffee date, but hasn't suggested a second one
What I want: Know if they're as interested as I am, want to move toward actually dating
```

---

## Update Triggers

- Had a defining conversation (DTR, asked them out)
- Got clearer signals in either direction
- Things faded or they went cold
- Moved into official relationship
