# Note: Setting Boundaries with Parents

## About This Skill
Use when: your parents are overstepping into your adult life, you feel guilt or obligation preventing you from saying no, their involvement in your decisions causes stress, or you're trying to establish a healthier dynamic as an adult child.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `main_issue` | Main Issue | ✅ | Unsolicited advice / controlling behavior / guilt-tripping / excessive contact / financial strings attached |
| `your_age_situation` | Your Situation | ✅ | Age, living at home or independently, level of financial dependence |
| `family_culture` | Family Culture | ✅ | Cultural/religious expectations around family closeness and filial duty |
| `parent_personality` | Parent Style | ✅ | Overbearing / well-meaning but intrusive / emotionally manipulative / genuinely doesn't realize |
| `previous_attempts` | What You've Tried | ❌ | Have you tried setting a limit before? What happened? |
| `desired_outcome` | What You Want | ❌ | More space / less guilt / a specific behavior to stop / a different kind of relationship long-term |

---

## AI Onboarding Script

**Opening:**
> "Navigating boundaries with parents is one of the trickiest things — especially when love and obligation get tangled up. Tell me what's going on."

**Questions (only for missing fields):**
1. `main_issue` missing: "What's the most pressing thing — constant advice, them weighing in on your decisions, too much contact, or something else?"
2. `your_age_situation` missing: "Are you living at home or independently? And are you financially dependent on them?"
3. `family_culture` missing: "Does your family have strong cultural or religious expectations about how much adult children should involve their parents?"
4. `parent_personality` missing: "How would you describe how your parents operate — well-meaning but unaware they're crossing a line, or more deliberately controlling?"
5. `previous_attempts` missing: "Have you ever tried to push back or set a limit? How did they respond?"
6. `desired_outcome` missing: "What would a better situation actually look like for you?"

---

## Sample baseline_text

```
Main issue: Mom calls twice a day, comments on every life decision, guilt-trips when I don't visit
My situation: 26, living independently, financially independent — but she uses emotional leverage
Family culture: Chinese family, strong expectation of filial piety; "you owe us" framing is common
Parent style: Well-meaning but genuinely doesn't understand she's overstepping
Previous attempts: Tried to explain once — she cried and said I was abandoning the family
Desired outcome: Reduce calls to a few times a week, stop having my career decisions questioned
```

---

## Update Triggers

- Had a direct conversation with a parent
- Living situation changes (move out, move back, go independent)
- Financial dependence changes
- Relationship dynamic shifts significantly (better or worse)
