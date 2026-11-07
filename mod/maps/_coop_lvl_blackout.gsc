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
//  * Lights-out at the blackout house (blackout.gsc:1216 / blackout_code.gsc:4193): gated on
//    flag_set_touching "player_at_blackout_door" which is player_-prefixed (local) and a replayed
//    touch clears itself immediately. -> shared_flag() so the first player at the door starts the
//    scene on both machines; a squadmate farther than 1200 units is pulled to the door trigger.
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
	shared_flag( "player_at_blackout_door" );
	shared_flag( "player_gets_on_heli" );

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
