// CoD4 SP Coop - level module: aftermath ("Aftermath", Jackson after the nuke)
//
// Scripted sequences (stock C:/Users/got/cod4-decomp/raw/maps/aftermath.gsc) and coop decision:
//
//  * Wake-up (player_wakeup, aftermath.gsc:342-389): prone, freezeControls, allowstand/crouch off,
//    setorigin( -989, 8433, 666 ) for every player, black overlay fade, "awake" flag.
//    -> native per player. Every machine teleports its own player to the SAME spot, so the non-host
//       players are spread a few units sideways one frame later (spread_wakeup) so the puppet of the
//       other dying marine lies next to you instead of inside you. "awake" is player state: local.
//  * Slow walk / limp / heartbeat / random blur / jump punishment (aftermath.gsc:302-312, 425-470,
//    474-489, 491-505): all level.player-local, nothing to do.
//  * Falls (fall(), aftermath.gsc:511-546; force_fall trigger_radius x2, setup_force_fall :493-503):
//    flag "fall" is set/cleared per player and building_collapse does flag_waitopen("fall")
//    (aftermath.gsc:242). Replicating it would make one player's stumble block the other's collapse
//    (and a client's flag_clear never reaches the host). -> local_flag("fall"), and the force_fall
//    triggers are local_trigger()'d so one player tripping does not knock the other over.
//  * Building collapse (building_collapse, aftermath.gsc:236-276): gated on trigger "raze" (shared,
//    replicated) and then a local within_fov() check of level.player (aftermath.gsc:241).
//    -> each machine plays its own collapse when its own player looks at it; "collapse" and
//       "collapse_done" are per-machine scene state (set/cleared locally, countdown_to_death :127-135
//       forces the collapse on its own copy) -> local flags.
//  * Countdown to death (countdown_to_death, aftermath.gsc:120-138): trigger "outside" (shared) or
//    50 s, +30 s, forced collapse, +15 s -> flag_set("radiation_death").
//  * Radiation death / level end (radiation_death, aftermath.gsc:174-222; flag_trigger_init on
//    trigger "death_point", :41): prone, freeze, stumble, vision sets, white/black overlay,
//    nextmission(). -> "radiation_death" stays SHARED (replicated): when the first player reaches
//    the death point or his countdown runs out, both marines die together and the host's
//    nextmission() then ends the level for everyone (clients that finish first wait for the host).
//  * Playground memory (playground(), aftermath.gsc:70-77): positional memory sound at a
//    trigger_radius -> local_trigger("playground"), only the player who walks there hears it.
//  * Ambient triggers (trigger_multiple with an "ambient" key, _ambient.gsc:323) -> local.
//  * Radio chatter, slowview shellshock loop, heartbeat: per machine, timer driven, nothing to do.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// player-state / per-copy scene flags (all flag_init'ed in aftermath.gsc:37-40)
	local_flag( "awake" );
	local_flag( "fall" );
	local_flag( "collapse" );
	local_flag( "collapse_done" );
	// "radiation_death" (aftermath.gsc:41) deliberately left shared: the squad dies together.

	// triggers that must only react to the local player
	local_trigger( "force_fall" );   // 2x trigger_radius, stumble-and-fall volumes
	local_trigger( "playground" );   // memory sound
	local_ambient_triggers();

	level thread spread_wakeup();
}

// trigger_multiple brushes with an "ambient" key drive the local sound mix only
local_ambient_triggers()
{
	trigs = getentarray( "trigger_multiple", "classname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		if ( isdefined( trigs[ i ].ambient ) )
			trigs[ i ].coop_local = true;
	}
}

// player_wakeup() puts every player at the same origin on the first frame (aftermath.gsc:357-361).
// One frame later move the non-host players a short way sideways (still frozen and prone).
spread_wakeup()
{
	if ( !level.coop.active || level.coop.ishost )
		return;
	wait 0.05;
	if ( !isdefined( level.player ) )
		return;
	n = level.coop.slot;
	if ( n < 1 )
		n = 1;
	pos = spread_spot( level.player.origin, n );
	if ( isdefined( pos ) )
	{
		level.player setorigin( pos );
		maps\_coop::log( "aftermath: wake-up spot spread to " + pos );
	}
}

spread_spot( pos, n )
{
	d = 44 * n;
	offsets = [];
	offsets[ 0 ] = ( 0, d, 0 );
	offsets[ 1 ] = ( 0, 0 - d, 0 );
	offsets[ 2 ] = ( d, 0, 0 );
	offsets[ 3 ] = ( 0 - d, 0, 0 );
	for ( i = 0; i < offsets.size; i++ )
	{
		p = pos + offsets[ i ];
		if ( !bullettracepassed( pos + ( 0, 0, 24 ), p + ( 0, 0, 24 ), false, undefined ) )
			continue;
		tr = bullettrace( p + ( 0, 0, 24 ), p - ( 0, 0, 64 ), false, undefined );
		if ( tr[ "fraction" ] < 1 )
			return tr[ "position" ];
	}
	return undefined;
}
