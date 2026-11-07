// CoD4 SP Coop - level module: village_defend ("Ultimatum")
//
// Scripted sequences and the coop decision for each (stock refs: raw/maps/village_defend*.gsc):
//
//  * Intro / southern hill (village_defend.gsc:846-1240): driven by replicated flags and triggers
//    (hill_patrol_trig -> objective_player_on_ridgeline 886-892, hill_patrol_shotdetector 1556-1572).
//    objective_player_at_vantage_point is a per-player distance check (894-918) and stays local; the
//    hill intro has its own timeout (1223-1228). The church tower death volume (875-883) and the
//    ridgeline mortar danger area (1765-1782) are info_volume istouching checks on level.player: native.
//  * Minigun (village_defend.gsc:2195-2245, village_defend_code.gsc:8-40, 433-700): each sim has its
//    own minigun; player_on_minigun (local by name) and disable_overheat toggle per sim -> LOCAL.
//    objective_player_uses_minigun ends the southern hill attack and the objective loop (1650, 1843,
//    2034) -> shared_flag so the squad progresses when either player mans it. The minigun user is not
//    moving, so the framework's linked heuristic already hides his puppet.
//  * Detonators / clackers (2620-2840): "detonator_usetrig" trigger_use. clacker_enable needs
//    level.player istouching the use volume; on a replay the local player is not there and
//    clacker_notouch -> clacker_disable runs takeweapon("c4") on him (2760-2840) -> LOCAL triggers.
//    The per-trigger availability flags (script_flag_true clacker_*_available, set/cleared 2694/2779)
//    and got_the_clacker (2763/2791/2828) toggle per sim -> LOCAL. The *_exploded story flags replicate.
//    Reviewer (soft-lock): each sim counts its own clackers (level.objectiveClackers, 2643) and only
//    the sim whose count reaches 0 sets fall_back_to_barn / barn_assault_begins and starts
//    tavern_storming_delay (2938-2947); nothing else sets them outside start points (615-731). With
//    per-player clackers, players who split the four detonators never reach 0 in either sim and the
//    level stalls. clacker_remote_sync(): when a *_exploded flag arrives for a detonator that is still
//    armed in this sim, consume it here exactly like clacker_fire (2853-2947): drop it from the
//    player's hands if he holds it, play the killzone fx, kill this sim's axis AI in the killzone
//    (no attacker, so they are not reported as our kills; the remote sim reports its own), delete the
//    use trigger / volume / objective marker, refresh objective 5 and count down.
//  * Tanks: "tank_killzone_east/west" triggers make the tank aim at level.player (3090-3133) -> LOCAL
//    triggers, so a tank only fires at the player that actually stands in its killzone.
//  * Javelin (3051-3062): a weapon entity, picked up per player. Native.
//  * Airstrikes (3375-3435, 5040-5210): per player (level.airStriker = level.player);
//    airstrike_in_progress toggles per sim -> LOCAL.
//  * Extraction (3268-3290, 3640-3935, village_defend_code.gsc:760-880): objective_get_to_lz and
//    lz_reached replicate, so the stopwatch starts together. Boarding is a per-player distance poll to
//    tag_door_rear (3895-3909) -> player_made_it (local by name), then rescue_ride links the player to a
//    rig at the same seaknight tag -> puppets hidden from player_made_it on.
//    The departure chain (seaknight_guards_boarding -> all_fake_friendlies_aboard -> grace ->
//    seaknight_unboardable -> outtahere, code 795-877) is driven by the *local* player_made_it; if it
//    replicated, the first player to board would take off the partner's seaknight ~17 s later and fail
//    him (countdown_events 3820-3840) -> those flags are LOCAL, each player keeps his own stock timer.
//    Level end: outtahere -> nextmission (3923-3932) on the host; clients are held by the framework.

#include maps\_utility;
#include common_scripts\utility;
#include maps\_coop_levels;

main()
{
	// progression: either player on the minigun stops the southern hill attack in both sims
	shared_flag( "objective_player_uses_minigun" );

	// per-sim toggles
	local_flag( "disable_overheat" );
	local_flag( "got_the_clacker" );
	local_flag( "clacker_nearslope_available" );
	local_flag( "clacker_farslope_available" );
	local_flag( "clacker_crashsite_available" );
	local_flag( "clacker_cliffside_available" );
	local_flag( "airstrike_in_progress" );

	// seaknight departure follows this sim's own player
	local_flag( "seaknight_guards_boarding" );
	local_flag( "all_real_friendlies_on_board" );
	local_flag( "all_fake_friendlies_aboard" );
	local_flag( "seaknight_unboardable" );
	local_flag( "outtahere" );

	// triggers that must only react to the local player
	local_trigger( "detonator_usetrig" );
	local_trigger( "tank_killzone_east" );
	local_trigger( "tank_killzone_west" );

	level thread delayed_setup();
	level thread clacker_remote_sync();
}

// village_defend flag_init()s its flags after _load::main (village_defend.gsc:148-236), i.e. after our
// postinit call; wait for the rest of this frame before any flag_wait
delayed_setup()
{
	waittillframeend;
	// both players ride the seaknight on rigs at the same tag
	if ( isdefined( level.flag[ "player_made_it" ] ) )
		hide_between( "player_made_it", undefined );
}

// ---------------------------------------------------------------------------------------------
// detonators used on the other machine (see header)
// ---------------------------------------------------------------------------------------------

clacker_remote_sync()
{
	waittillframeend; // flags are inited after _load::main
	trigs = getentarray( "detonator_usetrig", "targetname" );
	for ( i = 0; i < trigs.size; i++ )
	{
		trig = trigs[ i ];
		if ( !isdefined( trig.target ) )
			continue;
		dets = getentarray( trig.target, "targetname" );
		for ( j = 0; j < dets.size; j++ )
		{
			det = dets[ j ];
			if ( !isdefined( det.script_namenumber ) || det.script_namenumber != "objective_clacker" )
				continue;
			if ( !isdefined( det.script_noteworthy ) )
				continue;
			f = clacker_exploded_flag( det.script_noteworthy );
			if ( !isdefined( f ) || !isdefined( level.flag[ f ] ) )
				continue;
			det thread clacker_remote_use( trig, f );
		}
	}
}

// clacker_fire, village_defend.gsc:2865-2879
clacker_exploded_flag( noteworthy )
{
	if ( noteworthy == "detonator_nearslope" )
		return "nearslope_exploded";
	if ( noteworthy == "detonator_farslope" )
		return "farslope_exploded";
	if ( noteworthy == "detonator_crashsite" )
		return "crashsite_exploded";
	if ( noteworthy == "detonator_cliffside" )
		return "cliffside_exploded";
	return undefined;
}

clacker_remote_use( trig, f )
{
	self endon( "death" );
	flag_wait( f );
	waittillframeend; // a local clacker_fire deletes its trigger in the frame it sets the flag
	if ( !isdefined( trig ) || !isdefined( self ) )
		return; // used on this machine
	if ( !isdefined( level.objectiveClackers ) )
		return;
	maps\_coop::log( "village_defend: remote detonation " + f );

	useVolume = getent( self.script_noteworthy, "targetname" );
	if ( isdefined( useVolume ) && flag( "got_the_clacker" ) && level.player istouching( useVolume ) )
	{
		// we are holding this very detonator: put it away like clacker_disable (2826-2850)
		level notify( "detclacker_disarm" );
		flag_clear( "got_the_clacker" );
		level.player takeweapon( "c4" );
		prim = level.player getweaponslistprimaries();
		if ( prim.size )
			level.player switchtoweapon( prim[ 0 ] );
	}
	self hide();

	markers = [];
	if ( isdefined( self.target ) )
	{
		m = getent( self.target, "targetname" );
		while ( isdefined( m ) && markers.size < 64 )
		{
			markers[ markers.size ] = m;
			if ( !isdefined( m.target ) )
				break;
			m = getent( m.target, "targetname" );
		}
	}
	level thread clacker_remote_killzone( markers );

	// objective marker of this trigger (clacker_fire 2891-2903)
	used = undefined;
	targs = getentarray( trig.target, "targetname" );
	for ( i = 0; i < targs.size; i++ )
	{
		if ( isdefined( targs[ i ].script_noteworthy ) && targs[ i ].script_noteworthy == "clacker_objective_marker" )
			used = targs[ i ];
	}

	if ( isdefined( useVolume ) )
		useVolume delete();
	trig delete();
	if ( isdefined( used ) )
		used delete();

	// reprint objective 5 with the remaining detonators (clacker_fire 2905-2932), only while this sim's
	// objectives() thread has it up (added at 3508 after objective_detonators, done at 3524)
	if ( flag( "objective_detonators" ) && !flag( "objective_armor_arrival" ) )
	{
		objective_delete( 5 );
		objective_add( 5, "active", &"VILLAGE_DEFEND_USE_THE_DETONATORS_IN1" );
		objective_current( 5 );
		left = getentarray( "clacker_objective_marker", "script_noteworthy" );
		for ( i = 0; i < left.size; i++ )
		{
			if ( isdefined( left[ i ] ) )
				objective_additionalposition( 5, i, left[ i ].origin );
		}
	}

	level.objectiveClackers--;
	if ( level.objectiveClackers > 0 )
		return;
	if ( !flag( "fall_back_to_barn" ) )
		flag_set( "fall_back_to_barn" );
	if ( isdefined( level.flag[ "barn_assault_begins" ] ) && !flag( "barn_assault_begins" ) )
		flag_set( "barn_assault_begins" ); // inited by _load from the barn_helidrop script_flag_true
	autosave_by_name( "clackers_all_used_up" );
	if ( isdefined( level.coop_fn_tavern_storming_delay ) )
		level thread [[ level.coop_fn_tavern_storming_delay ]]();
}

// killzone_detonation (4072-4099) without radiusdamage, so the local player standing in the partner's
// killzone is not hurt by a blast that never hit him on the partner's machine
clacker_remote_killzone( squibs )
{
	n = 0;
	for ( i = 0; i < squibs.size; i++ )
	{
		squib = squibs[ i ];
		if ( !isdefined( squib ) )
			continue;
		if ( isdefined( level.killZoneFxProgram ) && level.killZoneFxProgram.size )
		{
			if ( n >= level.killZoneFxProgram.size )
				n = 0;
			if ( isdefined( level.killZoneFxProgram[ n ] ) )
				playfx( level.killZoneFxProgram[ n ], squib.origin );
		}
		if ( isdefined( level.killZoneSfx ) && isdefined( level.killZoneSfx[ n ] ) )
			squib playsound( level.killZoneSfx[ n ] );
		ai = getaiarray( "axis" );
		for ( k = 0; k < ai.size; k++ )
		{
			if ( isalive( ai[ k ] ) && distance( ai[ k ].origin, squib.origin ) < 240 )
				ai[ k ] dodamage( ai[ k ].health + 100500, squib.origin );
		}
		n++;
		wait randomfloatrange( 0.05, 0.15 );
	}
}
