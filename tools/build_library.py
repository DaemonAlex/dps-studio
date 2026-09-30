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
    ('lighting', 'Lighting', ['chandel', 'lamp', 'light', 'lantern', 'candle', 'neon', 'bulb', 'sconce', 'spotl', 'floodl', 'torch', 'fairyl', 'strobe', 'led_', 'glow']),
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
        if t is None:
            t = 'mappieces' if is_map else 'other'
        groups[t]['items'].append([n, src])
    data = {'groups': [g for g in groups.values() if g['items']], 'count': len(items)}
    with open(out, 'w') as f:
        json.dump(data, f, separators=(',', ':'))
    for g in data['groups']:
        print(f"{g['label']:<22} {len(g['items'])}")
    print('total', len(items), 'bytes', os.path.getsize(out))

if __name__ == '__main__':
    main(*sys.argv[1:4])
