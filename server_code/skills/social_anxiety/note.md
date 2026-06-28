# Note: Social Anxiety

## About This Skill
Use when: social situations trigger disproportionate fear or avoidance, you replay conversations afterward looking for what went wrong, you worry intensely about how others perceive you, or anxiety is limiting your social life or professional opportunities.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `main_triggers` | Main Triggers | ✅ | Specific situations that are hardest — large groups / meeting new people / speaking up / being evaluated / small talk |
| `anxiety_pattern` | Anxiety Pattern | ✅ | Pre-event dread / in-the-moment freeze / post-event rumination / avoidance / all of the above |
| `severity` | Severity | ✅ | Manageable but uncomfortable / significantly limiting opportunities / avoiding important things / affecting daily function |
| `physical_symptoms` | Physical Symptoms | ✅ | Blushing / sweating / shaking / blank mind / voice changes / heart racing |
| `current_situation` | Current Situation | ❌ | A specific upcoming event or ongoing challenge |
| `support` | Support | ❌ | In therapy / considering therapy / managing on your own |

---

## AI Onboarding Script

**Opening:**
> "Social anxiety is one of the most common — and most isolating — experiences. You're not alone in it, and it's genuinely workable. Tell me what's going on for you."

**Questions (only for missing fields):**
1. `main_triggers` missing: "What kinds of situations hit hardest — big group events, one-on-one with new people, speaking up in meetings, something else?"
2. `anxiety_pattern` missing: "Does the anxiety hit mostly before, during, or after social situations? Or some combination?"
3. `severity` missing: "How much is this actually limiting you — is it uncomfortable but you manage it, or are you avoiding things that matter because of it?"
4. `physical_symptoms` missing: "Does anxiety show up physically for you — blushing, shaking, sweating, mind going blank?"
5. `current_situation` missing: "Is there something specific coming up that's triggering this, or is it more of an ongoing pattern?"

---

## Sample baseline_text

```
Main triggers: Speaking up in group settings (meetings, classes) and small talk with strangers
Anxiety pattern: Strong pre-event dread + in-the-moment freeze + post-event rumination ("why did I say that?")
Severity: Significantly limiting — avoiding networking events, staying quiet in meetings even when I have something to say
Physical symptoms: Voice shakes when I speak in groups, go blank when put on the spot
Current situation: Big team offsite next month — dreading it
Support: Not in therapy currently — trying to manage on my own
```

---

## Update Triggers

- Faced a feared situation — want to debrief
- Anxiety pattern shifts (better or worse)
- Started or ended therapy
- New triggering situation arises
