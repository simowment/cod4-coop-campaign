// CoD4 SP Coop - level module: launchfacility_a ("Launch Facility")
//
// Scripted sequences (stock raw/maps/launchfacility_a.gsc) and the coop decision for each:
//
// 1. Container area / flanking wall C4 (c4_plant_think 2882-2898, c4_callback 3121-3129):
//    the approach trigger and the "generic_use_trigger" plant trigger are trigger hits ->
//    replicated, but detonation waits on the LOCAL player's "detonate" (_c4.gsc:141). The wall
//    (exploder from script_noteworthy "100") would only come down on the detonating machine while
//    "flanking_wall_breached" (replicated) moves the squad everywhere. When that flag arrives and
//    our charge has not gone off, we clear our charge ("clear_c4") and send the c4_plant origin its
//    "c4_detonation" so the exploder runs here too.
// 2. BMPs bmp_02/03/04 (vehicle_bmp_think 3314-3352, vehicle_death_think 3380-3431,
//    vehicle_c4_think 3664-3697): only the local player's damage counts and vehicle deaths are
//    not replicated; "<bmp>_destroyed" is (flag_set at 3346). When the flag arrives and our copy
//    of the BMP is still alive, we kill it with the stock vehicle_death() (same call the squad
//    uses in squad_bmp_destroy 3103), which also clears its C4.
//    "player_near_bmp_02" etc. are flag_set_touching triggers about the local player -> local.
// 3. Gate (gate_player_participation 1212-1256, gate_right_reach 1258-1271, gate_sequence
//    1276-1289): progression needs "player_reached_kill_max" (local player's kill counter
//    3108-3119, AI_axis_death 4290-4300). The name makes it local by convention, which would let
//    only the machine of the player with the kills open the extra gate triggers -> shared_flag().
//    gate_sequence() spawns from level.ent, which is only set by a gate trigger hit on this
//    machine (gate_right_reach_trig_wait 1440-1449); if the replicated "gate_sequence_starting"
//    beats the trigger replay, level.ent would be undefined -> we pre-seed level.ent with the
//    first "reached_right_gate" trigger's spawner (a real trigger hit still overwrites it).
// 4. Launch tube lids (launch_lid_think 2931-3016, lid_kill 3019-3032): opening is gated on
//    "player_near_launchtube_0X" flag_set triggers (zone) / script flag_set (1560-1629); those are
//    world events -> shared_flag() so both machines open the same lids. The kill check
//    (trigger_hurt_player_lid_0X, istouching level.player) is local by nature.
// 5. Hinds / strafing (hind_attack 2326+, 2498-2530): local istouching checks -> fine.
// 6. Player rappel (player_rappel 2235-2293, player_squad_rappel 2295-2322): "trig_rappel" use
//    trigger -> replicated, every machine plays the rig natively at "player_rappel_node" -> both
//    players share the rig spot: puppets hidden from "obj_rappel_complete" to level end.
//    Safety net (rappel_sync): if the trig_rappel replay was lost (arrived before this machine's
//    player_rappel reached its waittill), the replicated "obj_rappel_complete" re-fires the
//    trigger locally so nobody is left on the roof. No pull: lerp_player_view_to_tag links the
//    player from wherever they stand.
//    BMP patrols (vehicle_patrol_think 3943) choose paths from the LOCAL player position, so the
//    BMPs can drift apart between machines; deaths are re-synced by bmp_sync below.
// 7. Level end: flag "level_fade_out" -> nextmission (level_end 2554-2560), host-driven.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	shared_flag( "player_reached_kill_max" );
	shared_flag( "player_near_launchtube_03" );
	shared_flag( "player_near_launchtube_04" );
	shared_flag( "player_near_launchtube_05" );
	shared_flag( "player_near_launchtube_06" );

	local_touching_triggers();

	hide_between( "obj_rappel_complete", undefined );

	level thread wall_c4_sync();
	level thread bmp_sync( "bmp_02" );
	level thread bmp_sync( "bmp_03" );
	level thread bmp_sync( "bmp_04" );
	level thread gate_ent_seed();
	level thread rappel_sync();
}

// player_rappel (2235-2262) only rappels after trig_rappel fires locally. If the replayed use hit
// arrived before this machine reached that waittill, "obj_rappel_complete" still arrives
// replicated (squad rappels, puppets hidden) but our player would be left on the roof. Replay the
// hit once more (no activator -> not re-sent) when our trigger was never consumed.
rappel_sync()
{
	trig = getent( "trig_rappel", "targetname" );
	if ( !isdefined( trig ) )
		return;
	flag_wait( "obj_rappel_complete" );
	if ( !maps\_coop::in_coop() )
		return;
	flag_wait( "obj_rappel_given" );
	wait 0.25;
	// player_rappel trigger_off()'s the trigger right after consuming it (realOrigin is recorded,
	// common_scripts/utility.gsc:673-676)
	if ( !isdefined( trig ) || isdefined( trig.realOrigin ) )
		return;
	maps\_coop::log( "launchfacility_a: squadmate rappelled, replaying trig_rappel" );
	trig notify( "trigger" );
}

// flag_set_touching triggers about "the" player (player_near_bmp_02, player_near_right_gate,
// player_near_vents) only react to the local player
local_touching_triggers()
{
	ents = getentarray( "flag_set_touching", "targetname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].script_flag ) && issubstr( ents[ i ].script_flag, "player_" ) )
			ents[ i ].coop_local = true;
	}
}

wall_c4_sync()
{
	ents = getentarray( "c4_plant", "targetname" );
	for ( i = 0; i < ents.size; i++ )
		ents[ i ] thread mark_detonated();

	flag_wait( "flanking_wall_breached" );
	waittillframeend;
	if ( !maps\_coop::in_coop() )
		return;
	for ( i = 0; i < ents.size; i++ )
	{
		if ( !isdefined( ents[ i ] ) || isdefined( ents[ i ].coop_detonated ) )
			continue;
		if ( !isdefined( ents[ i ].script_noteworthy ) || ents[ i ].script_noteworthy != "100" )
			continue;
		ents[ i ] thread force_detonation();
	}
}

force_detonation()
{
	self endon( "death" );
	maps\_coop::log( "launchfacility_a: wall C4 blown by squadmate, detonating local copy" );
	// make sure c4_plant_think got past its approach trigger (no activator -> not re-broadcast)
	if ( isdefined( self.target ) )
	{
		trig = getent( self.target, "targetname" );
		if ( isdefined( trig ) )
			trig notify( "trigger" );
	}
	wait 0.05;
	self notify( "clear_c4" );
	wait 0.05;
	if ( !isdefined( self.coop_detonated ) )
		self notify( "c4_detonation" );
}

mark_detonated()
{
	self endon( "death" );
	self waittill( "c4_detonation" );
	self.coop_detonated = true;
}

bmp_sync( name )
{
	bmp = maps\_vehicle::waittill_vehiclespawn( name );
	if ( !isdefined( bmp ) )
		return;
	bmp thread mark_dead();
	flag_wait( name + "_destroyed" );
	waittillframeend;
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( bmp ) || isdefined( bmp.coop_dead ) )
		return;
	maps\_coop::log( "launchfacility_a: " + name + " destroyed by squadmate, killing local copy" );
	bmp thread maps\launchfacility_a::vehicle_death( bmp getentitynumber() );
}

mark_dead()
{
	self waittill( "death" );
	if ( isdefined( self ) )
		self.coop_dead = true;
}

gate_ent_seed()
{
	flag_wait( "bmp_02_destroyed" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( isdefined( level.ent ) )
		return;
	trigs = getentarray( "reached_right_gate", "targetname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( !isdefined( trigs[ i ].script_linkto ) )
			continue;
		spawner = getent( trigs[ i ].script_linkto, "script_linkname" );
		if ( isdefined( spawner ) )
		{
			level.ent = spawner;
			return;
		}
	}
}
