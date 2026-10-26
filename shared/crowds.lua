-- SHARED. DPS 2026-10-22 (Damon: "bars and clubs with full npcs", "I know the code exists somewhere").
-- Club crowds: dancers on a dance floor, plus staff spots (DJ, bartender, bouncer). Each player's game spawns
-- its own crowd, only while that player is inside a venue, so nothing runs anywhere else.
-- The After Hours dance floor spots, the dance list and the patron models come from PichotM's
-- fivem-nightclub-ped (MIT licence, github.com/PichotM/fivem-nightclub-ped).
StudioCrowd = {}
StudioCrowd.LEVELS = { off = 0.0, light = 0.4, packed = 1.0 }   -- share of the dance spots that get a dancer
StudioCrowd.MAX = 45                                              -- never more dancers than this in one venue
StudioCrowd.DANCE_DICT = 'anim@amb@nightclub@dancers@crowddance_groups@hi_intensity'
StudioCrowd.DANCES = {
    'hi_dance_crowd_15_v2_female^1', 'hi_dance_crowd_15_v2_female^2', 'hi_dance_crowd_15_v2_female^3', 'hi_dance_crowd_15_v2_female^4',
    'hi_dance_crowd_15_v2_female^5', 'hi_dance_crowd_15_v2_female^6', 'hi_dance_crowd_15_v2_male^1', 'hi_dance_crowd_15_v2_male^2',
    'hi_dance_crowd_15_v2_male^3', 'hi_dance_crowd_15_v2_male^4', 'hi_dance_crowd_15_v2_male^5', 'hi_dance_crowd_15_v2_male^6',
    'hi_dance_crowd_17_v1_female^1', 'hi_dance_crowd_17_v1_female^2', 'hi_dance_crowd_17_v1_female^3', 'hi_dance_crowd_17_v1_female^4',
    'hi_dance_crowd_17_v1_female^5', 'hi_dance_crowd_17_v1_female^6', 'hi_dance_crowd_17_v1_male^1', 'hi_dance_crowd_17_v1_male^2',
    'hi_dance_crowd_09_v1_female^1', 'hi_dance_crowd_17_v1_male^3', 'hi_dance_crowd_09_v1_female^2', 'hi_dance_crowd_17_v1_male^4',
    'hi_dance_crowd_17_v1_male^5', 'hi_dance_crowd_09_v1_female^3', 'hi_dance_crowd_17_v1_male^6', 'hi_dance_crowd_17_v2_female^1',
    'hi_dance_crowd_09_v1_female^4', 'hi_dance_crowd_17_v2_female^2', 'hi_dance_crowd_17_v2_female^3', 'hi_dance_crowd_09_v1_female^5',
    'hi_dance_crowd_17_v2_female^4', 'hi_dance_crowd_17_v2_female^5', 'hi_dance_crowd_09_v1_female^6', 'hi_dance_crowd_17_v2_female^6',
    'hi_dance_crowd_09_v1_male^1', 'hi_dance_crowd_17_v2_male^1', 'hi_dance_crowd_17_v2_male^2', 'hi_dance_crowd_09_v1_male^2',
    'hi_dance_crowd_17_v2_male^3', 'hi_dance_crowd_17_v2_male^4', 'hi_dance_crowd_09_v1_male^3', 'hi_dance_crowd_17_v2_male^5',
    'hi_dance_crowd_17_v2_male^6', 'hi_dance_crowd_09_v1_male^4', 'hi_dance_crowd_09_v1_male^5', 'hi_dance_crowd_09_v1_male^6',
    'hi_dance_crowd_09_v2_female^1', 'hi_dance_crowd_09_v2_female^2', 'hi_dance_crowd_09_v2_female^3', 'hi_dance_crowd_09_v2_female^4',
    'hi_dance_crowd_09_v2_female^5', 'hi_dance_crowd_09_v2_female^6', 'hi_dance_crowd_09_v2_male^1', 'hi_dance_crowd_09_v2_male^2',
    'hi_dance_crowd_09_v2_male^3', 'hi_dance_crowd_09_v2_male^4', 'hi_dance_crowd_09_v2_male^5', 'hi_dance_crowd_09_v2_male^6',
    'hi_dance_crowd_11_v1_female^1', 'hi_dance_crowd_11_v1_female^2', 'hi_dance_crowd_11_v1_female^3', 'hi_dance_crowd_11_v1_female^4',
    'hi_dance_crowd_11_v1_female^5', 'hi_dance_crowd_11_v1_female^6', 'hi_dance_crowd_11_v1_male^1', 'hi_dance_crowd_11_v1_male^2',
    'hi_dance_crowd_11_v1_male^3', 'hi_dance_crowd_11_v1_male^4', 'hi_dance_crowd_11_v1_male^5', 'hi_dance_crowd_11_v1_male^6',
    'hi_dance_crowd_13_v2_female^1', 'hi_dance_crowd_13_v2_female^2', 'hi_dance_crowd_13_v2_female^3', 'hi_dance_crowd_13_v2_female^4',
    'hi_dance_crowd_13_v2_female^5', 'hi_dance_crowd_13_v2_female^6', 'hi_dance_crowd_13_v2_male^1', 'hi_dance_crowd_13_v2_male^2',
    'hi_dance_crowd_13_v2_male^3', 'hi_dance_crowd_13_v2_male^4', 'hi_dance_crowd_13_v2_male^5', 'hi_dance_crowd_13_v2_male^6',
    'hi_dance_crowd_15_v1_female^1', 'hi_dance_crowd_15_v1_female^2', 'hi_dance_crowd_15_v1_female^3', 'hi_dance_crowd_15_v1_female^4',
    'hi_dance_crowd_15_v1_female^5', 'hi_dance_crowd_15_v1_female^6', 'hi_dance_crowd_15_v1_male^1', 'hi_dance_crowd_15_v1_male^2',
    'hi_dance_crowd_15_v1_male^3', 'hi_dance_crowd_15_v1_male^4', 'hi_dance_crowd_15_v1_male^5', 'hi_dance_crowd_15_v1_male^6',
}
StudioCrowd.MODELS = {
    'a_m_y_vinewood_02', 'a_f_y_vinewood_03', 'a_m_y_vinewood_03', 'a_f_y_vinewood_04', 'a_m_y_vinewood_04',
    'a_f_y_vinewood_02', 'a_m_y_vinewood_01', 'a_f_y_vinewood_01', 'a_m_y_vindouche_01', 'a_f_y_soucent_03',
    'a_m_y_skater_02', 'a_m_y_skater_01', 'a_m_m_skater_01', 'a_f_y_skater_01', 's_f_y_shop_mid',
    's_f_y_shop_low', 'a_f_y_hipster_04', 'a_m_y_hipster_03', 'a_f_y_hipster_03', 'a_m_y_hipster_02',
    'a_f_y_hipster_02', 'a_f_y_hipster_01', 'a_m_y_hipster_01', 'a_m_y_hippy_01', 'a_f_y_hippie_01',
    'a_f_y_genhot_01', 'a_f_y_eastsa_03',
}
-- staff: model, then an animation (dict + clip) or a scenario
StudioCrowd.STAFF = {
    dj        = { model = 'ig_djtalignazio', dict = 'mini@strip_club@idles@dj@base', clip = 'base' },
    bartender = { model = 's_f_y_clubbar_01', fallback = 's_m_y_barman_01', scenario = 'WORLD_HUMAN_STAND_IMPATIENT' },
    bouncer   = { model = 's_m_m_bouncer_01', scenario = 'WORLD_HUMAN_GUARD_STAND' },
}
-- Starting venues (written to the database once, then edited in game with /crowd).
StudioCrowd.DEFAULTS = {
    after_hours = {
        label = 'After Hours nightclub', x = -1595.0, y = -3012.0, z = -78.5, radius = 40.0, level = 'packed',
        dance = {
            { x = -1599.286, y = -3014.479, z = -79.00606, h = 74.99979 },
            { x = -1599.256, y = -3012.859, z = -79.00606, h = 89.9997 },
            { x = -1599.485, y = -3011.013, z = -79.00606, h = 99.99955 },
            { x = -1599.478, y = -3009.316, z = -79.00606, h = 109.9995 },
            { x = -1598.276, y = -3010.419, z = -79.00606, h = 89.99937 },
            { x = -1598.178, y = -3012.107, z = -79.00606, h = 94.99931 },
            { x = -1597.81, y = -3013.999, z = -79.00606, h = 64.99922 },
            { x = -1596.136, y = -3014.376, z = -79.00606, h = 64.99922 },
            { x = -1596.532, y = -3012.257, z = -79.00606, h = 84.99911 },
            { x = -1597.38, y = -3009.078, z = -79.00606, h = 84.99911 },
            { x = -1596.245, y = -3010.349, z = -79.00606, h = 94.99898 },
            { x = -1594.98, y = -3011.497, z = -79.00606, h = 74.99896 },
            { x = -1594.685, y = -3013.496, z = -79.00606, h = 89.99895 },
            { x = -1594.415, y = -3009.547, z = -79.00606, h = 94.99889 },
            { x = -1593.241, y = -3011.182, z = -79.00606, h = 94.99889 },
            { x = -1593.164, y = -3013.143, z = -79.00606, h = 69.99878 },
            { x = -1593.243, y = -3014.435, z = -79.00606, h = 69.99878 },
            { x = -1593.338, y = -3009.497, z = -79.00606, h = 99.99875 },
            { x = -1597.302, y = -3013.429, z = -79.00606, h = 89.99841 },
            { x = -1597.293, y = -3011.11, z = -79.00606, h = 89.99841 },
            { x = -1595.858, y = -3012.948, z = -79.00606, h = 89.99841 },
            { x = -1594.718, y = -3012.382, z = -79.00606, h = 84.99833 },
            { x = -1592.485, y = -3011.958, z = -79.00606, h = 104.9983 },
            { x = -1592.1, y = -3009.135, z = -79.00606, h = 104.9983 },
            { x = -1594.456, y = -3010.849, z = -79.00606, h = 74.99818 },
            { x = -1594.935, y = -3014.76, z = -79.00606, h = 79.99802 },
            { x = -1593.958, y = -3012.06, z = -79.00606, h = 79.99802 },
            { x = -1592.025, y = -3014.925, z = -79.00606, h = 74.99796 },
            { x = -1592.057, y = -3013.273, z = -79.00606, h = 74.99796 },
            { x = -1597.023, y = -3015.123, z = -79.00606, h = 84.99932 },
            { x = -1596.166, y = -3011.476, z = -79.00606, h = 119.999 },
            { x = -1595.68, y = -3009.549, z = -79.00606, h = 119.999 },
            { x = -1592.181, y = -3010.726, z = -79.00606, h = 119.999 },
            { x = -1598.637, y = -3008.974, z = -79.00606, h = 129.9987 },
            { x = -1589.201, y = -3013.824, z = -79.00606, h = 349.998 },
            { x = -1588.086, y = -3012.85, z = -79.00606, h = 139.9975 },
            { x = -1589.525, y = -3011.373, z = -79.00606, h = 104.9997 },
            { x = -1589.588, y = -3009.793, z = -79.00606, h = 134.9996 },
            { x = -1590.238, y = -3016.211, z = -79.00606, h = 64.99924 },
            { x = -1612.493, y = -3008.006, z = -79.00598, h = 0.0 },
            { x = -1612.234, y = -3007.077, z = -79.00598, h = 184.9996 },
            { x = -1603.387, y = -3004.944, z = -79.00606, h = 199.9994 },
            { x = -1601.498, y = -3005.343, z = -79.00606, h = 164.9993 },
            { x = -1601.012, y = -3006.264, z = -79.00606, h = 159.9992 },
            { x = -1597.325, y = -3017.721, z = -79.00606, h = 59.99892 },
            { x = -1598.735, y = -3018.321, z = -79.00606, h = 34.99891 },
            { x = -1599.519, y = -3017.069, z = -79.00606, h = 34.99886 },
            { x = -1598.335, y = -3016.935, z = -79.00606, h = 34.99886 },
            { x = -1600.323, y = -3017.858, z = -79.00606, h = 24.99882 },
            { x = -1605.931, y = -3014.545, z = -77.79105, h = 309.9981 },
            { x = -1606.391, y = -3013.633, z = -77.79105, h = 274.998 },
        },
        staff = { { kind = 'dj', x = -1602.862, y = -3012.739, z = -78.606, h = -81.672 } },
    },
}

---Clean a venue key: lower case letters, numbers and _ only, 2 to 32 long.
function StudioCrowd.CleanKey(k)
    if type(k) ~= 'string' then return nil end
    k = k:lower():gsub('[^%w_]', '_')
    if #k < 2 or #k > 32 then return nil end
    return k
end
