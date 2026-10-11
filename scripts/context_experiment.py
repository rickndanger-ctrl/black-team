#!/usr/bin/env python3
"""Synthetic context-policy experiment. Never reads customer conversations.

This evaluates bounded policy selection, not summarization or answer quality.
The hosted provider is called only with --provider jev. Existing settings are
never changed. Results are evaluation records, not approved training labels.
"""
import argparse
import json
import math
from pathlib import Path
import statistics
import sys
import time

ACTIONS = {
    'keep': 'Keep recent context unchanged when it fits and no older reference is needed.',
    'retrieve': 'Retrieve a known older reference locally; then enforce the token budget.',
    'compact': 'Request a local summary of older turns because space is tight; preserve pinned facts and recheck tokens.',
    'review': 'Ask for clarification or a narrower request when required content alone cannot fit or an older reference is unresolved.',
}


def reference_policy(state):
    if state['required_tokens'] > state['input_budget'] or state['older_reference'] == 'unresolved':
        return 'review'
    if state['older_reference'] == 'known':
        return 'retrieve'
    if state['candidate_tokens'] > state['input_budget']:
        return 'compact'
    return 'keep'


def fixtures():
    # All token counts and reference flags are fabricated, independent of users.
    rows = []
    for size in (1024, 4096, 16384):
        budget = size - size // 4 - 128
        for name, required, candidate, reference in (
            ('room', 80, budget // 2, 'none'),
            ('boundary', 80, budget, 'none'),
            ('pressure', 80, budget + 1, 'none'),
            ('older_fact', 80, budget // 2, 'known'),
            ('older_fact_pressure', 80, budget + 200, 'known'),
            ('missing_reference', 80, budget // 2, 'unresolved'),
            ('oversized_required', budget + 1, budget + 200, 'none'),
            ('oversized_with_reference', budget + 1, budget + 300, 'known'),
        ):
            state = dict(input_budget=budget, required_tokens=required,
                         candidate_tokens=candidate, older_reference=reference)
            rows.append(dict(id=f'{size}-{name}', state=state, expected=reference_policy(state)))
    return rows


def question(order):
    return {'context': {'type': 'choice', 'instructions':
        'Select one context action. Required tokens contain protected instructions and the latest request. '
        'Priority: if required tokens exceed input budget OR older_reference is unresolved, choose review. '
        'Otherwise if older_reference is known, choose retrieve even under pressure. '
        'Otherwise if candidate tokens exceed input budget, choose compact. Otherwise choose keep. '
        'You only select; local code performs any action and enforces limits.',
        'criteria': {key: ACTIONS[key] for key in order}}}


def normalize(result, order):
    answer = result.get('answers', {}).get('context', {})
    choice, probabilities = answer.get('choice'), answer.get('probabilities')
    if isinstance(probabilities, dict) and set(probabilities) == set(order):
        probabilities = [probabilities[key] for key in order]
    if (choice not in order or not isinstance(probabilities, list) or len(probabilities) != len(order)
            or any(type(p) not in (int, float) or not math.isfinite(p) or not 0 <= p <= 1 for p in probabilities)
            or abs(sum(probabilities) - 1) > .02):
        raise ValueError('Invalid decision distribution')
    support = probabilities[order.index(choice)]
    if support != max(probabilities):
        raise ValueError('Choice is not the highest supported option')
    return dict(choice=choice, support=support, probabilities=dict(zip(order, probabilities)),
                accepted=support >= .85)


def experiment(provider, judge=None, limit=24):
    rows = []
    unavailable = False
    for case in fixtures()[:limit]:
        for reverse in (False, True):
            order = list(reversed(ACTIONS)) if reverse else list(ACTIONS)
            row = dict(case, option_order=order, provider=provider)
            if unavailable:
                row['status'] = 'skipped_provider_unavailable'
                rows.append(row)
                continue
            start = time.perf_counter()
            try:
                if provider == 'baseline':
                    value = dict(choice=reference_policy(case['state']), accepted=True, support=None)
                else:
                    # Withhold the expected label and fixture ID from the provider.
                    value = normalize(judge.decide(case['state'], question(order)), order)
                row.update(value, status='completed', correct=value['choice'] == case['expected'])
            except Exception as error:
                # Raw provider exceptions may contain sensitive transport details.
                row.update(status='failed', error_type=type(error).__name__)
                if provider == 'jev':
                    unavailable = True  # One failed call, no repeated network retries.
            row['seconds'] = round(time.perf_counter() - start, 6)
            rows.append(row)
    complete = [r for r in rows if r['status'] == 'completed']
    accepted = [r for r in complete if r['accepted']]
    pairs = [(rows[i], rows[i+1]) for i in range(0, len(rows), 2)
             if rows[i]['status'] == rows[i+1]['status'] == 'completed']
    return dict(schema_version=1, provider=provider, synthetic_only=True, training_approved=False,
                scope='Explicit context-policy selection; not end-to-end answer quality or learned relevance detection.',
                summary=dict(planned=len(rows), completed=len(complete), correct=sum(r['correct'] for r in complete),
                             accepted=len(accepted), accepted_wrong=sum(not r['correct'] for r in accepted),
                             order_disagreements=sum(a['choice'] != b['choice'] for a,b in pairs),
                             comparable_pairs=len(pairs),
                             median_seconds=statistics.median(r['seconds'] for r in complete) if complete else None),
                rows=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--provider', choices=['baseline', 'jev', 'laya'], default='baseline')
    parser.add_argument('--adapter-root', type=Path)
    parser.add_argument('--jev-config', type=Path, default=Path.home()/'.config/black-team/jev.json', help='Private Black Team research key file; never reads another application profile.')
    parser.add_argument('--limit', type=int, choices=range(1,25), default=24)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    judge = None
    if args.provider != 'baseline':
        if not args.adapter_root:
            parser.error('Supply the existing reviewed Dog Walker checkout with --adapter-root.')
        sys.path.insert(0, str(args.adapter_root.resolve()))
        if args.provider == 'jev':
            from dog_walker.jev import JevJudge
            judge = JevJudge(config_path=args.jev_config, timeout=3, test_only=True)
        else:
            from dog_walker.judge import LocalJudge
            judge = LocalJudge()
    result = experiment(args.provider, judge, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(provider=args.provider, **result['summary']), indent=2))


if __name__ == '__main__':
    main()
