# Marginalia --- 5-Minute Demo Script

**Hard target: 4:30. Absolute max: 5:00.**

**Setup checklist (do 10 min before your slot):**
- [ ] Marginalia app running on iPhone, models loaded, "Ready" on dashboard
- [ ] G2 glasses on, connected (green dot in app)
- [ ] iPhone screen mirroring to projector via AirPlay / cable
- [ ] usemarginalia.com open in Safari tab on iPhone (for Act 3)
- [ ] Volunteer briefed, seated, knows the line

---

## ACT 1: Frame (50 seconds)

> *Walk up. G2 glasses already on --- they look like regular glasses. Nobody notices.*

"Hi, I'm Ben. I'm a Staff TPM at Meta, AR/VR hardware. Before that, six years at Apple.

Here's what I learned building hardware for a billion people: the most valuable conversations in business are the ones that *can't* be recorded.

Attorney-client privilege. Doctor-patient confidentiality. M&A deal rooms. The factory floor at Apple.

These conversations generate billions in value. And cloud AI can't touch any of them --- because the data can't leave the room.

So this weekend I built Marginalia."

> *Pause. Touch glasses frame casually.*

"Let me show you what it does."

---

## ACT 2: Live Demo (2 minutes 30 seconds)

### 2A: Airplane Mode (10 seconds)

> *Hold up iPhone so projector shows the screen.*

"First --- airplane mode."

> *Toggle airplane mode ON. Audience sees the toggle.*

"No WiFi. No cellular. No cloud. Everything you're about to see runs on this phone."

### 2B: The Setup (15 seconds)

"I'm in a 1:1 with my direct report. They're a strong engineer, been working 60-hour weeks on a migration. And they're about to tell me something."

> *Nod to volunteer.*

"Go ahead."

### 2C: The Utterance (10 seconds)

> *Volunteer stands and says, clearly:*

**"I've been feeling burned out. I think I need to take next week off."**

> *Volunteer sits. Beat of silence. You look at the audience.*

"Now watch."

### 2D: Options Appear (20 seconds)

> *Point to iPhone screen on projector. Inference is running.*

"Gemma 4 is reasoning over that audio right now. On this phone. In airplane mode."

> *Options appear on G2 lens. iPhone app shows them too.*

"Three options just appeared on my lens."

> *Read them aloud:*

"Approve --- block the calendar. Counter --- ask about workload. Defer --- send a calendar hold."

### 2E: Ring Tap (15 seconds)

> *Hold up hand with R1 ring.*

"I'm going to approve."

> *Tap ring. Calendar event appears on iPhone screen / projector.*

"Done. Calendar hold created. All on the phone. No server. No cloud. No network."

### 2F: The Line (20 seconds)

> *Take off glasses. Hold them up so audience can see them.*

"My direct report has no idea I just got tactical guidance. The conversation stayed natural. The AI stayed invisible."

> *Put glasses back on. Pause.*

"Cloud AI writes in the main text. **Marginalia writes in the margin.**"

> *Hold for 2 seconds.*

---

## ACT 3: Company (60 seconds)

> *Tap to usemarginalia.com on iPhone --- projector shows the landing page.*

"What you just saw is one product. The company is eight.

Every high-stakes profession gets a fine-tuned Marginalia trained on their domain's privileged data.

**Marginalia Counsel** for attorneys --- trained on deposition transcripts. Cloud AI in a client meeting is a malpractice event.

**Marginalia Clinical** for physicians --- HIPAA prohibits cloud AI with patient audio. Full stop.

**Marginalia Diligence** for deal teams --- material non-public information can't touch a server.

**Marginalia Floor** for manufacturing --- and that's where I start. Six years at Apple gave me the network to put this on factory floors no cloud vendor will ever reach."

> *Pause. Look at the judges.*

"I want a YC interview. **usemarginalia.com**. Thank you."

---

## Timing Checkpoints

| Clock | Cumulative | Beat |
|-------|-----------|------|
| 0:00 | 0:00 | "Hi, I'm Ben" |
| 0:50 | 0:50 | "Let me show you what it does" |
| 1:00 | 1:00 | Airplane mode toggle |
| 1:25 | 1:25 | Volunteer delivers line |
| 1:35 | 1:35 | "Now watch" |
| 1:55 | 1:55 | Options appear, read aloud |
| 2:10 | 2:10 | Ring tap, calendar appears |
| 2:30 | 2:30 | "Marginalia writes in the margin" |
| 2:40 | 2:40 | Start verticals |
| 3:40 | 3:40 | "I want a YC interview" |
| 3:45 | 3:45 | Done |

**You're landing at 3:45 --- full minute of buffer for slowness, fumbles, or audience reaction.**

---

## Fallbacks (memorize all six)

**G2 doesn't connect / no text on lens:**
> "For this room I'm showing the phone screen --- same model, same inference, same options."
> *(Point to iPhone projector. Demo continues with phone UI only.)*

**Inference is slow (>6 seconds):**
> "Gemma 4 is reasoning over the full context --- tone, intent, organizational dynamics. Not just transcribing."
> *(Fill naturally. If >15s, app has dummy mode --- canned response appears silently.)*

**Inference fails / no response:**
> *(Dummy mode returns pre-loaded options. Don't mention it. If even that fails:)*
> "Let me show you what the output looks like ---"
> *(Switch to Chat tab, type the volunteer line manually, generate.)*

**Ring doesn't work:**
> *(Tap temple of glasses instead --- same scroll events. Or:)*
> "I'm selecting option one."
> *(Tap on iPhone screen directly.)*

**Volunteer flubs or doesn't show up:**
> *(Say the line yourself:)*
> "Imagine my direct report just said: 'I'm feeling burned out. I need next week off.'"
> *(Alternatively, pre-record the line and play via iPhone speaker.)*

**AirPlay mirror drops:**
> *(Hold iPhone up directly. YC HQ is small. Everyone can see.)*
> "Technical difficulty with the mirror --- here's the phone."

---

## Pre-recorded Audio Fallback

If no volunteer, record the line on the iPhone:

```bash
# On MacBook, generate and transfer:
say -o /tmp/volunteer.aiff "I've been feeling burned out. I think I need to take next week off."
# Transfer to iPhone via AirDrop, play during demo
```

Or just say the line yourself. The demo works either way.

---

## Night-Before Rehearsal Checklist

- [ ] Run full demo 3 times, time each one
- [ ] Test every fallback at least once
- [ ] Confirm airplane mode doesn't kill BLE (it shouldn't --- BLE stays on)
- [ ] Charge G2 glasses to 100%
- [ ] Charge iPhone to 100%
- [ ] Charge R1 ring to 100%
- [ ] Pre-warm models (open app, let it load, leave running)
- [ ] Know your volunteer's seat location
- [ ] Know where the projector cable / AirPlay receiver is
