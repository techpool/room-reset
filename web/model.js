/* Deterministic practice rounds. Native file handles never enter the practice save. */
(function (root) {
  'use strict';
  const kinds = ['paper', 'media', 'archive', 'cache'];
  const props = [
    { name: 'Loose papers', kind: 'paper' },
    { name: 'Film camera', kind: 'media' },
    { name: 'Cardboard box', kind: 'archive' },
    { name: 'Paper ball', kind: 'cache' },
    { name: 'Magazines', kind: 'paper' },
    { name: 'Mixtape', kind: 'media' },
  ];
  const spots = [
    [36, 70],
    [62, 65],
    [72, 77],
    [48, 82],
    [23, 59],
    [54, 54],
    [33, 85],
    [74, 52],
    [43, 58],
  ];
  function permute(values, seed) {
    const result = values.slice();
    for (let i = result.length - 1; i > 0; i--) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      const j = seed % (i + 1);
      [result[i], result[j]] = [result[j], result[i]];
    }
    return result;
  }
  function roundItems(round) {
    const count = Math.min(5 + round, spots.length);
    const indices =
      round === 1
        ? [0, 1, 2, 3, 4, 5]
        : permute(
            Array.from({ length: count }, (_, i) => (i + round - 1) % 6),
            round * 71,
          );
    const places = round === 1 ? spots : permute(spots, round * 19);
    return indices.map((art, i) => ({ ...props[art], art, spot: places[i], id: 'p' + i }));
  }
  function restore(raw) {
    const fallback = { round: 1, history: [] };
    if (
      !raw ||
      !Number.isSafeInteger(raw.round) ||
      raw.round < 1 ||
      raw.round > 100000 ||
      !Array.isArray(raw.history)
    )
      return fallback;
    const available = new Set(roundItems(raw.round).map((item) => item.id));
    const history = [];
    for (const batch of raw.history) {
      if (!Array.isArray(batch) || !batch.length) return fallback;
      for (const id of batch) if (!available.delete(id)) return fallback;
      history.push(batch.slice());
    }
    return { round: raw.round, history };
  }
  function remaining(state) {
    const moved = new Set(state.history.flat());
    return roundItems(state.round).filter((item) => !moved.has(item.id));
  }
  function tidy(state, ids) {
    const chosen = new Set(ids);
    const batch = remaining(state)
      .filter((item) => chosen.has(item.id))
      .map((item) => item.id);
    return batch.length ? { ...state, history: [...state.history, batch] } : state;
  }
  function undo(state) {
    return { ...state, history: state.history.slice(0, -1) };
  }
  function decorateFiles(items) {
    return items.map((item, i) => {
      const art = { paper: 0, media: 1, archive: 2, cache: 3 }[item.kind];
      return { ...item, art, spot: spots[i % spots.length] };
    });
  }
  const model = { kinds, props, spots, roundItems, restore, remaining, tidy, undo, decorateFiles };
  root.RoomGame = model;
  if (typeof module !== 'undefined') module.exports = model;
})(typeof window !== 'undefined' ? window : globalThis);
