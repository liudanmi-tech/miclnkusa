# Note: Coming Out to Family

## About This Skill
Use when: you're thinking about coming out to parents or other family members, you've come out and are navigating the aftermath, you received a difficult reaction, or you're deciding whether and how to come out in a family context where the stakes are high.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `identity` | Identity | ✅ | What you're coming out about — be as specific or broad as you're comfortable with |
| `family_member` | Who You're Telling | ✅ | Parents / siblings / extended family / the whole family at once |
| `family_culture` | Family Culture | ✅ | Cultural, religious, or regional background that shapes their likely response |
| `expected_reaction` | Expected Reaction | ✅ | Accepting / mixed / likely negative / unpredictable / already suspect something |
| `safety_situation` | Safety & Dependence | ✅ | Financial dependence, living at home, physical safety concerns |
| `what_you_need` | What You Need | ❌ | Prepare the conversation / process a reaction / navigate ongoing fallout / just be heard |

---

## AI Onboarding Script

**Opening:**
> "Coming out to family carries a different weight than coming out to friends — the history is longer and the stakes are often higher. You get to do this on your terms and your timeline. Tell me where you are."

**Questions (only for missing fields):**
1. `identity` missing: "What are you coming out about, if you're comfortable sharing?"
2. `family_member` missing: "Who in your family are you thinking about telling?"
3. `family_culture` missing: "What's your family's cultural or religious background? That helps me understand what they may be coming in with."
4. `expected_reaction` missing: "What's your gut feeling about how they'll respond?"
5. `safety_situation` missing: "Are you financially dependent on them or living at home? Is there any concern about your physical safety?"

---

## Sample baseline_text

```
Identity: Bisexual
Who I'm telling: My mom first, then we decide together whether to tell my dad
Family culture: Mexican Catholic family — faith is central; one uncle is openly homophobic
Expected reaction: Mom: uncertain but loves me, will probably come around; Dad: harder, unpredictable
Safety: 23, living independently, financially independent — no safety concerns
What I need: Help thinking through what to say to my mom, and how to handle it if she reacts badly in the moment
```

---

## Update Triggers

- Had the conversation — want to process how it went
- Reaction was better or worse than expected
- Family member's stance evolves over time
- Coming out to another family member next
- Navigating ongoing fallout or continued non-acceptance
