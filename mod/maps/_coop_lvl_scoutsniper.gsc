// CoD4 SP Coop - level module: scoutsniper ("All Ghillied Up")
//
// Scripted sequences and the coop decision for each (stock refs: raw/maps/scoutsniper*.gsc, _stealth_*.gsc):
//
//  * STEALTH STATE MACHINE (_stealth_logic.gsc:321-560, _stealth_behavior.gsc:463-465, 2130-2178).
//    _stealth_spotted / _stealth_found_corpse are escalations: replicated (union) so if either player is
//    spotted both sims go loud, matching the shared "the squad got made" fiction.
//    _stealth_hidden / _stealth_alert are the *recovery* states each sim derives from its own AI
//    (system_state_spotted/alert, 473-560). Replicating a client's "hidden" into the host would run
//    system_message_handler (444-457) and kill the host's spotted state while its AI still fight -> LOCAL.
//    _stealth_event is set and cleared by default_event_awareness (2143/2151/2178) per sim; a set without
//    the matching clear would leave the other sim's Price parked on flag_waitopen("_stealth_event")
//    forever (scoutsniper.gsc:537, 925, 1759, 1933) -> LOCAL. _stealth_searching_for_nodes /
//    _stealth_getallnodes are CPU semaphores (_stealth_behavior.gsc:1744-1778) -> LOCAL.
//    NOT solvable here: stealth AI only perceive the local player (remote players are script_model
//    puppets, not sentients) and several helpers hardcode level.player (_stealth_logic.gsc:781, 1059,
//    1475; _stealth_behavior.gsc:776, 974). Each player is effectively hidden from his own sim's guards
//    by his own play; getting spotted on either machine is shared through the flag above.
//  * Shadow volumes "_stealth_shadow" (_stealth_logic.gsc:410-434) flag whoever touches them as in
//    shadow -> LOCAL triggers (a replay would put the local player "in shadow" where he is not).
//  * Intro (scoutsniper.gsc:213-283): native per player. intro_safezone is recomputed from the AI every
//    0.1 s and toggled (376-401) -> LOCAL so the sims don't fight over it.
//  * Church: Price waits for the local player within 200 units before opening the door (1559-1561).
//    Left native: each Price waits for his own player; church_door_open replicates harmlessly.
//    Graveyard hind (1795-1890) hunts level.player natively per sim (uses istouching, no triggers).
//  * Field: price_left_behind fail if the player is >3500 from Price while spotted when field_spawn is
//    hit (1975-1982). field_spawn is a replicated flag_set trigger (radius 2773, zone), so a lagging
//    partner could fail the whole squad. The check is against *this sim's* Price and only applies while
//    _stealth_spotted, so field_pull() moves the local player next to his own Price only in exactly that
//    case (reviewer: replaced an unconditional pull_to_buddy_on_flag( "field_spawn", 3000 ), which
//    teleported a sneaking player through the field patrols even when no fail was pending and measured
//    against the partner instead of the Price the fail tests). Ordering vs field_endmission's own
//    flag_wait on the same notify is not guaranteed; ours is registered first (frame 1).
//  * Cargo patrol position flags cargo_patrol_away/_danger/_kill, cargo_defender1_away/2_away are set and
//    cleared by script_origins along each sim's own patrol path (scoutsniper_code.gsc:1928-1966, ents
//    cargo_patrol_flag_set/clear) -> LOCAL.
//  * Radiation ("radiation"/"super_radiation", _radiation.gsc:19-49; "fake_radiation",
//    scoutsniper_code.gsc:1602-1618), the pond no-prone water (scoutsniper_code.gsc:3514-3528) and the fog
//    distance triggers (scoutsniper_code.gsc:10-23) only describe the local player -> LOCAL triggers.
//  * Intel laptops ("intelligence_item" trigger_use) are collected per player -> LOCAL triggers.
//  * Dash / dogs / center: driven by replicated flags and trigger hits; Price's hearing-distance checks
//    against level.player (3710-3822) only gate dialogue. Native.
//  * End: "level_complete" is a flag_set trigger (ents; scoutsniper.gsc:4486-4496) -> host ends, the
//    framework holds clients. No cinematic, no rig, so no puppet hiding is needed in this level.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// stealth recovery states / semaphores are per simulation
	local_flag( "_stealth_hidden" );
	local_flag( "_stealth_alert" );
	local_flag( "_stealth_event" );
	local_flag( "_stealth_searching_for_nodes" );
	local_flag( "_stealth_getallnodes" );

	// AI-derived toggles
	local_flag( "intro_safezone" );
	local_flag( "cargo_patrol_away" );
	local_flag( "cargo_patrol_danger" );
	local_flag( "cargo_patrol_kill" );
	local_flag( "cargo_defender1_away" );
	local_flag( "cargo_defender2_away" );

	// volumes that describe only the local player
	local_trigger( "_stealth_shadow" );
	local_trigger( "stealth_shadow" );
	local_trigger( "radiation" );
	local_trigger( "super_radiation" );
	local_trigger( "fake_radiation" );
	local_trigger( "water_no_prone" );
	local_trigger( "trigger_fogdist3000" );
	local_trigger( "trigger_fogdist5000" );
	local_trigger( "intelligence_item" );

	level thread delayed_setup();
}

// flag-gated helpers wait on flags; give the level script's own flag_init()s (and _load's trigger flags)
// the rest of this frame before touching them
delayed_setup()
{
	waittillframeend;
	// the field entry fails the mission for a player far from Price while spotted
	if ( isdefined( level.flag[ "field_spawn" ] ) )
		level thread field_pull();
}

// field_endmission (scoutsniper.gsc:1979-1981): spotted && distance( player, price ) > 3500 -> fail
field_pull()
{
	safe_flag_wait( "field_spawn" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( !safe_flag( "_stealth_spotted" ) )
		return;
	if ( !isdefined( level.price ) || !isalive( level.price ) || !isalive( level.player ) )
		return;
	if ( distance( level.player.origin, level.price.origin ) <= 3000 )
		return;
	pull_to( level.price.origin, "Regrouping with Captain MacMillan" );
}
