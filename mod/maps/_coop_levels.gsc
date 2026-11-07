// CoD4 SP Coop - per-level layer: which flags stay local, when to hide puppets, how to pull a
// lagging player into a cinematic their squadmate started, and host-coordinated sync points.
//
// Cinematics need no special networking: each player runs the scene natively on their own
// level.player. What has to be handled per level is *starting* them together. Most scenes start from
// flags or trigger hits, which are replicated, so the second player's copy of the scene starts within
// a frame. Scenes that wait on "level.player istouching(volume)" or a distance check are not
// replicated - those get a pull_on_flag() or sync_point() in the level module.

#include maps\_utility;
#include common_scripts\utility;

// ---------------------------------------------------------------------------------------------
// local-only flags (never replicated)
// ---------------------------------------------------------------------------------------------

init_local_flags()
{
	local_flag( "missionfailed" );
	local_flag( "game_saving" );
	local_flag( "can_save" );
	local_flag( "global_hint_in_use" );
	local_flag( "auto_adjust_initialized" );
	local_flag( "_radiation_poisoning" );
	local_flag( "introscreen_complete" );
	local_flag( "arcademode_complete" );
	local_flag( "arcademode_ending_complete" );
	local_flag( "disable_autosaves" );
}

local_flag( name )
{
	level.coop.local_flags[ name ] = true;
}

is_local_flag( msg )
{
	if ( isdefined( level.coop.local_flags[ msg ] ) )
		return true;
	// conventions used across the campaign scripts for flags about "the" player's own state
	if ( issubstr( msg, "player_" ) && !( isdefined( level.coop.shared_flags ) && isdefined( level.coop.shared_flags[ msg ] ) ) )
		return true;
	if ( getsubstr( msg, 0, 3 ) == "aa_" )
		return true;
	return false;
}

// triggers that must only ever react to the local player (kill/fall volumes, per-player hints,
// "you left the mission area" warnings...). key defaults to "targetname".
local_trigger( value, key )
{
	if ( !isdefined( key ) )
		key = "targetname";
	ents = getentarray( value, key );
	for ( i = 0; i < ents.size; i++ )
		ents[ i ].coop_local = true;
	return ents.size;
}

// every trigger of a classname (e.g. "trigger_hurt" is never replicated anyway)
local_trigger_class( classname )
{
	ents = getentarray( classname, "classname" );
	for ( i = 0; i < ents.size; i++ )
		ents[ i ].coop_local = true;
}

shared_flag( name )
{
	level.coop.shared_flags[ name ] = true;
}

// ---------------------------------------------------------------------------------------------
// level dispatch
// ---------------------------------------------------------------------------------------------

levels_main()
{
	c = level.coop;
	if ( !isdefined( c.shared_flags ) )
		c.shared_flags = [];
	c.hide_count = 0;
	c.sync = [];
	// the level's own main() exported its module (tools/patches.py LEVEL_PATCHES)
	if ( isdefined( level.coop_fn_level_main ) )
		[[ level.coop_fn_level_main ]]();
}

// ---------------------------------------------------------------------------------------------
// puppet visibility
// ---------------------------------------------------------------------------------------------

hide_puppets()
{
	return level.coop.hide_count > 0;
}

// hide every remote puppet from when startFlag is set until endFlag is set (or forever if undefined)
hide_between( startFlag, endFlag )
{
	level thread hide_between_proc( startFlag, endFlag );
}

hide_between_proc( startFlag, endFlag )
{
	if ( isdefined( startFlag ) )
		safe_flag_wait( startFlag );
	level.coop.hide_count++;
	if ( isdefined( endFlag ) )
	{
		safe_flag_wait( endFlag );
		level.coop.hide_count--;
	}
}

// flag_wait that tolerates a flag which is flag_init'ed later (or by another start point)
safe_flag_wait( name )
{
	while ( !isdefined( level.flag ) || !isdefined( level.flag[ name ] ) )
		wait 0.25;
	flag_wait( name );
}

hide_for( seconds )
{
	level.coop.hide_count++;
	wait seconds;
	level.coop.hide_count--;
}

// ---------------------------------------------------------------------------------------------
// pulling stragglers into scenes
// ---------------------------------------------------------------------------------------------

// When flag is set (by either player), anyone farther than radius from target is moved next to it.
// target: an entity, a struct with .origin, or a targetname string.
pull_on_flag( flagName, target, radius )
{
	level thread pull_on_flag_proc( flagName, target, radius );
}

pull_on_flag_proc( flagName, target, radius )
{
	safe_flag_wait( flagName );
	if ( !maps\_coop::in_coop() )
		return;
	pos = target_pos( target );
	if ( !isdefined( pos ) )
		return;
	if ( distance( level.player.origin, pos ) <= radius )
		return;
	pull_to( pos, "Regrouping with your squad" );
}

// When flag is set, a player who is far away is moved next to the closest squadmate.
pull_to_buddy_on_flag( flagName, radius )
{
	level thread pull_to_buddy_proc( flagName, radius );
}

pull_to_buddy_proc( flagName, radius )
{
	safe_flag_wait( flagName );
	if ( !maps\_coop::in_coop() )
		return;
	c = level.coop;
	best = undefined;
	bestd = 999999;
	for ( s = 0; s < c.slot; s++ ) // lower slots (the host first) are the anchors
	{
		if ( !maps\_coop_player::buddy_pose_ok( s ) )
			continue;
		pos = ( fgetarg( s, 0 ), fgetarg( s, 1 ), fgetarg( s, 2 ) );
		d = distance( level.player.origin, pos );
		if ( d < bestd )
		{
			bestd = d;
			best = pos;
		}
	}
	if ( isdefined( best ) && bestd > radius )
		pull_to( best, "Regrouping with your squad" );
}

pull_to( pos, msg )
{
	if ( maps\_coop::player_linked() )
		return; // a scene already owns this player
	level.player setorigin( maps\_coop_player::safe_spot_near( pos ) );
	if ( isdefined( msg ) )
		iprintln( msg );
	maps\_coop::log( "pulled to " + pos );
}

target_pos( target )
{
	if ( !isdefined( target ) )
		return undefined;
	if ( isstring_ent_name( target ) )
	{
		e = getent( target, "targetname" );
		if ( isdefined( e ) )
			return e.origin;
		s = getstruct( target, "targetname" );
		if ( isdefined( s ) )
			return s.origin;
		return undefined;
	}
	return target.origin;
}

isstring_ent_name( t )
{
	return isstring( t );
}

// ---------------------------------------------------------------------------------------------
// sync points: every connected player waits here until all have arrived (or timeout); the host
// then releases everyone in the same instant. For level modules that own their own scene logic.
//   Q|name|here   -> "I reached it"     (anyone)
//   Q|name|go     -> "everyone go"      (host)
// ---------------------------------------------------------------------------------------------

sync_point( name, timeout, hudtext )
{
	c = level.coop;
	if ( !maps\_coop::in_coop() )
		return;
	if ( !isdefined( c.sync[ name ] ) )
		c.sync[ name ] = spawnstruct();
	st = c.sync[ name ];
	if ( isdefined( st.go ) )
		return;
	if ( !isdefined( st.here ) )
		st.here = [];
	st.here[ c.slot ] = true;
	maps\_coop::send( "Q|" + name + "|here" );
	hud = undefined;
	if ( isdefined( hudtext ) )
	{
		hud = maps\_coop_player::make_center_text( -60, 1.4 );
		hud settext( hudtext );
	}
	if ( !isdefined( timeout ) )
		timeout = 20;
	end = gettime() + timeout * 1000;
	while ( !isdefined( st.go ) && gettime() < end )
	{
		if ( c.ishost && everyone_here( st ) )
		{
			st.go = true;
			maps\_coop::send( "Q|" + name + "|go" );
			break;
		}
		wait 0.05;
	}
	if ( c.ishost && !isdefined( st.go ) )
	{
		st.go = true;
		maps\_coop::send( "Q|" + name + "|go" );
	}
	st.go = true;
	if ( isdefined( hud ) )
		hud destroy();
}

everyone_here( st )
{
	c = level.coop;
	for ( s = 0; s < c.max; s++ )
	{
		if ( s == c.slot || !maps\_coop::slot_connected( s ) )
			continue;
		if ( !isdefined( st.here[ s ] ) )
			return false;
	}
	return true;
}

ev_scene( slot, tok )
{
	c = level.coop;
	if ( tok.size < 4 )
		return;
	name = tok[ 2 ];
	if ( !isdefined( c.sync[ name ] ) )
		c.sync[ name ] = spawnstruct();
	st = c.sync[ name ];
	if ( !isdefined( st.here ) )
		st.here = [];
	if ( tok[ 3 ] == "here" )
		st.here[ slot ] = true;
	else if ( tok[ 3 ] == "go" )
		st.go = true;
	level notify( "coop_sync_" + name );
}

// a flag-gated sync: when flagName gets set locally, hold here until the squad has also reached it
sync_on_flag( flagName, timeout, hudtext )
{
	level thread sync_on_flag_proc( flagName, timeout, hudtext );
}

sync_on_flag_proc( flagName, timeout, hudtext )
{
	safe_flag_wait( flagName );
	sync_point( "f_" + flagName, timeout, hudtext );
}
