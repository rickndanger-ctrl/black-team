# Context-controller experiment — 2026-10-10

This tests the proposed context controller: have a small decision model choose **when** to
keep context, retrieve an older reference, compact older turns, or request review.
It is separate from the earlier Cabinet task-answering pilot.

All inputs are synthetic token counts and fabricated reference flags. No chats,
project files, account details or private excerpts are used. Existing helper
services/settings are unchanged. The provider receives no expected label or case
ID. Every case is repeated with its options reversed.

| Path | Completed | Correct choices | Accepted at 0.85 | Option-order disagreements |
|---|---:|---:|---:|---:|
| Fixed reference policy | 48/48 | 48/48 | 48 | 0/24 pairs |
| Hosted JEV | 0/48 | Not measured | Not measured | Not measured |
| Installed local Laya, first 8 scenarios | 16/16 | 7/16 | 0 | 6/8 pairs |

The baseline implements the specified policy, so its perfect score is a
consistency check, not independent proof of conversation quality. JEV failed on
its first attempt with `JevError`; the runner stopped hosted calls and marked the
remaining cases skipped. There is **no JEV accuracy or latency conclusion**.
Laya's median call time was approximately 0.961 seconds, including the cold call
in the sample. Its runtime warned about inherited calibration. Zero accepted
decisions means it would always fall back at this threshold; zero accepted errors
does not demonstrate useful control.

The next JEV test should rerun this exact fixture on a network-capable desktop.
Then measure source retention and final answers with actual local retrieval and
summary operations. These policy fixtures supply the older-reference flag; they
do not test whether a model can discover relevant older information from raw text.

Current action: keep the deterministic local controller active, surface its token
budget/omissions in Companion, and leave experimental providers outside live chat.
Training is not started and these evaluation records are not approved training
labels. A trained selector needs held-out families, independent outcome checks,
calibration, order-sensitivity tests and local fallback.

Reproduction from the source directory:

```sh
python3 scripts/context_experiment.py --provider baseline --output benchmarks/context-baseline.json
/path/to/dog-walker/.venv/bin/python scripts/context_experiment.py --provider jev --adapter-root /path/to/dog-walker --output benchmarks/context-jev.json
/path/to/dog-walker/.venv/bin/python scripts/context_experiment.py --provider laya --adapter-root /path/to/dog-walker --limit 8 --output benchmarks/context-laya.json
```

`--provider jev` explicitly makes a hosted request using an explicitly supplied private Black Team research key
and adapter; credentials are never printed or copied. Results contain
only synthetic fixtures, validated distributions, timings and safe error types.
