"""Anchored hook insertions into stock scripts. Each anchor regex must match exactly once.

Keep these minimal: each one is a single call into our own maps/_coop*.gsc. Hooks are function
pointers on `level` so the stock code still runs unchanged when the coop scripts are not active.
"""

NL = '\r\n'

def export_fn(level_file, zone, exports):
    """Level scripts live only in their own fastfile, so mod modules (compiled in every level) cannot
    reference them. The level's main() hands the functions over as level.coop_fn_<name> pointers."""
    lines = ''.join('\tlevel.coop_fn_%s = %s;' % (n, ref) + NL for n, ref in exports)
    return {'file': level_file, 'zones': (zone,), 'edits': [(r'^main\(\)[ \t]*\r?\n(?:[ \t]*\r?\n)*\{[ \t]*\r?\n', 'after', lines)]}


LEVELS = ['killhouse', 'cargoship', 'coup', 'blackout', 'armada', 'bog_a', 'hunted', 'ac130', 'bog_b',
          'airlift', 'aftermath', 'village_assault', 'scoutsniper', 'sniperescape', 'village_defend', 'ambush',
          'icbm', 'launchfacility_a', 'launchfacility_b', 'jeepride', 'airplane']

# Extra level functions that a level's coop module calls (they only exist in that level's fastfile).
LEVEL_EXTRA_EXPORTS = {
    'bog_a': [('abrams_gets_drawing', 'maps\\bog_a_backhalf::abrams_gets_drawing')],
    'village_assault': [('do_alasad', 'maps\\village_assault_code::do_alasad')],
    'village_defend': [('tavern_storming_delay', '::tavern_storming_delay')],
}

# Each level's main() points at its own coop module, so a level only compiles its module. Referencing all
# 21 from common code made every level compile all of them and overflow the script variable pool on bog_a.
LEVEL_PATCHES = [export_fn('maps/%s.gsc' % lv, lv,
                           [('level_main', 'maps\\_coop_lvl_%s::main' % lv)] + LEVEL_EXTRA_EXPORTS.get(lv, []))
                 for lv in LEVELS]

PATCHES = LEVEL_PATCHES + [
    {
        'file': 'maps/_load.gsc',
        'edits': [
            # right after level.player is resolved, before the first wait: networking + precache
            (r'^\tlevel\.player\.a = spawnStruct\(\);\r?\n', 'after', '\tmaps\\_coop::preinit();' + NL),
            # end of _load::main: triggers, spawners, colors and loadout are set up
            (r'^\tthread filmy\(\);\r?\n', 'after', '\tthread maps\\_coop::postinit();' + NL),
        ],
    },
    {
        'file': 'common_scripts/utility.gsc',
        'edits': [
            # flag_set: replicate real false->true transitions only (checked before the assignment)
            (r'^\tlevel\.flag\[ message \] = true;\r?\n\tlevel notify\( message \);\r?\n', 'before',
             '\tif ( isdefined( level.coop_flag_hook ) && isdefined( level.flag[ message ] ) && !level.flag[ message ] )' + NL
             + '\t\t[[ level.coop_flag_hook ]]( message, true );' + NL),
            # flag_clear: replicate clear transitions
            (r'^\t\tlevel\.flag\[ message \] = false;\r?\n\t\tlevel notify\( message \);\r?\n', 'after',
             '\t\tif ( isdefined( level.coop_flag_hook ) )' + NL + '\t\t\t[[ level.coop_flag_hook ]]( message, false );' + NL),
        ],
    },
    {
        'file': 'maps/_utility.gsc',
        'edits': [
            # missionFailedWrapper: tell the other players (they fail too) before the local fail
            (r'^missionFailedWrapper\(\)\r?\n\{\r?\n', 'after',
             '\tif ( isdefined( level.coop_fail_hook ) && [[ level.coop_fail_hook ]]() )' + NL + '\t\treturn;' + NL),
        ],
    },
    {
        'file': 'maps/_endmission.gsc',
        'edits': [
            # _nextmission: host-driven level end barrier
            (r'^_nextmission\(\)\r?\n\{\r?\n', 'after',
             '\tif ( isdefined( level.coop_nextmission_hook ) && [[ level.coop_nextmission_hook ]]() )' + NL + '\t\treturn;' + NL),
        ],
    },
    {
        'file': 'maps/_autosave.gsc',
        'edits': [
            # tryAutoSave: clients only save when the host does
            (r'^tryAutoSave\( filename, description, image, timeout \)\r?\n\{\r?\n', 'after',
             '\tif ( isdefined( level.coop_save_hook ) && [[ level.coop_save_hook ]]( filename ) )' + NL + '\t\treturn false;' + NL),
            (r'^_autosave_game_now\( suppress_print \)\r?\n\{\r?\n', 'after',
             '\tif ( isdefined( level.coop_save_hook ) && [[ level.coop_save_hook ]]( "save_now" ) )' + NL + '\t\treturn false;' + NL),
            # after a committed checkpoint on the host: broadcast it
            (r'^\t\t\tcommitSave\( saveId \);\r?\n\t\t\tlevel\.lastSaveTime = getTime\(\);\r?\n', 'after',
             '\t\t\tif ( isdefined( level.coop_saved_hook ) )' + NL + '\t\t\t\t[[ level.coop_saved_hook ]]( filename );' + NL),
            (r'^\t\tcommitSave\( saveId \);\r?\n\t\tsetDvar\( "ui_grenade_death", "0" \);\r?\n', 'after',
             '\t\tif ( isdefined( level.coop_saved_hook ) )' + NL + '\t\t\t[[ level.coop_saved_hook ]]( "save_now" );' + NL),
            # nobody saves while a teammate is downed
            (r'^autoSaveCheck\( doPickyChecks \)\r?\n\{\r?\n', 'after',
             '\tif ( isdefined( level.coop_cansave_hook ) && ![[ level.coop_cansave_hook ]]() )' + NL + '\t\treturn false;' + NL),
        ],
    },
]
