// CoD4 SP Coop - airplane ("Mile High Club")
//
// Scripted sequences (stock raw/maps/airplane.gsc) and the coop decision for each:
//
// NOTE: most progression flags here are radiant trigger flags whose names contain "player_"
// (player_approach_*, player_approaching_breach*, player_up_breach_stairs, player_near_freefall,
// player_breach_jump). By the framework convention those flags are local. They still reach every
// copy, because the trigger hit that sets them is replayed. The exception is player_breach_jump.
//
// 1. Intro through the ceiling hole (intro_fade_in 222-290). Every copy links level.player to
//    org_intro_playerview, then SetOrigin to player_intro_start, the same spot for everyone.
//    DECISION: intro_fade_in_complete is made LOCAL (every copy sets it itself at 278 / 328; a
//    replicated copy from a faster squadmate would end the hide and run the step-back while this
//    copy is still linked in its own intro, and the stock SetOrigin would then undo it). Hide
//    puppets until it is set, wait for the linked heuristic to settle (the unlink + SetOrigin
//    teleport itself reads as "linked" for a few frames), then step each non-host player back down
//    the aisle so the players do not overlap.
//
// 2. Mission timer (airplane_timer 340-344, timer_start/timer_logic 1996-2054). Each copy starts it
//    on intro_fade_in_complete. Expiry fails locally and _coop turns that into a squad fail.
//    Nothing to do.
//
// 3. Fuselage breach (fuselage_breached 484-540) on the replayed player_approaching_breach trigger.
//    Native. player_breach_jump (player_breach_jump 1768-1777) is a fail trigger: "you jumped out of
//    the hole". It must not be replayed on a squadmate's copy. DECISION: mark the flag_set trigger
//    whose script_flag is player_breach_jump as local.
//
// 4. Human shield (humanshield 824-892, hostage_timer 2063-2113, human_shield_pain_monitor 1076-1153).
//    It starts on the replayed player_approach_human_shield trigger on every copy. The playerview
//    starts at each player's own origin and is deleted after 0.5 s, so the players are not on a rig
//    together. A straggler far away cannot take the shot. DECISION: 1 s after
//    human_shield_starting, pull a player farther than 400 units to the designed view spot
//    (org_humanshield_playerview, origin captured before the stock script moves the entity).
//    The outcome flags terrorist_killed / terrorist_wounded are replicated, but only the shooter's
//    copy plays the death or pain branch. The other copy would keep a live terrorist. A remote
//    AI-kill (dodamage with no hit location) would also take the wounded branch and fail Veteran
//    (1155-1162). DECISION: the terrorist and the hostage are taken out of the remote-kill table
//    (a K| from the shooter's copy - the headshot branch deletes the AI via convert_guy_to_drone
//    1121 - must never reach this copy as a hit-location-less dodamage). When one of the outcome
//    flags arrives and the local terrorist is alive and was never hit locally (own damage watcher),
//    send the matching damage notify (j_head for killed, torso_upper for wounded) to it, after its
//    pain monitor is running (a late copy may spawn the pair after the flag arrived). The monitor's
//    wounded branch is gated on !flag( "terrorist_wounded" ), which the replicated flag has already
//    set, so for the wounded mirror the flag value is lowered (raw level.flag, no notify, no
//    replication) for the duration of the notify and restored afterwards.
//
// 5. Freefall (freefall 1335-1405, white_flash 1412-1420, plane_explodes 1445-1471). trig_exit_door
//    is waited on only after exit_door_blown. A replayed hit therefore pulls the squadmate out with
//    the first jumper, but the replay is lost if that copy is not waiting yet. DECISION: when the
//    local player has jumped (player_jumped_out, a local flag), set the shared flag
//    coop_airplane_exit_jump. The other copies then re-notify their trig_exit_door until their own
//    player has jumped. white_done / plane_explodes / cut_to_black belong to each player's own
//    jump (white flash, explosion fx, level.player_sound_org) and are made local. A replicated
//    plane_explodes would run exit_door_fx's stopLoopSound on an undefined level.player_sound_org.
//    Puppets are hidden from the jump to the end of the level.
//
// 6. Level end: plane_explodes -> nextmission (1470). The host drives it.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// every copy runs its own intro and sets this itself (see 1.)
	local_flag( "intro_fade_in_complete" );

	// per-player freefall chain (each copy runs its own after its own player jumps)
	local_flag( "white_done" );
	local_flag( "plane_explodes" );
	local_flag( "cut_to_black" );

	// "jumped out of the breach hole" fail volume: only for the player who touched it
	ap_local_flag_trigger( "player_breach_jump" );

	// the stock humanshield() overwrites this entity's origin with level.player.origin
	org = getent( "org_humanshield_playerview", "targetname" );
	if ( isdefined( org ) )
		level.coop_ap_shield_pos = org.origin;

	flag_init( "coop_airplane_exit_jump" );

	level thread ap_intro();
	level thread ap_shield_pull();
	level thread ap_shield_actors();
	level thread ap_shield_mirror();
	level thread ap_exit_jump_report();
	level thread ap_exit_jump_follow();
	level thread ap_hide_after_jump();
}

// Our main() runs inside _load::main, before the level script's own flag_init calls (stock 79-122).
ap_wait_flag_exists( name )
{
	while ( !isdefined( level.flag[ name ] ) )
		wait 0.05;
}

// radiant flag triggers all share targetname "flag_set"; pick the one by its script_flag
ap_local_flag_trigger( flagName )
{
	trigs = getentarray( "flag_set", "targetname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].script_flag ) && trigs[ i ].script_flag == flagName )
			trigs[ i ].coop_local = true;
	}
}

// ---------------------------------------------------------------------------------------------
// 1. intro: everyone lands on player_intro_start
// ---------------------------------------------------------------------------------------------

ap_intro()
{
	ap_wait_flag_exists( "intro_fade_in_complete" );
	hide_between( undefined, "intro_fade_in_complete" );
	flag_wait( "intro_fade_in_complete" );
	if ( !maps\_coop::in_coop() )
		return;
	level.coop.hide_count++;
	// the stock intro has just unlinked us and teleported us; let the linked heuristic decay
	end = gettime() + 3000;
	wait 0.05;
	while ( maps\_coop::player_linked() && gettime() < end )
		wait 0.05;
	ap_spread_back();
	wait 1;
	level.coop.hide_count--;
}

ap_spread_back()
{
	c = level.coop;
	if ( c.ishost )
		return;
	if ( maps\_coop::player_linked() )
		return;
	ang = level.player getplayerangles();
	back = vectorScale( anglestoforward( ( 0, ang[ 1 ], 0 ) ), -1 );
	base = level.player.origin;
	dist = 40 * c.slot;
	if ( dist < 40 )
		dist = 40;
	for ( r = dist; r >= 24; r -= 16 )
	{
		p = base + vectorScale( back, r );
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

// ---------------------------------------------------------------------------------------------
// 4. human shield
// ---------------------------------------------------------------------------------------------

ap_shield_pull()
{
	ap_wait_flag_exists( "human_shield_starting" );
	flag_wait( "human_shield_starting" );
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( level.coop_ap_shield_pos ) )
		return;
	wait 1; // the playerview lerp (0.5 s) is over and the playerview is deleted
	if ( flag( "human_shield_over" ) )
		return;
	pos = level.coop_ap_shield_pos;
	if ( distance( level.player.origin, pos ) <= 400 )
		return;
	level.player setorigin( maps\_coop_player::safe_spot_near( pos ) );
	iprintln( "Regrouping with your squad" );
	maps\_coop::log( "airplane: pulled to human shield" );
}

// humanshield() spawns the pair synchronously right after player_approach_human_shield (826-838)
ap_shield_actors()
{
	ap_wait_flag_exists( "player_approach_human_shield" );
	flag_wait( "player_approach_human_shield" );
	waittillframeend;
	if ( isdefined( level.terrorist ) )
	{
		ap_no_remote_kill( level.terrorist );
		level.terrorist thread ap_watch_local_hit();
	}
	if ( isdefined( level.hostage ) )
		ap_no_remote_kill( level.hostage );
}

ap_no_remote_kill( guy )
{
	if ( !isdefined( guy ) || !isdefined( guy.coop_id ) || !isdefined( level.coop.ai ) )
		return;
	level.coop.ai[ guy.coop_id ] = undefined;
}

// remembers that this copy's own terrorist took a real (non flashbang) hit
ap_watch_local_hit()
{
	self endon( "death" );
	for ( ;; )
	{
		self waittill( "damage", damage, attacker, direction_vec, point, type );
		if ( isdefined( self.coop_mirrored ) )
			return;
		if ( isdefined( type ) && type == "MOD_IMPACT" )
			continue;
		self.coop_local_hit = true;
		return;
	}
}

ap_shield_mirror()
{
	ap_wait_flag_exists( "terrorist_killed" );
	ap_wait_flag_exists( "terrorist_wounded" );
	flag_wait_either( "terrorist_killed", "terrorist_wounded" );
	if ( !maps\_coop::in_coop() )
		return;
	// let this frame's own damage handling (monitor + local-hit watcher) finish first
	waittillframeend;
	// a lagging copy may not have spawned the pair yet
	end = gettime() + 15000;
	while ( !isdefined( level.terrorist ) && gettime() < end )
		wait 0.05;
	wait 0.1; // AI_human_shield_think has started the pain monitor
	t = level.terrorist;
	if ( !isdefined( t ) || !isalive( t ) )
		return;
	if ( isdefined( t.coop_local_hit ) || isdefined( t.coop_mirrored ) )
		return; // this copy already played its own branch
	t.coop_mirrored = true;
	maps\_coop::log( "airplane: mirroring human shield outcome" );
	if ( flag( "terrorist_killed" ) )
	{
		// same argument list human_shield_pain_monitor waits for
		t notify( "damage", 50, level.player, ( 1, 0, 0 ), t.origin, "MOD_PISTOL_BULLET", "", "", "j_head", 0 );
		return;
	}
	// the wounded branch requires !flag( "terrorist_wounded" ): lower it without notify / replication
	level.flag[ "terrorist_wounded" ] = false;
	t notify( "damage", 50, level.player, ( 1, 0, 0 ), t.origin, "MOD_PISTOL_BULLET", "", "", "torso_upper", 0 );
	waittillframeend;
	level.flag[ "terrorist_wounded" ] = true;
}

// ---------------------------------------------------------------------------------------------
// 5. freefall: whoever jumps, everyone jumps
// ---------------------------------------------------------------------------------------------

ap_exit_jump_report()
{
	ap_wait_flag_exists( "player_jumped_out" );
	flag_wait( "player_jumped_out" );
	if ( !flag( "coop_airplane_exit_jump" ) )
		flag_set( "coop_airplane_exit_jump" );
}

ap_exit_jump_follow()
{
	ap_wait_flag_exists( "player_jumped_out" );
	ap_wait_flag_exists( "exit_door_blown" );
	flag_wait( "coop_airplane_exit_jump" );
	if ( !maps\_coop::in_coop() )
		return;
	flag_wait( "exit_door_blown" );
	trig = getent( "trig_exit_door", "targetname" );
	if ( !isdefined( trig ) )
		return;
	// stock freefall() starts waiting on the trigger only once human_shield_over and exit_door_blown
	// have both happened locally, so keep nudging it for a while
	for ( i = 0; i < 40; i++ )
	{
		if ( flag( "player_jumped_out" ) )
			return;
		trig.coop_remote_time = gettime(); // our own nudge: _coop must not send it back out
		trig notify( "trigger", level.player );
		wait 0.5;
	}
}

ap_hide_after_jump()
{
	ap_wait_flag_exists( "player_jumped_out" );
	hide_between( "player_jumped_out", undefined );
}
