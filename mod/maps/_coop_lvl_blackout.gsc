// CoD4 SP Coop - level module: blackout ("Blackout")
//
// Scripted sequences and the coop decision for each (stock line refs are raw/maps/...):
//
//  * Intro / swamp / chess hut / meeting / overlook / cliff fight / farmhouse / blackout house
//    (blackout.gsc:300-1265). Driven by flag_set triggers ("targetname" "flag_set", "flag_clear")
//    and replicated flags (commence_attack blackout.gsc:586/604, bm21s_attack :704, go_up_hill,
//    cliff_complete ...). Lookat-gated flags (player_at_overlook, cliff_look, gaz_runs_by_window,
//    turned_corner; trigger_lookat in the entity string) only feed replicated story flags, so the
//    scenes already start together. -> nothing to do.
//
//  * Hut TV cinematic (blackout.gsc:264-288): flag_set_touching "hut_tv_on" plays an in-game
//    cinematic for whoever stands in front of the TV. Per-viewer display state -> hut_tv_on/tv_movie
//    are local flags and their flag_set_touching triggers are local.
//
//  * Night vision (blackout.gsc:90 maps\_nightvision::main; _nightvision.gsc:64/146 set/clear
//    "nightvision_on" for the local player's goggles) -> local flags.
//
//  * Rappel (blackout_code.gsc:2015-2084): trigger_use "player_rappel_trigger", enabled on
//    gaz_rappels (replicated), lerps the player onto a "player_rig" and plays the rappel; the
//    cliffhanger trigger_hurt is deleted in the same instance. The use trigger is REPLICATED on
//    purpose: when one player rappels, the other machine's copy of the trigger fires too and its
//    player is lerped onto the rope from wherever they are (that is the straggler pull), so both
//    reach the farm together and both instances delete their cliffhanger. Both players run the same
//    rig -> puppets hidden from player_rappels to player_finishes_rappel (both local flags,
//    set by each machine's own player_rappel_think, blackout_code.gsc:2056/2072).
//
//  * Rappel point (blackout_code.gsc:1942-1945 ally_rappels): the allies only set gaz_rappels and
//    start their own rappel after flag_wait( "player_at_rappel" ), a flag_set_touching flag
//    (player_-prefixed, local). gaz_rappels itself is replicated, so on the squadmate's machine the
//    rope is enabled and the rappel is replayed, but its allies would stay stuck at the top waiting
//    for its own player to stand in that volume. -> LATCHED (see below): the first player at the
//    rappel point latches player_at_rappel on every machine.
//
//  * Lights-out at the blackout house (blackout.gsc:1216 / blackout_code.gsc:4193): gated on
//    flag_set_touching "player_at_blackout_door" (player_-prefixed, local). The scene usually is
//    not waiting yet when the player gets there (Price/Gaz still walk up, blackout.gsc:1209-1214),
//    so a replayed touch (set + immediate clear) is lost. shared_flag() does NOT work for a
//    flag_set_touching flag: the host's replayed touch clears it again and the host's clear is
//    replicated, wiping the flag on the machine whose player is standing at the door.
//    -> LATCHED: the trigger is local and the first local set is broadcast as a "latch|<flag>"
//    event; every machine then keeps the flag set (nothing flag_waitopen()s it, only flag_wait at
//    blackout.gsc:1216 and blackout_code.gsc:4193). A squadmate farther than 1200 units from the
//    door trigger is pulled there.
//
//  * Overlook (blackout.gsc:581 flag_wait player_near_overlook, flag_set_touching): only feeds
//    Price's "in position" dialogue before commence_attack, which also arrives replicated from the
//    machine whose player got there. A late squadmate hears the line when they arrive. -> nothing.
//
//  * Evac (blackout.gsc:1336-1417, blackout_code.gsc:3438-3470): heli lands, the player boards by
//    the trigger_use "heli_rescue_trigger" (targetname flag_set, script_flag player_gets_on_heli) or
//    by jumping while in flag_set_touching "player_near_heli" (detect_player_mantle). Boarding lerps
//    the player onto the "player_rig" at tag_detach and the takeoff "fade" notetrack calls
//    nextmission (blackout_anim.gsc:467/471-479; host-driven via _coop). -> player_gets_on_heli is
//    shared so the jump route also boards the squadmate (who is lerped onto the rig on landing at
//    the latest); the player_near_heli touch trigger is local so a remote touch cannot flash the
//    mantle prompt or board us by accident; puppets hidden from boarding to level end.
//
//  * Local-only volumes: trigger_fog (_load.gsc:3034, would hit an undefined 'progress' on a remote
//    replay), ambient triggers (_ambient.gsc:369-400, same problem), no_prone / no_crouch_or_prone
//    (stance limits of the local player), intelligence_item (per-profile pickups).
//  * trigger_hurt (cliffhanger, fire) is never replicated anyway.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-local state
	local_flag( "nightvision_on" );
	local_flag( "nightvision_dlight_enabled" );
	local_flag( "hut_tv_on" );
	local_flag( "tv_movie" );

	// scene gates that must start on both machines
	shared_flag( "player_gets_on_heli" );
	level.coop_latch_ok = [];
	level.coop_latched = [];
	level.coop.handlers[ "latch" ] = ::blackout_ev_latch;
	blackout_latch( "player_at_rappel" );
	blackout_latch( "player_at_blackout_door" );

	// volumes that only ever react to the local player
	local_trigger( "trigger_fog" );
	local_trigger( "no_prone" );
	local_trigger( "no_crouch_or_prone" );
	local_trigger( "ambient_exit" );
	local_trigger( "intelligence_item" );
	blackout_local_ambient( "trigger_multiple" );
	blackout_local_ambient( "trigger_radius" );
	blackout_local_by_flag( "flag_set_touching", "hut_tv_on" );
	blackout_local_by_flag( "flag_set_touching", "tv_movie" );
	blackout_local_by_flag( "flag_set_touching", "player_near_heli" );

	// the flag-gated helpers flag_wait() at once, but blackout.gsc flag_init()s its flags only after
	// _load (and our postinit) returned, so they are started once the flags exist
	level thread blackout_scenes();
}

blackout_scenes()
{
	blackout_wait_flag_init( "player_rappels" );
	blackout_wait_flag_init( "player_finishes_rappel" );
	blackout_wait_flag_init( "player_at_blackout_door" );
	blackout_wait_flag_init( "player_gets_on_heli" );

	// rappel: both players ride the same rig
	hide_between( "player_rappels", "player_finishes_rappel" );

	// lights out: pull a straggler to the blackout house door
	door = blackout_trigger_by_flag( "flag_set_touching", "player_at_blackout_door" );
	if ( isdefined( door ) )
		pull_on_flag( "player_at_blackout_door", door, 1200 );

	// evac: both players are put on the same tag of the blackhawk
	hide_between( "player_gets_on_heli", undefined );
}

// ---------------------------------------------------------------------------------------------
// latched flag_set_touching gates: the first player to touch the volume sets the flag for everyone
// and it then stays set on every machine. The trigger is local (no replay, no set/clear pulse).
// ---------------------------------------------------------------------------------------------

blackout_latch( flagName )
{
	level.coop_latch_ok[ flagName ] = true;
	blackout_local_by_flag( "flag_set_touching", flagName );
	level thread blackout_latch_proc( flagName );
}

blackout_latch_proc( flagName )
{
	blackout_wait_flag_init( flagName );
	level thread blackout_latch_local( flagName );
	if ( !isdefined( level.coop_latched[ flagName ] ) )
		level waittill( "coop_latch_" + flagName );
	for ( ;; )
	{
		if ( !flag( flagName ) )
			flag_set( flagName );
		flag_waitopen( flagName );
	}
}

blackout_latch_local( flagName )
{
	flag_wait( flagName );
	if ( isdefined( level.coop_latched[ flagName ] ) )
		return;
	level.coop_latched[ flagName ] = true;
	maps\_coop::send( "latch|" + flagName );
	maps\_coop::log( "latched " + flagName );
	level notify( "coop_latch_" + flagName );
}

// "latch|<flag>" from a squadmate
blackout_ev_latch( slot, tok )
{
	if ( tok.size < 3 )
		return;
	flagName = tok[ 2 ];
	if ( !isdefined( level.coop_latch_ok[ flagName ] ) || isdefined( level.coop_latched[ flagName ] ) )
		return;
	level.coop_latched[ flagName ] = true;
	level notify( "coop_latch_" + flagName );
}

blackout_wait_flag_init( flagName )
{
	while ( !isdefined( level.flag ) || !isdefined( level.flag[ flagName ] ) )
		wait 0.05;
}

blackout_local_ambient( classname )
{
	ents = getentarray( classname, "classname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].ambient ) )
			ents[ i ].coop_local = true;
	}
}

blackout_local_by_flag( targetname, flagName )
{
	ents = getentarray( targetname, "targetname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].script_flag ) && ents[ i ].script_flag == flagName )
			ents[ i ].coop_local = true;
	}
}

blackout_trigger_by_flag( targetname, flagName )
{
	ents = getentarray( targetname, "targetname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].script_flag ) && ents[ i ].script_flag == flagName )
			return ents[ i ];
	}
	return undefined;
}
