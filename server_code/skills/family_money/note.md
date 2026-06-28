# Note: Family & Money

## About This Skill
Use when: there's tension around money in your family — parents supporting adult children, lending money to relatives, unequal inheritance, financial secrets, pressure to send remittances, or money being used as control.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `money_dynamic` | Money Dynamic | ✅ | Parents supporting you / you supporting parents / sibling inequality / family loans / inheritance conflict / remittances |
| `your_financial_situation` | Your Finances | ✅ | Whether you're financially stable, struggling, or dependent |
| `family_culture` | Family Culture | ✅ | Cultural norms around financial obligation, privacy, and family pooling |
| `current_tension` | Current Tension | ✅ | What the active friction is right now |
| `power_dynamic` | Power Dynamic | ❌ | Whether money is being used as leverage or control |
| `desired_outcome` | What You Want | ❌ | Set a limit / have a conversation / understand your options / process the stress |

---

## AI Onboarding Script

**Opening:**
> "Money and family is one of the most loaded combinations there is. Tell me what's going on — there's no judgment here."

**Questions (only for missing fields):**
1. `money_dynamic` missing: "What's the basic dynamic — are your parents supporting you, are you expected to contribute to them, is there a loan or inheritance issue, or something else?"
2. `your_financial_situation` missing: "How are you doing financially right now — stable, stretched, or struggling?"
3. `family_culture` missing: "Does your family have strong expectations around financial obligation — like the expectation that you'd support parents or contribute to the family when you earn?"
4. `current_tension` missing: "What's the active issue right now — a specific ask, an ongoing dynamic, or a resentment that's been building?"
5. `power_dynamic` missing: "Is money being used in any way as leverage — like financial support that comes with strings attached?"

---

## Sample baseline_text

```
Money dynamic: Parents paid for college; now expect significant financial contribution back — they've started asking for monthly transfers
My finances: First job, 8 months in, covering my own living in a high cost-of-living city — money is tight
Family culture: Chinese family; supporting parents financially when you're earning is considered expected, not optional
Current tension: Mom mentioned $500/month; I can't afford it without going into debt, but feel ashamed to say so
Power dynamic: Not explicit control, but "after everything we've done" framing creates strong guilt pressure
Desired outcome: Have an honest conversation about what I can actually afford without it becoming a referendum on my gratitude
```

---

## Update Triggers

- Had the conversation — outcome to debrief
- Financial situation changes (raise, job loss, expenses change)
- Family's financial needs change
- Decision made about an amount or arrangement
