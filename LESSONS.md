# LESSONS

- 13.11.2026: written without compiling on the Mac (rule: GitHub compiles); the workflow run is the check.
- Messages are copies per recipient, each with its own seq; an "all" send dedupes on id + recipient.
- 13.11.2026 (v2): v1 reported "delivered via typed" for a Mac tab whose `hub watch` was running; the message was lost (never typed, inbox empty because it was marked delivered at send time). Rule now: delivered means READ (inbox fetched or watch acked). Watch and typing only notify; the inbox is the source of truth. Every delivery decision is in log.jsonl (decision, typing, ack, watch-open, watch-close) so a missed watch can be traced.
