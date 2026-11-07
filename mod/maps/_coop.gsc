// CoD4 SP Coop - entry points called from the patched maps/_load.gsc
#include maps\_utility;

preinit()
{
	level.coop = spawnstruct();
	level.coop.version = "0.0.1";
	setdvar( "coop_probe", "preinit" );
}

postinit()
{
	setdvar( "coop_probe", "postinit" );
	wait 2;
	for ( i = 0; i < 5; i++ )
	{
		iprintlnbold( "COOP MOD LOADED v" + level.coop.version );
		wait 3;
	}
}
