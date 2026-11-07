// CoD4 SP Coop - level module: airlift ("Charlie Don't Surf" Seaknight ride, cobra crash, nuke)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps/airlift.gsc) and coop decision:
//
//  * Intro flight on the Mark 19 door gun (AA_intro_init :291, seaknight_player_think :4900-4967,
//    seaknight_turret_think :5095-5107 -> seaknight_player_mount_gun :5403-5430): every machine
//    spawns its own "seaknightPlayer" and mounts its own player on tag_player. The whole flight
//    (plaza, gas station, landing) is vehicle-path driven: flight_flags_think (:5600-5622) sets the
//    seaknight* flags from path origins, so both copies run the same timeline and the union-merged
//    flags only ever arrive a frame early. -> native. Both gunners sit on the SAME tag, so puppets
//    are hidden while the local player is on the gun (level.onMark19) and 2.5 s after dismounting
//    (seaknight_player_dismount_gun :5483-5507 lerps everyone to the same tag_turret_exit).
//  * Smoketown landing / dismount (smoketown_land :1355-1410): seaknight "landed" per copy ->
//    native. Door trigger "trigger_seaknight" (trigger_radius moved onto tag_door_rear,
//    seaknight_player_triggers :5521-5535) is left SHARED: the first player out counts as "the squad
//    is out" on every copy (seaknight_player_monitor :5536-5540), which only releases colour nodes.
//  * Smoketown streets / construction / AT4 / junkyard / LZ (:1420-1660): all gated on script_flag
//    trigger_multiples ("flag_set" targetname, player_* flags). Those flags are local by naming
//    convention but the TRIGGER hits are replicated, so every copy's flag_set_trigger (_load.gsc:
//    1940-1954) sets them -> shared progression with no extra work.
//  * Boarding the Mark 19 at the smoketown LZ (smoketown_lz_advance :1615-1675):
//    waittill_trigger_seaknight() then waittill_trigger_seaknight_gun() (:4708-4721, both
//    trigger_radius). Replicated hits mount the other player as well (lerp_player_view_to_tag pulls
//    him into the seat from anywhere), which is required: AA_cobraflight_init flies off right after.
//    -> fallback lz_mount_fallback(): once "obj_get_on_mark_19_complete" arrives and the local player
//       is still not on the gun after 2 s, re-notify both triggers locally until he is (20 s cap).
//  * Cobra flight / cobra hit / landing in cobrastreets (AA_cobraflight_init :1817, cobra_crash,
//    cobra_streetfight :2531-2700): path/timer driven per copy -> native.
//  * Cobrastreets kill volumes: trig_cobrastreets_kill instakill (cobrastreets_instakill :2317-2323,
//    trigger_radius) -> local_trigger(); "cobrastreets_kill" info_volume uses level.player istouching
//    (:2300-2313) -> already local.
//  * Pilot rescue (cobrapilot_think :2783-2842): the pilot AI is a use target ("self waittill
//    trigger" on the actor, not a trigger entity, so NOT replicated). The pickup plays the
//    player_carry rig "wounded_pullout" and only then threads AA_nuke_init (:2842); the 90 s
//    rescue_timer (:4425-4447) is only killed by the per-player "player_putting_down_pilot" flag.
//    "pilot_taken_from_cockpit" itself IS replicated. -> pilot_pickup_pull(): when it arrives and the
//    local pilot is still useable, notify the local pilot "trigger" so this player also does the
//    pull-out (pulls a straggler to the crash site; every Jackson carries his own copy of the
//    pilot). Puppets hidden for the length of the rig anim (both players on the same crashnode).
//    "player_near_cobra" flag_set_touching (pilot waves while YOU are near) -> local_trigger.
//  * Putdown in the seaknight / nuke (nuke_flight :2954-3075): trig_pilot_putdown (trigger_radius)
//    is replicated, so the first player in starts every copy's "wounded_putdown" rig (each player
//    is lerped into the seaknight). -> putdown_fallback(): after "nuke_section_start" arrives, keep
//    re-notifying trig_pilot_putdown locally until the local "player_putting_down_pilot" is set (the
//    local nuke_flight only listens once the local pull-out finished). Puppets hidden from the local
//    "player_putting_down_pilot" to the end: everyone is linked to the same ePlayerview tag.
//  * Nuke, crash, blackout, nextmission (nuke :3082-3177): per copy, timer driven; host ends the
//    level (_coop.gsc on_nextmission), clients wait.
//  * mission_failed_out_of_time (:4460-4468): per copy; any fail -> all fail (framework).
//  * Ambient triggers (trigger_multiple with an "ambient" key) -> local.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-local triggers
	local_trigger( "trig_cobrastreets_kill" );   // instakill radius near the crash site
	local_trigger( "flag_set_touching" );        // only "player_near_cobra" (pilot waving at YOU)
	local_ambient_triggers();

	// puppets: shared Mark 19 seat, carry rigs, putdown + nuke ride
	level thread mark19_puppet_hide();
	level thread hide_after_flag( "player_putting_down_pilot" );

	// keep both players in the same scene
	level thread lz_mount_fallback();
	level thread pilot_pickup_pull();
	level thread putdown_fallback();
}

local_ambient_triggers()
{
	trigs = getentarray( "trigger_multiple", "classname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].ambient ) )
			trigs[ i ].coop_local = true;
	}
}

// airlift flag_init()s its flags after _load::main (airlift.gsc:146-212), i.e. after our main()
wait_flag_init( name )
{
	while ( !isdefined( level.flag ) || !isdefined( level.flag[ name ] ) )
		wait 0.05;
}

// fire a trigger on this copy only: marking it as a remote replay for this frame keeps
// _coop.gsc watch_trigger from re-broadcasting our synthetic hit to the other machines
local_notify_trigger( trig )
{
	if ( !isdefined( trig ) )
		return;
	trig.coop_remote_time = gettime();
	trig notify( "trigger", level.player );
}

hide_after_flag( name )
{
	wait_flag_init( name );
	hide_between( name, undefined );
}

// ---------------------------------------------------------------------------------------------
// Mark 19: every player sits on the same tag_player of his own seaknight
// ---------------------------------------------------------------------------------------------

mark19_puppet_hide()
{
	while ( !isdefined( level.onMark19 ) )
		wait 0.05;
	for ( ;; )
	{
		while ( !level.onMark19 )
			wait 0.2;
		level.coop.hide_count++;
		while ( level.onMark19 )
			wait 0.2;
		wait 2.5; // dismount lerps everyone to the same tag_turret_exit
		level.coop.hide_count--;
	}
}

// smoketown LZ: the squadmate already mounted the gun; make sure we follow him into the seaknight
lz_mount_fallback()
{
	wait_flag_init( "obj_get_on_mark_19_complete" );
	flag_wait( "obj_get_on_mark_19_complete" );
	if ( !maps\_coop::in_coop() )
		return;
	wait 2;
	end = gettime() + 20000;
	while ( isdefined( level.onMark19 ) && !level.onMark19 && gettime() < end )
	{
		local_notify_trigger( getent( "trigger_seaknight", "targetname" ) );
		wait 0.1;
		local_notify_trigger( getent( "trigger_seaknight_gun", "targetname" ) );
		wait 1;
	}
	if ( isdefined( level.onMark19 ) && level.onMark19 )
		maps\_coop::log( "airlift: on the mark19 with the squad" );
}

// ---------------------------------------------------------------------------------------------
// cobrastreets: pilot pull-out and putdown
// ---------------------------------------------------------------------------------------------

pilot_pickup_pull()
{
	wait_flag_init( "pilot_taken_from_cockpit" );
	flag_wait( "pilot_taken_from_cockpit" );
	if ( !isdefined( level.cobrapilot ) )
		return; // nuke start point sets the flag without a pilot (airlift.gsc:352)

	pulled = false;
	end = gettime() + 10000;
	while ( gettime() < end )
	{
		if ( !isdefined( level.cobrapilot ) || !isalive( level.cobrapilot ) )
			return;
		if ( !isdefined( level.cobrapilot.useable ) || !level.cobrapilot.useable )
			break; // our own player has picked her up (cobrapilot_think :2810)
		if ( !maps\_coop::in_coop() )
			return;
		if ( isdefined( level.flag[ "player_near_crash_site" ] ) && flag( "player_near_crash_site" ) )
		{
			if ( !isdefined( level.coop.down ) || !level.coop.down )
			{
				level.cobrapilot notify( "trigger", level.player );
				pulled = true;
			}
		}
		wait 0.5;
	}
	if ( pulled )
		maps\_coop::log( "airlift: joined the pilot pull-out" );

	// both players play the carry rig on the same crashnode
	t = 9;
	if ( isdefined( level.scr_anim[ "player_carry" ] ) && isdefined( level.scr_anim[ "player_carry" ][ "wounded_pullout" ] ) )
		t = getanimlength( level.scr_anim[ "player_carry" ][ "wounded_pullout" ] ) + 1.5;
	hide_for( t );
}

putdown_fallback()
{
	wait_flag_init( "nuke_section_start" );
	wait_flag_init( "player_putting_down_pilot" );
	flag_wait( "nuke_section_start" );
	if ( !maps\_coop::in_coop() )
		return;
	wait 1.5;
	end = gettime() + 30000;
	while ( !flag( "player_putting_down_pilot" ) && gettime() < end )
	{
		local_notify_trigger( getent( "trig_pilot_putdown", "targetname" ) );
		wait 1;
	}
}
