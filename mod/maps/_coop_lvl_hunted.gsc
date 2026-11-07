// CoD4 SP Coop - level module: hunted ("Hunted")
//
// Scripted sequences (stock raw/maps/hunted.gsc) and the coop decision for each:
//
// 1. Flight intro (area_flight_init 321-353, flight_helicopter 492-527): every player is
//    playerlinktodelta'd to the same fake tag inside the same blackhawk until "blackhawk_down".
//    Runs natively per machine. Both players sit at the same spot -> puppets hidden.
// 2. Crash wake-up (crash_wakeup 728-764): playerlinktoabsolute to a viewhands rig at the same
//    start origin, released when the anim ends -> "wakeup_done". Puppets stay hidden from level
//    start until "wakeup_done" (only for the "default" / "crash" starts, the only ones that run it).
// 3. Tunnel / helicopter fly-over (dirt_path_* 826-1100): gated on flags + trigger hits
//    (truck_alert, path_trigger, barn_moveup = flag triggers) -> already replicated.
// 4. Barn interrogation (area_barn_init 1163+, barn_interrogation 1226-1290): the whole stealth/
//    loud branch depends on flag "player_interruption", set by set_flag_on_player_action
//    (4384-4406, local player's weapon_fired/grenades) and by spotters (road_axis_proximity
//    3208-3240). The name contains "player_" so the framework would keep it local, which would let
//    one machine stay in the stealth branch while the other went loud -> shared_flag().
//    flag_clear( "player_interruption" ) at creek start (2557) is host-replicated, which is fine.
//    "player_sprint" (115-143, 3229) is about the local player's movement -> stays local (default).
// 5. Barn rear door closes behind the squad on "field_cross" (barn_close_rear_door 1490-1494) ->
//    a straggler would be locked out: door_straggler() pulls only the player who is farther
//    from the field_cross trigger than barn_rear_door is (i.e. still behind the door) and who is
//    not touching the trigger himself (review fix: a wide trigger brush could otherwise pull the
//    player who set the flag back to the straggler).
// 6. Field / hit the deck (field_dialgue 1586-1630, field_helicopter_spot 1786-1798): spotlight
//    check is on the local player but sets the shared flag "field_spoted" -> replicated, fine.
// 7. Basement (basement_allies 2160-2208): loops until the squad AND level.player are inside volume
//    "basement_building"; after 12s a player outside "basement_building"/"stair_volume" gets
//    magic_kill (4455) which sets "heli_field_stragler_attack" and sends the heli after him.
//    When "squad_in_basement" (replicated) is set, Price shuts the inner door (basement_price
//    2210-2255) and "basement_player_block" goes solid -> a player still outside is pulled to his
//    squadmate. "heli_field_stragler_attack" is about the local straggler -> local_flag().
// 8. Creek gate closes on "creek_bridge" (creek_gate 2588-2625) to stop backtracking ->
//    door_straggler( "creek_bridge", "creek_gate", ... ), same rule as the barn door.
// 9. Greenhouse stinger fight (greenhouse_stinger 3320-3418, infinite_stinger 3287-3316,
//    greenhouse_fake_target 3422-3467): stinger lock / "stinger_fired" are level.player-only and
//    each machine has its own helicopter (vehicle deaths are not replicated). When the heli dies on
//    one machine we set a coop flag and the other machines kill their copy of level.helicopter, so
//    "helicopter_down" and the barn exit (greenhouse_barn_door 3604-3634) run everywhere.
// 10. AC-130 barrage (ac130_kill_player 3756-3780): distance checks on the local player, kills
//    only him -> local by nature; we deliberately do NOT pull anyone in this area.
//    End: flag_wait_or_timeout( "mission_end_trigger", 30 ) -> nextmission (area_ac130_init 3637-3660), host-driven.
// 11. Per-player triggers: "vision_trigger" (visionset_trigger 4008-4016) and "noprone"
//    (noprone 5121-5131) must only react to the local player -> local_trigger().

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	shared_flag( "player_interruption" );
	local_flag( "heli_field_stragler_attack" );

	local_trigger( "vision_trigger" );
	local_trigger( "noprone" );

	// flight + crash wake-up: everyone is linked to the same tag/rig
	if ( level.start_point == "default" || level.start_point == "crash" )
		hide_between( undefined, "wakeup_done" );

	// doors that close behind the squad. Only the player who is still behind the door is pulled:
	// a plain pull_to_buddy_on_flag() would also run on the machine of the player who hit the
	// trigger and pull HIM back to the straggler (both swap places), and a 1200 radius does not
	// cover a straggler standing right behind the door (field_cross is ~630 units from
	// barn_rear_door, creek_bridge ~1000 from creek_gate).
	door_straggler( "field_cross", "barn_rear_door", "field_cross" );
	door_straggler( "creek_bridge", "creek_gate", "creek_bridge" );

	// basement: Price locks the door once the squad is in
	level thread basement_straggler();

	// greenhouse helicopter: one death for everyone
	flag_init( "coop_hunted_heli_dead" );
	level thread heli_death_watch();
	level thread heli_death_apply();
}

basement_straggler()
{
	safe_flag_wait( "squad_in_basement" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( level.start_point == "basement" )
		return; // start_basement sets the flag itself (hunted.gsc:4104), everyone starts at the same node
	wait 1;
	if ( player_in_basement() )
		return;
	pull_to_buddy_proc( "squad_in_basement", 64 );
}

player_in_basement()
{
	volume = getent( "basement_building", "targetname" );
	volume2 = getent( "stair_volume", "targetname" );
	if ( isdefined( volume ) && level.player istouching( volume ) )
		return true;
	if ( isdefined( volume2 ) && level.player istouching( volume2 ) )
		return true;
	return false;
}

// on whichever machine the greenhouse helicopter is shot down, tell the others
heli_death_watch()
{
	safe_flag_wait( "road_helicopter_cleared" );
	// start_greenhouse sets the flag before start_greenhouse_helicopter assigns level.helicopter
	// (hunted.gsc:4172-4195), so give it a moment
	for ( i = 0; i < 40 && !isdefined( level.helicopter ); i++ )
		wait 0.05;
	heli = level.helicopter;
	if ( !isdefined( heli ) )
		return;
	heli waittill( "death" );
	if ( !isdefined( heli ) )
		return; // deleted by script, not shot down
	if ( !safe_flag( "coop_hunted_heli_dead" ) )
		flag_set( "coop_hunted_heli_dead" );
}

heli_death_apply()
{
	safe_flag_wait( "coop_hunted_heli_dead" );
	heli = level.helicopter;
	if ( !isdefined( heli ) || !isalive( heli ) )
		return;
	maps\_coop::log( "hunted: killing local helicopter (shot down by squadmate)" );
	heli dodamage( heli.health + 100000, heli.origin );
	wait 0.5;
	if ( isdefined( heli ) && isalive( heli ) )
		heli notify( "death" ); // same trick stock uses for vehicles (hunted.gsc:3885 ac130_vehicle_die)
}

// flagName: replicated flag that closes doorName (targetname) behind the squad.
// aheadName: targetname of the trigger the squad is heading for. A player farther from that
// trigger than the door itself is behind the door and gets pulled to the closest squadmate;
// the player who set the flag (standing in the trigger) is never moved.
door_straggler( flagName, doorName, aheadName )
{
	door = getent( doorName, "targetname" );
	ahead = getent( aheadName, "targetname" );
	if ( !isdefined( door ) || !isdefined( ahead ) )
		return;
	level thread door_straggler_proc( flagName, door.origin, ahead );
}

door_straggler_proc( flagName, doorPos, ahead )
{
	aheadPos = ahead.origin;
	safe_flag_wait( flagName );
	if ( !maps\_coop::in_coop() )
		return;
	// the player who set the flag is standing in the trigger: a wide trigger brush can put him
	// farther from its origin than the door is, so never move someone who is touching it
	if ( isdefined( ahead ) && level.player istouching( ahead ) )
		return;
	limit = distance( doorPos, aheadPos ) - 64;
	if ( distance( level.player.origin, aheadPos ) <= limit )
		return;
	pull_to_buddy_proc( flagName, 128 );
}
