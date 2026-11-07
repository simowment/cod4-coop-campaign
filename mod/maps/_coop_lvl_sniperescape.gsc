// CoD4 SP Coop - level module: sniperescape ("One Shot, One Kill")
//
// Scripted sequences and the coop decision for each (stock refs: raw/maps/sniperescape*.gsc):
//
//  * Barrett intro (sniperescape_exchange.gsc:2344-2365): every player is lerped onto the same
//    script_model view_org in the hotel window, then the "barrett_trigger" trigger_use (644-670) moves
//    him onto turret2. Both are native per player; the use trigger is replicated so both mount together.
//    Both players occupy the same spot -> puppets hidden from level start until player_gets_off_turret
//    (exchange_turret, 19-72; set by snipe() sniperescape.gsc:621 or blow_up_hotel exchange.gsc:2184),
//    default start only.
//  * The shot (exchange.gsc:440-487, 1280-1305): each sim has its own Zakhaev. exchange_success /
//    zakhaev_escaped / heli_destroyed are replicated, so one player's hit counts for the squad and the
//    other sim stops trying to hit Zak again (exchange.gsc:460). player_attacks_exchange would be
//    player-local by name but it is the squad's "we opened fire" story beat (guards flee, heli reacts,
//    snipe() waits on it at sniperescape.gsc:582) -> shared_flag.
//    player_on_barret / player_is_on_turret / player_used_zoom / player_gets_off_turret stay local.
//  * Hotel collapse (exchange.gsc:2178-2225): native per sim, deathtouch uses istouching on level.player.
//  * Rappel (sniperescape.gsc:796-861): "rappel_trigger" trigger_use is replicated, so both players
//    rappel at once on their own rigs at the same node -> puppets hidden from player_rappels (local)
//    until heli_moves_on (vehicle flag, set 1.5 s after the unlink) or a timeout.
//  * Heat area: kill heli summoned by camping in a zone, tracked through "heat_progression" triggers
//    (sniperescape_code.gsc:5567-5600) -> LOCAL triggers, each sim punishes its own player.
//  * Carrying Macmillan (sniperescape_code.gsc:2045-2160, 2320-2440, 2804-2880): pickup is
//    level.price waittill("trigger") (AI use, never replicated); Price is deleted while carried and
//    respawned at the drop point. Each player carries his own sim's Macmillan. The carry-state flags
//    toggle per sim (price_picked_up set 2835 / cleared 2601; can_manage_price 238/1732/1953/5497;
//    price_moves_to_position 1731 / code 1651) -> LOCAL; first_pickup selects the crash pickup and
//    arms the leash (code 2333, 2386) -> LOCAL. "price_drop_trigger" is moved onto level.player and
//    fired by the use key (code 1930-2035) -> LOCAL trigger (a replay would drop the other's Price).
//    price_dies_if_player_goes_too_far (code 2327-2362) is per player; no pulls are done in this phase
//    because teleporting a player away from his own Price would trip that leash.
//  * Fairgrounds: entering with Price on the ground fails ("left your spotter", check_for_price
//    wounding.gsc:1545-1562) and the evac countdown (code 849-873) both key off the
//    player_enters_fairgrounds flag_set trigger; player_reaches_extraction_point drives the
//    put-Macmillan-down sequence (sniperescape.gsc:1676-1726). Both depend on this sim's Price ->
//    their triggers are LOCAL, as are price_placement_trigger / price_putdown_hint_trigger and the
//    resulting put_price_near_wheel / price_is_put_down_near_wheel / beacon_placed / fair_hold_fire.
//    The flag_set_touching volumes (player_goes_to_pool, player_abandon_protection, player_plays_nice,
//    cant_pick_up_price, near_window) describe only the local player -> LOCAL triggers.
//  * Seaknight (sniperescape.gsc:1878-1997, wounding.gsc:319-410): each sim lands, waits 60 s, and
//    leaves; the player boards by distance to tag_door_rear and is linked to a rig at tag_detach.
//    seaknight_* timeline flags are per sim (a replicated seaknight_leaves would refuse the late
//    player's boarding at wounding.gsc:355) -> LOCAL. Puppets hidden once the local player boarded.
//    The take_off "fade" notetrack calls end_level -> nextmission (anim.gsc:904): host ends.
//  * Radiation triggers (_radiation.gsc) and intel pickups -> LOCAL triggers.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// story beat: either player opening fire on the exchange alerts both sims
	shared_flag( "player_attacks_exchange" );

	// Macmillan carry state (each sim carries its own Price)
	local_flag( "price_picked_up" );
	local_flag( "can_manage_price" );
	local_flag( "first_pickup" );
	local_flag( "price_moves_to_position" );
	local_flag( "put_price_near_wheel" );
	local_flag( "price_is_put_down_near_wheel" );
	local_flag( "beacon_placed" );
	local_flag( "fair_hold_fire" );

	// seaknight timeline is per sim
	local_flag( "seaknight_flies_in" );
	local_flag( "seaknight_lands" );
	local_flag( "seaknight_prepares_to_leave" );
	local_flag( "seaknight_leaves" );
	local_flag( "seaknight_leaves_prematurely" );

	// local-only triggers
	local_trigger( "price_drop_trigger" );
	local_trigger( "price_placement_trigger" );
	local_trigger( "price_putdown_hint_trigger" );
	local_trigger( "heat_progression" );
	local_trigger( "radiation" );
	local_trigger( "super_radiation" );
	local_trigger( "intelligence_item" );
	local_flag_trigger( "player_enters_fairgrounds" );
	local_flag_trigger( "player_reaches_extraction_point" );
	local_flag_trigger( "player_goes_to_pool" );
	local_flag_trigger( "player_abandon_protection" );
	local_flag_trigger( "player_plays_nice" );
	local_flag_trigger( "cant_pick_up_price" );
	local_flag_trigger( "near_window" );

	// puppets: both players share the hotel window / turret spot from the very first frame
	if ( !isdefined( level.start_point ) || level.start_point == "default" )
	{
		level.coop.hide_count++;
		level thread turret_unhide();
	}
	level thread delayed_setup();
}

// sniperescape flag_init()s its flags after _load::main (sniperescape.gsc:193-270), i.e. after our
// postinit call; wait for the rest of this frame before any flag_wait
delayed_setup()
{
	waittillframeend;
	if ( isdefined( level.flag[ "player_rappels" ] ) )
		level thread rappel_hide();
	if ( isdefined( level.flag[ "player_made_it_to_seaknight" ] ) )
		hide_between( "player_made_it_to_seaknight", undefined );
}

turret_unhide()
{
	waittillframeend;
	if ( isdefined( level.flag[ "player_gets_off_turret" ] ) )
		flag_wait( "player_gets_off_turret" );
	level.coop.hide_count--;
}

// flag_set / flag_set_touching / flag_unset triggers whose script_flag is flagName react only to the
// local player
local_flag_trigger( flagName )
{
	names = [];
	names[ names.size ] = "flag_set";
	names[ names.size ] = "flag_set_touching";
	names[ names.size ] = "flag_unset";
	n = 0;
	for ( k = 0; k < names.size; k++ )
	{
		ents = getentarray( names[ k ], "targetname" );
		for ( i = 0; i < ents.size; i++ )
		{
			if ( !isdefined( ents[ i ].script_flag ) || ents[ i ].script_flag != flagName )
				continue;
			ents[ i ].coop_local = true;
			n++;
		}
	}
	return n;
}

// both players rappel from the same node on their own rigs
rappel_hide()
{
	flag_wait( "player_rappels" );
	level.coop.hide_count++;
	wait 2;
	if ( isdefined( level.flag[ "heli_moves_on" ] ) )
		flag_wait_or_timeout( "heli_moves_on", 15 );
	else
		wait 10;
	level.coop.hide_count--;
}
