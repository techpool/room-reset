const test = require('node:test');
const assert = require('node:assert/strict');
const G = require('../web/model.js');

test('each round can be completed using individual trays, undone, and replayed', () => {
  for (let round = 1; round <= 100; round++) {
    let state = { round, history: [] };
    const initial = G.roundItems(round);
    assert.equal(new Set(initial.map((item) => item.id)).size, initial.length);
    assert.equal(new Set(initial.map((item) => item.spot.join(','))).size, initial.length);
    for (const kind of G.kinds) {
      const matching = G.remaining(state).filter((item) => item.kind === kind);
      state = G.tidy(
        state,
        matching.map((item) => item.id),
      );
      assert.ok(!G.remaining(state).some((item) => item.kind === kind));
    }
    assert.equal(G.remaining(state).length, 0);
    assert.deepEqual(G.restore(JSON.parse(JSON.stringify(state))), state);
    while (state.history.length) state = G.undo(state);
    assert.deepEqual(G.remaining(state), initial);
  }
});
test('stale IDs and repeated moves cannot grant progress', () => {
  let state = G.restore(null);
  state = G.tidy(state, ['p0', 'p0', 'not-present']);
  assert.deepEqual(state.history, [['p0']]);
  assert.equal(G.tidy(state, ['p0', 'unknown']), state);
  assert.deepEqual(G.restore({ round: 3, history: [['p0'], ['p0']] }), G.restore(null));
  assert.deepEqual(G.restore({ round: 0, history: [] }), G.restore(null));
});
