#!/usr/bin/env python3
"""Builds html/library.json: every placeable model Studio offers, sorted into themes.

Run on hv (never on the VM). Inputs:
  1. the game's spawnable object list (ObjectList.ini, one model name per line)
  2. a list of every streamed .ydr path on the live tree (find ... -name '*.ydr' under /stream/)
Output: {"groups": [{"key", "label", "items": [[model, source], ...]}], "count": n}
The game client later drops any name it cannot spawn, so a stale entry never shows.
"""
import json, os, re, sys, collections

THEMES = [  # (key, label, words) first match wins; words are matched inside the model name
    ('lighting', 'Lighting', ['chandel', 'lamp', 'light', 'pendant', 'ceiling', 'lantern', 'candle', 'neon', 'bulb', 'sconce', 'spotl', 'floodl', 'torch', 'fairyl', 'strobe', 'led_', 'glow']),
    ('seating', 'Seating', ['sofa', 'couch', 'chair', 'stool', 'seat', 'bench', 'armch', 'recliner', 'ottoman', 'pouf', 'beanbag']),
    ('tables', 'Tables and desks', ['table', 'desk', 'counter', 'podium', 'lectern']),
    ('beds', 'Beds', ['bed', 'mattress', 'bunk', 'cot_', 'crib']),
    ('storage', 'Storage and shelves', ['shelf', 'shelv', 'cabinet', 'drawer', 'wardrobe', 'locker', 'rack', 'dresser', 'cupboard', 'bookcase', 'safe', 'crate', 'box', 'chest', 'trunk', 'bin_', 'basket']),
    ('kitchen', 'Kitchen and food', ['fridge', 'oven', 'cooker', 'microwave', 'sink', 'kettle', 'toaster', 'kitchen', 'coffee', 'dish', 'plate', 'cup', 'mug', 'pan_', 'pot_', 'food', 'pizza', 'burger', 'fruit', 'bread', 'cake', 'donut', 'cereal', 'can_', 'soda', 'cutlery', 'fork', 'knife', 'spoon', 'blender', 'grill', 'bbq']),
    ('bathroom', 'Bathroom', ['toilet', 'shower', 'bath', 'towel', 'basin', 'soap', 'loo', 'urinal', 'tooth']),
    ('bar', 'Bar and club', ['bar_', 'bottle', 'glass', 'beer', 'wine', 'whisk', 'vodka', 'champ', 'cocktail', 'shot_', 'dj_', 'club', 'decks', 'pool_table', 'poker', 'casino', 'slot', 'dart', 'jukebox', 'keg', 'booze']),
    ('electronics', 'Electronics', ['tv', 'monitor', 'screen', 'laptop', 'computer', 'pc_', 'phone', 'speaker', 'radio', 'console', 'keyboard', 'printer', 'projector', 'camera', 'cctv', 'server', 'router', 'tablet', 'arcade', 'game']),
    ('office', 'Office', ['office', 'file', 'folder', 'paper', 'whiteboard', 'board', 'binder', 'clipboard', 'stapler', 'pen_', 'notepad', 'book']),
    ('decor', 'Decor and art', ['art', 'paint', 'picture', 'frame', 'poster', 'statue', 'vase', 'sculpt', 'clock', 'mirror', 'trophy', 'rug', 'carpet', 'mat_', 'curtain', 'blind', 'cushion', 'pillow', 'ornament', 'decor', 'photo', 'canvas', 'banner', 'flag', 'mural', 'bust', 'figure', 'doll', 'toy', 'teddy']),
    ('plants', 'Plants and garden', ['plant', 'flower', 'tree', 'bush', 'fern', 'palm', 'cactus', 'hedge', 'grass', 'shrub', 'ivy', 'garden', 'planter', 'weed_pot']),
    ('gym', 'Gym and sport', ['gym', 'weight', 'dumbbell', 'barbell', 'treadmill', 'punch', 'yoga', 'bike_ex', 'golf', 'tennis', 'basket', 'ball']),
    ('crime', 'Crime and work', ['drug', 'weed', 'coke', 'meth', 'cash', 'money', 'gold', 'bag', 'tool', 'drill', 'saw', 'hammer', 'wrench', 'ladder', 'barrel', 'gas', 'fuel', 'tyre', 'tire', 'engine', 'car_part', 'workbench', 'weld', 'lab_', 'scale', 'press']),
    ('street', 'Street and outdoor', ['barrier', 'cone', 'fence', 'sign', 'bollard', 'umbrella', 'parasol', 'tent', 'bench', 'post', 'pole', 'hydrant', 'dumpster', 'skip', 'rubbish', 'trash', 'litter', 'pallet', 'road', 'traffic', 'wall', 'gate', 'door', 'window']),
]
NOISE = re.compile(r'(^|_)(s?lod\d*|lod_|slod|proxy|shadow|occl|col|emissive|dec|decal|decals|ovly|overlay|detail|reflect|refl|mirror_proxy|milo|ref)(_|\d|$)')
NOISE2 = re.compile(r'(proxy|occluder|_l\d$|_lod\d*$|lod$)')

BAD = ('doorframe', 'windowframe', 'flight', 'lighthouse', 'highlight', 'slight', 'sled', 'partic', 'party', 'cart', 'start', 'dart_', 'depart', 'smart', 'heart', 'quart')

def theme_of(name):
    """Match on word starts inside the name: 'prop_sofa_01' and 'apa_mp_h_stn_sofacorn' are seating,
    'prop_cart' is not art. Words of 3 letters or less must be a whole token."""
    toks = [t for t in re.split(r'[_0-9]+', name) if t]
    for key, label, words in THEMES:
        for w in words:
            w = w.strip('_')
            for t in toks:
                if len(w) <= 3:
                    hit = t == w or t == w + 's'
                else:
                    hit = t.startswith(w) or (len(w) >= 5 and w in t)
                if hit and not any(b in t for b in BAD):
                    return key
    return None

# Decorate = pieces for dressing a room. Build = pieces for building the world (barriers,
# crates, signs, trees, industry, map parts). Studio's Place tab opens on Decorate.
DECOR_THEMES = {'lighting', 'seating', 'tables', 'beds', 'storage', 'kitchen', 'bathroom', 'bar', 'electronics', 'office', 'decor', 'plants', 'gym'}
INTERIOR_SETS = re.compile(r'^(apa_mp_h_|apa_prop_|ex_mp_h_|ex_prop_|ex_office|bkr_prop_clubhouse|bkr_prop_biker_(ceiling|pendant|chair|bar|table|sofa|lamp|jukebox|pool|dart|tv|laptop)|imp_prop_impexp_(sofa|table|chair|coffee|lamp|tv|desk|shelf|rack|art|plant)|sf_mp_h_|sf_prop_sf_|ch_prop_ch_|vw_prop_|h4_prop_h4_|xm3_prop_|m2[345]_\d_prop_|v_res_|v_ret_|v_club_|v_corp_|v_med_|v_ilev_|hei_heist_|hei_prop_hei_|ba_prop_|gr_prop_gr_|tr_prop_|reh_prop_|sum_prop_|prop_)')
NOT_DECOR = re.compile(r'(mesh|wall|floor|shell|detail|frame|window|door|stair|pipe|cable|wire|beam|pillar|shadow|roof|plinth|debris|rubble|trim|skirting|decal|'
                       r'truck|carrier|dock|race|runway|street|traffic|road|flood|construct|work_|mine|farm|military|heli|plane|boat|ship|snow|target|'
                       r'trolly|trolley|pallet|skip|dumpster|barrier|cone|fence|tree|bush|grass|hedge|weed_|crate|drum|barrel|tyre|tire|engine|'
                       r'_cr$|_ld_|_cs_|prologue|test|dummy|proxy|rail|redlight|phonebox|police|flag_|arena|acid|abattoir|ballistic|inflate|trailr|trailer)')

def use_of(n, src, theme):
    if theme not in DECOR_THEMES:
        return 'build'
    if NOT_DECOR.search(n):
        return 'build'
    if src == 'Game':
        return 'decorate' if INTERIOR_SETS.match(n) else 'build'
    return 'decorate' if 'prop' in src.lower() else 'build'

def main(objlist, ydrlist, out, root='/opt/fivem/server-data/resources/'):
    items = {}   # model -> (source, is_map)
    for l in open(objlist, encoding='utf-8', errors='ignore'):
        n = l.strip().lower()
        if re.fullmatch(r'[a-z0-9_]+', n) and not NOISE.search(n) and not NOISE2.search(n):
            items.setdefault(n, ('Game', False))
    for l in open(ydrlist, encoding='utf-8', errors='ignore'):
        p = l.strip()
        if not p.startswith(root):
            continue
        parts = p[len(root):].split('/')
        if 'stream' not in parts:
            continue
        i = parts.index('stream')
        res = parts[i - 1]
        is_map = parts[0] == '[maps]'
        n = os.path.splitext(parts[-1])[0].lower()
        if not re.fullmatch(r'[a-z0-9_]+', n) or NOISE.search(n) or NOISE2.search(n) or 'shell' in n:
            continue
        if n not in items or items[n][0] == 'Game':
            items[n] = (res, is_map) if n not in items else items[n]
    groups = collections.OrderedDict((k, {'key': k, 'label': lab, 'items': []}) for k, lab, _ in THEMES)
    groups['other'] = {'key': 'other', 'label': 'Other props', 'items': []}
    groups['mappieces'] = {'key': 'mappieces', 'label': 'Map pieces', 'items': []}
    for n in sorted(items):
        src, is_map = items[n]
        t = theme_of(n)
        if t == 'lighting' and src != 'Game' and 'prop' not in src.lower():
            # light parts cut from a map's interior only switch on inside their own room;
            # placed loose they flicker as the camera turns, so they are not offered as lamps
            t = 'mappieces'
        if t is None:
            t = 'mappieces' if is_map else 'other'
        groups[t]['items'].append([n, src, 'd' if use_of(n, src, t) == 'decorate' else 'b'])
    data = {'groups': [g for g in groups.values() if g['items']], 'count': len(items)}
    with open(out, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    for g in data['groups']:
        d = sum(1 for i in g['items'] if i[2] == 'd')
        print(f"{g['label']:<22} decorate {d:<6} build {len(g['items']) - d}")
    print('total', len(items), 'bytes', os.path.getsize(out))

if __name__ == '__main__':
    main(*sys.argv[1:4])
