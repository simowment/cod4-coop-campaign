// CoD4 SP Coop - killhouse (F.N.G. tutorial)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps) and the coop decision for each:
//
//  * Default start is inside_start (level.short_training, killhouse.gsc:9, 26, 520-538): both players
//    are placed at the same script_origin; Gaz "intro" anim on introscreen_complete (killhouse.gsc:540-560).
//    -> nothing to do, the intro is native per player.
//
//  * Rifle range / sidearm / melee (killhouse.gsc:573-1170): progression is polled on the LOCAL player
//    (isADS(), GetWeaponAmmoStock, HasWeapon("usp"), getCurrentWeapon - killhouse.gsc:592, 618, 625,
//    1044, 1060, 1078) plus a few trigger flags. Every player has to do their own training, so the
//    training trigger flags are made player-local instead of being unioned:
//      - rifleTraining_stall -> flag_trigger_init "player_at_rifle_stall" (killhouse.gsc:577). The flag is
//        already local ("player_"), but a replayed hit would still set it, so the trigger is local.
//      - scr_watermelon damage trigger -> melee_complete (killhouse_code.gsc:2257-2273) -> local.
//      - near_melee trigger_radius (script_flag_true sidearm_complete) -> local, sidearm_complete local.
//      - dialog gate flags melee_run_dialog, ADS_shoot_dialog, crosshair_dialog, ADS_targets_shot,
//        hip_targets_shot (killhouse.gsc:238-243, 717-718, 763) -> local (each copy runs its own Gaz).
//      - objective "done" flags from setObjectiveState (killhouse_code.gsc:1683) -> local.
//      - gaz_in_idle_position (killhouse_code.gsc:337/348, read by gaz_animation 2643) -> local: it is
//        our own Gaz's state; a replicated set would interrupt our Gaz's reach to station one.
//    Pop-up target dummies are per copy; remote shots replayed via magicbullet can knock targets on the
//    other copy, and while the local player stands in rifleTraining_stall they COUNT as our hits
//    (killhouse_code.gsc:1362-1364) - a squadmate shooting next to us can advance our rifle steps (benign).
//
//  * Frag / launcher / C4 / obstacle course: skipped by short_training (melee_training ->
//    report_to_price, killhouse.gsc:1153-1158). safety_pit is still marked local (killhouse.gsc:1300,
//    1453) in case a start point reaches it.
//
//  * Reveal (report_to_price / reveal_anims, killhouse.gsc:1968-2077): hangar door on flag
//    open_ship_hanger, SAS+Price reveal anim unpaused by a NON-replicated
//    "level.player istouching( looking_at_price )" loop (killhouse.gsc:2049), ladder flags at_ladder /
//    on_ladder. Decision: per player - each player gets the reveal when they walk in. The scene flags
//    (open_ship_hanger, at_ladder, on_ladder, reveal_dialog_starting, reveal_done, price_reveal_done,
//    reveal_dialog_done) and their flag_set triggers + looking_at_price are local. No pull: the other
//    player may still be at the rifle range and their own tutorial scripts must keep running.
//
//  * Cargoship mock-up CQB course (cargoship_training, killhouse.gsc:2142-2374; killhouse_code.gsc
//    624-1030): a solo timed run. Course state lives in flags that stock clears locally
//    (killhouse.gsc:2337-2341) - with union replication a squadmate's run would complete/skip ours
//    (e.g. at_finish set by them -> our safe_flag_wait("at_finish") passes, killhouse.gsc:2334). Decision:
//    every course flag (at_top_of_ladder, activate_rope, got_flashes, sprint, sprinted, ready_to_finish,
//    at_finish) and every course trigger (top_of_ladder_trigger, top_of_rope_trigger, near_rope,
//    jump_off_trigger, position_one..six) is local, so both players run their own course and get their
//    own time. The rope slide is a lerp_player_view_to_tag link (killhouse_code.gsc:852-870); puppets
//    are hidden by the linked heuristic.
//
//  * Debrief (killhouse.gsc:2491-2541): debrief_trigger -> difficulty menu -> nextmission. Local trigger;
//    the host's nextmission ends the level for everyone (framework), a client that finishes first waits.
//
// Known limits (not handled here): course fails (timer killhouse_code.gsc:885-949, jump-off 624-636,
// out of flashbangs 638-657, shooting a "friendly" target 875-882, menu "tryagain" killhouse.gsc:2532)
// call missionFailedWrapper, which the framework turns into a squad-wide fail.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// --- shared rifle range: the host's pop-up targets drive everyone's (stock hooks in
	// killhouse_code.gsc moveTargetDummy / target_down and killhouse.gsc timedTargets) ---
	level.coop_target_hook = ::target_hook;
	level.coop_timed_hook = ::timed_hook;
	h = level.coop.handlers;
	h[ "KT" ] = ::ev_target;
	h[ "KH" ] = ::ev_target_hit;
	level.coop.handlers = h;

	// --- rifle range / sidearm / melee: per-player training progress ---
	local_flag( "melee_complete" );
	local_flag( "melee_run_dialog" );
	local_flag( "sidearm_complete" );
	local_flag( "near_melee" );
	local_flag( "ADS_targets_shot" );
	local_flag( "hip_targets_shot" );
	local_flag( "crosshair_dialog" );
	local_flag( "ADS_shoot_dialog" );
	// gaz_animation() only plays when this is set (killhouse_code.gsc:2643); it describes OUR Gaz having
	// finished his reach to station one (killhouse_code.gsc:337). Replicated, a squadmate's flag would make
	// our gaz_animation() stopanimscripted() our Gaz in the middle of his reach.
	local_flag( "gaz_in_idle_position" );
	local_trigger( "rifleTraining_stall" );
	local_trigger( "scr_watermelon" );
	local_trigger( "safety_pit" );
	local_flag_trigger( "near_melee" );

	// objective completion flags (registerObjective/setObjectiveState, killhouse_code.gsc:1646-1685)
	local_flag( "obj_enter_range" );
	local_flag( "obj_rifle" );
	local_flag( "obj_timed_rifle" );
	local_flag( "obj_sidearm" );
	local_flag( "obj_melee" );
	local_flag( "obj_price" );
	local_flag( "obj_debrief" );

	// --- reveal: each player gets Price's reveal when they walk into the hangar ---
	local_flag( "open_ship_hanger" );
	local_flag( "at_ladder" );
	local_flag( "on_ladder" );
	local_flag( "reveal_dialog_starting" );
	local_flag( "reveal_done" );
	local_flag( "price_reveal_done" );
	local_flag( "reveal_dialog_done" );
	local_flag_trigger( "open_ship_hanger" );
	local_flag_trigger( "at_ladder" );
	local_flag_trigger( "on_ladder" );
	local_trigger( "looking_at_price" );

	// --- cargoship mock-up: a solo timed run for each player ---
	local_flag( "at_top_of_ladder" );
	local_flag( "activate_rope" );
	local_flag( "got_flashes" );
	local_flag( "sprint" );
	local_flag( "sprinted" );
	local_flag( "ready_to_finish" );
	local_flag( "at_finish" );
	local_flag_trigger( "at_top_of_ladder" );
	local_flag_trigger( "sprint" );
	local_flag_trigger( "at_finish" );
	local_trigger( "top_of_ladder_trigger" );
	local_trigger( "top_of_rope_trigger" );
	local_trigger( "near_rope" );
	local_trigger( "jump_off_trigger" );
	local_trigger( "position_one" );
	local_trigger( "position_two" );
	local_trigger( "position_three" );
	local_trigger( "position_four" );
	local_trigger( "position_five" );
	local_trigger( "position_six" );

	// --- debrief: per player; the host's nextmission ends the level ---
	local_trigger( "debrief_trigger" );
}

// _load's "flag_set" triggers all share targetname "flag_set"; mark only the one(s) for this flag
local_flag_trigger( flagName )
{
	trigs = getentarray( "flag_set", "targetname" );
	n = 0;
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( !isdefined( trigs[ i ].script_flag ) || trigs[ i ].script_flag != flagName )
			continue;
		trigs[ i ].coop_local = true;
		n++;
	}
	return n;
}

// ---------------------------------------------------------------------------------------------
// shared rifle range
//   host:   every raise / lower / knock-down of a target is broadcast ("KT|<entnum>|<command>")
//   client: its own script may not move targets; it mirrors the host's, and a hit it lands on a
//           target is sent to the host ("KH|<entnum>"), whose target then goes down for everyone.
//   The timed drill on the client counts every knocked-down target instead of its own random pick.
// ---------------------------------------------------------------------------------------------

target_hook( command )
{
	c = level.coop;
	if ( !maps\_coop::in_coop() )
		return true;
	id = self getentnum();
	if ( c.ishost )
	{
		maps\_coop::send( "KT|" + id + "|" + command );
		return true;
	}
	if ( isdefined( self.coop_applying ) )
		return true;
	if ( command == "down" )
		maps\_coop::send( "KH|" + id ); // a hit here: the host decides, and its knock-down comes back
	return false;
}

ev_target( slot, tok )
{
	if ( level.coop.ishost || tok.size < 4 )
		return;
	t = getentbynum( int( tok[ 2 ] ) );
	if ( !isdefined( t ) )
		return;
	t thread apply_target( tok[ 3 ] );
}

apply_target( command )
{
	self.coop_applying = true;
	if ( command == "down" )
	{
		level notify( "coop_target_hit" );
		self [[ level.coop_fn_target_down ]]();
	}
	else
		self [[ level.coop_fn_move_target ]]( command );
	self.coop_applying = undefined;
}

ev_target_hit( slot, tok )
{
	if ( !level.coop.ishost || tok.size < 3 )
		return;
	t = getentbynum( int( tok[ 2 ] ) );
	if ( !isdefined( t ) || !isdefined( t.raised ) || !t.raised || ( isdefined( t.moving ) && t.moving ) )
		return;
	// a squadmate's hit counts wherever the host stands: do what the target's own handler does for a valid
	// hit from the stall (killhouse_code.gsc targetDummyThink): score it ("hit") and knock it down
	t notify( "hit" );
	t thread [[ level.coop_fn_target_down ]]();
}

timed_hook()
{
	if ( !maps\_coop::in_coop() || level.coop.ishost )
		return false;
	level thread count_shared_hits();
	return true;
}

count_shared_hits()
{
	level endon( "times_up" );
	for ( ;; )
	{
		level waittill( "coop_target_hit" );
		level.num_hit++;
	}
}
