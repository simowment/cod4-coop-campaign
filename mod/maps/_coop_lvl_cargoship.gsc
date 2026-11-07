// CoD4 SP Coop - cargoship (Crew Expendable)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps) and the coop decision for each:
//
//  * Intro helicopter + fastrope (maps\mo_fastrope::main, cargoship.gsc:171; player seat, camera rig and
//    playerlinktodelta mo_fastrope.gsc:462-603). Runs natively on every machine and every player gets
//    the same player seat, so the puppets would sit in each other. -> puppets hidden from level start
//    until bridge_landing (set by the start_bridge_standoff trigger the players touch after the rope,
//    cargoship.gsc:612-613), with a timeout as a safety net. Only for the "start" jumpto
//    (level.jumpto, cargoship_code.gsc:2529).
//
//  * Bridge / quarters / deck / hallways / cargoholds / last stand (cargoship.gsc:364-3205): combat,
//    gated by trigger flags (replicated) and AI deaths (replicated). player_speed_set (g_speed,
//    cargoship_code.gsc:1977) is per machine. Local-only volumes: "stairs" (stairs_proc slows whoever
//    touches it, cargoship_code.gsc:7-38) and "no_prone" (player_noprone, cargoship_code.gsc:4321-4334).
//
//  * Package room (package_main, cargoship.gsc:3207-3300): doors open on a NON-replicated
//    distance( guy, level.player ) > 700 loop (cargoship.gsc:3274) but the result is the flag
//    package_open_doors, which is replicated -> one player near is enough. Laptop pickup is a
//    trigger_use (objective_package, cargoship.gsc:4488-4511) -> replicated -> package_secure on all.
//
//  * Escape explosion (escape_explosion / escape_shellshock, cargoship_code.gsc:3820-3895, 958-1032):
//    escape_sink_start trigger (replicated) links every player absolute to a rig that moves them to the
//    same fixed spot (620,-296,-360) -> a far player is yanked in by the scene itself; puppets hidden
//    from escape_explosion until escape_get_to_catwalks (flag_set_delayed 22.25s, cargoship.gsc:3932),
//    then (linked heuristic) until the unlink, plus 2s after level notify "escape_unlink_player"
//    (cargoship_code.gsc:1057), since both players are dropped on the same spot.
//    Water-leak escape_event triggers blur the toucher's screen (cargoship_code.gsc:213-219, 343-358):
//    the per-leak blur triggers (escape_event -> struct -> trigger) are local.
//
//  * Escape run (escape_invisible_timer, cargoship_code.gsc:4026-4082): section timers end on trigger
//    flags (escape_cargohold1_enter, escape_catwalk_madeit, escape_hallway_lower_flood_save,
//    escape_aftdeck_flag, end_no_jump) - replicated, so the fastest player keeps the timers happy for
//    everyone. Catwalk (escape_catwalk, cargoship_code.gsc:3143-3181) collapses on
//    escape_catwalk_fall / escape_death_cargohold1; with the union flags a straggler's catwalk falls
//    under them once the leader is across. -> when escape_catwalk_madeit is set, a player still before
//    the madeit trigger is pulled to it (catwalk_straggler()).
//    Fail volumes end_player_fall / end_wrongway / end_wrongway_kill (cargoship_code.gsc:4139-4201) only
//    look at the local player -> local triggers.
//
//  * Ending jump (end_main / end_jump / end_anim_thread, cargoship.gsc:3573-3870): end_jump waits for the
//    local player's jump while touching escape_player_jump, standing and facing the Sea Knight
//    (cargoship.gsc:3806-3818), then sets end_start_player_anim; end_main only reaches that flag_wait
//    after distance( level.player, price ) <= 490 (cargoship.gsc:3592). Decision: end_start_player_anim
//    stays SHARED, so when one player makes the jump every player is caught by Price (end_main rigs the
//    local player wherever they are, and escape_mission_failed is disabled by that flag,
//    cargoship_code.gsc:4132). A player still stuck in end_main's distance( price ) > 490 loop when the
//    flag arrives is pulled to the jump spot so their own gate passes (end_straggler; a player already in
//    range is left alone, because end_main links them in that same frame). The rig/camera part (end_linked_player_to_rig, gotcha, end_finished,
//    end_screen_done, cargoship.gsc:3652, 3903, 3912, 4047) is made LOCAL so each player sees their own
//    rescue anim and end screen in full; the host's objective_main nextmission (cargoship.gsc:4423-4424)
//    ends the level (clients wait). Puppets hidden from end_start_player_anim on (everyone shares the
//    end_hands rig on tag_detach). escape_player_jump / escape_player_nojump are local triggers
//    (mantle hint and allowjump are per player, cargoship.gsc:3834-3873).

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// --- per-player volumes ---
	local_trigger( "stairs" );
	local_trigger( "no_prone" );
	local_trigger( "end_player_fall" );
	local_trigger( "end_wrongway" );
	local_trigger( "end_wrongway_kill" );
	local_trigger( "escape_player_jump" );
	local_trigger( "escape_player_nojump" );

	// --- intro heli: everyone sits in the same seat ---
	if ( isdefined( level.jumpto ) && level.jumpto == "start" )
		level thread intro_hide();

	// --- escape explosion: everyone is moved onto the same rig spot ---
	hide_between( "escape_explosion", "escape_get_to_catwalks" );

	// --- catwalk collapses once the leader is across ---
	level thread catwalk_straggler();

	// --- ending: one jump rescues the squad, each player plays their own rig ---
	// "end_start_player_anim" contains "player_", so is_local_flag() would keep it local by default:
	// share it explicitly, or the straggler's copy never sees the jump and its own end_anim_thread times
	// out into end_seaknight_leaving -> escape_mission_failed (cargoship.gsc:3721-3731) = squad fail.
	shared_flag( "end_start_player_anim" );
	// end_seaknight_leaving is set by a copy whose 3s jump window ran out (cargoship.gsc:3730); shared it
	// would kill end_jump on the other copies (endon, cargoship.gsc:3798) while their window is still
	// open. Local: a late copy still recovers when the squadmate's jump flag arrives within the 5s
	// before escape_mission_failed (which returns once end_start_player_anim is set, cargoship_code:4131).
	local_flag( "end_seaknight_leaving" );
	local_flag( "end_linked_player_to_rig" );
	local_flag( "gotcha" );
	local_flag( "end_finished" );
	local_flag( "end_screen_done" );
	level thread end_straggler();
	hide_between( "end_start_player_anim", undefined );

	// both players are unlinked onto the same spot at the end of the explosion anim
	// (escape_new_explosion_scene, cargoship_code.gsc:1057-1058): keep puppets hidden a moment longer
	level thread unlink_hide();

	// escape_event water leaks blur the screen of whoever touches their trigger
	// (escape_event_waterleak_blur, cargoship_code.gsc:213-219, 343-358) -> only our own player
	local_waterleak_triggers();
}

// end_main only reaches flag_wait( "end_start_player_anim" ) once distance( level.player, price ) <= 490
// (cargoship.gsc:3592). A player who is already inside that range is rigged by end_main in the same
// frame the flag arrives, so they must NOT be moved (setorigin racing the PlayerLinkToAbsolute).
// Only a player still stuck in that distance loop is moved to the jump spot.
end_straggler()
{
	flag_wait( "end_start_player_anim" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( level.heroes3 ) || !isdefined( level.heroes3[ "price" ] ) )
		return;
	price = level.heroes3[ "price" ];
	if ( !isdefined( price ) )
		return;
	if ( distance( level.player.origin, price.origin ) <= 490 )
		return; // end_main rigs us itself
	jump = getent( "escape_player_jump", "targetname" );
	if ( isdefined( jump ) )
		pull_to( jump.origin, "Regrouping with your squad" );
	// On this copy Price may not be at the Sea Knight yet: the heroes pace themselves on the local player
	// (escape_heroes_holdtheline) and only run to the rescue node after this very gate
	// (cargoship.gsc:3595-3597). If the jump spot is still > 490 from our Price, move next to him.
	wait 0.5;
	if ( flag( "end_linked_player_to_rig" ) || !isdefined( price ) )
		return;
	if ( distance( level.player.origin, price.origin ) <= 490 )
		return;
	pull_to( price.origin, "Regrouping with your squad" );
}

unlink_hide()
{
	level waittill( "escape_unlink_player" );
	hide_for( 2 );
}

local_waterleak_triggers()
{
	events = getentarray( "escape_event", "targetname" );
	for ( i = 0; i < events.size; i++ )
	{
		ev = events[ i ];
		if ( !isdefined( ev.script_parameters ) || !issubstr( ev.script_parameters, "event_waterleak" ) )
			continue;
		if ( !isdefined( ev.target ) )
			continue;
		structs = getstructarray( ev.target, "targetname" );
		for ( j = 0; j < structs.size; j++ )
		{
			if ( !isdefined( structs[ j ].target ) )
				continue;
			local_trigger( structs[ j ].target );
		}
	}
}

intro_hide()
{
	level.coop.hide_count++;
	flag_wait_or_timeout( "bridge_landing", 120 );
	level.coop.hide_count--;
}

catwalk_straggler()
{
	trig = flag_trigger( "escape_catwalk_madeit" );
	if ( !isdefined( trig ) )
		return;
	// escape_catwalk_madeit is only flag_init'ed by _load's flag_set trigger; escape_get_to_catwalks is
	// flag_init'ed in cargoship::main and always comes first (cargoship.gsc:89, 3932)
	flag_wait( "escape_get_to_catwalks" );
	if ( !isdefined( level.flag[ "escape_catwalk_madeit" ] ) )
		return;
	flag_wait( "escape_catwalk_madeit" );
	if ( !maps\_coop::in_coop() )
		return;
	wait 0.05;
	if ( !isdefined( trig ) )
		return;
	// the escape runs towards -x through the cargoholds (sink start x=776 -> madeit x=-2084)
	if ( level.player.origin[ 0 ] <= trig.origin[ 0 ] + 150 )
		return;
	pull_to( trig.origin, "Regrouping with your squad" );
}

// the _load "flag_set" trigger for a flag (they all share targetname "flag_set")
flag_trigger( flagName )
{
	trigs = getentarray( "flag_set", "targetname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].script_flag ) && trigs[ i ].script_flag == flagName )
			return trigs[ i ];
	}
	return undefined;
}
