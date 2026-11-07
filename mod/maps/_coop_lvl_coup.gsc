// CoD4 SP Coop - coup (The Coup)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps) and the coop decision for each:
//
//  The whole level is an on-rails cinematic of the player (Al-Fulani). Player is locked down for the
//  entire level: allowcrouch/allowprone false, takeAllWeapons, EnableInvulnerability, global
//  level.playerview rig (coup.gsc:89-96).
//
//  * Intro drag + throw into the car: playerview anim "intro", playerlinkto(playerview) (execIntro,
//    coup.gsc:210-280; notetracks coup_anim.gsc:36-37).
//  * Drive: playerview linked to level.car tag_guy1, playerlinktodelta (execDrive, coup.gsc:282-364);
//    roadside scenes start from trigger_radius "flag_set" triggers along the car path (drive_* flags,
//    coup.gsc:706-1357), "passenger_event" / "loudspeaker_event" triggers (coup.gsc:1555-1608) and
//    crowd triggers (coup.gsc:1610-1648).
//  * Car exit + blackouts: playerlinktodelta / playerlinkto "carexit", coup_blackout1/2/3 shellshocks
//    and re-links (execCarExit, coup.gsc:366-521).
//  * Ending: ending_slowmo (settimescale via _cheat, coup.gsc:1683-1710), cg_fov, "ending" execution anim
//    (execEnding, coup.gsc:531-597), coup_death shellshock + nextmission from a notetrack
//    (coup_anim.gsc:401-405).
//
//  Decision: fully native per player - every machine runs its own copy of the drive in lockstep from the
//  level start (all timing is the car's vehicle path), nothing is shared:
//    - every remote puppet is hidden for the whole level: both players are Al-Fulani in the same seat
//      and rig, a puppet would only ever float inside the car;
//    - every trigger in the map is a trigger_radius on the car path; a squadmate whose drive runs a
//      little ahead must not start our roadside scenes early (or replay passenger dialog) -> all
//      trigger_radius are local;
//    - every scene flag is local: the level's own flags (coup.gsc:79-83), all _load "flag_set" trigger
//      flags (drive_*, basehelicopters_flyaway...) and the runners2_dead deathflag (coup.gsc:1143);
//    - level end is the framework's: the host's nextmission ends the level, a client that gets there
//      first waits (its own ending has already played).
//    - AI death reports are switched off for this level (no_death_reports: every AI is tagged
//      coop_remote_kill, which _coop's watch_ai_death treats as "do not report"), because every death is
//      scripted on each copy and the host's report could kill a client's AI before its own scene.
//  Not handled: the timescale of ending_slowmo is per machine.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// no puppets anywhere in this level (startFlag undefined = from now, endFlag undefined = forever)
	hide_between( undefined, undefined );

	// every trigger on the drive path reacts to our own car only
	local_trigger_class( "trigger_radius" );

	// level flags
	local_flag( "drive" );
	local_flag( "doors_open" );
	local_flag( "ending" );
	local_flag( "firingsquad_atnodes" );
	local_flag( "firingsquad_aiming" );
	local_flag( "runners2_dead" );

	// all _load flag_set trigger flags (drive_carexit, drive_doorkick1, ... read from the map itself)
	trigs = getentarray( "flag_set", "targetname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].script_flag ) )
			local_flag( trigs[ i ].script_flag );
	}

	// every death in this level is scripted per copy (the player has no weapons, coup.gsc:91-93): stop
	// the framework from reporting deaths, so the host's copy (which may be a moment ahead) never kills a
	// client's firing-squad victim / runner before its own scene does. _coop's watch_ai_death skips the
	// report for an AI that carries coop_remote_kill.
	no_death_reports();
}

no_death_reports()
{
	spawners = getspawnerarray();
	for ( i = 0; i < spawners.size; i++ )
	{
		if ( isdefined( spawners[ i ].spawn_functions ) )
			spawners[ i ] add_spawn_function( ::mark_no_death_report );
	}
	ai = getaiarray();
	for ( i = 0; i < ai.size; i++ )
		ai[ i ].coop_remote_kill = true;
}

mark_no_death_report()
{
	self.coop_remote_kill = true;
}
