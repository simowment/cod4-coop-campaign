// CoD4 SP Coop - level module: bog_a ("The Bog")
//
// Scripted sequences and the coop decision for each (stock line refs are raw/maps/...):
//
//  * Bridge / first building / apartment / laundromat / alley (bog_a.gsc:300-1000, bog_a_code.gsc).
//    Driven by flag_set/flag_unset triggers (player_heads_towards_apartment, player_enters_the_fray,
//    player_interupts_melee_struggle, friendlies_* ...), "waittill trigger" triggers and replicated
//    flags. The player_-prefixed trigger flags are still effectively shared because the triggers
//    themselves are replayed. Melee struggle (bog_a_code.gsc:645-800) is trigger driven. -> nothing.
//
//  * Night vision: maps\_nightvision::main (bog_a.gsc:82) sets/clears "nightvision_on" for the local
//    player's goggles (_nightvision.gsc:64/146); bog_a_code.gsc:1840 modulate_laser and the
//    grenade-launcher hint (bog_a.gsc:2374) read it. -> local flags.
//
//  * Run-ahead ambush (bog_a.gsc:515-535 player_gets_ambushed): flag_set trigger "ambush_player"
//    aims two manual MGs at level.player and kills him. That punishes the player who ran ahead only;
//    replicated, it would kill the squadmate wherever they are. -> local flag + local trigger.
//
//  * Javelin (bog_a.gsc:1336-1376, 1825-1875; bog_a_code.gsc:2720 player_has_javelin): every
//    machine has its own weapon_javelin to pick up; "player_has_javelin" is player_-prefixed and
//    stays local (each player opens their own apartment door / music). flag_set_touching
//    "player_can_shoot_jav" is a per-player check -> local trigger.
//    Bridge BMPs (bog_a_code.gsc:1379-1505): four T72s "bridge_bmp1..4" (godon, only the local
//    player's MOD_PROJECTILE hits count). Vehicle deaths are not replicated by _coop, so the BMPs a
//    squadmate destroyed would keep living on our copy. -> each machine reports its own BMP kills
//    with a level event "bmp|<n>"; the receiver kills the same BMP locally (godoff + lethal
//    dodamage with level.player as attacker so _vehicle's friendlyfire_shield does not refund it;
//    bridge_bmp_is_shot_at ignores the non-projectile hit, the story flags overpass_baddies_flee /
//    bmps_are_dead / all_bmps_dead come from the killer's machine through flag replication).
//    Shanty-run weapon drop (bog_a.gsc:2305-2345, trigger "shanty_run_trigger") takes the javelin
//    away from level.player -> local trigger, each player loses theirs when they get there.
//
//  * Tank defense (bog_a_backhalf.gsc:1060-1187): trigger_radius "tank_defense_warning" (AWOL radio
//    nags) and "tank_defense_failed" (tank overrun -> missionFailedWrapper) react to the player
//    leaving the tank. -> local triggers: only the deserter's machine nags / fails, and a mission
//    fail on any machine already fails everyone through _coop.
//
//  * ZPU C4 (bog_a_backhalf.gsc:1246-1264 zpu_c4, _c4.gsc:39-178): C4 is planted with a pooled
//    trigger_use "generic_use_trigger" and detonated with the local player's detonator; only that
//    machine gets "c4_detonation" (model swap, fx, abrams_gets_drawing) while "zpus_destroyed" is
//    replicated. -> generic_use_trigger is local (a replay would plant C4 and hand the detonator to
//    the other player); when zpus_destroyed arrives without a local detonation, the local zpu gets
//    "clear_c4" (removes our own unplanted/planted C4 and detonator) and "death", and the same
//    visuals are applied, without the radiusDamage (the squadmate's blast must not hurt us).
//
//  * IR beacon (bog_a_backhalf.gsc:769-793): trigger_use "beaconTrig" -> beacon_planted. Replicated
//    on purpose, the cobra strike runs on both machines. -> nothing.
//
//  * Ending (bog_a_backhalf.gsc:1464-1534 ending_sequence): the tank talk waits on
//    "distance( level.player.origin, org.origin ) > 220" (non-replicated) before setting
//    "reached_ending_area" (replicated) and calling nextmission (host-driven by _coop). -> when the
//    flag arrives, a squadmate more than 200 units from the tank is pulled next to Price (or Mark)
//    so their own tank talk starts too.
//
//  * get_closest_* friendly picks from level.player (bog_a.gsc:1847 roof_guy, bog_a_code.gsc:
//    get_closest_colored_friendly) can choose different marines per machine - cosmetic, left alone.
//  * Local-only volumes: trigger_hint, ambient triggers (_ambient.gsc:369-400, a remote replay hits
//    an undefined 'progress'), intelligence_item pickups.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-local state
	local_flag( "nightvision_on" );
	local_flag( "nightvision_dlight_enabled" );
	local_flag( "ambush_player" );

	// volumes that only ever react to the local player
	local_trigger( "trigger_hint" );
	local_trigger( "intelligence_item" );
	local_trigger( "generic_use_trigger" );
	local_trigger( "shanty_run_trigger" );
	local_trigger( "tank_defense_warning" );
	local_trigger( "tank_defense_failed" );
	bog_a_local_ambient( "trigger_multiple" );
	bog_a_local_ambient( "trigger_radius" );
	bog_a_local_by_flag( "flag_set", "ambush_player" );
	bog_a_local_by_flag( "flag_set_touching", "player_can_shoot_jav" );

	// bridge BMPs: share kills
	level.coop.handlers[ "bmp" ] = ::bog_a_ev_bmp;
	level.coop_bmp = [];
	level.coop_bmp_dead = [];
	for ( i = 1; i <= 4; i++ )
		level thread bog_a_watch_bmp( i );

	level thread bog_a_zpu_sync();
	level thread bog_a_ending_pull();
}

// ---------------------------------------------------------------------------------------------
// trigger helpers
// ---------------------------------------------------------------------------------------------

bog_a_local_ambient( classname )
{
	ents = getentarray( classname, "classname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].ambient ) )
			ents[ i ].coop_local = true;
	}
}

bog_a_local_by_flag( targetname, flagName )
{
	ents = getentarray( targetname, "targetname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].script_flag ) && ents[ i ].script_flag == flagName )
			ents[ i ].coop_local = true;
	}
}

// the level script flag_init()s its flags only after _load (and our postinit) returned
bog_a_wait_flag_init( flagName )
{
	while ( !isdefined( level.flag ) || !isdefined( level.flag[ flagName ] ) )
		wait 0.05;
}

// ---------------------------------------------------------------------------------------------
// bridge BMPs (bog_a_code.gsc:1379-1505)
// ---------------------------------------------------------------------------------------------

bog_a_watch_bmp( idx )
{
	bmp = maps\_vehicle::waittill_vehiclespawn( "bridge_bmp" + idx );
	if ( !isdefined( bmp ) )
		return;
	level.coop_bmp[ idx ] = bmp;
	if ( isdefined( level.coop_bmp_dead[ idx ] ) )
	{
		// a squadmate already killed it: let bridge_bmp_rolls_in finish its setup (health, godon)
		wait 0.5;
		bog_a_kill_bmp( idx );
		return;
	}
	bmp waittill( "death" );
	if ( !isdefined( bmp ) )
		return; // deleted at the end of its path, not destroyed
	bmp.coop_dead = true;
	if ( isdefined( bmp.coop_remote_kill ) )
		return;
	maps\_coop::send( "bmp|" + idx );
	maps\_coop::log( "bridge_bmp" + idx + " destroyed" );
}

bog_a_ev_bmp( slot, tok )
{
	if ( tok.size < 3 )
		return;
	idx = int( tok[ 2 ] );
	level.coop_bmp_dead[ idx ] = true;
	if ( isdefined( level.coop_bmp[ idx ] ) )
		level thread bog_a_kill_bmp( idx );
}

bog_a_kill_bmp( idx )
{
	bmp = level.coop_bmp[ idx ];
	if ( !isdefined( bmp ) || isdefined( bmp.coop_dead ) || isdefined( bmp.coop_remote_kill ) )
		return;
	bmp.coop_remote_kill = true;
	bmp maps\_vehicle::godoff();
	// front armor regens a third of the damage (_bmp/_t72 build_frontarmor .33)
	bmp dodamage( bmp.health * 3 + 1000, bmp.origin, level.player );
}

// ---------------------------------------------------------------------------------------------
// ZPU destroyed by a squadmate's C4 (bog_a_backhalf.gsc:1246-1264)
// ---------------------------------------------------------------------------------------------

bog_a_zpu_sync()
{
	zpu = getent( "zpu", "targetname" );
	if ( !isdefined( zpu ) )
		return;
	zpu endon( "c4_detonation" ); // we blew it ourselves: stock zpu_c4 handles everything
	bog_a_wait_flag_init( "zpus_destroyed" );
	flag_wait( "zpus_destroyed" );
	if ( !isdefined( zpu ) )
		return;
	zpu notify( "clear_c4" );
	zpu notify( "death" );
	if ( isdefined( level.tankExplosion_fx ) )
		playfx( level.tankExplosion_fx, zpu.origin );
	thread play_sound_in_space( "bog_aagun_explode", zpu.origin );
	zpu setmodel( "vehicle_zpu4_burn" );
	if ( isdefined( level.abrams ) )
		maps\bog_a_backhalf::abrams_gets_drawing();
	maps\_coop::log( "zpu destroyed by squadmate" );
}

// ---------------------------------------------------------------------------------------------
// ending tank talk (bog_a_backhalf.gsc:1464-1534)
// ---------------------------------------------------------------------------------------------

bog_a_ending_pull()
{
	bog_a_wait_flag_init( "reached_ending_area" );
	flag_wait( "reached_ending_area" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( level.abrams ) )
		return;
	org = level.abrams.origin;
	if ( distance( level.player.origin, org ) <= 200 )
		return;
	pos = undefined;
	if ( isdefined( level.price ) && isalive( level.price ) && distance( level.price.origin, org ) <= 180 )
		pos = level.price.origin;
	else if ( isdefined( level.mark ) && isalive( level.mark ) && distance( level.mark.origin, org ) <= 180 )
		pos = level.mark.origin;
	else if ( isdefined( level.price ) && isalive( level.price ) )
		pos = level.price.origin;
	if ( !isdefined( pos ) )
		return;
	pull_to( pos, "Regrouping with your squad" );
}
