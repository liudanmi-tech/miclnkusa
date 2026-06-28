# Note: Coming Out

## About This Skill
Use when: you're thinking about coming out to someone, you've recently come out and want to process how it went, you're navigating a mixed response, or you're figuring out who to tell and when.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `identity` | Identity | ✅ | What you're coming out as — feel free to be as specific or broad as feels right |
| `who_youre_telling` | Who You're Telling | ✅ | Parents / family / friends / a specific person / at work or school |
| `your_confidence` | Your Confidence | ✅ | Solid in your identity / still figuring it out / confident but nervous about their reaction |
| `their_likely_reaction` | Expected Reaction | ✅ | Supportive / uncertain / potentially negative / unpredictable |
| `safety_situation` | Safety | ✅ | Financially / physically dependent on them / safe regardless of outcome |
| `what_you_need` | What You Need | ❌ | Prepare what to say / process a recent coming out / handle a bad reaction / just be heard |

---

## AI Onboarding Script

**Opening:**
> "Coming out is yours to do on your own terms and timeline. There's no right way to do it, and you don't owe anyone any particular explanation. Tell me what's going on."

**Questions (only for missing fields):**
1. `identity` missing: "What are you thinking about coming out about, if you're comfortable sharing?"
2. `who_youre_telling` missing: "Who are you thinking about telling — a parent, a close friend, someone at school?"
3. `your_confidence` missing: "Where are you in terms of your own sense of this — solid, or still working it out?"
4. `their_likely_reaction` missing: "What's your gut feeling about how they'll respond?"
5. `safety_situation` missing: "Are you in a situation where a negative reaction could affect your housing, finances, or physical safety?"

---

## Sample baseline_text

```
Identity: Gay (out to close friends, not to family)
Who I'm telling: My parents — have been putting it off for a year
My confidence: Solid in who I am, nervous about their reaction
Expected reaction: Dad is harder to read; mom has made some comments that could go either way
Safety: 19, in college, financially somewhat dependent on them through school
What I need: Help thinking through what I want to say and how to handle a difficult reaction
```

---

## Update Triggers

- Had the conversation — want to process how it went
- Reaction was significantly better or worse than expected
- Decided to wait — new thinking on timing
- Want to come out to someone else now
