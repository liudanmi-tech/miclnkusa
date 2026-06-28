# Note: Networking as a Student

## About This Skill
Use when: reaching out to professionals on LinkedIn, preparing for career fairs, following up after an informational interview, or trying to build connections in an industry you want to enter.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `goal` | Networking Goal | ✅ | Learn about a field / find internship leads / get a referral / stay in touch with alumni |
| `target_industry` | Target Industry / Role | ✅ | What field or type of role you're trying to break into |
| `current_network` | Current Network | ✅ | Professors / alumni / career center / LinkedIn / family connections |
| `year_in_school` | Year in School | ✅ | Affects urgency and what you're asking for |
| `comfort_level` | Comfort Level | ❌ | Confident / nervous / never done this / worried about being annoying |
| `specific_person` | Specific Target | ❌ | Name, role, or company you're trying to connect with |

---

## AI Onboarding Script

**Opening:**
> "Networking doesn't have to feel transactional or awkward — let me help you approach it in a way that feels natural. Tell me what you're trying to accomplish."

**Questions (only for missing fields):**
1. `goal` missing: "What are you hoping to get out of networking right now — learning about a career path, finding internship leads, or something specific like a referral?"
2. `target_industry` missing: "What industry or type of role are you aiming for?"
3. `current_network` missing: "Who do you already have in your corner — any alumni connections, professors who know people, or a career center you use?"
4. `year_in_school` missing: "What year are you in? That affects how urgent and specific your outreach should be."
5. `comfort_level` missing: "How comfortable are you with reaching out to people you don't know — nervous, or fairly confident?"

---

## Sample baseline_text

```
Goal: Find internship leads at product management roles in tech
Target: Product management / tech industry
Current network: One alumni from my major who works at a startup — haven't reached out yet
Year: Junior (recruiting starts in 2 months)
Comfort level: Nervous — worried about seeming opportunistic
Specific target: A PM at Spotify who spoke at a campus event last month
```

---

## Update Triggers

- Had an informational interview — want to follow up or debrief
- Got a referral or lead
- Career fair coming up
- LinkedIn connection responded (or didn't)
