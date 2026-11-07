// CoD4 SP Coop - level module: village_defend ("Ultimatum")
//
// Scripted sequences and the coop decision for each (stock refs: raw/maps/village_defend*.gsc):
//
//  * Intro / southern hill (village_defend.gsc:846-1240): driven by replicated flags and triggers
//    (hill_patrol_trig -> objective_player_on_ridgeline 886-892, hill_patrol_shotdetector 1556-1572).
//    objective_player_at_vantage_point is a per-player distance check (894-918) and stays local; the
//    hill intro has its own timeout (1223-1228). The church tower death volume (875-883) and the
//    ridgeline mortar danger area (1765-1782) are info_volume istouching checks on level.player: native.
//  * Minigun (village_defend.gsc:2195-2245, village_defend_code.gsc:8-40, 433-700): each sim has its
//    own minigun; player_on_minigun (local by name) and disable_overheat toggle per sim -> LOCAL.
//    objective_player_uses_minigun ends the southern hill attack and the objective loop (1650, 1843,
//    2034) -> shared_flag so the squad progresses when either player mans it. The minigun user is not
//    moving, so the framework's linked heuristic already hides his puppet.
//  * Detonators / clackers (2620-2840): "detonator_usetrig" trigger_use. clacker_enable needs
//    level.player istouching the use volume; on a replay the local player is not there and
//    clacker_notouch -> clacker_disable runs takeweapon("c4") on him (2760-2840) -> LOCAL triggers.
//    The per-trigger availability flags (script_flag_true clacker_*_available, set/cleared 2694/2779)
//    and got_the_clacker (2763/2791/2828) toggle per sim -> LOCAL. The *_exploded story flags replicate.
//  * Tanks: "tank_killzone_east/west" triggers make the tank aim at level.player (3090-3133) -> LOCAL
//    triggers, so a tank only fires at the player that actually stands in its killzone.
//  * Javelin (3051-3062): a weapon entity, picked up per player. Native.
//  * Airstrikes (3375-3435, 5040-5210): per player (level.airStriker = level.player);
//    airstrike_in_progress toggles per sim -> LOCAL.
//  * Extraction (3268-3290, 3640-3935, village_defend_code.gsc:760-880): objective_get_to_lz and
//    lz_reached replicate, so the stopwatch starts together. Boarding is a per-player distance poll to
//    tag_door_rear (3895-3909) -> player_made_it (local by name), then rescue_ride links the player to a
//    rig at the same seaknight tag -> puppets hidden from player_made_it on.
//    The departure chain (seaknight_guards_boarding -> all_fake_friendlies_aboard -> grace ->
//    seaknight_unboardable -> outtahere, code 795-877) is driven by the *local* player_made_it; if it
//    replicated, the first player to board would take off the partner's seaknight ~17 s later and fail
//    him (countdown_events 3820-3840) -> those flags are LOCAL, each player keeps his own stock timer.
//    Level end: outtahere -> nextmission (3923-3932) on the host; clients are held by the framework.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// progression: either player on the minigun stops the southern hill attack in both sims
	shared_flag( "objective_player_uses_minigun" );

	// per-sim toggles
	local_flag( "disable_overheat" );
	local_flag( "got_the_clacker" );
	local_flag( "clacker_nearslope_available" );
	local_flag( "clacker_farslope_available" );
	local_flag( "clacker_crashsite_available" );
	local_flag( "clacker_cliffside_available" );
	local_flag( "airstrike_in_progress" );

	// seaknight departure follows this sim's own player
	local_flag( "seaknight_guards_boarding" );
	local_flag( "all_real_friendlies_on_board" );
	local_flag( "all_fake_friendlies_aboard" );
	local_flag( "seaknight_unboardable" );
	local_flag( "outtahere" );

	// triggers that must only react to the local player
	local_trigger( "detonator_usetrig" );
	local_trigger( "tank_killzone_east" );
	local_trigger( "tank_killzone_west" );

	level thread delayed_setup();
}

// village_defend flag_init()s its flags after _load::main (village_defend.gsc:148-236), i.e. after our
// postinit call; wait for the rest of this frame before any flag_wait
delayed_setup()
{
	waittillframeend;
	// both players ride the seaknight on rigs at the same tag
	if ( isdefined( level.flag[ "player_made_it" ] ) )
		hide_between( "player_made_it", undefined );
}
