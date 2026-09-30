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
    place: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> place or move &nbsp;<kbd>M</kbd> pieces in this room &nbsp;<kbd>Delete</kbd> remove · type to search',
    shells: '<kbd>↑↓</kbd> next shell &nbsp;<kbd>← →</kbd> or drag to turn &nbsp;<kbd>Page Up / Down</kbd> tilt &nbsp;wheel zoom &nbsp;<kbd>Enter</kbd> walk inside',
    inspect: 'Hold <kbd>Middle mouse</kbd> anywhere to inspect. The last 30 are kept here.',
    spots: '<kbd>Page Up</kbd> marks a spot &nbsp;<kbd>F3</kbd> captures coords &nbsp;<kbd>Enter</kbd> open · type to search',
    doors: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> open or save &nbsp;<kbd>1-7</kbd> tabs · type to search',
    history: '<kbd>↑↓</kbd> move &nbsp;<kbd>Enter</kbd> open · every change can be put back',
  };
  const PH = { rooms: 'Search rooms…', place: 'Search furniture…', shells: 'Search shells: warehouse, office, garage…', inspect: 'Search scans…', spots: 'Search spots…', doors: 'Search doors: name, job, room…', history: 'Search history…' };

  const S = { tab: 'rooms', boot: null, rooms: [], spots: [], hist: [], scans: [], here: null, pick: null,
              items: [], sel: -1, open: false, chip: { place: 'all', lib: 'lighting', shells: 'all', spots: 'all' }, q: {}, shellTimer: null, shown: false, pv: null,
              src: 'decorate', lib: null, bad: new Set(), more: 0, pieces: [], thumbs: {},
              shellSrc: 'shells', ipls: null, iplStyle: {}, styling: null, doors: [], pickers: null, acc: {} };
  const iplLabel = (exp) => { if (/^at:/.test(exp || '')) return 'a place in the world (' + exp.slice(3) + ')'; const e = (S.ipls || []).find((x) => x.export === exp); return e ? e.label : exp; };
  const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v)) ? v : {};   // an empty Lua table arrives as []
  const styleOf = (exp) => S.iplStyle[exp] || (S.iplStyle[exp] = { preset: 'default', choice: {}, on: {} });
  const PRESET = { default: 'As the game has it', full: 'Full, everything on', empty: 'Empty', custom: 'Pick each part' };
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
        if (S.src === 'pieces') {
          return S.pieces.filter((p) => match(`${p.model} ${pretty(p.model)}`))
            .map((p) => ({ object: p.model, label: pretty(p.model), id: p.id, dist: p.dist, piece: true }));
        }
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
        if (S.shellSrc === 'ipls') {
          return (S.ipls || []).filter((e) => (S.chip.ipls === undefined || S.chip.ipls === 'all' || e.group === S.chip.ipls) && match(`${e.label} ${e.group} ${e.export}`))
            .map((e) => ({ ipl: true, export: e.export, label: e.label, group: e.group, groups: e.groups, model: e.export }));
        }
        if (!S.boot) return [];
        const meta = S.boot.meta || {};
        return S.boot.shells.filter((m) => (S.chip.shells === 'all' || (meta[m] && meta[m].use === S.chip.shells)) && match(shellWords(m))).map((m) => ({ model: m, meta: meta[m] }));
      }
      case 'inspect': return S.scans.filter((s) => match(`${s.name} ${s.kind} ${s.note || ''}`));
      case 'spots': return S.spots.filter((s) => (S.chip.spots === 'all' || s.kind === S.chip.spots) && match(`${s.id} ${s.label} ${s.street} ${s.zone} ${s.by_name} ${s.kind}`));
      case 'history': return S.hist.filter((h) => match(`${h.summary} ${h.room} ${h.by_name} ${h.action}`));
      case 'doors': return S.doors.filter((d) => match(`${d.name} ${d.id} ${d.room || ''} ${accessSummary(d.access)}`)).map((d) => Object.assign({ door: true }, d));
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
      nm = esc(it.label); mt = `<code>${esc(it.name)}</code> · ${esc(it.kind === 'ipl' ? iplLabel(it.ipl) : it.shell)} · look <b>${esc(it.lookName)}</b>`;
      rt = pieceMeter(it.count, it.max) + (S.here === it.name ? '<span class="badge on">You are here</span>' : '');
    } else if (tab === 'place') {
      const pic = it.img || S.thumbs[it.object];
      thumb = pic ? `<img src="${esc(pic)}" alt="" loading="lazy">` : `<i class="fa-solid ${it.lib ? (LIB_ICON[it.gkey] || 'fa-cube') : 'fa-couch'}"></i>`;
      nm = esc(it.label);
      mt = it.piece ? `<code>${esc(it.object)}</code> · ${it.dist} m from you` : `<code>${esc(it.object)}</code> · ${esc(it.cat)}${it.lib ? ' · ' + esc(it.src === 'Game' ? 'game' : it.src) : ''}`;
      if (it.piece) thumb = '<i class="fa-solid fa-location-crosshairs"></i>';
    } else if (tab === 'shells' && it.ipl) {
      thumb = '<i class="fa-solid fa-building"></i>';
      nm = esc(it.label); mt = `${esc(it.group)} · ${it.groups.length ? it.groups.length + ' style parts' : 'one look'}`;
      const owner = S.rooms.find((r) => r.kind === 'ipl' && r.ipl === it.export);
      if (S.styling && S.styling.export === it.export) rt = '<span class="badge on">Styling</span>';
      else if (owner) rt = `<span class="badge">Used by ${esc(owner.label)}</span>`;
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
    } else if (tab === 'doors') {
      thumb = `<i class="fa-solid ${Number(it.state) === 1 ? 'fa-lock' : 'fa-lock-open'}"></i>`;
      nm = esc(it.name); mt = `#${it.id}${it.double ? ' · double' : ''} · ${esc(accessSummary(it.access))}${it.room ? ' · room ' + esc(it.room) : ''}`;
      rt = `<span class="badge${Number(it.state) === 1 ? ' on' : ''}">${Number(it.state) === 1 ? 'Locked' : 'Open'}</span>`;
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
        <span class="lbl">Door and ${it.kind === 'ipl' ? 'interior' : 'shell'}</span>
        <div class="acts"><button data-a="door">Move the door to me</button><button data-a="redo">Change ${it.kind === 'ipl' ? 'interior' : 'shell'} or way out</button><button data-a="copy">Copy room to my spot</button></div>
        ${it.kind === 'ipl' ? `<p>Interior: <b>${esc(iplLabel(it.ipl))}</b> · style: ${esc(PRESET[(it.style || {}).preset] || PRESET.default)}</p><div class="acts"><button data-a="restyle">Change style</button></div>` : ''}
        <div class="acts"><button class="bad" data-a="delete">Remove room</button></div>
        ${(() => { const key = 'room:' + it.name; if (!S.acc[key]) S.acc[key] = accCopy(it.access); return accessHtml(key, false); })()}
        <div class="acts"><button data-a="roomAccessSave">Save who can go in${(it.doors || []).length ? ' (and its ' + it.doors.length + ' doors)' : ''}</button></div>
        <p>Last change: ${esc(it.updatedBy || '-')} · ${esc(it.updatedAt || '-')}</p></div>`;
    }
    if (tab === 'place' && it.piece) return `<div class="det"><p>This piece is lit up orange in the room.</p><div class="acts"><button class="pri" data-a="pieceMove">Move it <kbd>Enter</kbd></button><button class="bad" data-a="pieceRemove">Remove <kbd>Delete</kbd></button><button data-a="copyName">Copy name</button></div></div>`;
    if (tab === 'place') return `<div class="det"><div class="acts"><button class="pri" data-a="place">Place it <kbd>Enter</kbd></button><button data-a="copyName">Copy name</button></div></div>`;
    if (tab === 'shells' && it.ipl) {
      const st = styleOf(it.export);
      const presets = Object.keys(PRESET).map((k) => `<button class="chip${st.preset === k ? ' on' : ''}" data-a="iplPreset" data-v="${k}">${esc(PRESET[k])}</button>`).join('');
      let parts = '';
      if (st.preset === 'custom') {
        parts = it.groups.map((g) => {
          const chips = g.options.map((o) => {
            const on = g.kind === 'many' ? !!(st.on[g.key] && st.on[g.key][o]) : st.choice[g.key] === o;
            return `<button class="chip${on ? ' on' : ''}" data-a="iplOpt" data-g="${esc(g.key)}" data-o="${esc(o)}" data-k="${g.kind}">${esc(o)}</button>`;
          }).join('');
          const none = g.kind === 'many' ? '' : `<button class="chip${!st.choice[g.key] ? ' on' : ''}" data-a="iplOpt" data-g="${esc(g.key)}" data-o="" data-k="${g.kind}">none</button>`;
          return `<span class="lbl">${esc(g.key)}${g.kind === 'many' ? ' · switch each on or off' : ''}</span><div class="chips inl">${none}${chips}</div>`;
        }).join('') || '<p>This interior has no parts to pick.</p>';
      }
      const how = S.pick ? '<p>Go inside, stand where people should arrive, face into the room and press <kbd>G</kbd>.</p>' : '<p>Go inside to see it. Style changes show straight away while you are in there.</p>';
      const save = S.styling && S.styling.export === it.export ? '<button class="pri" data-a="saveStyle">Save style to the room</button>' : '';
      return `<div class="det">${how}<span class="lbl">Style</span><div class="chips inl">${presets}</div>${parts}
        <div class="acts">${save}<button class="${save ? '' : 'pri'}" data-a="iplGo">Go inside <kbd>Enter</kbd></button><button data-a="copyName">Copy name</button></div></div>`;
    }
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
    if (tab === 'doors') {
      const key = 'door:' + it.id;
      if (!S.acc[key]) S.acc[key] = accCopy(it.access);
      return `<div class="det">${accessHtml(key, true)}
        <span class="lbl">Settings</span>
        <div class="chips inl"><button class="chip${Number(it.state) === 1 ? ' on' : ''}" data-a="doorLock">Locked</button><button class="chip${it.lockpick ? ' on' : ''}" data-a="doorPick">Can be lockpicked</button></div>
        <div class="addrow"><label class="small">Locks again after (seconds, 0 = never)<input id="door-auto" type="text" value="${esc(it.autolock || 0)}"></label><label class="small">Usable from (metres)<input id="door-dist" type="text" value="${esc(it.maxDistance || 2)}"></label></div>
        <div class="acts"><button class="pri" data-a="doorSave">Save <kbd>Enter</kbd></button><button data-a="doorGo">Go to the door</button><button class="bad" data-a="doorRemove">Remove</button></div></div>`;
    }
    if (tab === 'history') {
      if (/^door:/.test(it.room || '') && Number(it.has_before)) return `<div class="det"><div class="acts"><button class="pri" data-a="doorRestore">Put this door back</button></div></div>`;
      if (Number(it.has_before)) return `<div class="det"><div class="acts"><button class="pri" data-a="restore">Put the room back to before this</button></div><p>The current state is saved first, so this can be put back too.</p></div>`;
      if (!Number(it.pruned) && ['create', 'copy', 'import'].includes(it.action)) return `<div class="det"><div class="acts"><button class="pri" data-a="restore">Undo: remove the room this made</button></div><p>The room is saved first, so this can be put back too.</p></div>`;
      return `<div class="det"><p>${Number(it.pruned) ? 'This change is too old to put back. Each room keeps its last 200.' : 'Nothing to put back for this line.'}</p></div>`;
    }
    return '';
  }

  /* ---------- render ---------- */
  function renderHead() {
    const t = S.tab;
    banner.hidden = !((S.pick || S.styling) && (t === 'rooms' || t === 'shells'));
    if (!banner.hidden && S.pick) banner.innerHTML = `<span>Making <b>${esc(S.pick.label)}</b>. Choose where it leads:</span>
      <button class="btn${S.shellSrc === 'shells' ? ' pri' : ''}" data-a="useShell"><i class="fa-solid fa-cube"></i>&nbsp;Use a shell</button>
      <button class="btn${S.shellSrc === 'ipls' ? ' pri' : ''}" data-a="useIpl"><i class="fa-solid fa-building"></i>&nbsp;Use a game interior</button>
      <button class="btn" data-a="usePlace"><i class="fa-solid fa-person-walking"></i>&nbsp;Use a place I go to</button>
      <button class="btn" data-a="pickCancel">Cancel</button>`;
    else if (!banner.hidden) banner.innerHTML = `<span>Styling <b>${esc(S.styling.label)}</b>: pick a style, then Save style to the room.</span><button class="btn" data-a="stylingCancel">Cancel</button>`;
    let h = '';
    if (t === 'rooms') h = `<span class="grow">${S.rooms.length} rooms. A room is a door, a shell and saved looks of furniture.</span><button class="btn pri" data-a="newRoom">New room at my spot <kbd>N</kbd></button>`;
    else if (t === 'place') {
      const r = roomByName(S.here);
      h = (r ? `<span class="grow"><b>${esc(r.label)}</b> · look <b>${esc(r.lookName)}</b></span>${pieceMeter(r.count, r.max)}<button class="btn" data-a="showPieces">Move or remove <kbd>M</kbd></button>` : '<span class="grow">Place</span>') + boothButton();
    } else if (t === 'shells') h = S.shellSrc === 'ipls'
      ? `<span class="grow">${S.ipls ? S.ipls.length : 0} game interiors. Each one serves one room.</span>`
      : `<span class="grow">${S.boot ? S.boot.shells.length : 0} shells from the housing list. The one you pick floats in the sky so open shells show from every side.</span>`;
    else if (t === 'spots') h = `<span class="grow">${S.spots.length} spots, newest first.</span><button class="btn pri" data-a="markSpot">Mark my spot</button>`;
    else if (t === 'doors') h = `<span class="grow">${S.doors.length} doors in the city's lock system.</span><button class="btn pri" data-a="doorNew">New door</button>`;
    else if (t === 'inspect') h = `<span class="grow">Hold middle mouse and aim. Close this panel first so you can look around.</span>`;
    head.innerHTML = h;

    let c = '';
    if (t === 'place' && S.here) {
      const srcs = `<button class="chip src${S.src === 'pieces' ? ' on' : ''}" data-s="pieces"><i class="fa-solid fa-location-crosshairs"></i> In this room${S.pieces.length ? ' · ' + S.pieces.length : ''}</button><button class="chip src${S.src === 'decorate' ? ' on' : ''}" data-s="decorate"><i class="fa-solid fa-couch"></i> Decorate</button><button class="chip src${S.src === 'build' ? ' on' : ''}" data-s="build"><i class="fa-solid fa-trowel-bricks"></i> Build</button><button class="chip src${S.src === 'housing' ? ' on' : ''}" data-s="housing"><i class="fa-solid fa-image"></i> Housing furniture, with pictures</button><span class="brk"></span>`;
      if (S.src === 'pieces') c = srcs;
      else if ((S.src === 'decorate' || S.src === 'build') && S.lib) c = srcs + [['all', 'All']].concat(S.lib.groups.filter((g) => g.n[S.src] > 0).map((g) => [g.key, g.label])).map(([k, l]) => `<button class="chip${S.chip.lib === k && !q.value.trim() ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('') + (q.value.trim() ? '<span class="brk"></span><span class="hint2">Searching every group</span>' : '');
      else if (S.boot) c = srcs + [['all', 'All']].concat(S.boot.furniture.map((f) => [f.key, f.label])).map(([k, l]) => `<button class="chip${S.chip.place === k ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('');
      else c = srcs;
    }
    else if (t === 'shells') {
      const srcs = `<button class="chip src${S.shellSrc === 'shells' ? ' on' : ''}" data-ss="shells"><i class="fa-solid fa-cube"></i> Shells</button><button class="chip src${S.shellSrc === 'ipls' ? ' on' : ''}" data-ss="ipls"><i class="fa-solid fa-building"></i> Interiors${S.ipls ? ' · ' + S.ipls.length : ''}</button><span class="brk"></span>`;
      if (S.shellSrc === 'ipls') {
        const groups = Array.from(new Set((S.ipls || []).map((e) => e.group))).sort();
        c = srcs + [['all', 'All']].concat(groups.map((g) => [g, g])).map(([k, l]) => `<button class="chip${(S.chip.ipls || 'all') === k ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('');
      } else if (S.boot) {
        const uses = Array.from(new Set(Object.values(S.boot.meta || {}).map((m) => m.use))).sort();
        c = srcs + [['all', 'All']].concat(uses.map((u) => [u, u])).map(([k, l]) => `<button class="chip${S.chip.shells === k ? ' on' : ''}" data-c="${esc(k)}">${esc(l)}</button>`).join('');
      } else c = srcs;
    } else if (t === 'spots') c = [['all', 'All'], ['spot', 'Spots'], ['pos', 'F3 coords']].map(([k, l]) => `<button class="chip${S.chip.spots === k ? ' on' : ''}" data-c="${k}">${l}</button>`).join('');
    chips.innerHTML = c; chips.hidden = !c;
  }

  function render(keepSel) {
    const t = S.tab, prevKey = keepSel ? keyOf(S.items[S.sel]) : null, wasOpen = S.open;
    renderHead();
    hint.innerHTML = HINTS[t] || '';
    document.querySelectorAll('.mode').forEach((b) => b.classList.toggle('on', b.dataset.t === t));
    q.disabled = false; q.placeholder = PH[t] || '';
    stage.hidden = !(t === 'shells' && S.shown && S.shellSrc !== 'ipls');

    if (t === 'place' && S.here && (S.src === 'decorate' || S.src === 'build') && !S.lib) { renderHead(); list.innerHTML = '<div class="empty"><b>Loading the library…</b></div>'; S.items = []; return; }
    if (t === 'place' && !S.here) { renderHead(); list.innerHTML = placeEmpty(); S.items = []; $('#cnt').textContent = ''; return; }
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
    if (S.tab === 'shells' && !S.items[i].ipl) previewSoon(S.items[i].model);
    if (S.tab === 'place' && S.src === 'pieces' && S.items[i].piece) post('highlight', { id: S.items[i].id });
  }

  /* ---------- loading ---------- */
  function load(tab) {
    const t = tab || S.tab;
    if (t === 'rooms') loadPickers();
    if (t === 'rooms' || t === 'place' || t === 'shells') {
      if (t === 'place' && S.src === 'pieces') loadPieces();
      return post('rooms').then((r) => { S.rooms = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
    }
    if (t === 'doors') return Promise.all([loadPickers(), post('doorsList')]).then(([, r]) => { S.doors = Array.isArray(r) ? r : []; if (S.tab === t) render(true); });
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
  // pieces on the chosen side (Decorate or Build) that still have no picture
  function boothList() {
    if (!S.lib) return [];
    const side = S.src === 'build' ? 'build' : 'decorate';
    const out = [];
    for (const g of S.lib.groups) for (const it of g.items) if (it.use === side && !S.bad.has(it.m) && !S.thumbs[it.m]) out.push(it.m);
    return out;
  }
  function boothButton() {
    if (!S.lib) return '';
    const need = boothList().length;
    return need ? `<button class="btn pri" data-a="booth"><i class="fa-solid fa-camera"></i>&nbsp;Take photos · ${need.toLocaleString('en-US')} to go</button>` : '<span class="badge on">Every piece has a photo</span>';
  }
  function loadThumbs() { return post('thumbs').then((t) => { if (t && typeof t === 'object' && !Array.isArray(t)) S.thumbs = t; if (S.shown && S.tab === 'place') render(true); }); }
  // crop the middle of a full screenshot to a small square webp for the booth
  function cropShot(model, dataUri) {
    const img = new Image();
    img.onload = () => {
      const side = Math.min(img.width, img.height) * 0.92, sx = (img.width - side) / 2, sy = (img.height - side) / 2;
      const c = document.createElement('canvas'); c.width = 224; c.height = 224;
      c.getContext('2d').drawImage(img, sx, sy, side, side, 0, 0, 224, 224);
      const out = c.toDataURL('image/webp', 0.78);
      post('cropDone', { model, b64: out.slice(out.indexOf(',') + 1) });
    };
    img.onerror = () => post('cropDone', { model, b64: false });
    img.src = dataUri;
  }
  /* ---------- who can go in: one editor for doors, rooms and new rooms ---------- */
  const accCopy = (a) => {
    a = obj(a);
    return { open: a.open !== false && !(a.staff || Object.keys(obj(a.groups)).length || (a.items || []).length || (a.characters || []).length || a.passcode),
             staff: !!a.staff, groups: Object.assign({}, obj(a.groups)), items: Array.isArray(a.items) ? a.items.slice() : [],
             characters: Array.isArray(a.characters) ? a.characters.slice() : [], passcode: a.passcode || '' };
  };
  const pickLabel = (name) => { const j = S.pickers && S.pickers.jobs.find((x) => x.name === name); return j ? j.label : name; };
  const itemLabel = (name) => { const i = S.pickers && S.pickers.items.find((x) => x.name === name); return i ? i.label : name; };
  function accessSummary(a) {
    a = obj(a);
    if (a.open !== false && !(a.staff || Object.keys(obj(a.groups)).length || (a.items || []).length || (a.characters || []).length)) return 'Everyone';
    const parts = [];
    Object.keys(obj(a.groups)).forEach((g) => parts.push(`${pickLabel(g)} ${a.groups[g]}+`));
    (a.items || []).forEach((i) => parts.push('key: ' + itemLabel(i)));
    if ((a.characters || []).length) parts.push(a.characters.length + ' named');
    if (a.staff) parts.push('staff');
    return parts.join(', ') || 'Locked to everyone';
  }
  function accessHtml(key, withPasscode) {
    const a = S.acc[key];
    const jobs = (S.pickers && S.pickers.jobs) || [], items = (S.pickers && S.pickers.items) || [];
    let h = `<span class="lbl">Who can go in</span><div class="chips inl">
      <button class="chip${a.open ? ' on' : ''}" data-a="accOpen" data-k="${esc(key)}">Everyone</button>
      <button class="chip${!a.open ? ' on' : ''}" data-a="accLimit" data-k="${esc(key)}">Only some people</button></div>`;
    if (a.open) return h;
    const rows = Object.keys(a.groups).map((g) => {
      const j = jobs.find((x) => x.name === g);
      const opts = (j ? j.grades : [{ level: a.groups[g], name: '' }]).map((gr) => `<option value="${gr.level}"${gr.level === a.groups[g] ? ' selected' : ''}>${gr.level}${gr.name ? ' · ' + esc(gr.name) : ''} and up</option>`).join('');
      return `<div class="look"><span class="ln">${esc(pickLabel(g))}<small>${esc(g)}</small></span><select class="sel" data-a="accGrade" data-k="${esc(key)}" data-g="${esc(g)}">${opts}</select><button data-a="accDelGroup" data-k="${esc(key)}" data-g="${esc(g)}">Remove</button></div>`;
    }).join('');
    h += `<span class="lbl">Jobs and gangs</span><div class="looks">${rows}</div>
      <div class="addrow"><input list="dl-jobs" id="acc-job-${esc(key)}" placeholder="Type a job or gang, then Add"><button class="btn" data-a="accAddGroup" data-k="${esc(key)}">Add</button></div>
      <datalist id="dl-jobs">${jobs.map((j) => `<option value="${esc(j.name)}">${esc(j.label)} (${j.kind})</option>`).join('')}</datalist>`;
    h += `<span class="lbl">Key items</span><div class="chips inl">${a.items.map((i) => `<button class="chip on" data-a="accDelItem" data-k="${esc(key)}" data-i="${esc(i)}">${esc(itemLabel(i))} ✕</button>`).join('') || '<span class="hint2">None</span>'}</div>
      <div class="addrow"><input list="dl-items" id="acc-item-${esc(key)}" placeholder="Type an item, then Add"><button class="btn" data-a="accAddItem" data-k="${esc(key)}">Add</button></div>
      <datalist id="dl-items">${items.map((i) => `<option value="${esc(i.name)}">${esc(i.label)}</option>`).join('')}</datalist>`;
    h += `<span class="lbl">Named people (citizen IDs, with commas)</span><div class="addrow"><input id="acc-chars-${esc(key)}" value="${esc(a.characters.join(', '))}" placeholder="ABC12345, XYZ67890" data-a2="accChars" data-k="${esc(key)}"></div>`;
    h += `<div class="chips inl"><button class="chip${a.staff ? ' on' : ''}" data-a="accStaff" data-k="${esc(key)}">Staff can always go in</button></div>`;
    if (withPasscode) h += `<span class="lbl">Passcode (optional, letters and numbers)</span><div class="addrow"><input id="acc-pass-${esc(key)}" value="${esc(a.passcode)}" maxlength="12" data-a2="accPass" data-k="${esc(key)}"></div>`;
    return h;
  }
  function readAccessInputs(key) {
    const a = S.acc[key]; if (!a) return;
    const c = document.getElementById('acc-chars-' + key); if (c) a.characters = c.value.split(',').map((x) => x.trim()).filter(Boolean);
    const pw = document.getElementById('acc-pass-' + key); if (pw) a.passcode = pw.value.trim();
  }
  function accessOut(key) { readAccessInputs(key); const a = S.acc[key]; return a.open ? { open: true } : { open: false, staff: a.staff, groups: a.groups, items: a.items, characters: a.characters, passcode: a.passcode || undefined }; }
  function loadPickers() {
    if (S.pickers && S.pickers.jobs.length && S.pickers.items.length) return Promise.resolve();   // retry until both lists loaded
    return post('doorPickers').then((r) => { S.pickers = { jobs: Array.isArray(r && r.jobs) ? r.jobs : [], items: Array.isArray(r && r.items) ? r.items : [] }; });
  }
  // keep what was typed (citizen IDs, passcode, and the door number boxes) before a redraw
  function keepTyped(key, it) {
    readAccessInputs(key);
    if (it && it.door) {
      const auto = document.getElementById('door-auto'), dist = document.getElementById('door-dist');
      if (auto) it.autolock = Number(auto.value) || 0;
      if (dist) it.maxDistance = Number(dist.value) || 2;
      const orig = S.doors.find((d) => d.id === it.id);
      if (orig) { orig.state = it.state; orig.lockpick = it.lockpick; orig.autolock = it.autolock; orig.maxDistance = it.maxDistance; }
    }
  }
  function rerenderAccess(key) {
    if (key === 'new') { const box = document.getElementById('acc-modal'); if (box) box.innerHTML = accessHtml('new', false); return; }
    select(S.sel, true, true);
  }
  function askAccess(title) {
    return new Promise((resolve) => {
      modal.innerHTML = `<div class="form"><h4>${esc(title)}</h4><p>You can change this any time from the room.</p><div id="acc-modal">${accessHtml('new', false)}</div>
        <div class="row2"><button class="btn" id="fno">Cancel</button><button class="btn pri" id="fyes">Next</button></div></div>`;
      modal.hidden = false;
      const done = (v) => { modal.hidden = true; modal.innerHTML = ''; list.focus(); resolve(v); };
      modal.querySelector('#fno').onclick = () => done(null);
      modal.querySelector('#fyes').onclick = () => done(accessOut('new'));
    });
  }
  function loadPieces() {
    return post('pieces').then((r) => { S.pieces = (r && r.ok && Array.isArray(r.pieces)) ? r.pieces : []; if (S.tab === 'place' && S.src === 'pieces') render(true); });
  }
  function setSrc(src) {
    S.src = src;
    if (src !== 'housing' && src !== 'pieces') S.chip.lib = src === 'build' ? 'all' : 'lighting';
    if (src !== 'pieces') { keep('dps-studio-src', src); post('highlight', { id: -1 }); }
    if (src === 'pieces') loadPieces();
    render(false);
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
        await loadPickers();
        S.acc.new = accCopy({ open: true });
        const acc = await askAccess(`Who can go in to ${v[1]}?`);
        if (!acc) return;
        const r = await post('roomNew', { name: v[0], label: v[1], access: acc });
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
      case 'edit': case 'showPieces': setSrc('pieces'); return;
      case 'accOpen': case 'accLimit': { const k = el.dataset.k; keepTyped(k, it); S.acc[k].open = a === 'accOpen'; rerenderAccess(k); return; }
      case 'accStaff': { const k = el.dataset.k; keepTyped(k, it); S.acc[k].staff = !S.acc[k].staff; rerenderAccess(k); return; }
      case 'accAddGroup': {
        const k = el.dataset.k, inp = document.getElementById('acc-job-' + k), v = inp ? inp.value.trim() : '';
        let j = S.pickers && S.pickers.jobs.find((x) => x.name === v || x.label.toLowerCase() === v.toLowerCase());
        if (!j && (!S.pickers || !S.pickers.jobs.length) && /^[\w-]+$/.test(v)) j = { name: v, grades: [{ level: 0 }] };   // list did not load: take the typed name
        if (!j) { toast('Pick a job or gang from the list', true); return; }
        keepTyped(k, it); S.acc[k].groups[j.name] = (j.grades[0] || { level: 0 }).level; rerenderAccess(k); return;
      }
      case 'accDelGroup': { const k = el.dataset.k; keepTyped(k, it); delete S.acc[k].groups[el.dataset.g]; rerenderAccess(k); return; }
      case 'accAddItem': {
        const k = el.dataset.k, inp = document.getElementById('acc-item-' + k), v = inp ? inp.value.trim() : '';
        let i = S.pickers && S.pickers.items.find((x) => x.name === v || x.label.toLowerCase() === v.toLowerCase());
        if (!i && (!S.pickers || !S.pickers.items.length) && /^[\w-]+$/.test(v)) i = { name: v };
        if (!i) { toast('Pick an item from the list', true); return; }
        keepTyped(k, it); if (!S.acc[k].items.includes(i.name)) S.acc[k].items.push(i.name); rerenderAccess(k); return;
      }
      case 'accDelItem': { const k = el.dataset.k; keepTyped(k, it); S.acc[k].items = S.acc[k].items.filter((x) => x !== el.dataset.i); rerenderAccess(k); return; }
      case 'doorLock': if (it && it.door) { keepTyped('door:' + it.id, it); it.state = Number(it.state) === 1 ? 0 : 1; keepTyped('door:' + it.id, it); select(S.sel, true, true); } return;
      case 'doorPick': if (it && it.door) { keepTyped('door:' + it.id, it); it.lockpick = !it.lockpick; keepTyped('door:' + it.id, it); select(S.sel, true, true); } return;
      case 'doorSave': {
        if (!it || !it.door) return;
        const auto = document.getElementById('door-auto'), dist = document.getElementById('door-dist');
        const f = { access: accessOut('door:' + it.id), state: Number(it.state) === 1, lockpick: !!it.lockpick,
                    autolock: auto ? Number(auto.value) || 0 : undefined, maxDistance: dist ? Number(dist.value) || 2 : undefined };
        post('doorSave', { id: it.id, f }).then((r) => { if (result(r, 'Door saved')) { delete S.acc['door:' + it.id]; load('doors'); } }); return;
      }
      case 'doorGo': if (it && it.door && it.coords) post('doorGo', it.coords); return;
      case 'doorRemove': {
        if (!it || !it.door) return;
        if (!await confirmBox('Remove door', `${it.name} leaves the lock system. A copy is kept in History, so it can be put back.`, 'Remove')) return;
        post('doorRemove', { id: it.id }).then((r) => { if (result(r, 'Removed. History can put it back.')) setTimeout(() => load('doors'), 400); }); return;
      }
      case 'doorNew': {
        const v = await ask('New door', 'Name it, then look at the door in the game and left click it. Set who can open it afterwards, here in Doors.', [{ label: 'Door name', ph: 'City Hall front', max: 40 }], 'Pick the door');
        if (!v) return;
        post('doorNew', { name: v[0], access: { open: true }, locked: false }).then((r) => result(r)); return;
      }
      case 'doorRestore': if (it) post('doorRestore', { id: it.id }).then((r) => { if (result(r, 'Door put back')) load(); }); return;
      case 'roomAccessSave': {
        if (!it || !it.name) return;
        post('roomAccess', { name: it.name, access: accessOut('room:' + it.name) }).then((r) => { if (result(r, 'Saved')) { delete S.acc['room:' + it.name]; load(); } }); return;
      }
      case 'useShell': S.shellSrc = 'shells'; setTab('shells'); return;
      case 'useIpl': S.shellSrc = 'ipls'; post('previewStop'); S.pv = null; setTab('shells'); return;
      case 'usePlace': post('placeWalk').then((r) => result(r)); return;
      case 'iplGo': if (it && it.ipl) post('iplVisit', { export: it.export, style: styleOf(it.export) }); return;
      case 'iplPreset': {
        if (!it || !it.ipl) return;
        const st = styleOf(it.export); st.preset = el.dataset.v;
        post('iplStyle', { export: it.export, style: st }); select(S.sel, true, true); return;
      }
      case 'iplOpt': {
        if (!it || !it.ipl) return;
        const st = styleOf(it.export), g = el.dataset.g, o = el.dataset.o;
        st.on = obj(st.on); st.choice = obj(st.choice);
        if (el.dataset.k === 'many') { st.on[g] = obj(st.on[g]); if (st.on[g][o]) delete st.on[g][o]; else st.on[g][o] = true; }
        else if (o) st.choice[g] = o; else delete st.choice[g];
        post('iplStyle', { export: it.export, style: st }); select(S.sel, true, true); return;
      }
      case 'restyle': {
        if (!it || it.kind !== 'ipl') return;
        S.styling = { name: it.name, label: it.label, export: it.ipl };
        const base = JSON.parse(JSON.stringify(it.style || {}));
        const on = obj(base.on); Object.keys(on).forEach((g) => { on[g] = obj(on[g]); });
        S.iplStyle[it.ipl] = { preset: base.preset || 'default', choice: obj(base.choice), on };
        S.shellSrc = 'ipls'; q.value = ''; S.chip.ipls = 'all';
        setTab('shells');
        setTimeout(() => { const i = S.items.findIndex((x) => x.export === it.ipl); if (i >= 0) select(i, true); }, 60);
        return;
      }
      case 'saveStyle': {
        if (!S.styling) return;
        const st = styleOf(S.styling.export);
        post('roomStyle', { name: S.styling.name, style: st }).then((r) => { if (result(r, 'Style saved. Everyone inside sees it now.')) { S.styling = null; render(true); } });
        return;
      }
      case 'stylingCancel': S.styling = null; render(true); return;
      case 'booth': {
        let list = boothList();
        const first = Object.keys(S.thumbs).length === 0;
        if (first) list = list.slice(0, 10);   // first run is a test of ten, to check the pictures look right
        const mins = Math.ceil(list.length * 1.4 / 60);
        const text = first
          ? 'First run: 10 pieces as a test, under a minute. Then look at their pictures in the list. If they look right, press Take photos again for the rest.'
          : `${list.length.toLocaleString('en-US')} pieces still need a picture, about ${mins} minutes. The panel closes and the booth runs on its own. Leave the game running. Backspace stops it, and it carries on next time.`;
        if (!await confirmBox('Photo booth', text, 'Start')) return;
        post('booth', { models: list }).then((r) => result(r)); return;
      }
      case 'pieceMove': if (it && it.piece) post('pieceMove', { id: it.id }).then((r) => result(r)); return;
      case 'pieceRemove': if (it && it.piece) post('pieceRemove', { id: it.id }).then((r) => { if (result(r, 'Removed. History can put it back.')) loadPieces(); }); return;
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
    const b = e.target.closest('[data-a]');
    if (b && (!modal.contains(b) || /^acc/.test(b.dataset.a))) { e.stopPropagation(); act(b.dataset.a, b); return; }
    const tbtn = e.target.closest('.mode'); if (tbtn) { setTab(tbtn.dataset.t); return; }
    const c = e.target.closest('.chip'); if (c && chips.contains(c)) {
      if (c.dataset.s) { setSrc(c.dataset.s); return; }
      if (c.dataset.ss) { S.shellSrc = c.dataset.ss; if (S.shellSrc === 'ipls') post('previewStop'); S.pv = null; render(false); return; }
      if (S.tab === 'shells' && S.shellSrc === 'ipls') { S.chip.ipls = c.dataset.c; render(false); return; }
      S.chip[S.tab === 'place' && S.src !== 'housing' ? 'lib' : S.tab] = c.dataset.c; render(false); return;
    }
    const r = e.target.closest('.row'); if (r && list.contains(r) && !e.target.closest('.det')) { const i = +r.dataset.i; select(i, i === S.sel ? !S.open : true); }
  });
  document.addEventListener('change', (e) => {
    const sel = e.target.closest('select[data-a="accGrade"]'); if (!sel) return;
    const k = sel.dataset.k; if (S.acc[k]) S.acc[k].groups[sel.dataset.g] = Number(sel.value) || 0;
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
    if (t === 'place') return act(S.src === 'pieces' ? 'pieceMove' : 'place');
    if (t === 'shells') return act(S.items[S.sel] && S.items[S.sel].ipl ? 'iplGo' : 'walk');
    if (t === 'spots') { const it = S.items[S.sel]; if (it) copy(`vector4(${f2(it.x)}, ${f2(it.y)}, ${f2(it.z)}, ${Number(it.h || 0).toFixed(1)})`); return; }
    if (t === 'history') return select(S.sel, true);
    if (t === 'inspect') return act('copyName');
    if (t === 'doors') return S.open ? act('doorSave') : select(S.sel, true);
  }

  document.addEventListener('keydown', (e) => {
    if (app.hidden) return;
    if (!modal.hidden) { if (e.key === 'Escape') { e.preventDefault(); modal.querySelector('#fno') && modal.querySelector('#fno').click(); } return; }
    const ae = document.activeElement;
    const inBox = ae && ae !== q && /^(INPUT|TEXTAREA|SELECT)$/.test(ae.tagName);
    if (inBox) { if (e.key === 'Escape') { e.preventDefault(); ae.blur(); } return; }   // typing in a form box stays in the box
    const typing = ae === q;
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
    if (S.tab === 'place' && k === 'm') { e.preventDefault(); return act('showPieces'); }
    if (S.tab === 'place' && S.src === 'pieces' && e.key === 'Delete') { e.preventDefault(); return act('pieceRemove'); }
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
    p.innerHTML = `${m.key === '' ? '<i class="fa-solid fa-lock"></i>' : `<kbd>${esc(m.key || 'E')}</kbd>`}<span>${esc(m.text)}</span>`; p.hidden = false;
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
        loadThumbs();
        if (!S.ipls) post('ipls').then((r) => { S.ipls = Array.isArray(r) ? r : []; if (S.shown && (S.tab === 'shells' || S.tab === 'rooms')) render(true); });
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
      case 'crop': if (m.model && m.data) cropShot(m.model, m.data); break;
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
