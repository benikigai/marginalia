# Volunteer Briefing Card

## Your role
You are my direct report — a senior engineer who's been working 60-hour weeks.

## Your line (say this EXACTLY)
> "I've been feeling burned out. I think I need to take next week off."

## Instructions
1. When I point to you and say "Go ahead" — stand up
2. Say the line at **normal speaking pace** — not too fast, not too slow
3. Natural tone — you're tired, not dramatic
4. One take. Then sit down.
5. That's it. Thank you.

## Timing
- You speak for about 5 seconds
- Pause after you finish — I'll handle the rest
- Do NOT ad-lib or add extra context

## If something goes wrong
- If I say "Can you repeat that?" — say the exact same line again
- If the demo seems stuck — just stay seated, I'll handle it

---

## Fallback: Pre-recorded Audio
If no volunteer is available, pre-record the line:

```bash
# On MacBook, record yourself saying the line:
say -o /tmp/volunteer.aiff "I've been feeling burned out. I think I need to take next week off."
ffmpeg -i /tmp/volunteer.aiff -ar 16000 -ac 1 -f s16le /tmp/volunteer.pcm

# During demo, play through MacBook speakers:
afplay /tmp/volunteer.aiff
```

The G2 mic picks it up from ambient, or use the MacBook mic fallback.
