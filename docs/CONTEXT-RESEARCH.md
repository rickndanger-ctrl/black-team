# Black Team context management: JEV and Laya review

Initially reviewed 2026-10-10. This is an engineering investigation and proposed experiment,
not an enabled integration or a trained model. No JEV inference requests were
made during the initial review. A subsequent user-authorized synthetic experiment
is recorded in `benchmarks/CONTEXT-RESULTS.md`: JEV returned no decision and local
Laya completed 16 trials. No private inputs were uploaded, no retired services
were reenabled, and no weights were changed. The component installed in the existing
project is **Laya**; “Layla” is understood to refer to it.

## Recommendation

Build local token budgeting and recoverable conversation history first. Evaluate
Laya later as a small selector of context actions. A JEV-assisted teacher/student
experiment is technically feasible for those bounded actions; it is not a proven
replacement for context budgeting, retrieval or a text summarizer. Keep hosted
JEV outside the default customer runtime. A student can eventually ship and work
offline without its hosted teacher.

| Approach | Useful work | Limits | Recommended role |
| --- | --- | --- | --- |
| Deterministic local policy | Count tokens, preserve current instructions, keep recent turns, select source excerpts within a budget | Fixed heuristics can miss relevance; needs clear omission reporting and retrieval | Required foundation and fallback |
| JEV | Choose among supplied context actions using a compact evidence record | Hosted request, connection dependency, additional latency; choices do not produce summaries | Optional research teacher on synthetic/public examples |
| Current local Laya | Score a few candidate actions in one local inference pass | Small input window; existing probabilities are not calibrated for Black Team; adds runtime/weight dependencies | Experimental selector after held-out evaluation |
| Main local language model | Produce a structured summary of older turns when necessary | Adds inference and can omit or invent details | Optional local compaction, with source references and original history retained |

The model helper chooses a policy; trusted application code enforces the token
budget and permissions. It must never remove pinned requirements, approve tool
actions, erase the source transcript or declare work verified.

## What is installed and what it actually does

The existing `dog-walker` project pins `laya==0.4.1` and the checkpoint
`convaiinnovations/laya-typed-decisions` at revision
`e929ae5cf69bc34259cd2f95c9e91145b818b1f0`. Local `rl_agent_config.json`
specifies `answerdotai/ModernBERT-large`, a two-layer decision head,
`max_len: 1024`, `head_max_len: 256`, and `max_prefixes: 6`. The checkpoint file is
approximately 804 MiB, before Python/PyTorch and runtime memory.

`dog_walker/judge.py` loads verified local files on CPU with two Torch threads and
offline Hugging Face/Transformers settings. It rejects questions over 200 tokens
and state-plus-question-plus-margin over 1,000 tokens. It also rejects detected
truncation. That conservative boundary is appropriate: silently dropping a
constraint can reverse a decision.

Laya returns typed classification results; it does not generate a prose summary.
The publisher identifies this checkpoint as a 421M-parameter English specialist
trained for four workflow families, with a 1,024-token limit. The model card also
acknowledges problematic calibration inheritance and fitting on training examples;
its confidence values should be recalibrated on separate domain data.
[Publisher model card](https://huggingface.co/convaiinnovations/laya-typed-decisions)

The installed `dog_walker/routing.py` already has an applicable small prototype:
it chooses `project_map`, `project_search` or `none`. Search is available only for
one explicit safe filename; only previously granted tools are candidates. Results
are bounded to 6,000 characters and labeled as untrusted data. This is optional
read-only retrieval selection, not long-conversation memory or automatic training.

The hosted adapter in `dog_walker/jev.py` targets `jev-1.13.0` through
`https://api.typesafe.ai/v1/systemone`. A configured key alone does not enable it.
The archived Cabinet service differs: its database initializer enabled both
helpers by default. That initializer must not be reused in the customer product.
The archive documents that its service was retired and its switches turned off.

Current upstream source documents Laya 0.4.2 and an 8,192-token option for a
different multilingual checkpoint. That does not enlarge the installed typed
checkpoint's window or establish long-context accuracy here. Upstream also
provides training and calibration tooling. These are version-specific capabilities
to pin and test before changing the installed runtime.
[Upstream project](https://github.com/NandhaKishorM/laya)

## Existing local evidence

The archived Cabinet pilot contains four synthetic cases per completed arm,
not enough to establish general accuracy or production latency.

| Main model / path | Correct final answers | Median total request | Helper behavior |
| --- | ---: | ---: | --- |
| Ornith alone | 4/4 | 6.27 s | No helper |
| Ornith + JEV tool | 4/4 | 49.47 s | 4 supported calls |
| Ornith + Laya tool | 4/4 | 53.20 s | 4 abstentions |
| Qwen alone | 4/4 | 41.66 s | No helper |
| Qwen + JEV before/after | 4/4 | 52.09 s | 8 supported calls |

JEV's median helper-only time was 0.270 s per Ornith trial and Laya's 0.962 s.
The large end-to-end penalty includes extra main-model/tool turns. The Qwen arm
hosted a precheck and postcheck without another main-model turn; it still did not
improve correctness on these four examples. These timings do not predict a
host-managed context selector, but they argue against adding a tool round trip
to every message.

Separately, the local 32-case semantic-judge diagnostic recorded zero false
passes, **zero true passes**, and 28 reviews at the fixed 0.85 threshold. Avoid
reading the zero-false-pass count as sufficient competence. A synthetic JEV
controller fixture selected `project_search` in 0.195 s; it explicitly recorded
zero main-model calls and therefore did not measure end-to-end answer quality.

Local sources:

- Existing prototype `benchmarks/REPORT.md` and `benchmarks/README.md`.
- Existing prototype `archive/decision-helpers/docs/JEV.md`, `decision_hub.py`
  and `decision_schema.py`.
- Dog Walker `dog_walker/judge.py`, `routing.py`, `jev.py` and
  `docs/PROJECT_CONTEXT.md`.
- Dog Walker `artifacts/judge-diagnostic.json` and
  `artifacts/jev-controller-acceptance.json`.

A recent independent preprint reports substantial option-order sensitivity and
warns that isolated decision accuracy and omitted preprocessing costs can distort
end-to-end claims. Another preprint measures label-definition conflicts in open
typed decision models. Neither is a Black Team evaluation; they identify useful
stress tests: option permutations, neutral label names and conflicting wording.
[Paired evaluation](https://arxiv.org/abs/2610.02267),
[label-bias study](https://arxiv.org/abs/2610.02586)

## Concrete local context design

These are proposed product behaviors, not claims about what is already shipped.

1. Use the active model's actual context setting. Compute the input allowance as
   `context − output reserve − template/tool overhead − safety margin`. Prefer the
   runtime's tokenizer; report estimates as estimates where exact counting is
   unavailable. Count after formatting the actual request.
2. Preserve system instructions, current user request, explicit ongoing task
   constraints, and unresolved approvals. Add recent complete turns as a group so
   a tool result is not detached from its call. If required content alone is too
   large, explain the limit and ask for a narrower input instead of silently
   discarding it.
3. Store the complete original transcript locally. Prompt selection changes which
   content is sent to inference, not what is saved. Record included/omitted source
   IDs and the policy used, so context selection can be inspected and reversed.
4. Retrieve older relevant passages locally when the recent window is insufficient.
   Begin with deterministic lexical search, recency and explicit references.
   Keep source provenance and distinguish retrieved data from instructions.
5. When summarization is needed, let the existing local language model produce a
   bounded record of decisions, constraints, pending work and source IDs. Preserve
   exact user constraints separately. A summary is an aid, not authoritative proof
   that the underlying work happened.
6. Expose a compact status such as “18K / 32K context; older turns available in
   history.” A later Laya selector may suggest `recent_only`, `retrieve_older`,
   `summarize_older`, or `needs_review` from a small metadata/evidence packet.
   Application code still enforces every invariant and provides the fallback.

The selector's evidence should fit its own measured token budget. Include current
task synopsis, budget pressure, candidate summaries, recent references and missing
information flags. Supplying an arbitrary whole conversation defeats the intended
small classifier design. A larger input setting alone is not a memory strategy.

## JEV as teacher, Laya as local student

The installed Laya package contains `train.py`, `train_cli.py`, `calibrate.py`,
`evals.py` and evidence reporting. Its CLI supports a local base-checkpoint path,
JSONL/CSV data, `--freeze-encoder`, `--loss soft-ce`, `--shuffle-options`,
`--eval`, and `--dry-run`. Soft target distributions are supported by the local
training implementation. Thus a concrete narrow training experiment can be built
without replacing the main local model. It has not been run in this task.

Proposed experiment:

1. Define the context-action schema and deterministic reference policy first.
   Generate synthetic conversations with known constraints and retrieval targets,
   plus licensed public examples. JEV is a classifier, so another authoring process
   must create those examples; it cannot generate the training conversations itself.
2. Store one decision record per example: dataset/schema version, source/group ID,
   evidence packet, exact options and order, verified target action, provenance,
   teacher ID/version, optional teacher probability vector, review status, token
   counts and measured downstream result. Never mark “API call succeeded” as
   “correct label.” Preserve disagreements for review.
3. If teacher collection is separately enabled, ask JEV the same bounded question
   and preserve its advisory distribution. Use human labels or reproducible task
   outcomes as independent truth; learning only teacher agreement inherits teacher
   errors. Do not automatically turn old unreviewed call logs into training data.
4. Split by conversation/project/template family **before** augmentation so nearby
   variants do not leak between sets. Maintain training, validation/calibration and
   a frozen final test set. Keep all existing Cabinet pilot examples held out.
5. Start with frozen-encoder head tuning and soft cross-entropy; compare with the
   unmodified checkpoint and a simple non-neural baseline. Shuffle option order.
   Fine-tuning should specialize the context selector, not run continuously while
   customers are chatting. Use a new checkpoint directory with a manifest and
   rollback reference.
6. Fit temperature/abstention behavior on held-out calibration examples, not the
   training set or final test. Verify inherited option-specific temperature buckets
   cannot mask the new fit. Check whether the installed trainer's automatic split
   preserves the intended family boundaries before using it; supply explicit splits
   or adapt the training harness if necessary.
7. Run in shadow mode first: record proposed decisions locally while the baseline
   remains in control. Promote a checkpoint only when the evaluation below shows a
   benefit. Ambiguity and runtime failures return to the deterministic/local path.

“Capable” should mean measurable performance on this defined task, not matching
JEV indefinitely. There is no guarantee a 421M classifier will replace every
reasoning or memory operation performed by a much larger system.

## Evaluation and promotion gates

Measure final answer/task quality, recall of required context, unnecessary context
tokens, number of retrieval/summary calls, abstention coverage, wrong confident
actions, peak memory, cold startup and warm p50/p95 total latency. Teacher agreement
is a diagnostic metric, not the release target. Include helper preparation and any
extra model turns in timing.

Test code edits, project switching, references to much older turns, explicit user
corrections, near-limit inputs, long individual messages, multilingual input,
contradictory facts, stale summaries, prompt injection inside retrieved text,
similar choices, shuffled choices, label-definition conflicts, helper unavailability
and interrupted inference. Never permit a learned decision to cross a project or
permission boundary.

Suggested initial gates, to agree before running the experiment:

- Every budget and pinned-instruction invariant passes deterministic tests.
- No observed loss of a required constraint in the frozen critical-case set;
  report its size and uncertainty. For example, zero failures in 300 independent
  cases only suggests an approximately 1% upper 95% failure bound, not zero risk.
- Final task quality stays within a predeclared margin against the local baseline,
  with per-category results and uncertainty, while tokens or end-to-end latency
  improve enough to justify the extra model dependency.
- High-confidence errors and abstention coverage are reported together. A model
  that abstains on everything has not satisfied the utility requirement.
- The selected policy continues offline without a teacher, cloud fallback or a
  remote license check. Model failure cannot delete conversation history.

## Privacy and distribution boundaries

Hosted JEV receives whatever evidence is included in its request. Default-off
teacher collection using synthetic/public examples preserves the local product's
default behavior. Do not send private customer chats as an automatic fallback or
quietly pool customers' local logs for training. An optional online mode would need
clear data selection and user consent distinct from ordinary local chat.

TypeSafe publicly says it does not train on customer inputs, while zero retention
is described as an enterprise arrangement. Neither statement makes an API request
local or establishes this account's retention settings.
[TypeSafe enterprise data statements](https://typesafe.ai/enterprise)

The public website terms say separate product/service agreements govern those
services. The API agreement applicable to this account was not available in this
review, so permission to reuse API output for student training is not established
here. Confirm that applicable agreement before collecting hosted teacher labels;
local/human labels remain a workable alternative.
[TypeSafe website terms](https://typesafe.ai/legal/terms)

Laya code and the inspected model card are labeled Apache 2.0. A separately shipped
helper must retain the applicable licenses/notices and pinned checkpoint metadata;
its Python/PyTorch dependencies and large weights change the installer footprint.
No Laya runtime, teacher key or model weights were added to Black Team's preview
package by this investigation.
[Laya license source](https://github.com/NandhaKishorM/laya/blob/main/LICENSE)
