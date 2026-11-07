"""Anchored hook insertions into stock scripts. Each anchor regex must match exactly once.

Keep these minimal: all real logic lives in our own mod/maps/_coop*.gsc files.
"""

PATCHES = [
    {
        'file': 'maps/_load.gsc',
        'edits': [
            # right after level.player is resolved: networking + puppet precache must run before the first wait
            (r'^\tlevel\.player\.a = spawnStruct\(\);\r?\n', 'after', '\tmaps\\_coop::preinit();\r\n'),
            # end of _load::main: everything is set up
            (r'^\tthread filmy\(\);\r?\n', 'after', '\tthread maps\\_coop::postinit();\r\n'),
        ],
    },
]
