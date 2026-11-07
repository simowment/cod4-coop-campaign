// CoD4 SP Coop - level module: icbm ("ICBM")
//
// Scripted sequences (stock raw/maps/icbm.gsc, icbm_code.gsc) and the coop decision for each:
//
// 1. Parachute landing (icbm_code.gsc:974-1003) and the intro freeze (icbm_code.gsc:227-246) are
//    dead code (add_start "chute" commented out icbm.gsc:19; default start is landed_start 18).
//    Nothing to do.
// 2. Stealth / knife kill in the basement (knife_kill_setup, AI_hostile_knife_kill_think
//    icbm_code.gsc:1121-1176): AI-only, gated on flags -> replicated, runs natively.
// 3. Interior vision (set_interior_vision icbm_code.gsc:427-438): flag "player_is_inside" is set /
//    cleared by "flag_set" / "flag_clear" trigger_multiples (zone entity string) and only drives
//    the local player's vision set -> those triggers are made player-local so a squadmate walking
//    into a house does not switch our vision. The flag itself is local by naming convention.
// 4. Interrogation / Griggs rescue breach (beehive2_wait 638-650, rescue_breach_setup 654-705,
//    rescue_sequence 720-743, player_cut_grigs_loose 747-763): "start_breach" trigger, the breach
//    trigger "trigger_volume_room01", "player_is_behind_griggs" and the use trigger
//    "grigs_use_trigger" are all trigger hits -> replicated. "player_shooting_interogators" is a
//    trigger_damage flag_set trigger whose flag only leads to the shared "get_yer_ass" (643);
//    "player_in_chopper_area" (803) gates the chopper fly-over for everyone -> both made
//    shared_flag() so a squadmate's hit counts on every machine even if the trigger replay is
//    throttled. fail_on_damage (708-718) checks attacker==level.player -> per machine, the fail is
//    replicated by the framework. Safety net (griggs_sync): if the "player_is_behind_griggs" /
//    "grigs_use_trigger" replays reached this machine before rescue_sequence was waiting on them,
//    Griggs would stay tied up here although "griggs_loose" arrived -> on "griggs_loose" we replay
//    both triggers without activator when our use trigger was never consumed.
// 5. Power tower C4 (flyover_to_tower_handler 855-901, _c4.gsc:91-180): plant use triggers are
//    "generic_use_trigger" trigger_use's -> replicated, so every machine gets both charges and a
//    detonator. Detonation waits on the LOCAL player's "detonate" (_c4.gsc:141), so on the
//    machine(s) of the squadmate(s) who did not press it the tower would never receive
//    "c4_detonation" (lights_off, flyover thread...). When the replicated "tower_destroyed" arrives
//    and our tower has not detonated, we clear our charges ("clear_c4": deletes the models and
//    removes the detonator, _c4.gsc:165-179) and send the tower its "c4_detonation" ourselves.
//    The collapse itself (icbm_code.gsc:1488-1497) is flag-gated -> already runs everywhere.
//    If a plant replay was lost here, flyover_to_tower_handler would still sit in
//    level waittill( "c4_in_place" ) (873/879), so "c4_planted", c4_set() and with it
//    fense_to_base_handler() (957) would never run on this machine: before clearing, the missing
//    "c4_in_place" notifies are sent (counted locally; sent BEFORE "clear_c4" because
//    remove_detonator, _c4.gsc:182, ends on "c4_in_place").
// 6. Base fights / launch (meet_second_squad_handler 1240-1283, missile_launch 1326-1358):
//    "lift_off" is a flag_set trigger (player in position) -> replicated. A squadmate far away
//    when the launch scene is triggered is pulled to the buddy.
// 7. Level end (run_to_gate 1361-1376): flag "level_done" + nextmission, host-driven.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	shared_flag( "player_in_chopper_area" );
	shared_flag( "player_shooting_interogators" );

	local_flag_triggers( "flag_set", "player_is_inside" );
	local_flag_triggers( "flag_clear", "player_is_inside" );

	level thread tower_c4_sync();
	level thread griggs_sync();

	pull_to_buddy_on_flag( "lift_off", 2000 );
}

// rescue_sequence (720-743) only threads player_cut_grigs_loose after a LOCAL pass of
// trigger_wait( "player_is_behind_griggs" ). If that trigger replay arrived before this machine
// reached the wait (interogators_dead / breach_started lagging), the grigs_use_trigger replay is
// lost too: "griggs_loose" / "griggs_is_good" still arrive replicated, but Griggs never plays
// "grigsby_rescue" here and stays tied up. Replay both triggers (no activator -> not re-sent).
griggs_sync()
{
	behind = getent( "player_is_behind_griggs", "targetname" );
	usetrig = getent( "grigs_use_trigger", "targetname" );
	if ( !isdefined( behind ) || !isdefined( usetrig ) )
		return;
	safe_flag_wait( "griggs_loose" );
	if ( !maps\_coop::in_coop() )
		return;
	safe_flag_wait( "breach_started" );
	safe_flag_wait( "interogators_dead" );
	wait 0.25;
	// player_cut_grigs_loose (747-753) trigger_off()'s the use trigger once it consumed a hit,
	// which records realOrigin (common_scripts/utility.gsc:673-676)
	if ( !isdefined( usetrig ) || isdefined( usetrig.realOrigin ) )
		return;
	maps\_coop::log( "icbm: griggs freed by squadmate, replaying rescue triggers" );
	if ( isdefined( behind ) )
		behind notify( "trigger" );
	wait 0.05;
	if ( isdefined( usetrig ) && !isdefined( usetrig.realOrigin ) )
		usetrig notify( "trigger" );
}

// mark the trigger_multiples of a _load trigger type (targetname) that drive one flag as local
local_flag_triggers( targetname, flagName )
{
	ents = getentarray( targetname, "targetname" );
	for ( i = 0; i < ents.size; i++ )
	{
		if ( isdefined( ents[ i ].script_flag ) && ents[ i ].script_flag == flagName )
			ents[ i ].coop_local = true;
	}
}

tower_c4_sync()
{
	tower = getent( "tower", "targetname" );
	if ( !isdefined( tower ) )
		return;
	tower thread mark_detonated();
	level.coop_icbm_plants = 0;
	level thread count_plants();

	safe_flag_wait( "tower_destroyed" );
	waittillframeend;
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( tower ) || isdefined( tower.coop_detonated ) )
		return;
	maps\_coop::log( "icbm: tower blown by squadmate, clearing local charges" );
	// flyover_to_tower_handler sets multiple_c4 (861) right before it starts waiting for plants
	if ( isdefined( tower.multiple_c4 ) )
	{
		missing = 2 - level.coop_icbm_plants;
		for ( i = 0; i < missing; i++ )
		{
			maps\_coop::log( "icbm: plant replay missing, sending c4_in_place" );
			level notify( "c4_in_place", level.player ); // an entity, so "ent1 == planted_ent" (874) is valid
			wait 0.05;
		}
	}
	if ( !isdefined( tower ) || isdefined( tower.coop_detonated ) )
		return;
	tower notify( "clear_c4" );
	wait 0.05;
	if ( isdefined( tower ) && !isdefined( tower.coop_detonated ) )
		tower notify( "c4_detonation" );
}

mark_detonated()
{
	self endon( "death" );
	self waittill( "c4_detonation" );
	self.coop_detonated = true;
}

count_plants()
{
	for ( ;; )
	{
		level waittill( "c4_in_place" );
		level.coop_icbm_plants++;
	}
}
