// CoD4 SP Coop - level module: ambush ("The Sins of the Father")
//
// Scripted sequences (stock raw/maps/ambush.gsc) and the coop decision for each:
//
// 1. Takeover briefing + fade (takeover_briefing 555-571, takeover_briefing_dialogue 573-580,
//    takeover_fade 590-613): gated on flags "takeover_fade" / "takeover_briefing_done" /
//    "takeover_fade_clear" / "takeover_fade_done" -> replicated, runs natively everywhere.
//    ambush_setup (1109-1193) then setorigin's EVERY player onto the same node
//    "startnodeplayer_ambush" (1160-1162) -> puppets hidden from "takeover_fade" until
//    "takeover_fade_done". Non-host players are nudged ~40 units aside right after that teleport
//    (still frozen under the black overlay, takeover_fade 598-607; detected by standing on the
//    node), so nobody gets yanked after controls came back.
// 2. Early-fire gate (ambush_player_interrupt 690-711, set_flag_on_player_action 3610-3633,
//    ambush_mission_fail 713-720): local player's weapon_fired/grenade sets "ambush_mission_fail"
//    / "ambush_early_start" with flag_set -> replicated, so either player firing early fails or
//    springs the ambush for everyone. No change needed.
// 3. Guard tower collapse (ambush_tower_fall 1365-1433): driven by the convoy vehicle nodes
//    "collision_imminent" / "tower_collision", which run on every machine's own convoy.
//    "player_tower_hits_ground" is player-local by naming convention -> each machine starts its
//    own blackout when its own tower lands. No change needed.
// 4. Tower blackout (ambush_tower_blackout 1455-1522): setorigin to "player_outofsight", then to
//    the fixed spot (-439,-197,9), prone + freezeControls for ~21s, then "ambush_recovered" ->
//    both players land on the same spot. Puppets are hidden for the LOCAL blackout duration
//    (player_tower_hits_ground + 21.5s), NOT until "ambush_recovered": that flag is replicated
//    and can arrive from the faster machine before/while our own blackout runs. Non-host players
//    are nudged aside while still under the black overlay (just after the teleport at 1478).
// 5. Chase of V. Zakhaev (failed_to_pursue 3060-3101, failed_to_pursue_timer 3103-3125,
//    badguy_died 3170-3180, badguy_proximity_kill 3182-3208): timers are flag-gated (trigger
//    flags, replicated); "failed_to_pursue" volumes fail the mission -> made local_trigger() so a
//    remote player's hit is not replayed as ours (the mission fail itself is still replicated by
//    the framework). Badguy death -> AI death replicated -> both fail. Proximity check is on the
//    local player only (no puppet AI) -> fine.
// 6. Apartment MG nests (apartment_mg_killzone 2766-2782, apartment_mg_kill 2784-2803): the
//    "mg_player_target(_2)" zones retarget the MG at level.player and "mg_player_kill(_2)" keep
//    dodamage'ing level.player -> must only react to the local player: local_trigger().
//    Nest destruction (apartment_mg_nest_player_damage 2689-2707) uses attacker==level.player and
//    flag_set -> replicated.
// 7. Rooftop suicide (apartment_suicide 2805-2817, apartment_suicide_badguy 2852-2880,
//    apartment_suicide_badguy_interrupt 2926-2967, slowdown 2969-2982): "apartment_suicide" is a
//    trigger flag and "force_suicide" a trigger -> replicated, both machines start the jump /
//    slowmo together. A squadmate far away when the scene starts is pulled to the buddy (no
//    playerlinkto in this scene, so the pull cannot fight a rig).
// 8. Level end: flag_wait( "mission_done" ) -> nextmission (aarea_apartment_init 2342-2346),
//    host-driven by the framework.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-only volumes
	local_trigger( "failed_to_pursue" );
	local_trigger( "mg_player_target" );
	local_trigger( "mg_player_target_2" );
	local_trigger( "mg_player_kill" );
	local_trigger( "mg_player_kill_2" );

	// takeover fade: everyone is teleported onto startnodeplayer_ambush
	hide_between( "takeover_fade", "takeover_fade_done" );
	level thread takeover_nudge();

	// tower blackout: everyone is teleported to the same prone spot
	level thread tower_blackout_coop();

	// rooftop suicide scene
	pull_to_buddy_on_flag( "apartment_suicide", 1500 );
}

// ambush_setup (1160-1162) puts every player on startnodeplayer_ambush while the screen is black
takeover_nudge()
{
	flag_wait( "takeover_fade_clear" );
	if ( !maps\_coop::in_coop() || level.coop.ishost )
		return;
	node = getnode( "startnodeplayer_ambush", "targetname" );
	if ( !isdefined( node ) )
		return;
	if ( !wait_on_spot( node.origin, 3 ) )
		return; // a start point skipped the teleport
	nudge_from( node.origin );
}

// ambush_tower_blackout (1455-1515): teleport to a fixed spot, ~21s frozen prone
tower_blackout_coop()
{
	flag_wait( "player_tower_hits_ground" ); // player-local: our own tower landed
	level.coop.hide_count++;
	start = gettime();
	spot = ( -439, -197, 9 );
	if ( maps\_coop::in_coop() && !level.coop.ishost )
	{
		if ( wait_on_spot( spot, 3 ) )
		{
			wait 0.3;
			nudge_from( spot );
		}
	}
	left = 21.5 - ( gettime() - start ) / 1000;
	if ( left > 0 )
		wait left;
	level.coop.hide_count--;
}

// true once the local player stands within 24 units of pos (gives up after timeout seconds)
wait_on_spot( pos, timeout )
{
	end = gettime() + timeout * 1000;
	while ( gettime() < end )
	{
		if ( distance( level.player.origin, pos ) < 24 )
			return true;
		wait 0.05;
	}
	return false;
}

// step a non-host player aside of a spot the whole squad was teleported onto (slot-dependent
// distance so several clients do not all land on the same offset)
nudge_from( pos )
{
	if ( maps\_coop::player_linked() )
		return;
	k = level.coop.slot;
	if ( k < 1 )
		k = 1;
	spot = pos;
	for ( i = 0; i < k; i++ )
		spot = maps\_coop_player::safe_spot_near( spot );
	level.player setorigin( spot );
	maps\_coop::log( "ambush: nudged aside of " + pos );
}
