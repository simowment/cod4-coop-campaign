// CoD4 SP Coop - level module: bog_b ("Charlie Don't Surf" / The Bog part 2)
//
// Scripted sequences (stock raw/maps/bog_b.gsc) and the coop decision for each:
//
// 1. No player rigs, links or vehicle rides at all; start points only setorigin the local player
//    (313-314, 340-341, 389-390). Everything runs natively per machine.
// 2. Tank crush (tank_advancement_bog 1804-1850): waits for "truck_crush_tank_in_position" and
//    "truck_crush_player_in_position", the latter set by a trigger_multiple (targetname "flag_set",
//    script_flag "truck_crush_player_in_position", zone ent at 3342 295 82). The trigger hit is
//    replayed, but the name contains "player_" so the flag itself would be treated as local ->
//    shared_flag() so the crush (and the Abrams moving on along tank_path_2) starts for both.
//    The following within_fov look-at wait is local with a 10s timeout -> harmless.
// 3. Tank escort shots at buildings (tank exploder pick 720-750): istouching/within_fov on the
//    local player + random index -> each machine picks its own exploder. Cosmetic divergence only,
//    left alone.
// 4. Dumpster push (982-1010, player_passed_dumpster 2096): "start_dumpster_push" is replicated;
//    one of its triggers, "player_passed_dumpster" (flag set from trigger targetname
//    "player_passed_dumpster"), would be treated as local by name -> shared_flag().
// 5. Teams split up / door blocker / spotter (teamsSplitUp 1201, lastSequence 1240-1310): gated on
//    trigger hits and AI-reached-goal flags -> replicated already.
// 6. T72 MG kill volume (t72_kill_player_trigger 1314-1345): waits for "trigger" with
//    ent == level.player and then shoots the local player dead. A replayed hit is delivered as
//    notify( "trigger", level.player ), which would kill the *other* player too ->
//    local_trigger( "t72_kill_player_trigger" ).
// 7. level.player.ignoreme toggles (292-294, 1585, 1279) and playRadioSound on level.player are
//    per-player -> native, nothing to do.
// 9. fog_adjust (258-273): trigger_multiple "fog_in" / "fog_out" change the fog for the local
//    player's position -> local_trigger() so a squadmate's hit does not change our fog.
// 8. End: seaknight() 1968-2012 waits on trigger "player_in_seaknight" (replicated) and
//    "seaknight_dialog_done", then nextmission() -> level end is host-driven by the framework.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	shared_flag( "truck_crush_player_in_position" );
	shared_flag( "player_passed_dumpster" );

	local_trigger( "t72_kill_player_trigger" );

	// fog_adjust (bog_b.gsc:258-273): setExpFog on fog_in / fog_out hits is the local player's view
	local_trigger( "fog_in" );
	local_trigger( "fog_out" );
}
