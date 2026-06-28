# Note: Immigrant Family Dynamics

## About This Skill
Use when: you're navigating the gap between your parents' culture and the one you grew up in, feeling caught between two worlds, dealing with pressure around career/marriage/lifestyle, or trying to bridge communication across a generational and cultural divide.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `your_background` | Your Background | ✅ | Your family's country of origin, how long you've been in the current country |
| `main_tension` | Main Tension | ✅ | Career expectations / marriage pressure / lifestyle judgment / language gap / identity conflict |
| `generation` | Generation | ✅ | First-gen (immigrated yourself) / 1.5-gen (immigrated young) / second-gen (born here) |
| `parents_situation` | Parents' Context | ✅ | Their level of integration, language fluency, whether they understand your life here |
| `your_identity_comfort` | Identity Comfort | ❌ | How settled you feel in navigating your dual identity — comfortable / conflicted / still figuring out |
| `desired_outcome` | What You Need | ❌ | Navigate a specific conversation / process the tension / find language for the gap / just be understood |

---

## AI Onboarding Script

**Opening:**
> "The immigrant family experience is its own specific kind of hard — you're often translating not just language but entire worlds. Tell me about your situation."

**Questions (only for missing fields):**
1. `your_background` missing: "What's your family's background, and roughly how long have you been in this country?"
2. `main_tension` missing: "What's creating the most friction right now — career pressure, relationship expectations, feeling judged for how you live, or something else?"
3. `generation` missing: "Did you immigrate yourself, come as a young child, or were you born here?"
4. `parents_situation` missing: "How much do your parents understand about the life you're actually living here — work culture, social norms, what's expected of young people?"
5. `your_identity_comfort` missing: "How do you feel about navigating both worlds — like you've found your footing, or still feels like a split?"

---

## Sample baseline_text

```
Background: Chinese-American, second-gen — parents immigrated from Fujian in the 90s
Main tension: Parents want me to go to medical or law school; I want to work in UX design — they see it as unstable and unserious
Generation: Second-gen, born in the US
Parents' context: Mom speaks limited English, lives within the Chinese community — her frame of reference is China in the 90s + what neighbors' kids are doing
Identity comfort: Generally settled in who I am, but feel guilt about not fulfilling their sacrifice narrative
What I need: Help navigating the career conversation without it becoming a fight about everything they've sacrificed
```

---

## Update Triggers

- Had a significant conversation with parents about the tension
- Career/life path decision made or changed
- Relationship with parents shifts
- Identity or values evolve
