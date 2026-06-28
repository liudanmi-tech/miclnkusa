# Note: Making Friends in College

## About This Skill
Use when: feeling isolated or lonely on campus, struggling to move from acquaintance to actual friend, trying to find your people, or navigating social anxiety in new environments.

---

## Baseline Fields

| Field | Label | Required | Description |
|-------|-------|----------|-------------|
| `current_situation` | Current Situation | ✅ | New student / transferred / friend group fell apart / naturally introverted / socially anxious |
| `what_you_ve_tried` | What You've Tried | ✅ | Clubs, dorm events, classes, apps — what has or hasn't worked |
| `social_comfort_level` | Social Comfort | ✅ | Comfortable initiating / awkward but trying / anxious / prefer one-on-one over groups |
| `campus_involvement` | Campus Involvement | ❌ | Clubs, sports, jobs, organizations you're currently in |
| `what_you_re_looking_for` | What You Want | ❌ | Study friends / hangout crew / deep connections / just not feeling so alone |

---

## AI Onboarding Script

**Opening:**
> "Making friends in college is genuinely hard — especially after the first few weeks when everyone stops introducing themselves. Tell me where you're at."

**Questions (only for missing fields):**
1. `current_situation` missing: "What's your situation right now — are you a freshman, a transfer, or someone who's been here a while but hasn't quite found their people yet?"
2. `what_you_ve_tried` missing: "Have you tried anything so far — clubs, dorm events, talking to classmates? What's worked or not worked?"
3. `social_comfort_level` missing: "How do you feel in social situations — comfortable starting conversations, or more of a watcher-and-waiter?"
4. `what_you_re_looking_for` missing: "What kind of connection are you looking for — just people to study with, a group to hang out with, or something deeper?"

---

## Sample baseline_text

```
Situation: Sophomore, transferred last semester — didn't come in with a friend group
What I've tried: Went to a few club info sessions, chatted with some classmates, but nothing stuck beyond surface level
Social comfort: A bit anxious in big groups, much better one-on-one
Current involvement: Joined a photography club but only went twice
Looking for: A small group to actually hang out with, not just study partners
```

---

## Update Triggers

- Made a meaningful connection (plans with someone, friendship progressing)
- Tried a specific approach — want to debrief
- Social context changes (moved, new semester, club change)
- Feeling significantly better or worse about social life
