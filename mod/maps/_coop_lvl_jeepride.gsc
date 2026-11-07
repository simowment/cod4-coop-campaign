// CoD4 SP Coop - jeepride ("Ultimatum")
//
// Scripted sequences (stock raw/maps/jeepride.gsc, jeepride_code.gsc) and the coop decision for each:
//
// 1. Slam-zoom intro + THE RIDE (slam_zoom_intro jeepride.gsc:384-452, ride_start 509-520,
//    player_link_update / playerlinkto on level.playerlinkmodel in jeepride_code.gsc:53-76).
//    Each copy links its own level.player to the same seat of its own convoy, so both players sit
//    in the same place. DECISION: hide puppets from the start of the level until end_ride (the
//    linked heuristic would also hide them, but the explicit hide stops flicker at link changes).
//    Vehicle-node flags (end_ride etc.) replicate as a union, so the first copy to reach a node
//    starts the next beat on every copy.
//
// 2. RPG / hind lock-on (hind gag jeepride_code.gsc:1140-1165, rpg_spot 167-203, do_or_die 1206-1218).
//    rpg_taken / rpg_shot are left replicated on purpose. If only one player fires the RPG, the
//    other copy's hind lock-on still ends, so do_or_die does not kill the squadmate who did not fire.
//
// 3. Bridge transition (bridge_transition jeepride.gsc:803-853). This is a fade, an unlink, and
//    player_fudge_moveto to bridge_startspot, the same spot for every player. DECISION: hide puppets
//    from end_ride until bridge_sequence. Then, once the move has finished, step each non-host player
//    sideways so the players do not stand inside each other.
//
// 4. Bridge defence volumes (layer_of_death jeepride_code.gsc:3718-3747, which aims the axis at
//    level.player and kills that player 4 s after layer 4; bridge_fall jeepride_code.gsc:4205-4218,
//    the fall-off kill). These are about one player's own position. DECISION: local_trigger on
//    layer_of_death0..4 and falltrigger.
//
// 5. Tanker blast / topple / Zakhaev end scene / rescue (bridge_zakhaev 1461-1760,
//    hind_shoots_the_tanker 2381-2410 with a local player_in_blastradius, escape_shellshock_thing
//    1349-1382, slow-mo series 2236-2293, bridge_rescue 1813-1923). From the topple on, each player is
//    linked to a playerview rig at player_drag_node until nextmission. Every copy plays it natively
//    and starts together because end_action_bmp / end_action_hind are replicated flags.
//    all_end_scene_guys_dead is replicated, so either player's last kill ends the shoot-out on both
//    copies. DECISION: hide puppets from bridge_zakhaev_setup to the end of the level, because both
//    players share the same rig spot.
//
// 6. Level end (bridge_rescue -> nextmission 1923): the host drives it.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-position volumes on the bridge: never replay them on a squadmate's copy
	local_trigger( "layer_of_death0" );
	local_trigger( "layer_of_death1" );
	local_trigger( "layer_of_death2" );
	local_trigger( "layer_of_death3" );
	local_trigger( "layer_of_death4" );
	local_trigger( "falltrigger" );

	// 1. the ride: everyone shares one seat
	jr_hide_between( undefined, "end_ride" );

	// 3. bridge transition: everyone is moved to bridge_startspot
	jr_hide_between( "end_ride", "bridge_sequence" );
	level thread jr_bridge_spread();

	// 5. topple + Zakhaev scene + rescue: everyone is on the same playerview rig until nextmission
	jr_hide_between( "bridge_zakhaev_setup", undefined );
}

// Our main() runs inside _load::main, before the level script's own flag_init calls, and some of
// these flags (bridge_sequence) are only ever created by flag_set. Wait without touching
// level.flag[ name ] while it is undefined. flag_set always notifies level with the flag name.
jr_wait_flag_set( name )
{
	for ( ;; )
	{
		if ( isdefined( level.flag[ name ] ) )
		{
			if ( level.flag[ name ] )
				return;
		}
		level waittill( name );
	}
}

// like maps\_coop_levels::hide_between, but safe for flags that do not exist yet
jr_hide_between( startFlag, endFlag )
{
	level thread jr_hide_between_proc( startFlag, endFlag );
}

jr_hide_between_proc( startFlag, endFlag )
{
	if ( isdefined( startFlag ) )
		jr_wait_flag_set( startFlag );
	level.coop.hide_count++;
	if ( isdefined( endFlag ) )
	{
		jr_wait_flag_set( endFlag );
		level.coop.hide_count--;
	}
}

jr_bridge_spread()
{
	jr_wait_flag_set( "bridge_sequence" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( jr_flag_is_set( "bridge_zakhaev_setup" ) )
		return;
	// keep puppets hidden until the move has released us and we have stepped apart
	level.coop.hide_count++;
	jr_spread_from_squad( 10 );
	wait 1.5;
	level.coop.hide_count--;
}

// Waits (up to timeoutSec) for the scripted move to release the player, then steps a non-host player
// to the side, so players who were placed on the same spot do not overlap.
jr_spread_from_squad( timeoutSec )
{
	c = level.coop;
	end = gettime() + timeoutSec * 1000;
	while ( maps\_coop::player_linked() && gettime() < end )
		wait 0.25;
	if ( c.ishost )
		return;
	if ( maps\_coop::player_linked() )
		return;
	if ( jr_flag_is_set( "bridge_zakhaev_setup" ) )
		return;
	right = anglestoright( level.player getplayerangles() );
	side = 1;
	if ( c.slot % 2 == 0 )
		side = -1;
	base = level.player.origin;
	for ( r = 48; r >= 24; r -= 24 )
	{
		p = base + vectorScale( right, r * side );
		if ( !bullettracepassed( base + ( 0, 0, 40 ), p + ( 0, 0, 40 ), false, undefined ) )
			continue;
		tr = bullettrace( p + ( 0, 0, 40 ), p - ( 0, 0, 100 ), false, undefined );
		if ( tr[ "fraction" ] < 1 )
		{
			level.player setorigin( tr[ "position" ] );
			return;
		}
	}
	level.player setorigin( maps\_coop_player::safe_spot_near( base ) );
}

jr_flag_is_set( name )
{
	if ( !isdefined( level.flag[ name ] ) )
		return false;
	return level.flag[ name ];
}
