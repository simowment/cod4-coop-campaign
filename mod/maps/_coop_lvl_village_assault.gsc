// CoD4 SP Coop - level module: village_assault ("Safehouse", hunting Al-Asad)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps/village_assault.gsc and
// village_assault_code.gsc) and coop decision:
//
//  * Opening (gameplay_start village_assault.gsc:80-95, opening_sequence code:2620-2633): Price and
//    opening_guy animate, the player is never locked -> native.
//  * Free-roam building clears (add_objective_building code:747-847): six aigroups; AI deaths are
//    replicated, so the clears mostly happen together.
//  * Al-Asad location (code:837-846): decided by WHICH of buildings 2/6 is left last -> order
//    dependent, can differ per copy. -> HOST-AUTHORITATIVE: on the non-host copies
//    level.alasad_sequence_init is set on the first frame so the stock pick returns early
//    (code:841-842); the host's choice (level.alasad_objective_location, set in do_alasad
//    code:2214/2237) is published as our own shared flag "coop_alasad_barn"/"coop_alasad_house" and
//    the clients then run maps\village_assault_code::do_alasad() with it. A client that is alone
//    (host gone) falls back to the stock rule.
//  * Approach gating (alasad_sequence_wait code:2303-2340): polls level.player isTouching(the
//    "alasad_*_area" trigger_radius) -> only the copy whose player is in the area threads
//    alasad_sequence_ready, which waits the start trigger ("alasad_barn_trigger" trigger_radius /
//    "alasad_house_trigger" trigger_multiple, code:2342-2353). The start trigger hit IS replicated,
//    but it is lost on a copy whose player is outside the area.
//    Worse, flag "alasad_sequence_started" (set after the Price lookat, code:2404) is also the
//    level endon of that wait loop (code:2308) - replicating it would kill the other copy's scene.
//    -> local_flag("alasad_sequence_started"); when a copy starts the scene (level notify at
//       code:2357) it sets shared flag "coop_alasad_go"; a copy that has not started 1.5 s later
//       pulls its player into the start trigger (facing Price), which starts its own scene natively;
//       if the player is then inside the "alasad_*_area" but not the start trigger, the start
//       trigger is notified on that copy only (downed players are skipped until revived).
//  * Interrogation A (code:2355-2425): removeWeaponFromPlayer, Price waittill_player_lookat(cos 60)
//    (code:2402, per player), anim_single "interrogationA", goBlack -> native per copy.
//  * Interrogation B (code:2427-2468): freezeControls, takeAllWeapons, movePlayerToLocation(
//    "alasad_*_playerlocation") puts EVERY player on the same script_origin -> puppets hidden from
//    the local "alasad_sequence_started" to the end of the level.
//  * Execution + end (alasad_execution_notes code:2515-2530): freeze, goBlack, nextmission() -> host
//    ends the level, clients wait (framework).
//  * Cobra air support (chopper_air_support code:877-933, ..._end code:1358-1393): a fake weapon
//    with a per-copy chopper and refuel cooldown. -> native, one chopper per player on his own copy.
//    Its state flags are per player: "air_support_refueling" (set/cleared per call; a client's clear
//    would never reach the host), "ammo_cheat_for_chopper", hint flags "gave_air_support_hint",
//    "delete_attack_coord_hint" -> local flags.
//  * enemy_color_hint_trigger (code:679-696): toggles enemy seek mode while level.player istouching
//    -> local_trigger. Ambient triggers ("ambient" key) -> local.
//  * Distracted guys / assassination / upstairs / genocide audio triggers: shared (replicated) so
//    both copies spawn and alert the same AI.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-state flags
	local_flag( "alasad_sequence_started" );   // code:25, endon of alasad_sequence_wait (code:2308)
	local_flag( "air_support_refueling" );     // code:26
	local_flag( "gave_air_support_hint" );     // code:24
	local_flag( "delete_attack_coord_hint" );  // code:27
	local_flag( "ammo_cheat_for_chopper" );    // code:882

	// our own shared flags
	flag_init( "coop_alasad_barn" );
	flag_init( "coop_alasad_house" );
	flag_init( "coop_alasad_go" );

	local_trigger( "enemy_color_hint_trigger" );
	local_ambient_triggers();

	// Al-Asad location: the host decides
	if ( level.coop.active && !level.coop.ishost )
		level.alasad_sequence_init = true; // suppress the local, order-dependent pick (code:841-842)
	if ( level.coop.ishost )
		level thread host_publish_location();
	else
		level thread client_follow_location();

	// interrogation scene: start together, then hide puppets (scene B puts everyone on one spot)
	level thread announce_scene_start();
	level thread pull_into_scene();
	hide_between( "alasad_sequence_started", undefined );
}

local_ambient_triggers()
{
	trigs = getentarray( "trigger_multiple", "classname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].ambient ) )
			trigs[ i ].coop_local = true;
	}
}

// ---------------------------------------------------------------------------------------------
// Al-Asad location
// ---------------------------------------------------------------------------------------------

host_publish_location()
{
	while ( !isdefined( level.alasad_objective_location ) )
		wait 0.25;
	if ( level.alasad_objective_location == "6" )
		flag_set( "coop_alasad_barn" );
	else if ( level.alasad_objective_location == "2" )
		flag_set( "coop_alasad_house" );
	maps\_coop::log( "village_assault: host picked al-asad location " + level.alasad_objective_location );
}

client_follow_location()
{
	for ( ;; )
	{
		if ( flag( "coop_alasad_barn" ) || flag( "coop_alasad_house" ) )
		{
			if ( isdefined( level.alasad_objective_location ) )
				return; // already set up (start point)
			if ( flag( "coop_alasad_barn" ) )
				level thread maps\village_assault_code::do_alasad( "barn" );
			else
				level thread maps\village_assault_code::do_alasad( "house" );
			maps\_coop::log( "village_assault: following host al-asad location" );
			return;
		}
		// alone (host left): stock rule from add_objective_building (code:838-846)
		if ( !maps\_coop::in_coop() && !isdefined( level.alasad_objective_location ) )
		{
			rem = level.alasad_possible_objective_locations_remaining;
			if ( isdefined( rem ) && rem.size == 1 )
			{
				if ( rem[ 0 ] == "2" )
				{
					level thread maps\village_assault_code::do_alasad( "house" );
					return;
				}
				if ( rem[ 0 ] == "6" )
				{
					level thread maps\village_assault_code::do_alasad( "barn" );
					return;
				}
			}
		}
		wait 0.25;
	}
}

// ---------------------------------------------------------------------------------------------
// interrogation start
// ---------------------------------------------------------------------------------------------

announce_scene_start()
{
	level waittill( "alasad_sequence_started" ); // alasad_sequence_start code:2357 (local scene began)
	level.coop_va_scene = true;
	flag_set( "coop_alasad_go" );
}

pull_into_scene()
{
	flag_wait( "coop_alasad_go" );
	if ( !maps\_coop::in_coop() )
		return;
	wait 1.5;
	for ( tries = 0; tries < 5; tries++ )
	{
		if ( isdefined( level.coop_va_scene ) )
			return; // our own copy is running the scene
		if ( isdefined( level.coop.down ) && level.coop.down )
		{
			wait 3;
			continue; // downed: let the revive happen first
		}
		trig = scene_trigger();
		if ( isdefined( trig ) && !( level.player istouching( trig ) ) )
		{
			pull_to( trig.origin, "Regrouping with your squad" );
			if ( isdefined( level.price ) )
			{
				ang = vectortoangles( level.price.origin - level.player.origin );
				level.player setplayerangles( ( 0, ang[ 1 ], 0 ) );
			}
		}
		// alasad_sequence_wait polls the area every frame and then threads alasad_sequence_ready,
		// which waits for the start trigger (code:2318-2348). safe_spot_near() may drop us just
		// outside the start trigger (or the house brush origin may not be inside its brush), so
		// once we are inside the area fire the start trigger on this copy only.
		wait 0.5;
		area = scene_area();
		if ( !isdefined( level.coop_va_scene ) && isdefined( trig ) && isdefined( area ) && level.player istouching( area ) )
		{
			trig.coop_remote_time = gettime(); // keep _coop.gsc watch_trigger from re-broadcasting
			trig notify( "trigger", level.player );
		}
		wait 2.5;
	}
}

scene_area()
{
	if ( !isdefined( level.alasad_objective_location ) )
		return undefined;
	if ( level.alasad_objective_location == "6" )
		return getent( "alasad_barn_area", "targetname" );
	if ( level.alasad_objective_location == "2" )
		return getent( "alasad_house_area", "targetname" );
	return undefined;
}

scene_trigger()
{
	if ( !isdefined( level.alasad_objective_location ) )
		return undefined;
	if ( level.alasad_objective_location == "6" )
		return getent( "alasad_barn_trigger", "targetname" );
	if ( level.alasad_objective_location == "2" )
		return getent( "alasad_house_trigger", "targetname" );
	return undefined;
}
