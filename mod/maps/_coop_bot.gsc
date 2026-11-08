// CoD4 coop: AI squadmates ("bots"), run by the host.
//
// The native proxy gives each bot a player slot with no network link (host command line: coop_bot N).
// This file is the bot's brain. It runs on the host only, picks the bot's pose and events every frame,
// and hands them to the proxy with openfile( "coop", "as", slot ) followed by fprintfields / fprintln.
// From there a bot is like any other squadmate: the host's puppet code draws it and replays its shots
// (real bullets), the squad HUD lists it, sync points don't wait for it, and real clients get its pose
// and events relayed by the host.
//
// Behaviour: follow the host along the path the host actually walked (no navmesh needed), keep some
// spacing, fight enemies it can see, revive the host when they go down, hide during rides and rigs.

#include maps\_utility;
#include common_scripts\utility;

init()
{
	c = level.coop;
	if ( !c.active || !c.ishost )
		return;
	n = 0;
	for ( s = 1; s < c.max; s++ )
	{
		if ( openfile( "coop", "isbot", s ) == 1 )
		{
			thread bot_think( s, n );
			n++;
		}
	}
	if ( n > 0 )
		maps\_coop::log( "bots: " + n );
}

is_bot( slot )
{
	return level.coop.active && level.coop.ishost && openfile( "coop", "isbot", slot ) == 1;
}

bot_send( slot, msg )
{
	openfile( "coop", "as", slot );
	fprintln( level.script + "|" + msg );
}

bot_pose( slot, b, flags, pitch, yaw )
{
	openfile( "coop", "as", slot );
	fprintfields( b.origin[ 0 ], b.origin[ 1 ], b.origin[ 2 ], pitch, yaw, flags, 100, 0 );
}

ground_at( pos )
{
	tr = bullettrace( pos + ( 0, 0, 48 ), pos - ( 0, 0, 160 ), false, undefined );
	if ( tr[ "fraction" ] < 1 )
		return tr[ "position" ];
	return pos;
}

// a spot behind the host that we can stand on
spot_behind_host( idx )
{
	p = level.player;
	a = p getplayerangles();
	fwd = anglestoforward( ( 0, a[ 1 ], 0 ) );
	right = anglestoright( ( 0, a[ 1 ], 0 ) );
	side = 40;
	if ( idx % 2 == 1 )
		side = -40;
	want = p.origin - vectorscale( fwd, 70 + idx * 30 ) + vectorscale( right, side );
	if ( bullettracepassed( p.origin + ( 0, 0, 40 ), want + ( 0, 0, 40 ), false, undefined ) )
		return ground_at( want );
	return maps\_coop_player::safe_spot_near( p.origin );
}

bullet_weapon( w )
{
	if ( !isdefined( w ) || w == "" || w == "none" )
		return false;
	wc = weaponclass( w );
	if ( wc != "rifle" && wc != "smg" && wc != "mg" && wc != "pistol" && wc != "spread" && wc != "sniper" )
		return false;
	return !issubstr( w, "gl_" ) && !issubstr( w, "rpg" ) && !issubstr( w, "at4" );
}

// the host's gun if it fires bullets, else one of the host's other guns
pick_weapon( current )
{
	p = level.player;
	w = p getcurrentweapon();
	if ( bullet_weapon( w ) )
		return w;
	if ( bullet_weapon( current ) )
		return current;
	list = p getweaponslistprimaries();
	for ( i = 0; i < list.size; i++ )
		if ( bullet_weapon( list[ i ] ) )
			return list[ i ];
	return current;
}

bot_eye( b )
{
	h = 60;
	if ( b.stance == 1 )
		h = 40;
	else if ( b.stance == 2 )
		h = 11;
	return b.origin + ( 0, 0, h );
}

// nearest enemy the bot can actually see
find_target( slot, b )
{
	eye = bot_eye( b );
	ignore = level.coop.puppets[ slot ];
	axis = getaiarray( "axis" );
	best = undefined;
	bestd = 2200;
	for ( i = 0; i < axis.size; i++ )
	{
		ai = axis[ i ];
		if ( !isalive( ai ) || ( isdefined( ai.ignoreme ) && ai.ignoreme ) )
			continue;
		d = distance( ai.origin, b.origin );
		if ( d >= bestd )
			continue;
		if ( !sighttracepassed( eye, ai geteye(), false, ignore ) )
			continue;
		best = ai;
		bestd = d;
	}
	return best;
}

trail_pop( b )
{
	t = [];
	for ( i = 1; i < b.trail.size; i++ )
		t[ t.size ] = b.trail[ i ];
	b.trail = t;
}

bot_think( slot, idx )
{
	level endon( "coop_stop" );
	c = level.coop;
	p = level.player;
	b = spawnstruct();
	b.origin = spot_behind_host( idx );
	b.trail = [];
	b.stance = 0;
	b.shots = 0;
	b.weapon = "";
	b.target = undefined;
	b.seen_since = 0;
	b.next_shot = 0;
	b.burst = 0;
	b.revive_start = undefined;
	pa = p getplayerangles();
	b.yaw = pa[ 1 ];
	b.pitch = 0;
	spacing = 100 + idx * 60;
	tick = 0;

	for ( ;; )
	{
		tick++;
		now = gettime();

		// weapon: announce like a player does (on change, and every few seconds)
		if ( tick % 20 == 1 )
		{
			w = pick_weapon( b.weapon );
			if ( w != b.weapon || tick % 100 == 1 )
			{
				b.weapon = w;
				if ( w != "" )
					bot_send( slot, "W|" + w );
			}
		}

		// in a ride, rig or scene: the host is not walking, so the bot rides along out of sight
		if ( isdefined( c.hidden ) || maps\_coop::player_linked() || !isalive( p ) )
		{
			b.origin = p.origin;
			b.trail = [];
			bot_pose( slot, b, 32, 0, b.yaw );
			wait 0.05;
			continue;
		}

		// breadcrumb trail: only spots the host stood on
		if ( p isonground() && ( b.trail.size == 0 || distance( b.trail[ b.trail.size - 1 ], p.origin ) > 32 ) )
		{
			b.trail[ b.trail.size ] = p.origin;
			if ( b.trail.size > 120 )
				trail_pop( b );
		}

		d = distance( b.origin, p.origin );
		if ( d > 1400 || abs( b.origin[ 2 ] - p.origin[ 2 ] ) > 300 )
		{
			// left behind (host teleported, fell, or the trail got lost): regroup
			b.origin = spot_behind_host( idx );
			b.trail = [];
			d = distance( b.origin, p.origin );
		}

		goal = undefined;
		speed = 190;
		if ( c.down )
		{
			// host is down: go straight to them and revive
			if ( d > 44 )
				goal = p.origin;
			else
			{
				if ( !isdefined( b.revive_start ) )
					b.revive_start = now;
				if ( now - b.revive_start > 3000 )
				{
					bot_send( slot, "V|" + c.slot );
					b.revive_start = undefined;
				}
			}
		}
		else
		{
			b.revive_start = undefined;
			if ( d > spacing )
			{
				while ( b.trail.size > 0 && distance( b.trail[ 0 ], b.origin ) < 24 )
					trail_pop( b );
				// shortcut: skip trail points while a later one is in clear sight
				while ( b.trail.size > 1 && distance( b.trail[ 1 ], b.origin ) < 160 && bullettracepassed( b.origin + ( 0, 0, 30 ), b.trail[ 1 ] + ( 0, 0, 30 ), false, undefined ) )
					trail_pop( b );
				if ( b.trail.size > 0 )
					goal = b.trail[ 0 ];
				else
					goal = p.origin;
				if ( d > 450 )
					speed = 280;
			}
		}

		moving = false;
		if ( isdefined( goal ) )
		{
			dir = goal - b.origin;
			len = length( dir );
			if ( len > 1 )
			{
				step = speed * 0.05;
				if ( step > len )
					step = len;
				b.origin = b.origin + vectorscale( dir, step / len );
				moving = true;
				if ( len > 8 )
				{
					ma = vectortoangles( ( dir[ 0 ], dir[ 1 ], 0 ) );
					b.move_yaw = ma[ 1 ];
				}
			}
		}

		// stance: match the host; stand to run
		st = p getstance();
		b.stance = 0;
		if ( isdefined( b.revive_start ) || st == "crouch" )
			b.stance = 1;
		else if ( st == "prone" && !moving )
			b.stance = 2;

		if ( tick % 100 == 0 && getdvar( "coop_debug" ) == "1" )
			debug_axis( slot, b );

		// combat
		if ( tick % 5 == 0 )
		{
			t = find_target( slot, b );
			if ( !isdefined( t ) || !isdefined( b.target ) || t != b.target )
				b.seen_since = now;
			b.target = t;
		}
		if ( isdefined( b.target ) && !isalive( b.target ) )
		{
			if ( getdvar( "coop_debug" ) == "1" )
				maps\_coop::log( "bot " + slot + " target down after " + b.shots + " shots" );
			b.target = undefined;
		}
		firing = false;
		if ( isdefined( b.target ) && !c.down )
		{
			ang = vectortoangles( b.target geteye() - ( 0, 0, 8 ) - bot_eye( b ) );
			b.pitch = ang[ 0 ] + randomfloatrange( -1.2, 1.2 );
			b.yaw = ang[ 1 ] + randomfloatrange( -1.5, 1.5 );
			// short reaction time, then 3-round bursts
			if ( now - b.seen_since > 450 && now >= b.next_shot && b.weapon != "" )
			{
				b.shots++;
				b.burst++;
				if ( getdvar( "coop_debug" ) == "1" && b.shots % 6 == 1 )
					maps\_coop::log( "bot " + slot + " fires at " + b.target.origin + " dist " + int( distance( b.target.origin, b.origin ) ) );
				firing = true;
				if ( b.burst >= 3 )
				{
					b.burst = 0;
					b.next_shot = now + randomintrange( 450, 900 );
				}
				else
					b.next_shot = now + 110;
			}
		}
		else
		{
			b.pitch = 0;
			if ( moving && isdefined( b.move_yaw ) )
				b.yaw = b.move_yaw;
			else if ( d > 60 )
			{
				fa = vectortoangles( p.origin - b.origin );
				b.yaw = fa[ 1 ];
			}
		}

		flags = b.stance;
		if ( isdefined( b.target ) )
			flags += 4;
		if ( firing )
			flags += 8;
		flags += ( b.shots % 256 ) * 256;
		bot_pose( slot, b, flags, b.pitch, b.yaw );
		wait 0.05;
	}
}

debug_axis( slot, b )
{
	axis = getaiarray( "axis" );
	near = 999999;
	seen = 0;
	for ( i = 0; i < axis.size; i++ )
	{
		if ( !isalive( axis[ i ] ) )
			continue;
		d = distance( axis[ i ].origin, b.origin );
		if ( d < near )
			near = d;
		if ( sighttracepassed( bot_eye( b ), axis[ i ] geteye(), false, level.coop.puppets[ slot ] ) )
			seen++;
	}
	maps\_coop::log( "bot " + slot + " at " + b.origin + " axis " + axis.size + " nearest " + int( near ) + " visible " + seen + " shots " + b.shots );
}
