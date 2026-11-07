// CoD4 SP Coop - level module: ac130 ("Death From Above")
//
// Scripted sequences (stock raw/maps/ac130.gsc, ac130_code.gsc, _ac130.gsc) and coop decisions:
//
// 1. The player never walks: attachPlayer (_ac130.gsc:504) links level.player to tag_player on
//    the level.ac130 rig, and rotatePlane / movePlaneToWaypoint (_ac130.gsc:479, 537) fly it.
//    Every machine runs its own gunship with its own level.player in the seat, natively. All
//    players sit at the same tag, so the remote puppets would float inside the camera -> puppets
//    hidden for the whole level (hide_between( undefined, undefined )).
// 2. Progression (ac130.gsc gameplay_chuch 102-160, gameplay_fields 163-190, gameplay_junkyard1/2
//    391-460) is timer driven plus waitForPlayerKillCount( N ) (ac130_code.gsc:409-413), which
//    polls level.enemiesKilledByPlayer. That counter is only bumped when the attacker is the
//    local level.player (enemy_killed_thread, _ac130.gsc:1246-1257). Kills replicated from a
//    squadmate arrive as an attacker-less dodamage, so each machine would only count its own
//    player's kills and the two timelines would drift apart (or one would stall).
//    -> every machine reports its own player's axis kills with a level-specific "AK" event and
//    adds the squadmate's reported kills to level.enemiesKilledByPlayer. We hook in through
//    level.LevelSpecificSpawnerCallbackThread, the slot _ac130.gsc:1200 provides for exactly this
//    (unused by ac130.gsc). Each kill is counted once: locally by stock, remotely by "AK".
// 3. Fail conditions: firing before "clear_to_engage" (failMissionForEngaging _ac130.gsc:870),
//    hitting the church (damage_church ac130_code.gsc:152), friendly vehicles / helicopters
//    killed by level.player (ac130_code.gsc:192, 353, 379) and friendly casualties
//    (mission_fail_casualties _ac130.gsc:1677) are evaluated on the shooter's own machine; the
//    framework replicates mission fail (any player fails -> all fail) and friendly AI deaths.
// 4. Flags: "clear_to_engage", "allow_context_sensative_dialog", "hijacked_vehicles_stopped",
//    "friendlies_*", "choppers_*", "mission_failed" are story flags -> replicated (default).
//    "player_changed_weapons" (_ac130.gsc:173) is per-player HUD state -> local (default, name
//    contains "player_").
// 5. End: missionEnd -> nextmission (ac130_code.gsc:80-87), host-driven by the framework.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// everyone sits in the same gunship seat
	hide_between( undefined, undefined );

	local_flag( "player_changed_weapons" );

	// shared kill credit for waitForPlayerKillCount()
	if ( isdefined( level.coop.handlers ) )
	{
		h = level.coop.handlers;
		h[ "AK" ] = ::ev_kill_credit;
		level.coop.handlers = h;
	}
	if ( !isdefined( level.LevelSpecificSpawnerCallbackThread ) )
		level.LevelSpecificSpawnerCallbackThread = ::coop_enemy_spawned;
}

// called by _ac130 spawn_callback_thread for every spawned AI
coop_enemy_spawned( guy )
{
	if ( !isdefined( guy ) || !isalive( guy ) )
		return;
	if ( !isdefined( guy.team ) || guy.team != "axis" )
		return;
	guy waittill( "death", attacker );
	if ( !isdefined( attacker ) || attacker != level.player )
		return;
	if ( !level.coop.active )
		return;
	maps\_coop::send( "AK" );
}

ev_kill_credit( slot, tok )
{
	if ( !isdefined( level.enemiesKilledByPlayer ) )
		level.enemiesKilledByPlayer = 0;
	level.enemiesKilledByPlayer++;
}
