/* DPS Studio panel. Same shell as DPS Fleet: a bar, a tab row, a list whose selected row
   opens its actions. The Lua client owns the game side; this file renders and routes keys.
   Nothing here polls: every refresh follows a user action or a message from the client.
   No-focus overlays (#keys, #prompt, #card) are drawn for every player, panel or not. */
(function () {
  'use strict';
  const RES = (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'dps-studio';
  const $ = (s) => document.querySelector(s);
  const app = $('#app'), bar = $('#bar'), list = $('#list'), q = $('#q'), hint = $('#hint'), head = $('#head'),
        chips = $('#chips'), banner = $('#banner'), modal = $('#modal'), stage = $('#stage');

  const TABS = ['rooms', 'place', 'shells', 'inspect', 'spots', 'doors', 'history'];
  const HINTS = {
    rooms: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> open &nbsp;<kbd>N</kbd> new room at my spot &nbsp;<kbd>1-7</kbd> tabs &nbsp;<kbd>Tab</kbd> buttons &nbsp;<kbd>Esc</kbd> close',
    place: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> place it &nbsp;<kbd>M</kbd> move or remove pieces · type to search',
    shells: '<kbd>↑↓</kbd> next shell &nbsp;<kbd>← →</kbd> or drag to turn &nbsp;<kbd>Page Up / Down</kbd> tilt &nbsp;wheel zoom &nbsp;<kbd>Enter</kbd> walk inside',
    inspect: 'Hold <kbd>Middle mouse</kbd> anywhere to inspect. The last 30 are kept here.',
    spots: '<kbd>Page Up</kbd> marks a spot &nbsp;<kbd>F3</kbd> captures coords &nbsp;<kbd>Enter</kbd> open · type to search',
    doors: '<kbd>Enter</kbd> opens the door maker &nbsp;<kbd>1-7</kbd> tabs',
    history: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> open · every change can be put back',
  };
  const PH = { rooms: 'Search rooms…', place: 'Search furniture…', shells: 'Search shells: warehouse, office, garage…', inspect: 'Search scans…', spots: 'Search spots…', doors: '', history: 'Search history…' };

  const S = { tab: 'rooms', boot: null, rooms: [], spots: [], hist: [], scans: [], here: null, pick: null,
              items: [], sel: -1, open: false, chip: { place: 'all', lib: 'lighting', shells: 'all', spots: 'all' }, q: {}, shellTimer: null, shown: false, pv: null,
              src: 'decorate', lib: null, bad: new Set(), more: 0 };
  const LIB_ICON = { lighting: 'fa-lightbulb', seating: 'fa-couch', tables: 'fa-table', beds: 'fa-bed', storage: 'fa-box-archive', kitchen: 'fa-kitchen-set',
    bathroom: 'fa-bath', bar: 'fa-martini-glass', electronics: 'fa-tv', office: 'fa-briefcase', decor: 'fa-image', plants: 'fa-seedling', gym: 'fa-dumbbell',
    crime: 'fa-screwdriver-wrench', street: 'fa-road-barrier', other: 'fa-cube', mappieces: 'fa-puzzle-piece' };
  const PREFIX = /^(prop_|v_res_|v_ret_|v_ilev_|v_serv_|v_corp_|v_club_|v_med_|v_ind_|v_\d+_|apa_mp_h_|apa_prop_|ex_prop_|ex_mp_h_|bkr_prop_|imp_prop_|ba_prop_|xs_prop_|h4_prop_|ch_prop_|vw_prop_|sf_prop_|sf_mp_h_|tr_prop_|reh_prop_|sum_prop_|gr_prop_|hei_prop_|hei_heist_|sm_prop_|xm_prop_|xm3_prop_|m2\d_\d_prop_|p_)/;
  const pretty = (m) => { const s = m.replace(PREFIX, '').replace(/_/g, ' ').trim(); return s ? s.charAt(0).toUpperCase() + s.slice(1) : m; };
  const LIB_CAP = 300;

  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const store = (k, d) => { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch (e) { return d; } };
  const keep = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} };
  const f2 = (n) => Number(n || 0).toFixed(2);
  function post(name, body) {
    return fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) })
      .then((r) => r.json()).catch(() => ({ ok: false, err: 'No answer from the game' }));
  }
  let tt;
  function toast(text, bad) { const t = $('#toast'); t.textContent = text; t.classList.toggle('bad', !!bad); t.classList.add('on'); clearTimeout(tt); tt = setTimeout(() => t.classList.remove('on'), 2400); }
  function copy(text) {
    const ta = document.createElement('textarea'); ta.value = text; ta.setAttribute('readonly', ''); ta.style.cssText = 'position:fixed;opacity:0';
    document.body.appendChild(ta); ta.select();
    let ok = false; try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    toast(ok ? 'Copied: ' + text : 'Could not copy', !ok);
  }
  function result(r, okText) { if (r && r.ok) { if (okText) toast(okText); return true; } toast((r && r.err) || 'That did not work', true); return false; }

  /* ---------- forms (no prompt(): the game view has none) ---------- */
  function ask(title, text, fields, okLabel) {
    return new Promise((resolve) => {
      modal.innerHTML = `<form class="form" autocomplete="off"><h4>${esc(title)}</h4>${text ? `<p>${esc(text)}</p>` : ''}
        ${fields.map((f, i) => `<label>${esc(f.label)}<input type="text" id="f${i}" maxlength="${f.max || 40}" value="${esc(f.value || '')}" placeholder="${esc(f.ph || '')}"></label>`).join('')}
        <div class="err" id="ferr"></div><div class="row2"><button type="button" class="btn" id="fno">Cancel</button><button type="submit" class="btn pri">${esc(okLabel || 'Save')}</button></div></form>`;
      modal.hidden = false;
      const first = modal.querySelector('input'); if (first) { first.focus(); first.select(); }
      const done = (v) => { modal.hidden = true; modal.innerHTML = ''; list.focus(); resolve(v); };
      modal.querySelector('#fno').onclick = () => done(null);
      modal.querySelector('form').onsubmit = (e) => {
        e.preventDefault();
        const vals = fields.map((f, i) => modal.querySelector('#f' + i).value.trim());
        const bad = fields.findIndex((f, i) => f.required !== false && !vals[i]);
        if (bad >= 0) { modal.querySelector('#ferr').textContent = fields[bad].label + ' is needed'; return; }
        done(vals);
      };
    });
  }
  function confirmBox(title, text, okLabel) {
    return new Promise((resolve) => {
      modal.innerHTML = `<div class="form"><h4>${esc(title)}</h4><p>${esc(text)}</p><div class="row2"><button class="btn" id="fno">Cancel</button><button class="btn pri" id="fyes">${esc(okLabel)}</button></div></div>`;
      modal.hidden = false;
      const done = (v) => { modal.hidden = true; modal.innerHTML = ''; list.focus(); resolve(v); };
      modal.querySelector('#fno').onclick = () => done(false);
      modal.querySelector('#fyes').onclick = () => done(true);
      modal.querySelector('#fyes').focus();
    });
  }

  /* ---------- data per tab ---------- */
  const words = (s) => String(s || '').toLowerCase();
  const words_ = (s) => words(s).split(/\s+/).filter(Boolean);
  const match = (hay) => { const t = words(q.value).split(/\s+/).filter(Boolean); const h = words(hay); return t.every((w) => h.includes(w)); };
  const roomByName = (n) => S.rooms.find((r) => r.name === n);

  function shellWords(m) {
    const x = S.boot && S.boot.meta && S.boot.meta[m];
    return x ? `${m} ${x.pack} ${x.use} ${x.type} ${x.furnished ? 'furnished' : 'empty'} ${x.note}` : m;
  }

  function itemsFor(tab) {
    switch (tab) {
      case 'rooms': return S.rooms.filter((r) => match(`${r.label} ${r.name} ${r.shell} ${r.lookName}`));
      case 'place': {
        const out = [];
        S.more = 0;
        if (S.src === 'decorate' || S.src === 'build') {
          if (!S.lib) return out;
          const words = words_(q.value);
          const searching = words.length > 0;
          for (const g of S.lib.groups) {
            if (!searching && S.chip.lib !== 'all' && S.chip.lib !== g.key) continue;
            for (const it of g.items) {
              if (it.use !== S.src || S.bad.has(it.m)) continue;
              if (searching && !words.every((w) => it.hay.includes(w))) continue;
              if (out.length >= LIB_CAP) { S.more++; continue; }
              out.push({ object: it.m, label: it.label, cat: g.label, gkey: g.key, src: it.src, lib: true });
            }
          }
          return out;
        }
        if (!S.boot) return out;
        for (const c of S.boot.furniture) {
          if (S.chip.place !== 'all' && S.chip.place !== c.key) continue;
          for (const it of c.items) if (match(`${it.label} ${it.object} ${c.label}`)) out.push(Object.assign({ cat: c.label }, it));
        }
        return out;
      }
      case 'shells': {
        if (!S.boot) return [];
        const meta = S.boot.meta || {};
        return S.boot.shells.filter((m) => (S.chip.shells === 'all' || (meta[m] && meta[m].use === S.chip.shells)) && match(shellWords(m))).map((m) => ({ model: m, meta: meta[m] }));
      }
      case 'inspect': return S.scans.filter((s) => match(`${s.name} ${s.kind} ${s.note || ''}`));
      case 'spots': return S.spots.filter((s) => (S.chip.spots === 'all' || s.kind === S.chip.spots) && match(`${s.id} ${s.label} ${s.street} ${s.zone} ${s.by_name} ${s.kind}`));
      case 'history': return S.hist.filter((h) => match(`${h.summary} ${h.room} ${h.by_name} ${h.action}`));
      default: return [];
    }
  }

  /* ---------- rows ---------- */
  function pieceMeter(count, max) {
    const pct = Math.min(100, Math.round((count / (max || 400)) * 100));
    return `<span class="meter${pct >= 100 ? ' full' : pct >= 80 ? ' warn' : ''}"><span><i style="width:${pct}%"></i></span>${count} / ${max}</span>`;
  }

  function rowHtml(tab, it, i) {
    let thumb = '', nm = '', mt = '', rt = '';
    if (tab === 'rooms') {
      thumb = '<i class="fa-solid fa-door-open"></i>';
      nm = esc(it.label); mt = `<code>${esc(it.name)}</code> · ${esc(it.shell)} · look <b>${esc(it.lookName)}</b>`;
      rt = pieceMeter(it.count, it.max) + (S.here === it.name ? '<span class="badge on">You are here</span>' : '');
    } else if (tab === 'place') {
      thumb = it.img ? `<img src="${esc(it.img)}" alt="" loading="lazy">` : `<i class="fa-solid ${it.lib ? (LIB_ICON[it.gkey] || 'fa-cube') : 'fa-couch'}"></i>`;
      nm = esc(it.label); mt = `<code>${esc(it.object)}</code> · ${esc(it.cat)}${it.lib ? ' · ' + esc(it.src === 'Game' ? 'game' : it.src) : ''}`;
    } else if (tab === 'shells') {
      const m = it.meta;
      thumb = `<i class="fa-solid ${m && m.use === 'garage' ? 'fa-warehouse' : m && m.use === 'business' ? 'fa-briefcase' : 'fa-cube'}"></i>`;
      nm = `<code>${esc(it.model)}</code>`; mt = m ? `${esc(m.pack)} · ${esc(m.type)} · ${m.furnished ? 'furnished' : 'empty'}${m.note ? ' · ' + esc(m.note) : ''}` : 'no type yet';
      rt = `<span class="badge">${i + 1}</span>`;
    } else if (tab === 'inspect') {
      thumb = '<i class="fa-solid fa-crosshairs"></i>';
      nm = `<code>${esc(it.name)}</code>`; mt = `${esc(it.kind || '')}${it.hash ? ' · hash ' + esc(it.hash) : ''}${it.note ? ' · ' + esc(it.note) : ''}`;
    } else if (tab === 'spots') {
      thumb = `<i class="fa-solid ${it.kind === 'pos' ? 'fa-crosshairs' : 'fa-location-dot'}"></i>`;
      nm = `#${esc(it.id)} ${esc(it.label || (it.kind === 'pos' ? 'F3 coords' : 'Spot'))}`;
      mt = `${esc([it.street, it.zone].filter(Boolean).join(' · '))}${it.street || it.zone ? ' · ' : ''}${esc(it.at)} · ${esc(it.by_name || '')}`;
    } else if (tab === 'history') {
      thumb = '<i class="fa-solid fa-clock-rotate-left"></i>';
      nm = esc(it.summary); mt = `${esc(it.at)} · ${esc(it.by_name || '')} · <code>${esc(it.room)}</code>`;
      rt = `<span class="badge">${esc(it.action)}</span>`;
    }
    return `<div class="row" data-i="${i}" role="option"><div class="thumb">${thumb}</div><div class="txt"><div class="nm">${nm}</div><div class="mt">${mt}</div></div><div class="rt">${rt}</div></div>`;
  }

  function detHtml(tab, it) {
    if (tab === 'rooms') {
      const looks = (it.looks || []).map((l) => `<div class="look${l.id === it.look ? ' on' : ''}"><span class="ln">${esc(l.name)}<small>${l.count} pieces</small></span>
        ${l.id === it.look ? '<span class="badge on">Showing</span>' : `<button data-a="lookShow" data-id="${l.id}">Show this</button>`}
        <button data-a="lookRename" data-id="${l.id}">Rename</button>
        ${l.id === it.look ? '' : `<button data-a="lookDelete" data-id="${l.id}">Remove</button>`}</div>`).join('');
      return `<div class="det"><div class="acts">
          <button class="pri" data-a="decorate">Decorate <kbd>Enter</kbd></button>
          <button data-a="goIn">Go inside</button>
          <button data-a="goDoor">Go to the door</button></div>
        <span class="lbl">Looks · switching changes the room for everyone</span><div class="looks">${looks}</div>
        <div class="acts"><button data-a="lookNewCopy">New look from this one</button><button data-a="lookNewEmpty">New empty look</button><button data-a="label">Change door words</button></div>
        <span class="lbl">Door and shell</span>
        <div class="acts"><button data-a="door">Move the door to me</button><button data-a="redo">Change shell or way out</button><button data-a="copy">Copy room to my spot</button></div>
        <div class="acts"><button class="bad" data-a="delete">Remove room</button></div>
        <p>Last change: ${esc(it.updatedBy || '-')} · ${esc(it.updatedAt || '-')}</p></div>`;
    }
    if (tab === 'place') return `<div class="det"><div class="acts"><button class="pri" data-a="place">Place it <kbd>Enter</kbd></button><button data-a="copyName">Copy name</button></div></div>`;
    if (tab === 'shells') {
      const pick = S.pick ? `<p>Walk inside, find where people should arrive, face into the room and press <kbd>G</kbd>.</p>` : '';
      return `<div class="det">${pick}<div class="acts"><button class="pri" data-a="walk">Walk inside <kbd>Enter</kbd></button><button data-a="copyName">Copy name</button><button data-a="stop">Stop preview</button></div></div>`;
    }
    if (tab === 'inspect') {
      const v4 = `vector4(${f2(it.x)}, ${f2(it.y)}, ${f2(it.z)}, ${Number(it.h || 0).toFixed(1)})`;
      return `<div class="det"><p><code>${esc(v4)}</code></p><div class="acts"><button class="pri" data-a="copyName">Copy name</button><button data-a="copyV4" data-v="${esc(v4)}">Copy vector4</button><button data-a="copyHash">Copy hash</button></div></div>`;
    }
    if (tab === 'spots') {
      const v3 = `vec3(${f2(it.x)}, ${f2(it.y)}, ${f2(it.z)})`, v4 = `vector4(${f2(it.x)}, ${f2(it.y)}, ${f2(it.z)}, ${Number(it.h || 0).toFixed(1)})`;
      return `<div class="det"><p><code>${esc(v4)}</code></p><div class="acts"><button class="pri" data-a="copyV4" data-v="${esc(v4)}">Copy vector4 <kbd>Enter</kbd></button><button data-a="copyV3" data-v="${esc(v3)}">Copy vec3</button><button data-a="spotGo">Go there</button></div></div>`;
    }
    if (tab === 'history') {
      if (Number(it.has_before)) return `<div class="det"><div class="acts"><button class="pri" data-a="restore">Put the room back to before this</button></div><p>The current state is saved first, so this can be put back too.</p></div>`;
      if (!Number(it.pruned) && ['create', 'copy', 'import'].includes(it.action)) return `<div class="det"><div class="acts"><button class="pri" data-a="restore">Undo: remove the room this made</button></div><p>The room is saved first, so this can be put back too.</p></div>`;
      return `<div class="det"><p>${Number(it.pruned) ? 'This change is too old to put back. Each room keeps its last 200.' : 'Nothing to put back for this line.'}</p></div>`;
    }
    return '';
  }

  /* ---------- render ---------- */
  function renderHead() {
    const t = S.tab;
    banner.hidden = !(S.pick && (t === 'rooms' || t === 'shells'));
    if (!banner.hidden) banner.innerHTML = `<span>Making <b>${esc(S.pick.label)}</b>: pick a shell, press Walk inside, then <kbd>G</kbd> at the way out.</span><button class="btn" data-a="pickCancel">Cancel</button>`;
    let h = '';
    if (t === 'rooms') h = `<span class="grow">${S.rooms.length} rooms. A room is a door, a shell and saved looks of furniture.</span><button class="btn pri" data-a="newRoom">New room at my spot <kbd>N</kbd></button>`;
    else if (t === 'place') {
      const r = roomByName(S.here);
      h = r ? `<span class="grow"><b>${esc(r.label)}</b> · look <b>${esc(r.lookName)}</b></span>${pieceMeter(r.count, r.max)}<button class="btn" data-a="edit">Move or remove <kbd>M</kbd></button>` : '';
    } else if (t === 'shells') h = `<span class="grow">${S.boot ? S.boot.shells.length : 0} shells from the housing list. The one you pick floats in the sky so open shells show from every side.</span>`;
    else if (t === 'spots') h = `<span class="grow">${S.spots.length} spots, newest first.</span><button class="btn pri" data-a="markSpot">Mark my spot</button>`;
    else if (t === 'inspect') h = `<span class="grow">Hold middle mouse and aim. Close this panel first so you can look around.</span>`;
    head.innerHTML = h;

    let c = '';
    if (t === 'place' && S.here) {
      const srcs = `<button class="chip src${S.src === 'decorate' ? ' on' : ''}" data-s="decorate"><i class="fa-solid fa-couch"></i> Decorate</button><button class="chip src${S.src === 'build' ? ' on' : ''}" data-s="build"><i class="fa-solid fa-trowel-bricks"></i> Build</button><button class="chip src${S.src === 'housing' ? ' on' : ''}" data-s="housing"><i class="fa-solid fa-image"></i> Housing furniture, with pictures</button><span class="brk"></span>`;
      if ((S.src === 'decorate' || S.src === 'build') && S.lib) c = srcs + [['all', 'All']].concat(S.lib.groups.filter((g) => g.n[S.src] > 0).map((g) => [g.key, g.label])).map(([k, l]) => `<button class="chip${S.chip.lib === k && !q.value.trim() ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('') + (q.value.trim() ? '<span class="brk"></span><span class="hint2">Searching every group</span>' : '');
      else if (S.boot) c = srcs + [['all', 'All']].concat(S.boot.furniture.map((f) => [f.key, f.label])).map(([k, l]) => `<button class="chip${S.chip.place === k ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('');
      else c = srcs;
    }
    else if (t === 'shells' && S.boot) {
      const uses = Array.from(new Set(Object.values(S.boot.meta || {}).map((m) => m.use))).sort();
      c = [['all', 'All']].concat(uses.map((u) => [u, u])).map(([k, l]) => `<button class="chip${S.chip.shells === k ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('');
    } else if (t === 'spots') c = [['all', 'All'], ['spot', 'Spots'], ['pos', 'F3 coords']].map(([k, l]) => `<button class="chip${S.chip.spots === k ? ' on' : ''}" data-c="${k}">${l}</button>`).join('');
    chips.innerHTML = c; chips.hidden = !c;
  }

  function render(keepSel) {
    const t = S.tab, prevKey = keepSel ? keyOf(S.items[S.sel]) : null, wasOpen = S.open;
    renderHead();
    hint.innerHTML = HINTS[t] || '';
    document.querySelectorAll('.mode').forEach((b) => b.classList.toggle('on', b.dataset.t === t));
    q.disabled = t === 'doors'; q.placeholder = PH[t] || '';
    stage.hidden = !(t === 'shells' && S.shown);
    if (t === 'doors') { list.innerHTML = doorsDoc(); S.items = []; $('#cnt').textContent = ''; return; }
    if (t === 'place' && S.here && S.src !== 'housing' && !S.lib) { renderHead(); list.innerHTML = '<div class="empty"><b>Loading the library…</b></div>'; S.items = []; return; }
    if (t === 'place' && !S.here) { list.innerHTML = placeEmpty(); S.items = []; $('#cnt').textContent = ''; return; }
    S.items = itemsFor(t);
    list.innerHTML = S.items.length ? S.items.map((it, i) => rowHtml(t, it, i)).join('') + (S.more ? `<div class="empty"><span>${S.more.toLocaleString('en-US')} more. Type a word to narrow it down, like lamp, neon or chandelier.</span></div>` : '') : `<div class="empty">${emptyMsg(t)}</div>`;
    $('#cnt').textContent = S.items.length ? (S.more ? `${S.items.length}+${S.more}` : String(S.items.length)) : '';
    S.sel = -1;
    if (S.items.length) {
      let i = 0;
      if (prevKey != null) { const j = S.items.findIndex((x) => keyOf(x) === prevKey); if (j >= 0) i = j; }
      select(i, keepSel ? wasOpen : t === 'rooms' && S.items.length === 1, true);
    }
  }
  function keyOf(it) { if (!it) return null; return it.name || it.object || it.model || it.id; }

  function emptyMsg(t) {
    if (q.value) return `<b>No match for “${esc(q.value)}”.</b>`;
    if (t === 'rooms') return '<b>No rooms yet.</b><span>Stand where the door should be, then press New room at my spot.</span>';
    if (t === 'inspect') return '<b>Nothing inspected yet.</b><span>Close the panel, hold middle mouse and aim at a prop, car or person.</span>';
    if (t === 'spots') return '<b>No spots yet.</b><span>Press Page Up anywhere to mark one.</span>';
    if (t === 'history') return '<b>No changes yet.</b>';
    return 'Nothing to show.';
  }
  function placeEmpty() {
    const rows = S.rooms.map((r) => `<button class="btn" data-a="decorateRoom" data-n="${esc(r.name)}">${esc(r.label)}</button>`).join('');
    return `<div class="empty"><b>Go into a room to decorate it.</b><span>Pick one and Studio takes you inside.</span><div class="acts">${rows}</div></div>`;
  }
  function doorsDoc() {
    return `<div class="doc"><p>Doors use the city's lock system. Its own window opens to set one up.</p>
      <ul><li>Point at a door, then name it and pick whether it starts locked.</li>
      <li>Under groups, add the jobs that may open it, with a lowest grade. For example police 0 and bcso 0 lets every deputy and officer in.</li>
      <li>Staff can be given access by job, by character, or by an item such as a key card.</li>
      <li>Doors work inside Studio rooms too. Stand inside the room before you open the maker.</li></ul>
      <div class="acts"><button class="btn pri" data-a="doors">Open the door maker</button></div></div>`;
  }

  function select(i, expand, noScroll) {
    if (!S.items.length) { S.sel = -1; return; }
    i = Math.max(0, Math.min(S.items.length - 1, i));
    const old = list.querySelector('.row.sel');
    if (old) { old.classList.remove('sel'); const d = old.querySelector('.det'); if (d) d.remove(); }
    S.sel = i; if (expand !== undefined) S.open = expand;
    const r = list.querySelector(`.row[data-i="${i}"]`); if (!r) return;
    r.classList.add('sel');
    if (S.open || S.tab === 'shells') r.insertAdjacentHTML('beforeend', detHtml(S.tab, S.items[i]));
    if (!noScroll) r.scrollIntoView({ block: 'nearest' });
    if (S.tab === 'shells') previewSoon(S.items[i].model);
  }

  /* ---------- loading ---------- */
  function load(tab) {
    const t = tab || S.tab;
    if (t === 'rooms' || t === 'place') return post('rooms').then((r) => { S.rooms = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
    if (t === 'spots') return post('spots').then((r) => { S.spots = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
    if (t === 'history') return post('history').then((r) => { S.hist = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
    if (t === 'inspect') return post('scans').then((r) => { S.scans = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
    render(true);
    return Promise.resolve();
  }
  function setTab(t) {
    if (!TABS.includes(t)) t = 'rooms';
    const same = S.tab === t;
    if (!same) { S.q[S.tab] = q.value; q.value = S.q[t] || ''; S.open = false; }
    if (t !== 'shells') { clearTimeout(S.shellTimer); S.pv = null; }
    S.tab = t;
    keep('dps-studio-tab', t);
    post('tab', { tab: t }).then((r) => { if (r && r.here !== undefined) S.here = r.here || null; load(t); });
    render(same);
  }
  function previewSoon(model) {
    clearTimeout(S.shellTimer);
    if (model === S.pv) return;   // already showing (for example after walking it)
    S.shellTimer = setTimeout(() => { S.pv = null; post('shell', { model }).then((r) => {
      if (r && r.ok) S.pv = model;
      else if (r && r.err) toast(r.err, true);   // no err: a newer pick replaced it
    }); }, 220);
  }

  /* ---------- actions ---------- */
  async function act(a, el) {
    const it = S.items[S.sel], t = S.tab;
    switch (a) {
      case 'pickCancel': S.pick = null; post('pickCancel'); render(true); return;
      case 'newRoom': {
        const v = await ask('New room at my spot', 'Stand at the door, facing it. Then pick a shell and mark the way out inside.', [
          { label: 'Short name (for commands and history)', ph: 'greenroom', max: 32 }, { label: 'Door words players read', ph: 'Green Room', max: 40 }], 'Pick a shell');
        if (!v) return;
        const r = await post('roomNew', { name: v[0], label: v[1] });
        if (!result(r)) return;
        S.pick = { name: v[0], label: v[1] }; setTab('shells'); return;
      }
      case 'decorate': if (!it) return; S.here = it.name; post('decorate', { name: it.name }).then((r) => { if (result(r)) setTab('place'); }); return;
      case 'decorateRoom': { const n = el.dataset.n; S.here = n; post('decorate', { name: n }).then((r) => { if (result(r)) setTab('place'); }); return; }
      case 'goIn': case 'goDoor': post('roomGo', { name: it.name, inside: a === 'goIn' }).then((r) => result(r)); return;
      case 'lookShow': post('lookSwitch', { name: it.name, id: el.dataset.id }).then((r) => { if (result(r, 'Everyone now sees this look')) load(); }); return;
      case 'lookRename': {
        const l = it.looks.find((x) => String(x.id) === el.dataset.id);
        const v = await ask('Rename look', '', [{ label: 'Look name', value: l ? l.name : '', max: 30 }]); if (!v) return;
        post('lookRename', { name: it.name, id: el.dataset.id, look: v[0] }).then((r) => { if (result(r, 'Renamed')) load(); }); return;
      }
      case 'lookDelete': {
        if (!await confirmBox('Remove look', 'The look goes to History, so it can be put back.', 'Remove')) return;
        post('lookDelete', { name: it.name, id: el.dataset.id }).then((r) => { if (result(r, 'Removed')) load(); }); return;
      }
      case 'lookNewCopy': case 'lookNewEmpty': {
        const v = await ask(a === 'lookNewCopy' ? 'New look from this one' : 'New empty look', 'The new look shows straight away. The old one is kept.', [{ label: 'Look name', ph: 'Halloween', max: 30 }]); if (!v) return;
        post('lookNew', { name: it.name, look: v[0], copy: a === 'lookNewCopy' }).then((r) => { if (result(r, 'Look made')) load(); }); return;
      }
      case 'label': {
        const v = await ask('Change door words', '', [{ label: 'Door words players read', value: it.label, max: 40 }]); if (!v) return;
        post('roomLabel', { name: it.name, label: v[0] }).then((r) => { if (result(r, 'Saved')) load(); }); return;
      }
      case 'door': {
        if (!await confirmBox('Move the door to me', `The door of ${it.label} moves to where you stand now, facing your way. The room and its looks come with it.`, 'Move it')) return;
        post('roomDoor', { name: it.name }).then((r) => { if (result(r, 'Door moved')) load(); }); return;
      }
      case 'redo': {
        if (!await confirmBox('Change shell or way out', 'Pick a shell and mark the way out again. With the same shell every look stays. A different shell starts with one empty look, and the old room stays in History.', 'Go on')) return;
        const r = await post('roomNew', { name: it.name, label: it.label, keepDoor: true });
        if (!result(r)) return;
        S.pick = { name: it.name, label: it.label }; setTab('shells'); return;
      }
      case 'copy': {
        const v = await ask('Copy room to my spot', 'A new door where you stand, with the same shell and every look.', [
          { label: 'Short name', ph: it.name + '2', max: 32 }, { label: 'Door words players read', value: it.label, max: 40 }], 'Copy');
        if (!v) return;
        post('roomCopy', { name: it.name, newName: v[0], label: v[1] }).then((r) => { if (result(r, 'Copied')) load(); }); return;
      }
      case 'delete': {
        if (!await confirmBox('Remove room', `${it.label} goes away for everyone. It stays in History and can be put back.`, 'Remove')) return;
        post('roomDelete', { name: it.name }).then((r) => { if (result(r, 'Removed')) load(); }); return;
      }
      case 'edit': post('edit').then((r) => result(r)); return;
      case 'place': if (it) post('place', { model: it.object }).then((r) => result(r)); return;
      case 'walk': post('walk'); return;
      case 'stop': clearTimeout(S.shellTimer); S.pv = null; post('previewStop'); return;
      case 'copyName': if (it) copy(it.object || it.model || it.name); return;
      case 'copyHash': if (it && it.hash) copy(String(it.hash)); return;
      case 'copyV3': case 'copyV4': copy(el.dataset.v); return;
      case 'spotGo': if (it) post('spotGo', { x: it.x, y: it.y, z: it.z, h: it.h }); return;
      case 'markSpot': {
        const v = await ask('Mark my spot', 'Saves where you stand now.', [{ label: 'Words (optional)', max: 80, required: false }], 'Mark'); if (!v) return;
        post('spotMark', { label: v[0] }).then(() => setTimeout(() => load('spots'), 400)); return;
      }
      case 'restore': {
        if (!await confirmBox('Put it back', it.summary, 'Put it back')) return;
        post('restore', { id: it.id }).then((r) => { if (result(r, 'Put back')) load(); }); return;
      }
      case 'doors': post('doors'); return;
    }
  }

  /* ---------- events ---------- */
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-a]'); if (b && !modal.contains(b)) { e.stopPropagation(); act(b.dataset.a, b); return; }
    const tbtn = e.target.closest('.mode'); if (tbtn) { setTab(tbtn.dataset.t); return; }
    const c = e.target.closest('.chip'); if (c && chips.contains(c)) {
      if (c.dataset.s) { S.src = c.dataset.s; S.chip.lib = S.src === 'build' ? 'all' : 'lighting'; keep('dps-studio-src', S.src); render(false); return; }
      S.chip[S.tab === 'place' && S.src !== 'housing' ? 'lib' : S.tab] = c.dataset.c; render(false); return;
    }
    const r = e.target.closest('.row'); if (r && list.contains(r) && !e.target.closest('.det')) { const i = +r.dataset.i; select(i, i === S.sel ? !S.open : true); }
  });
  list.addEventListener('dblclick', (e) => { const r = e.target.closest('.row'); if (r && !e.target.closest('.det')) primary(); });
  list.addEventListener('error', (e) => { if (e.target.tagName === 'IMG') e.target.parentNode.innerHTML = '<i class="fa-solid fa-couch"></i>'; }, true);
  function closeModal() { if (!modal.hidden) { const n = modal.querySelector('#fno'); if (n) n.click(); else { modal.hidden = true; modal.innerHTML = ''; } } }
  $('#close').addEventListener('click', () => { closeModal(); post('close'); });
  $('#fleet').addEventListener('click', () => post('fleet'));
  let qt = null; q.addEventListener('input', () => { clearTimeout(qt); qt = setTimeout(() => { qt = null; render(false); }, 90); });
  q.addEventListener('focus', () => bar.classList.add('focus'));
  q.addEventListener('blur', () => bar.classList.remove('focus'));

  function primary() {
    const t = S.tab;
    if (t === 'rooms') return act('decorate');
    if (t === 'place') return act('place');
    if (t === 'shells') return act('walk');
    if (t === 'spots') { const it = S.items[S.sel]; if (it) copy(`vector4(${f2(it.x)}, ${f2(it.y)}, ${f2(it.z)}, ${Number(it.h || 0).toFixed(1)})`); return; }
    if (t === 'history') return select(S.sel, true);
    if (t === 'inspect') return act('copyName');
    if (t === 'doors') return act('doors');
  }

  document.addEventListener('keydown', (e) => {
    if (app.hidden) return;
    if (!modal.hidden) { if (e.key === 'Escape') { e.preventDefault(); modal.querySelector('#fno') && modal.querySelector('#fno').click(); } return; }
    const typing = document.activeElement === q;
    const onButton = document.activeElement && document.activeElement.tagName === 'BUTTON';
    if (e.key === 'Escape') { e.preventDefault(); if (typing && q.value) { q.value = ''; render(false); } else post('close'); return; }
    if (onButton && (e.key === 'Enter' || e.key === ' ')) return;   // a focused button presses itself
    if (e.key === 'ArrowDown') { e.preventDefault(); select(S.sel + 1, S.tab === 'shells' ? undefined : S.open); if (typing) list.focus(); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); select(S.sel - 1, S.tab === 'shells' ? undefined : S.open); if (typing) list.focus(); return; }
    if (e.key === 'Enter') { e.preventDefault(); if (qt) { clearTimeout(qt); qt = null; render(false); } if (S.tab === 'rooms' && !S.open) select(S.sel, true); else primary(); return; }
    if (e.key === 'Tab') return;   // Tab walks through the buttons as normal
    if (typing) return;
    if (/^[1-7]$/.test(e.key)) { e.preventDefault(); setTab(TABS[Number(e.key) - 1]); return; }
    const k = e.key.toLowerCase();
    if (S.tab === 'shells') {
      if (k === 'arrowleft') { e.preventDefault(); return post('cam', { turn: -8 }); }
      if (k === 'arrowright') { e.preventDefault(); return post('cam', { turn: 8 }); }
      if (k === 'pageup') { e.preventDefault(); return post('cam', { tilt: 0.08 }); }
      if (k === 'pagedown') { e.preventDefault(); return post('cam', { tilt: -0.08 }); }
    }
    if (S.tab === 'rooms' && k === 'n') { e.preventDefault(); return act('newRoom'); }
    if (S.tab === 'place' && k === 'm') { e.preventDefault(); return act('edit'); }
    if (k.length === 1 && k !== ' ' && !e.ctrlKey && !e.altKey && !e.metaKey && S.tab !== 'doors') q.focus();
  });

  /* stage: drag to turn, wheel to zoom (shell preview only) */
  let drag = null;
  stage.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY, t: 0 }; stage.setPointerCapture(e.pointerId); });
  stage.addEventListener('pointermove', (e) => {
    if (!drag) return;
    const now = Date.now(); if (now - drag.t < 30) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y; drag.x = e.clientX; drag.y = e.clientY; drag.t = now;
    if (dx || dy) post('cam', { turn: dx * 0.35, tilt: dy * 0.004 });
  });
  stage.addEventListener('pointerup', () => { drag = null; });
  stage.addEventListener('wheel', (e) => { e.preventDefault(); post('cam', { zoom: e.deltaY > 0 ? 1 : -1 }); }, { passive: false });

  /* move and resize, remembered per player */
  const geo = store('dps-studio-geo', { x: 24, y: null, w: 600, h: 66 });
  function applyGeo() {
    const vw = window.innerWidth, vh = window.innerHeight;
    const w = Math.max(420, Math.min(vw - 20, geo.w)); geo.w = w;
    document.documentElement.style.setProperty('--w', w + 'px');
    document.documentElement.style.setProperty('--h', Math.max(30, Math.min(88, geo.h)) + 'vh');
    // the whole panel stays on screen: left edge, top edge and bottom edge
    const x = Math.max(0, Math.min(vw - w, geo.x));
    const top = geo.y == null ? Math.round(vh * 0.06) : Math.max(0, Math.min(vh - 260, geo.y));
    app.style.left = x + 'px';
    app.style.top = top + 'px';
    document.documentElement.style.setProperty('--maxh', Math.max(200, vh - top - 50 - 8 - 12) + 'px');
  }
  function dragger(handle, onMove) {
    let sx = 0, sy = 0, active = false, base = null;
    handle.addEventListener('pointerdown', (e) => { sx = e.clientX; sy = e.clientY; active = true; base = Object.assign({}, geo, { top: app.offsetTop }); handle.setPointerCapture(e.pointerId); handle.classList.add('on'); e.preventDefault(); });
    handle.addEventListener('pointermove', (e) => { if (active) { onMove(e.clientX - sx, e.clientY - sy, base); applyGeo(); } });
    handle.addEventListener('pointerup', () => { active = false; handle.classList.remove('on'); keep('dps-studio-geo', geo); });
  }
  dragger($('#grip'), (dx, dy, b) => { geo.x = b.x + dx; geo.y = b.top + dy; });
  dragger($('#wgrip'), (dx, _, b) => { geo.w = b.w + dx; });
  dragger($('#hgrip'), (_, dy, b) => { geo.h = b.h + (dy / window.innerHeight) * 100; });
  applyGeo();
  window.addEventListener('resize', applyGeo);

  /* ---------- no-focus overlays ---------- */
  function showKeys(m) {
    const k = $('#keys');
    if (!m.keys) { k.hidden = true; k.innerHTML = ''; return; }
    k.innerHTML = `<h5>${esc(m.title || '')}</h5><div class="ks">${m.keys.map(([a, b]) => `<span class="k"><kbd>${esc(a)}</kbd>${esc(b)}</span>`).join('')}</div>`;
    k.hidden = false;
  }
  function showPrompt(m) {
    const p = $('#prompt');
    if (!m.text) { p.hidden = true; return; }
    p.innerHTML = `<kbd>${esc(m.key || 'E')}</kbd><span>${esc(m.text)}</span>`; p.hidden = false;
  }
  let cardT;
  function showCard(html, ms) {
    const c = $('#card'); clearTimeout(cardT);
    if (html == null) { c.hidden = true; return; }
    c.innerHTML = html; c.hidden = false;
    if (ms) cardT = setTimeout(() => { c.hidden = true; }, ms);
  }
  function inspectCard(d) {
    const v4 = d.x != null ? `vector4(${f2(d.x)}, ${f2(d.y)}, ${f2(d.z)}, ${Number(d.h || 0).toFixed(1)})` : '';
    return `<h5>INSPECT</h5><div class="big">${esc(d.name)}</div><dl>
      ${d.where ? `<dt>You</dt><dd>${esc(d.where)}</dd>` : ''}
      ${d.kind ? `<dt>Kind</dt><dd>${esc(d.kind)}</dd>` : ''}${d.hash ? `<dt>Hash</dt><dd>${esc(d.hash)}</dd>` : ''}${v4 ? `<dt>Spot</dt><dd>${esc(v4)}</dd>` : ''}</dl>
      ${d.note ? `<p>${esc(d.note)}</p>` : ''}<p>Open /admin, Inspect tab, to copy it.</p>`;
  }

  /* ---------- messages from the game ---------- */
  window.addEventListener('message', (e) => {
    const m = e.data || {};
    switch (m.action) {
      case 'open':
        S.shown = true; app.hidden = false;
        S.here = m.here || null;
        if (m.pick !== undefined) S.pick = m.pick || null;
        S.pv = m.previewing || null;
        S.src = store('dps-studio-src', 'decorate'); if (!['decorate', 'build', 'housing'].includes(S.src)) S.src = 'decorate';
        if (!S.lib) fetch('library.json').then((r) => r.json()).then((d) => {
          if (!d || !Array.isArray(d.groups)) throw new Error('bad');
          // label and search words worked out once, not on every key press
          for (const g of d.groups) {
            g.items = g.items.map(([m, src, use]) => { const label = pretty(m); return { m, src, use: use === 'd' ? 'decorate' : 'build', label, hay: `${m} ${label} ${src} ${g.label}`.toLowerCase() }; });
            g.n = { decorate: g.items.filter((i) => i.use === 'decorate').length, build: 0 };
            g.n.build = g.items.length - g.n.decorate;
          }
          S.lib = d; if (S.shown && S.tab === 'place') render(true);
        }).catch(() => { S.src = 'housing'; toast('The library did not load, showing housing furniture', true); if (S.shown && S.tab === 'place') render(true); });
        (S.boot && !S.boot.missing ? Promise.resolve({ ok: true }) : post('boot').then((r) => {
          if (r && r.ok) {
            r.shells = Array.isArray(r.shells) ? r.shells : [];
            r.furniture = Array.isArray(r.furniture) ? r.furniture : [];
            S.boot = r;
            if (r.missing) toast('Could not read the housing ' + r.missing.trim() + ' list. Close and open again in a moment.', true);
          } else toast('Studio did not load. Are you an admin?', true);
        }))
          .then(() => { setTab(m.tab || store('dps-studio-tab', 'rooms')); list.focus(); });
        break;
      case 'libBad': S.bad = new Set(Array.isArray(m.names) ? m.names : []); if (S.shown && S.tab === 'place') render(true); break;
      case 'hide': S.shown = false; clearTimeout(S.shellTimer); closeModal(); app.hidden = true; stage.hidden = true; break;
      case 'keys': showKeys(m); break;
      case 'prompt': showPrompt(m); break;
      case 'inspect':
        if (m.card) showCard(inspectCard(m.card));
        else if (m.linger) { clearTimeout(cardT); cardT = setTimeout(() => showCard(null), m.linger); }
        break;
      case 'pos': showCard(`<h5>F3 COORDS · #${esc(m.id)}</h5><div class="big">${esc(m.text)}</div>${m.where ? `<dl><dt>You</dt><dd>${esc(m.where)}</dd></dl>` : ''}<p>Saved. Open /admin, Spots tab, to copy it.</p>`, 12000); break;
      case 'changed':
        if (m.here !== undefined) S.here = m.here || null;
        if (S.shown && (!m.what || m.what === S.tab)) load();
        break;
    }
  });
})();
