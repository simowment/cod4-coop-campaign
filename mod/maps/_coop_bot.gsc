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
	// ignore every puppet: the trace would land on the bot's own body and float it
	ignore = undefined;
	for ( i = 0; i < level.coop.max; i++ )
		if ( isdefined( level.coop.puppets[ i ] ) )
		{
			ignore = level.coop.puppets[ i ];
			break;
		}
	tr = bullettrace( pos + ( 0, 0, 48 ), pos - ( 0, 0, 160 ), false, ignore );
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
	b.speed = 0;
	b.following = false;
	b.aim_p = 0;
	b.aim_y = 0;
	spacing = 100 + idx * 60;
	tick = 0;

	for ( ;; )
	{
		if ( isdefined( c.bot_demo ) )
		{
			c.bot_demo = undefined;
			bot_demo( slot, b );
			b.trail = [];
		}
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
		want = 0;
		if ( c.down )
		{
			// host is down: go straight to them and revive
			b.following = false;
			if ( d > 44 )
			{
				goal = p.origin;
				want = 250;
			}
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
			// hysteresis: start walking well outside the spacing, stop inside it (no stop-go flicker)
			if ( d > spacing + 60 )
				b.following = true;
			else if ( d < spacing )
				b.following = false;
			if ( b.following )
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
				// pace like a person: walk to close a small gap, run for a bigger one, sprint to catch up,
				// and never slower than the host is moving (speeds match the puppet's walk/run/sprint anims)
				gap = d - spacing;
				want = 100;
				if ( gap > 140 )
					want = 185;
				if ( gap > 450 )
					want = 250;
				hv = length( p getvelocity() );
				if ( hv > want )
					want = hv;
				if ( want > 260 )
					want = 260;
			}
		}

		// accelerate and brake smoothly instead of jumping between standing and running
		if ( b.speed < want )
			b.speed = min( want, b.speed + 30 );
		else
			b.speed = max( want, b.speed - 45 );

		moving = false;
		if ( b.speed > 5 )
		{
			if ( isdefined( goal ) )
			{
				dir = goal - b.origin;
				len = length( dir );
				if ( len > 1 )
					b.move_dir = vectorscale( dir, 1 / len );
				else if ( !isdefined( b.move_dir ) )
					b.move_dir = ( 0, 0, 0 );
				step = b.speed * 0.05;
				if ( len > 0 && step > len )
					step = len;
			}
			else
				step = b.speed * 0.05; // braking: coast a few units along the last heading
			if ( isdefined( b.move_dir ) )
			{
				b.origin = b.origin + vectorscale( b.move_dir, step );
				moving = true;
				if ( abs( b.move_dir[ 0 ] ) + abs( b.move_dir[ 1 ] ) > 0.01 )
				{
					ma = vectortoangles( ( b.move_dir[ 0 ], b.move_dir[ 1 ], 0 ) );
					b.move_yaw = ma[ 1 ];
				}
			}
		}
		else
			b.speed = 0;

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
			// aim error is picked once per burst: per-frame jitter would twitch the body every frame
			b.pitch = ang[ 0 ] + b.aim_p;
			b.yaw = turn_toward( b.yaw, ang[ 1 ] + b.aim_y, 30 );
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
					b.aim_p = randomfloatrange( -1.2, 1.2 );
					b.aim_y = randomfloatrange( -1.5, 1.5 );
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
				b.yaw = turn_toward( b.yaw, b.move_yaw, 20 );
			else if ( d > 60 )
			{
				fa = vectortoangles( p.origin - b.origin );
				// idle: only turn when the host has moved well off to the side
				if ( abs( maps\_coop_puppet::angle180( fa[ 1 ] - b.yaw ) ) > 35 )
					b.yaw = turn_toward( b.yaw, fa[ 1 ], 12 );
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

// turn from a toward b by at most maxStep degrees (smooth body turns; the puppet re-anchors on every turn > 2)
turn_toward( a, b, maxStep )
{
	d = maps\_coop_puppet::angle180( b - a );
	if ( d > maxStep )
		d = maxStep;
	else if ( d < 0 - maxStep )
		d = 0 - maxStep;
	return maps\_coop_puppet::angle180( a + d );
}

// ---------------------------------------------------------------------------------------------
// animation check (test cmd "botdemo"): the bot performs every puppet animation state in front of the
// host's camera, 3 s each, logging "botdemo <phase>" so screenshots can be matched to phases
// ---------------------------------------------------------------------------------------------

bot_demo( slot, b )
{
	p = level.player;
	// turn the camera to the most open direction (no wall, no character within 260 units if possible)
	eye = p geteye();
	best = 0;
	bestf = -1;
	for ( y = 0; y < 360; y += 15 )
	{
		// the bot walks up to 70 units either side, so the whole cone must be open, not just the centre line
		f = 1;
		for ( dy = -30; dy <= 30; dy += 15 )
		{
			dir = anglestoforward( ( 0, y + dy, 0 ) );
			tr = bullettrace( eye, eye + vectorscale( dir, 240 ), true, p );
			low = bullettrace( p.origin + ( 0, 0, 20 ), p.origin + ( 0, 0, 20 ) + vectorscale( dir, 240 ), true, p );
			f = min( f, min( tr[ "fraction" ], low[ "fraction" ] ) );
		}
		if ( f > bestf )
		{
			bestf = f;
			best = y;
		}
	}
	p setplayerangles( ( 10, best, 0 ) );
	maps\_coop::log( "botdemo facing " + best + " clear " + bestf );
	wait 0.1;
	a = p getplayerangles();
	fwd = anglestoforward( ( 0, a[ 1 ], 0 ) );
	right = anglestoright( ( 0, a[ 1 ], 0 ) );
	center = ground_at( p.origin + vectorscale( fwd, 170 ) );
	face = a[ 1 ] + 180; // looking at the camera
	// name, stance, flags, speed, mode (still / across = sideways facing travel / strafe = sideways facing camera / away = backing away facing camera)
	ph = [];
	ph[ ph.size ] = "stand_idle|0|0|0|still";
	ph[ ph.size ] = "stand_aim|0|4|0|still";
	ph[ ph.size ] = "stand_fire|0|12|0|still";
	ph[ ph.size ] = "walk_f|0|0|100|across";
	ph[ ph.size ] = "walk_strafe|0|0|100|strafe";
	ph[ ph.size ] = "walk_b|0|0|100|away";
	ph[ ph.size ] = "run_f|0|0|185|across";
	ph[ ph.size ] = "run_strafe|0|0|185|strafe";
	ph[ ph.size ] = "run_b|0|0|185|away";
	ph[ ph.size ] = "sprint|0|0|250|across";
	ph[ ph.size ] = "crouch_idle|1|0|0|still";
	ph[ ph.size ] = "crouch_aim|1|4|0|still";
	ph[ ph.size ] = "crouch_walk|1|0|90|across";
	ph[ ph.size ] = "prone|2|0|0|still";
	ph[ ph.size ] = "crawl|2|0|40|across";
	ph[ ph.size ] = "downed|2|16|0|still";
	for ( i = 0; i < ph.size; i++ )
	{
		t = strtok( ph[ i ], "|" );
		stance = int( t[ 1 ] );
		flags = int( t[ 2 ] );
		speed = int( t[ 3 ] );
		mode = t[ 4 ];
		maps\_coop::log( "botdemo " + t[ 0 ] );
		off = -70;
		dirsign = 1;
		if ( mode == "away" )
			off = 0;
		for ( k = 0; k < 60; k++ )
		{
			yaw = face;
			if ( mode == "across" || mode == "strafe" )
			{
				off += dirsign * speed * 0.05;
				if ( off > 70 || off < -70 )
					dirsign = 0 - dirsign;
				pos = center + vectorscale( right, off );
				if ( mode == "across" )
				{
					ra = vectortoangles( vectorscale( right, dirsign ) );
					yaw = ra[ 1 ];
				}
			}
			else if ( mode == "away" )
			{
				off += speed * 0.05;
				if ( off > 120 )
					off = 0;
				pos = center + vectorscale( fwd, off );
			}
			else
				pos = center;
			b.origin = ground_at( pos );
			f = stance + flags;
			if ( ( flags & 8 ) != 0 && k % 3 == 0 )
				b.shots++;
			f += ( b.shots % 256 ) * 256;
			fire_yaw = yaw;
			if ( ( flags & 8 ) != 0 )
				fire_yaw = yaw + 50; // replayed shots toward the camera are suppressed; aim to the side
			bot_pose( slot, b, f, 0, fire_yaw );
			if ( k == 25 || k == 45 )
				openfile( "coop", "shot", t[ 0 ] + "_" + k ); // test mode only: the proxy saves this frame
			wait 0.05;
		}
	}
	maps\_coop::log( "botdemo done" );
}
