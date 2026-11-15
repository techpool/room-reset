(() => {
  'use strict';
  const G = window.RoomGame;
  const el = (id) => document.getElementById(id);
  const labels = { paper: 'Papers', media: 'Media', archive: 'Archives', cache: 'Scraps' };
  const areas = { desk: 'Desk corner', rug: 'Rug', cabinet: 'Cabinet' };
  const trayArt = { paper: 0, media: 1, archive: 2, cache: 3 };
  const messages = new Map();
  let serial = 0;
  function hasNative() {
    return !!(window.webkit?.messageHandlers?.room || window.RoomNative?.postMessage);
  }
  function native(op, args = {}) {
    return new Promise((resolve, reject) => {
      const id = String(++serial);
      messages.set(id, { resolve, reject });
      try {
        if (window.webkit?.messageHandlers?.room)
          window.webkit.messageHandlers.room.postMessage({ id, op, args });
        else if (window.RoomNative?.postMessage)
          window.RoomNative.postMessage(JSON.stringify({ id, op, args }));
        else throw new Error('Folder mode needs the installed app.');
      } catch (error) {
        messages.delete(id);
        reject(error);
      }
    });
  }
  window.roomReply = (id, reply) => {
    const task = messages.get(String(id));
    if (!task) return;
    messages.delete(String(id));
    if (reply?.ok) task.resolve(reply.value);
    else task.reject(new Error(reply?.error || 'The folder operation did not finish.'));
  };
  function read(key, fallback) {
    try {
      return JSON.parse(localStorage.getItem('room-reset.' + key)) ?? fallback;
    } catch {
      return fallback;
    }
  }
  function write(key, value) {
    try {
      localStorage.setItem('room-reset.' + key, JSON.stringify(value));
    } catch {
      /* Practice remains playable without storage. */
    }
  }
  let practice = G.restore(read('practice', null));
  let mode = 'practice',
    scan = null,
    scope = null,
    chosen = null,
    working = false,
    drag = null;
  let quiet = !read('sound', false),
    ctx,
    toastTimer,
    suppressClickUntil = 0;
  let folderItems = [];
  const trayButtons = new Map();
  const getItems = () => (mode === 'folder' ? folderItems : G.remaining(practice));
  function inScope(item, filter = scope) {
    if (!filter || item.kind === filter) return true;
    if (mode !== 'practice' || !areas[filter]) return false;
    const x = item.spot[0];
    const corner = x < 42 ? 'desk' : x > 59 ? 'cabinet' : 'rug';
    return corner === filter;
  }
  const scopedItems = () => getItems().filter((item) => inScope(item));
  const rm = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function announce(text, error = false) {
    const toast = el('toast');
    clearTimeout(toastTimer);
    toast.textContent = String(text);
    toast.hidden = false;
    toastTimer = setTimeout(
      () => {
        toast.hidden = true;
      },
      error ? 6500 : 2400,
    );
  }
  function tone(high = false) {
    if (quiet) return;
    try {
      const Audio = window.AudioContext || window.webkitAudioContext;
      if (!Audio) return;
      ctx ||= new Audio();
      if (ctx.state === 'suspended') ctx.resume().catch(() => {});
      const t = ctx.currentTime;
      (high ? [392, 493.88, 587.33] : [349.23, 523.25]).forEach((pitch, i) => {
        const osc = ctx.createOscillator(),
          gain = ctx.createGain(),
          start = t + i * 0.065;
        osc.type = 'sine';
        osc.frequency.value = pitch;
        gain.gain.setValueAtTime(0.001, start);
        gain.gain.exponentialRampToValueAtTime(0.045, start + 0.014);
        gain.gain.exponentialRampToValueAtTime(0.001, start + 0.16);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(start);
        osc.stop(start + 0.18);
      });
    } catch {
      /* Feedback is optional when audio is unavailable. */
    }
  }
  function art(node, index) {
    node.style.setProperty('--sx', (index % 3) * 50 + '%');
    node.style.setProperty('--sy', Math.floor(index / 3) * 100 + '%');
  }
  function make(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function sizeText(value) {
    if (!Number.isFinite(value) || value < 0) return '';
    if (value < 1024) return value + ' B';
    const power = Math.min(4, Math.floor(Math.log(value) / Math.log(1024)));
    return (
      new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 }).format(value / 1024 ** power) +
      ' ' +
      ['B', 'KiB', 'MiB', 'GiB', 'TiB'][power]
    );
  }
  function initTrays() {
    for (const kind of G.kinds) {
      const button = make('button', 'tray');
      button.dataset.kind = kind;
      const tile = make('span', 'tray-art');
      const sprite = make('span', 'sprite');
      art(sprite, trayArt[kind]);
      tile.append(sprite);
      const count = make('span', 'tray-count');
      count.setAttribute('aria-hidden', 'true');
      button.append(tile, make('span', 'tray-label', labels[kind]), count);
      button.onclick = () => chooseTray(kind);
      el('trays').append(button);
      trayButtons.set(kind, button);
    }
  }
  function currentSelection() {
    return getItems().find((item) => item.id === chosen);
  }
  function applyScan(value) {
    if (!value || !Array.isArray(value.items)) throw new Error('Please select the folder again.');
    scan = value;
    folderItems = G.decorateFiles(
      value.items.filter(
        (item) =>
          G.kinds.includes(item.kind) &&
          typeof item.name === 'string' &&
          typeof item.id === 'string',
      ),
    );
    if (!folderItems.some((item) => item.id === chosen)) chosen = null;
    if (scope && !folderItems.some((item) => item.kind === scope)) scope = null;
  }
  function selectObject(id, keyboard) {
    if (working) return;
    const item = getItems().find((entry) => entry.id === id);
    if (!item) return;
    chosen = chosen === id ? null : id;
    if (!inScope(item)) scope = null;
    render();
    if (keyboard) {
      if (chosen !== null) trayButtons.get(item.kind).focus();
      else el('floor').querySelector('button')?.focus();
    }
  }
  function chooseTray(kind) {
    if (working) return;
    const selected = currentSelection();
    if (selected) {
      if (selected.kind === kind) return requestTidy([selected]);
      const button = trayButtons.get(kind);
      button.classList.remove('shake');
      void button.offsetWidth;
      button.classList.add('shake');
      announce('Try the ' + labels[selected.kind].toLowerCase() + ' tray.');
    } else {
      if (!getItems().some((item) => item.kind === kind) && scope !== kind) {
        announce(labels[kind] + ' is tidy.');
        return;
      }
      scope = scope === kind ? null : kind;
      render();
    }
  }
  function visibleItems(all) {
    if (mode === 'practice') return all;
    const pool = scope ? all.filter((item) => item.kind === scope) : all;
    const display = pool.slice(0, G.spots.length);
    const selected = currentSelection();
    if (selected && !display.some((item) => item.id === selected.id))
      display[display.length < G.spots.length ? display.length : display.length - 1] = selected;
    return display.map((item, i) => ({ ...item, spot: G.spots[i] }));
  }
  function render() {
    const real = mode === 'folder';
    const all = getItems(),
      selected = currentSelection();
    const done = all.length === 0 && (!real || !!scan?.canUndo || !!scan?.stagedCount);
    el('practice').setAttribute('aria-pressed', String(!real));
    el('folder').setAttribute('aria-pressed', String(real));
    el('practice').disabled = working;
    el('folder').disabled = working;
    el('roundLabel').textContent = real
      ? 'MY FOLDER'
      : 'ROUND ' + String(practice.round).padStart(2, '0');
    const night = !real && practice.round % 2 === 0;
    const backdrop = el('backdrop'),
      artPath = night ? 'assets/evening.webp' : 'assets/room.webp';
    if (backdrop.getAttribute('src') !== artPath) backdrop.src = artPath;
    backdrop.alt = night
      ? 'Illustrated moonlit room with a desk, a cabinet and a rug'
      : 'Illustrated sunlit room with a desk, a cabinet and a rug';
    el('title').textContent = real
      ? scan?.name || 'My folder'
      : night
        ? 'The moonlit room'
        : 'The sunroom';
    el('count').textContent = working
      ? 'Working…'
      : all.length
        ? all.length + ' to sort'
        : done
          ? 'All tidy'
          : '0 to sort';
    el('floor').replaceChildren();
    for (const item of visibleItems(all)) {
      const button = make('button', 'object');
      button.type = 'button';
      button.dataset.item = item.id;
      button.dataset.kind = item.kind;
      button.style.setProperty('--x', item.spot[0] + '%');
      button.style.setProperty('--y', item.spot[1] + '%');
      button.style.setProperty('--z', Math.round(item.spot[1]));
      button.classList.toggle('selected', item.id === chosen);
      button.classList.toggle('dim', !inScope(item));
      button.setAttribute('aria-pressed', String(item.id === chosen));
      button.setAttribute('aria-label', item.name + ', ' + labels[item.kind]);
      button.title = item.name;
      button.disabled = working;
      const sprite = make('span', 'sprite');
      art(sprite, item.art);
      button.append(sprite);
      button.onpointerdown = (event) => startDrag(event, item, button);
      button.onclick = (event) => {
        if (event.detail === 0 || performance.now() >= suppressClickUntil) {
          selectObject(item.id, event.detail === 0);
        }
      };
      el('floor').append(button);
    }
    for (const [kind, button] of trayButtons) {
      const count = all.reduce((total, item) => total + Number(item.kind === kind), 0);
      button.lastElementChild.textContent = String(count);
      button.classList.toggle('active', scope === kind);
      button.classList.toggle('target', selected?.kind === kind);
      button.setAttribute('aria-pressed', String(scope === kind));
      button.setAttribute(
        'aria-label',
        (selected ? 'Place ' + selected.name + ' in ' : 'Show ') +
          labels[kind] +
          ', ' +
          count +
          ' remaining',
      );
      button.disabled = working;
    }
    const scopeName = (labels[scope] || areas[scope] || '').toLowerCase();
    const area = el('area');
    area.hidden = real || !all.length;
    area.disabled = working;
    area.value = areas[scope] ? scope : '';
    if (!real) for (const option of area.options) {
      option.disabled = !!option.value && !all.some(item => inScope(item, option.value));
    }
    el('hint').textContent = selected
      ? selected.name + ' → ' + labels[selected.kind]
      : scope
        ? scopedItems().length + ' to sort here.'
        : !all.length
          ? real
            ? 'No sortable files in this folder.'
            : 'Everything has a place.'
          : 'Pick an object, then choose its tray.';
    el('hint').title = el('hint').textContent;
    el('list').hidden = !real || !all.length;
    el('list').disabled = working;
    el('sweepLabel').textContent = working
      ? 'Working…'
      : !all.length && !real
        ? 'Next round'
        : scope
          ? 'Sweep ' + scopeName
          : 'Sweep room';
    el('sweep').disabled = working || (real && !all.length);
    el('scopeLine').hidden = !scope || !!areas[scope];
    el('resetScope').disabled = working;
    el('undo').disabled = working || !(real ? scan?.canUndo : practice.history.length);
    el('celebration').hidden = !done || working;
    el('folderTools').hidden = !real;
    el('repick').disabled = working;
    el('refresh').disabled = working;
    el('empty').disabled = working;
    el('empty').hidden = !(scan?.stagedCount > 0);
    el('empty').textContent = 'Empty staging (' + (scan?.stagedCount || 0) + ')';
    el('sound').setAttribute('aria-pressed', String(!quiet));
    el('sound').setAttribute('aria-label', quiet ? 'Turn sound on' : 'Mute sound');
    el('sound').title = el('sound').getAttribute('aria-label');
    document.body.setAttribute('aria-busy', String(working));
  }
  function spriteGhost(item, rect, x, y) {
    const ghost = make('span', 'sprite drag-ghost');
    art(ghost, item.art);
    ghost.style.width = rect.width + 'px';
    ghost.style.height = rect.height + 'px';
    ghost.style.left = x + 'px';
    ghost.style.top = y + 'px';
    document.body.append(ghost);
    return ghost;
  }
  function startDrag(event, item, button) {
    if (working || drag || event.button !== 0 || !event.isPrimary) return;
    drag = {
      pointer: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      button,
      item,
      ghost: null,
      hover: null,
    };
    button.setPointerCapture(event.pointerId);
  }
  function hoverTray(d, x, y) {
    const next = document.elementFromPoint(x, y)?.closest('.tray');
    if (d.hover !== next) {
      d.hover?.classList.remove('hot');
      next?.classList.add('hot');
      d.hover = next;
    }
  }
  window.addEventListener('pointermove', (event) => {
    if (!drag || event.pointerId !== drag.pointer) return;
    if (!drag.ghost && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 6) return;
    if (!drag.ghost) {
      drag.ghost = spriteGhost(
        drag.item,
        drag.button.getBoundingClientRect(),
        event.clientX,
        event.clientY,
      );
      drag.button.classList.add('grabbing');
      trayButtons.get(drag.item.kind).classList.add('target');
    }
    drag.ghost.style.left = event.clientX + 'px';
    drag.ghost.style.top = event.clientY + 'px';
    hoverTray(drag, event.clientX, event.clientY);
  });
  function endDrag(event, cancelled) {
    if (!drag || event.pointerId !== drag.pointer) return;
    const d = drag;
    drag = null;
    if (!d.ghost) return;
    suppressClickUntil = performance.now() + 320;
    d.ghost.remove();
    d.button.classList.remove('grabbing');
    hoverTray(d, event.clientX, event.clientY);
    d.hover?.classList.remove('hot');
    if (cancelled) {
      render();
      return;
    }
    chosen = d.item.id;
    if (!inScope(d.item)) scope = null;
    render();
    if (d.hover) chooseTray(d.hover.dataset.kind);
  }
  window.addEventListener('pointerup', (event) => endDrag(event, false));
  window.addEventListener('pointercancel', (event) => endDrag(event, true));
  window.addEventListener('lostpointercapture', (event) => endDrag(event, true));
  async function fly(items) {
    if (rm() || !Element.prototype.animate) return;
    const requested = new Map(items.map((item) => [item.id, item]));
    const nodes = Array.from(el('floor').children).filter((n) => requested.has(n.dataset.item));
    await Promise.all(
      nodes.map(async (node, i) => {
        const item = requested.get(node.dataset.item),
          rect = node.getBoundingClientRect(),
          tray = trayButtons.get(item.kind),
          target = tray.getBoundingClientRect();
        const x = rect.left + rect.width / 2,
          y = rect.top + rect.height / 2;
        const gx = target.left + target.width / 2 - x,
          gy = target.top + target.height / 2 - y;
        const ghost = spriteGhost(item, rect, x, y);
        node.classList.add('flying');
        const keyframes = [
          { transform: 'translate(-50%,-50%) scale(1)', opacity: 1 },
          {
            transform: `translate(calc(-50% + ${gx * 0.5}px),calc(-50% + ${gy * 0.5 - 36}px)) scale(.86)`,
            opacity: 1,
          },
          {
            transform: `translate(calc(-50% + ${gx}px),calc(-50% + ${gy}px)) scale(.28)`,
            opacity: 0,
          },
        ];
        try {
          const flight = ghost.animate(keyframes, {
            duration: 360,
            delay: i * 95,
            fill: 'both',
            easing: 'ease-in-out',
          });
          await flight.finished;
        } catch {
          /* A suspended web view may cancel animations. */
        } finally {
          ghost.remove();
          tray.classList.remove('bump');
          void tray.offsetWidth;
          tray.classList.add('bump');
        }
      }),
    );
  }
  async function run(action) {
    if (working) return;
    working = true;
    render();
    try {
      await action();
    } catch (error) {
      announce(error?.message || 'Please try again.', true);
    } finally {
      working = false;
      render();
    }
  }
  function dismiss() {
    el('sheet').close();
  }
  function openSheet(title, copy, buttons, list, picking = false) {
    if (el('sheet').open) dismiss();
    el('sheetTitle').textContent = title;
    const body = el('sheetBody');
    body.replaceChildren();
    if (copy) body.append(make('p', '', copy));
    if (list) {
      const ul = make('ul', 'filelist');
      body.append(ul);
      let offset = 0;
      const more = make('button', 'inline-button', 'Show more files');
      function appendPage() {
        for (const item of list.slice(offset, offset + 75)) {
          const li = make('li');
          const row = make(picking ? 'button' : 'div', picking ? 'file-row file-jump' : 'file-row');
          row.append(
            make('strong', '', item.name),
            make(
              'small',
              '',
              (item.kind === 'cache' ? 'Stage' : labels[item.kind]) + ' · ' + sizeText(item.bytes),
            ),
          );
          if (picking)
            row.onclick = () => {
              dismiss();
              chosen = item.id;
              scope = null;
              render();
              trayButtons.get(item.kind).focus();
            };
          li.append(row);
          ul.append(li);
        }
        offset += 75;
        more.hidden = offset >= list.length;
      }
      appendPage();
      more.onclick = appendPage;
      body.append(more);
    }
    const actions = el('sheetActions');
    actions.replaceChildren();
    for (const spec of buttons) {
      const button = make('button', spec.style || '', spec.label);
      button.onclick = () => {
        dismiss();
        spec.action?.();
      };
      actions.append(button);
    }
    el('sheet').showModal();
  }
  function requestTidy(items) {
    if (working || !items.length) return;
    const ids = items.map((item) => item.id);
    async function apply() {
      await run(async () => {
        if (mode === 'folder') {
          const result = await native('tidy', { ids });
          const left = new Set(result.items.map((item) => item.id));
          await fly(items.filter((item) => !left.has(item.id)));
          applyScan(result);
          if (result.notice) announce(result.notice);
        } else {
          practice = G.tidy(practice, ids);
          write('practice', practice);
          await fly(items);
        }
        chosen = null;
        if (scope && !scopedItems().length) scope = null;
        tone(getItems().length === 0);
      });
    }
    if (mode === 'practice') return apply();
    const staged = items.filter((item) => item.kind === 'cache').length,
      organized = items.length - staged;
    const noun = (n) => (n === 1 ? 'file' : 'files');
    const copy = [
      organized ? `Move ${organized} ${noun(organized)} into the organizer in this folder.` : '',
      staged ? `Stage ${staged} disposable ${noun(staged)} for later removal.` : '',
    ]
      .filter(Boolean)
      .join(' ');
    openSheet(
      'Tidy ' + items.length + ' ' + noun(items.length) + '?',
      copy,
      [{ label: 'Cancel' }, { label: 'Tidy files', style: 'confirm', action: apply }],
      items,
    );
  }
  function pickFolder(repick) {
    if (!hasNative()) {
      openSheet(
        'My folder',
        'Open Room Reset on macOS, iOS or Android to play with files in a folder you choose.',
        [{ label: 'Back to practice', style: 'confirm' }],
      );
      return;
    }
    return run(async () => {
      // A move or a revoked permission can invalidate a previously selected folder.
      let result = repick ? null : await native('scan').catch(() => null);
      if (!result) result = await native('pick');
      if (!result) return;
      applyScan(result);
      mode = 'folder';
      scope = null;
      chosen = null;
      write('mode', mode);
      if (result.notice) announce(result.notice);
    });
  }
  function refresh(op) {
    return run(async () => {
      const result = await native(op);
      if (!result) {
        mode = 'practice';
        scan = null;
        folderItems = [];
        write('mode', mode);
        announce('Choose your folder again.');
      } else {
        applyScan(result);
        if (result.notice) announce(result.notice);
      }
      chosen = null;
      scope = null;
    });
  }
  el('practice').onclick = () => {
    if (mode === 'practice') return;
    mode = 'practice';
    scope = null;
    chosen = null;
    write('mode', mode);
    render();
  };
  el('folder').onclick = () => {
    if (mode !== 'folder') pickFolder(false);
  };
  el('repick').onclick = () => pickFolder(true);
  el('refresh').onclick = () => refresh('scan');
  el('empty').onclick = () => {
    const count = scan?.stagedCount || 0;
    if (!count || working) return;
    const bytes = sizeText(scan.stagedBytes);
    openSheet(
      'Empty staging?',
      `Permanently delete ${count} staged ${count === 1 ? 'file' : 'files'}${bytes ? ' (' + bytes + ')' : ''}. This cannot be undone.`,
      [
        { label: 'Cancel' },
        { label: 'Delete staged files', style: 'danger', action: () => refresh('purge') },
      ],
    );
  };
  el('sweep').onclick = () => {
    if (working) return;
    if (mode === 'practice' && !getItems().length) {
      practice = { round: (practice.round % 100000) + 1, history: [] };
      write('practice', practice);
      scope = null;
      chosen = null;
      render();
      el('floor').firstElementChild?.focus({ preventScroll: true });
      return;
    }
    requestTidy(scopedItems());
  };
  el('undo').onclick = () => {
    if (working) return;
    if (mode === 'folder') return refresh('undo');
    practice = G.undo(practice);
    write('practice', practice);
    chosen = null;
    scope = null;
    render();
    announce('Last tidy undone.');
  };
  el('resetScope').onclick = () => {
    scope = null;
    chosen = null;
    render();
  };
  el('area').onchange = () => {
    scope = el('area').value || null;
    chosen = null;
    render();
  };
  el('sound').onclick = () => {
    quiet = !quiet;
    write('sound', !quiet);
    tone();
    render();
  };
  el('list').onclick = () =>
    openSheet(
      'Files in this room',
      'Choose a file to place in its tray.',
      [{ label: 'Done' }],
      getItems(),
      true,
    );
  el('closeSheet').onclick = dismiss;
  el('sheet').addEventListener('click', (event) => {
    if (event.target === el('sheet')) {
      const r = el('sheet').getBoundingClientRect();
      if (
        event.clientX < r.left ||
        event.clientX > r.right ||
        event.clientY < r.top ||
        event.clientY > r.bottom
      )
        dismiss();
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !el('sheet').open && !working) {
      chosen = null;
      scope = null;
      render();
    }
  });
  initTrays();
  render();
  if (hasNative() && read('mode', 'practice') === 'folder') {
    run(async () => {
      const saved = await native('scan');
      if (saved) {
        applyScan(saved);
        mode = 'folder';
      } else write('mode', 'practice');
    });
  }
})();
