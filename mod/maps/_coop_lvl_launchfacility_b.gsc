// CoD4 SP Coop - launchfacility_b ("No Fighting In The War Room")
//
// Scripted sequences (stock raw/maps/launchfacility_b.gsc) and the coop decision for each:
//
// 1. Countdown timer (787-803, startTimer 847-874, killTimer on codes_uploaded 709-718).
//    begin_countdown / countdown_started are plain flags -> replicated, so every copy starts its own
//    timer within a frame of the others. Expiry fails the mission locally and _coop turns any fail
//    into a squad fail. Nothing to do.
//
// 2. Launch tubes -> blast door (launchtubes_teleport_friendlies 1148-1182, run_to_the_door 1278-1340,
//    in_volume 1257-1274, kill_player_in_tubes 1389-1401). in_volume() only checks the AI, and the
//    trigger hit is replicated, so every copy slams the door when the first player gets to the door
//    room. A squadmate still in the silos would be shut in and burned by kill_player_in_tubes
//    in their own copy. DECISION: when blast_door_player_clip_on is set (the door is starting to close),
//    pull a player who is not inside the shut_blast_door volume to the centre of that volume.
//
// 3. C4 on the control-room wall (plant_the_c4 1643-1656, blow_the_wall 1658-1680, maps\_c4).
//    The generic_use_trigger plant is replicated, so each copy plants its own charge and hands out
//    a detonator. Only the copy that detonates runs blow_the_wall(): the wall_destroyed flag reaches
//    the others, but their wall (exploder 100) and their charge stay in place.
//    DECISION: when wall_destroyed arrives from a squadmate, clear the local charge (the stock
//    "clear_c4" notify removes the model and the detonator) and play the wall breach locally: exploder
//    100, connectpaths, fx, sound and quake, without the radiusdamage, then activate
//    breaching_control_room as blow_the_wall does 1 s later.
//
// 4. Abort codes keypad (upload_codes 1720-1803). This is a trigger_use with a 3 s hold-use progress
//    bar that freezes level.player. A replayed use would freeze the other player and start a
//    progress bar that fails at once. DECISION: local_trigger("keyboard_use_trigger"). The first
//    player to finish sets codes_uploaded (replicated). The other copies then switch their keypad
//    trigger off and swap the objective keyboard model.
//
// 5. Big-screen bink (control_room_bigscreen 1897-1904) on flag zakhaev_leaving -> replicated, native.
//
// 6. Elevator (elevator 1961-1976, in_the_elevator 2007-2017, elevator_think 2024-2085). The lift
//    leaves when Price and Griggs touch standing_in_elevator, whoever sent the trigger. The player
//    is not checked. A straggler is left at the bottom of the shaft. DECISION: when
//    elevator_player_clip_on is set (elevator_think starts, doors close in 2 s), pull a player who is
//    not inside standing_in_elevator to the centre of that volume (the lift floor).
//
// Note: blast_door_player_clip_on and elevator_player_clip_on are local by the "player_" rule. Each
// copy sets them itself: shut_blast_door and standing_in_elevator are player-only trigger_multiples
// (no spawnflags in the zone), so the squadmate's touch is replayed (about once a second) and wakes
// in_volume() / in_the_elevator() on every copy.
//
// 7. Level end: vehical_depot -> level_end -> nextmission (2104-2137). The host drives it. Nothing to do.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// keypad hold-use is per player (freezeControls + useButtonPressed polling)
	local_trigger( "keyboard_use_trigger" );

	level.coop_lfb_local_blast = false;

	level thread lfb_blast_door_pull();
	level thread lfb_watch_local_detonation();
	level thread lfb_remote_wall_blow();
	level thread lfb_codes_uploaded_cleanup();
	level thread lfb_elevator_pull();
}

// Our main() runs inside _load::main, before the level script's own flag_init calls (stock 117-172).
lfb_wait_flag_exists( name )
{
	while ( !isdefined( level.flag[ name ] ) )
		wait 0.05;
}

// ---------------------------------------------------------------------------------------------
// blast door: nobody may be left in the silos when the door closes
// ---------------------------------------------------------------------------------------------

lfb_blast_door_pull()
{
	lfb_wait_flag_exists( "blast_door_player_clip_on" );
	safe_flag_wait( "blast_door_player_clip_on" );
	if ( !maps\_coop::in_coop() )
		return;
	vol = getent( "shut_blast_door", "targetname" );
	if ( !isdefined( vol ) )
		return;
	if ( level.player istouching( vol ) )
		return;
	// The volume centre (-874 4155 -309, ~43u above the floor) is inside the door room. Price stands
	// at close_blastdoor_animent (-622 3946), right in the sweep of the closing door, so do not use him.
	pull_to( vol.origin, "Regrouping with your squad" );
}

// ---------------------------------------------------------------------------------------------
// control room wall C4
// ---------------------------------------------------------------------------------------------

lfb_watch_local_detonation()
{
	c4 = getent( "wall_explosives", "targetname" );
	if ( !isdefined( c4 ) )
		return;
	c4 waittill( "c4_detonation" );
	level.coop_lfb_local_blast = true;
}

lfb_remote_wall_blow()
{
	lfb_wait_flag_exists( "wall_destroyed" );
	safe_flag_wait( "wall_destroyed" );
	// on the detonating copy, plant_the_c4's blow_the_wall() may set the flag before our
	// c4_detonation watcher has resumed: let every thread of this frame run first
	waittillframeend;
	if ( level.coop_lfb_local_blast )
		return; // our own charge went off: stock blow_the_wall() is running
	maps\_coop::log( "lfb: wall destroyed by squadmate, mirroring breach" );

	level thread lfb_clear_local_c4();

	blasted_wall = getent( "blasted_wall", "targetname" );
	if ( isdefined( blasted_wall ) )
		blasted_wall connectpaths();
	exploder( 100 );
	explosives = getent( "wall_explosives", "targetname" );
	if ( isdefined( explosives ) )
	{
		if ( isdefined( level.wallExplosionSmall_fx ) )
			playfx( level.wallExplosionSmall_fx, explosives.origin );
		thread play_sound_in_space( "detpack_explo_metal", explosives.origin );
		earthquake( 0.4, 1, explosives.origin, 1000 );
	}
	// blow_the_wall's aa_ (stat / auto-adjust section) flags are local: mirror them too
	if ( isdefined( level.flag[ "aa_blow_the_wall" ] ) )
		flag_clear( "aa_blow_the_wall" );
	if ( isdefined( level.flag[ "aa_upload_them_codes" ] ) )
		flag_set( "aa_upload_them_codes" );

	wait 1;
	trig = getent( "breaching_control_room", "targetname" );
	if ( isdefined( trig ) && !isdefined( trig.trigger_off ) )
		trig activate_trigger();
}

// The local plant may still be on its way (plant_the_c4 starts after three radio lines), so clear
// the charge every second for a while.
lfb_clear_local_c4()
{
	for ( i = 0; i < 30; i++ )
	{
		if ( level.coop_lfb_local_blast )
			return;
		c4 = getent( "wall_explosives", "targetname" );
		if ( isdefined( c4 ) )
			c4 notify( "clear_c4" );
		wait 1;
	}
}

// ---------------------------------------------------------------------------------------------
// abort codes: once anyone has uploaded them, retire the local keypad
// ---------------------------------------------------------------------------------------------

lfb_codes_uploaded_cleanup()
{
	lfb_wait_flag_exists( "codes_uploaded" );
	safe_flag_wait( "codes_uploaded" );
	// upload_codes() on this copy may still be waiting for its aigroup and then trigger_on() the
	// keypad and spawn the _obj model later (1726-1737). Keep it retired until the level is over.
	// The uploader's copy clears these local aa_ section flags (1800-1801); do the same here.
	if ( safe_flag( "aa_countdown_started" ) )
		flag_clear( "aa_countdown_started" );
	if ( safe_flag( "aa_upload_them_codes" ) )
		flag_clear( "aa_upload_them_codes" );
	while ( !safe_flag( "at_the_jeep" ) )
	{
		trig = getent( "keyboard_use_trigger", "targetname" );
		if ( isdefined( trig ) && !isdefined( trig.trigger_off ) )
			trig trigger_off();
		models = getentarray( "script_model", "classname" );
		for ( m = 0; m < models.size; m++ )
		{
			if ( isdefined( models[ m ].model ) && models[ m ].model == "com_computer_keyboard_obj" )
				models[ m ] setmodel( "com_computer_keyboard" );
		}
		wait 1;
	}
}

// ---------------------------------------------------------------------------------------------
// elevator: do not leave a squadmate at the bottom of the shaft
// ---------------------------------------------------------------------------------------------

lfb_elevator_pull()
{
	lfb_wait_flag_exists( "elevator_player_clip_on" );
	safe_flag_wait( "elevator_player_clip_on" );
	if ( !maps\_coop::in_coop() )
		return;
	vol = getent( "standing_in_elevator", "targetname" );
	if ( !isdefined( vol ) || level.player istouching( vol ) )
		return;
	// the trigger volume is the inside of the lift; elevator_player_clip (-1130 5668 -303) turns solid
	// right now near tunnel_animent, so aim for the volume centre instead
	pull_to( vol.origin, "Regrouping with your squad" );
}
