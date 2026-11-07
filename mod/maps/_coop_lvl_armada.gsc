// CoD4 SP Coop - level module: armada ("Charlie Don't Surf")
//
// Scripted sequences and the coop decision for each (stock line refs are raw/maps/...):
//
//  * Slam-zoom intro + helicopter insertion (armada.gsc:1170-1184 ride_start, 1046-1121 loadplayer,
//    1419-1460 player_control_during_ride; armada_code.gsc:296-326 slam_zoom_intro). Every machine
//    seats its own level.player at position 3 of its own "players_helicopter" with
//    playerlinktodelta, so both players sit on the same seat. Native per player -> no sync needed;
//    puppets hidden from level start until "start_first_obj" (set by loadplayer after the fast-rope
//    unlink, armada.gsc:1120, and by every non-ride start point :777/803/823/1489/1954).
//
//  * Landing / street / HQ / TV station (armada.gsc:1283-1330, 600-930). Driven by flag_set
//    triggers (on_ground, player_in_atrium, regrouped, tvstation_entered, tv_station_locked_down),
//    "self waittill trigger" triggers (end_water_visionset, barbed_wire_dialog, on_me_to_building,
//    one_red_to_orange, enemy_mass_trigger, second_floor_obj, end_positions, final_room_obj) and
//    replicated flags (hq_entered, hq_cleared, news_room_clear). All replicated -> nothing to do.
//
//  * TV station TVs (armada_code.gsc:9-56 near_tv/movies_on_tvs): "near_tv" triggers set the
//    "near_tv" flag while level.player stands in them and play the asad_speech_180 in-game
//    cinematic. Per-viewer display -> local flag + local triggers (a replayed touch would start and
//    immediately stop the cinematic on the other machine).
//
//  * Flashbang hint (armada_code.gsc:60-77): flashbang_hint trigger plays Price's line (kept
//    replicated, it is dialogue); "player_has_flashed" is player_-prefixed and already local.
//
//  * Final breach + ending (armada.gsc:1678-1758 final_breach, 1779-1917 final_price/final_griggs/
//    end_dialog_sequence -> nextmission). Gated on trigger_start_final_breach / end_positions and
//    the _breach volume trigger "trigger_final_volume" (script_flag_true i_hear_him), all
//    replicated; nextmission is host-driven by _coop. -> when Griggs says "I hear him" (flag
//    i_hear_him, armada.gsc:1737) a squadmate more than 1500 units away is pulled to the stack-up
//    trigger "trigger_start_final_breach" so both are in the room for the ending.
//
//  * Closest-AI picks from level.player (armada.gsc:506/514, 1718/1720 final breach room-clear guys,
//    2012 tv_breacher) may choose different marines per machine - cosmetic only, left alone. The
//    tv_breacher gets magic_bullet_shield on its own machine, and _coop's ev_kill never kills a
//    shielded AI remotely, so a host-side death of the other machine's pick cannot break tv_breach.
//  * g_friendlyfireDist / g_friendlyNameDist saved dvars during the ride (armada.gsc:1424-1455) are
//    per instance; fine.
//  * Local-only volumes: ambient triggers (_ambient.gsc:369-400, a remote replay hits an undefined
//    'progress'), intelligence_item pickups.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-local state
	local_flag( "near_tv" );

	// volumes that only ever react to the local player
	local_trigger( "near_tv" );
	local_trigger( "ambient_exit" );
	local_trigger( "intelligence_item" );
	armada_local_ambient( "trigger_multiple" );
	armada_local_ambient( "trigger_radius" );

	// the flag-gated helpers flag_wait() at once, but armada.gsc flag_init()s its flags only after
	// _load (and our postinit) returned, so they are started once the flags exist
	level thread armada_scenes();
}

armada_scenes()
{
	armada_wait_flag_init( "start_first_obj" );
	// heli insertion: both players are linked to the same seat
	hide_between( undefined, "start_first_obj" );

	// final breach: bring a straggler to the stack-up point. i_hear_him is created by _load from the
	// script_flag_true of trigger_final_volume (its flag_init in armada.gsc:105 is commented out)
	armada_wait_flag_init( "i_hear_him" );
	pull_on_flag( "i_hear_him", "trigger_start_final_breach", 1500 );
}

armada_wait_flag_init( flagName )
{
	while ( !isdefined( level.flag ) || !isdefined( level.flag[ flagName ] ) )
		wait 0.05;
}

armada_local_ambient( classname )
{
	ents = getentarray( classname, "classname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].ambient ) )
			ents[ i ].coop_local = true;
	}
}
