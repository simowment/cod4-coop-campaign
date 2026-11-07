"""Anchored hook insertions into stock scripts. Each anchor regex must match exactly once.

Keep these minimal: each one is a single call into our own maps/_coop*.gsc. Hooks are function
pointers on `level` so the stock code still runs unchanged when the coop scripts are not active.
"""

NL = '\r\n'

PATCHES = [
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
            # flag_set: replicate set transitions
            (r'^\tlevel\.flag\[ message \] = true;\r?\n\tlevel notify\( message \);\r?\n', 'after',
             '\tif ( isdefined( level.coop_flag_hook ) )' + NL + '\t\t[[ level.coop_flag_hook ]]( message, true );' + NL),
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
