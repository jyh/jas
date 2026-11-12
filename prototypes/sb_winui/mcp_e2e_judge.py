"""(A) W2: the agent path's e2e on Windows, judged against the corpus.

Two modes, both reading `test_fixtures/operations/mcp_exchanges.json`, the
corpus the Rust session and the C ABI already replay:

  mcp_e2e_judge.py steps <work dir>
      Writes the run's plan from the corpus case whose steps include an artist
      accept, reject and undo (the journal case): `steps.json` for the stepped
      client (mcp_steps.ps1) and `expect.json` for the judge. Two document
      reads are added around the reject (ids 101/102), which the corpus does
      not hold: a Reject must leave the document byte-identical.

  mcp_e2e_judge.py judge <work dir>
      Reads `out.jsonl` (each line the client received, tagged with its step)
      and judges every step with the corpus's own rule (mcp::exchange_match: a
      subset match on objects, exact length on arrays, "<any>", an expected
      object against an actual JSON string). Prints one row per step and a
      VERDICT; exit 0 PASS, 1 FAIL, 2 NOT RUN.
"""
import json
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, '..', '..', 'test_fixtures', 'operations', 'mcp_exchanges.json')
DOC_BEFORE, DOC_AFTER = 'DOC-BEFORE', 'DOC-AFTER'


def journal_case(corpus):
    """The case whose artist acts are accept, reject and undo, in that order."""
    for case in corpus['cases']:
        acts = [s['artist'] for s in case['steps'] if 'artist' in s]
        if acts == ['accept', 'reject', 'undo']:
            return case
    raise SystemExit('NOT RUN: no corpus case has the artist acts accept, reject, undo')


def make_steps(work):
    with open(CORPUS, encoding='utf-8') as f:
        case = journal_case(json.load(f))

    def doc_read(i):
        return {'client': {'jsonrpc': '2.0', 'id': i, 'method': 'resources/read', 'params': {'uri': 'jas://document'}}}

    steps, expects = [], []
    reject_proposal = next(s['proposal'] for s in case['steps'] if s.get('artist') == 'reject')
    for st in case['steps']:
        # The document read before the proposal the artist will reject.
        if 'client' in st and st['client'].get('method') == 'tools/call' and any(
                e.get('result', {}).get('structuredContent', {}).get('proposal') == reject_proposal for e in st['expect']):
            steps.append(doc_read(101))
            expects.append(DOC_BEFORE)
        steps.append({'client': st['client']} if 'client' in st else {k: v for k, v in st.items() if k != 'expect'})
        expects.append(st['expect'])
        if st.get('artist') == 'reject':
            steps.append(doc_read(102))
            expects.append(DOC_AFTER)
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, 'steps.json'), 'w', encoding='utf-8', newline='') as f:
        json.dump(steps, f, separators=(',', ':'))
    with open(os.path.join(work, 'expect.json'), 'w', encoding='utf-8', newline='') as f:
        json.dump(expects, f)
    print(f"steps: {len(steps)} from case '{case['name']}' (setup {case['setup_svg']})")
    print(f"setup_svg={case['setup_svg']}")


def match(want, have):
    """mcp::exchange_match, the corpus's rule."""
    if want == '<any>':
        return True
    if isinstance(want, dict):
        if isinstance(have, str):
            try:
                have = json.loads(have)
            except ValueError:
                return False
        return isinstance(have, dict) and all(k in have and match(want[k], have[k]) for k in want)
    if isinstance(want, list):
        return isinstance(have, list) and len(want) == len(have) and all(match(a, b) for a, b in zip(want, have))
    return want == have


def judge(work):
    out = os.path.join(work, 'out.jsonl')
    if not os.path.exists(out):
        print('VERDICT: NOT RUN (no out.jsonl: the client received nothing)')
        return 2
    with open(os.path.join(work, 'expect.json'), encoding='utf-8') as f:
        expects = json.load(f)
    got = defaultdict(list)
    with open(out, encoding='utf-8-sig') as f:
        for raw in f.read().splitlines():
            if raw.strip():
                rec = json.loads(raw)
                got[rec['step']].append(rec['line'])
    bad, docs = 0, {}
    for i, want in enumerate(expects):
        lines = got.get(i, [])
        if want in (DOC_BEFORE, DOC_AFTER):
            docs[want] = lines
            print(f'step {i:2} {want}: {len(lines)} line(s)')
            continue
        have = [json.loads(line) for line in lines]
        ok = match(want, have)
        bad += not ok
        print(f'step {i:2} {"OK  " if ok else "DIFF"} want {len(want)} line(s), got {len(have)}')
        if not ok:
            print('   want:', json.dumps(want)[:300])
            print('   got :', json.dumps(have)[:300])

    def doc_text(lines):
        return json.loads(lines[0])['result']['contents'][0]['text'] if len(lines) == 1 else None

    before, after = doc_text(docs.get(DOC_BEFORE, [])), doc_text(docs.get(DOC_AFTER, []))
    same = before is not None and before == after
    print(f'a Reject leaves the document byte-identical: {same} ({len(before or "")} bytes)')
    extra = sorted(set(got) - set(range(len(expects))))
    if extra:
        print('lines at steps the plan does not have:', extra)
    verdict = bad == 0 and same and not extra
    print('VERDICT:', 'PASS' if verdict else f'FAIL (steps differing: {bad}; document byte-identical: {same})')
    return 0 if verdict else 1


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('steps', 'judge'):
        print(__doc__)
        sys.exit(2)
    if sys.argv[1] == 'steps':
        make_steps(sys.argv[2])
        sys.exit(0)
    sys.exit(judge(sys.argv[2]))
