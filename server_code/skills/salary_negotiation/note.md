# Note: Salary Negotiation

## About This Skill
Use when: negotiating a raise with your current employer, discussing compensation before accepting a new offer, or pushing for a promotion after a performance review.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `work_years` | Years of Experience | ✅ | Total years worked + years in current field |
| `current_salary` | Current Salary | ✅ | Monthly/annual, including structure (base + bonus) |
| `target_salary` | Target Salary | ✅ | Desired range + your walk-away number |
| `competing_offer` | Competing Offers | ❌ | Other offer amounts or interview progress |
| `company_type` | Company Type | ❌ | Large corp/mid-size/startup — affects salary flexibility |
| `risk_tolerance` | Willingness to Leave | ❌ | Whether you'd leave if negotiation fails — affects leverage |

---

## AI Onboarding Script

On first activation, retrieve a draft from KG, present it to the user for confirmation, then fill in missing fields:

**Opening:**
> "Before I help you build a negotiation strategy, I need to understand your situation. I've pulled together some details from our previous conversations — please confirm whether they're accurate, and fill in anything I'm missing."

**Questions (only for missing fields):**
1. `work_years` missing: "How many years have you been working? What's your main area?"
2. `current_salary` missing: "What's your current salary range — monthly or annual? Do you have a bonus?"
3. `target_salary` missing: "What number are you aiming for? Do you have a walk-away number?"
4. `competing_offer` missing: "Do you have any other offers or active interviews? (No worries if not.)"
5. `risk_tolerance` missing: "If this negotiation doesn't go well, would you consider leaving?"

---

## Sample baseline_text

```
Years of experience: 5 years (backend engineer, payments focus)
Current salary: $120K/year (base only, no bonus)
Target salary: $155–165K, walk-away at $140K
Competing offer: Offer from Company X at $150K (pending signing)
Company type: Mid-size tech, moderate salary flexibility
Willingness to leave: Yes, but prefer to stay
```

---

## Update Triggers (detect state_change on exit)

Prompt user to confirm a baseline update if the conversation includes:
- Completed salary negotiation, salary has changed
- Changed jobs / joined a new company
- Received or rejected an offer
- Revised salary target
