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
	// preferred: a real campaign soldier, driven by the game's own AI (pathing, cover, anims, combat)
	if ( !isdefined( c.bot_ai ) )
		c.bot_ai = [];
	for ( ; getdvar( "coop_bot_puppet" ) != "1"; ) // tests: force the scripted puppet bot
	{
		guy = spawn_real_bot( slot, idx );
		if ( !isdefined( guy ) )
			break;
		bot_ai_think( slot, idx, guy ); // returns if the level removed it: spawn a new one
		if ( isdefined( c.bot_ai_frozen ) )
			break; // this level's scripts hold its AI still (e.g. killhouse): use the scripted bot
		wait 2;
	}
	// fallback (no friendly spawner in this level): the scripted puppet bot below
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
		if ( isdefined( c.bot_place ) )
		{
			b.origin = c.bot_place;
			c.bot_place = undefined;
			b.trail = [];
			b.speed = 0;
		}
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
				// only the anims' natural speeds (walk / run / sprint), so the body's root motion matches
				sp = level.coop.anim_speed;
				gap = d - spacing;
				hv = length( p getvelocity() );
				want = sp[ "walk_f" ];
				if ( gap > 140 || hv > sp[ "walk_f" ] * 1.15 )
					want = sp[ "run_f" ];
				if ( gap > 450 || hv > sp[ "run_f" ] * 1.15 )
					want = sp[ "sprint" ];
				if ( p getstance() == "crouch" )
					want = sp[ "crouch_f" ];
				else if ( p getstance() == "prone" )
					want = sp[ "crawl" ];
			}
		}

		// accelerate and brake smoothly instead of jumping between standing and running
		// reach the gait speed within ~0.15 s: in-between speeds would not match any anim's own motion
		if ( b.speed < want )
			b.speed = min( want, b.speed + 80 );
		else
			b.speed = max( want, b.speed - 90 );

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
		vel = ( 0, 0, 0 );
		if ( moving && isdefined( b.move_dir ) )
			vel = vectorscale( b.move_dir, b.speed );
		flags += bot_gait( vel, b.yaw );
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
	maps\_coop::log( "bot " + slot + " at " + b.origin + " axis " + axis.size + " nearest " + int( near ) + " visible " + seen + " shots " + b.shots + " reanchors " + level.coop.reanchors );
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
	ph[ ph.size ] = "turn_idle|0|0|0|turn";
	ph[ ph.size ] = "walk_circle|0|0|walk_f|circle";
	ph[ ph.size ] = "run_circle|0|0|run_f|circle";
	ph[ ph.size ] = "stand_idle|0|0|0|still";
	ph[ ph.size ] = "stand_aim|0|4|0|still";
	ph[ ph.size ] = "stand_fire|0|12|0|still";
	ph[ ph.size ] = "walk_f|0|0|walk_f|across";
	ph[ ph.size ] = "walk_strafe|0|0|walk_l|strafe";
	ph[ ph.size ] = "walk_b|0|0|walk_b|away";
	ph[ ph.size ] = "run_f|0|0|run_f|across";
	ph[ ph.size ] = "run_strafe|0|0|run_l|strafe";
	ph[ ph.size ] = "run_b|0|0|run_b|away";
	ph[ ph.size ] = "sprint|0|0|sprint|across";
	ph[ ph.size ] = "crouch_idle|1|0|0|still";
	ph[ ph.size ] = "crouch_aim|1|4|0|still";
	ph[ ph.size ] = "crouch_walk|1|0|crouch_f|across";
	ph[ ph.size ] = "prone|2|0|0|still";
	ph[ ph.size ] = "crawl|2|0|crawl|across";
	ph[ ph.size ] = "downed|2|16|0|still";
	for ( i = 0; i < ph.size; i++ )
	{
		t = strtok( ph[ i ], "|" );
		stance = int( t[ 1 ] );
		flags = int( t[ 2 ] );
		speed = 0;
		if ( t[ 3 ] != "0" )
			speed = level.coop.anim_speed[ t[ 3 ] ];
		r0 = level.coop.reanchors;
		steps = [];
		pup = level.coop.puppets[ slot ];
		last = undefined;
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
			else if ( mode == "turn" )
			{
				pos = center;
				yaw = face + k * 6; // 120 deg/s, on the spot
			}
			else if ( mode == "circle" )
			{
				// circle of radius 60 around the centre, facing the way it walks
				ang = k * speed * 0.05 / 60 * 57.3;
				pos = center + ( cos( ang ) * 60, sin( ang ) * 60, 0 );
				yaw = ang + 90;
			}
			else
				pos = center;
			prev = b.origin;
			b.origin = ground_at( pos );
			f = stance + flags;
			if ( k > 0 )
				f += bot_gait( vectorscale( b.origin - prev, 20 ), yaw );
			else
				f += 65536;
			if ( ( flags & 8 ) != 0 && k % 3 == 0 )
				b.shots++;
			f += ( b.shots % 256 ) * 256;
			fire_yaw = yaw;
			if ( ( flags & 8 ) != 0 )
				fire_yaw = yaw + 50; // replayed shots toward the camera are suppressed; aim to the side
			bot_pose( slot, b, f, 0, fire_yaw );
			if ( isdefined( pup ) )
			{
				body = pup gettagorigin( "j_mainroot" ); // where the skeleton is actually drawn
				if ( isdefined( last ) && k > 10 )
					steps[ steps.size ] = distance( ( body[ 0 ], body[ 1 ], 0 ), ( last[ 0 ], last[ 1 ], 0 ) );
				last = body;
			}
			if ( k == 25 || k == 45 || ( ( mode == "turn" || mode == "circle" ) && k >= 20 && k < 32 ) )
				openfile( "coop", "shot", t[ 0 ] + "_" + ( 100 + k ) ); // test mode only: the proxy saves this frame
			wait 0.05;
		}
		step_stats( t[ 0 ], steps, level.coop.reanchors - r0 );
	}
	maps\_coop::log( "botdemo done" );
}

// per-frame body movement of the puppet: smooth motion = steps all close to speed * 0.05
step_stats( name, steps, reanchors )
{
	if ( steps.size == 0 )
		return;
	sum = 0;
	mx = 0;
	mn = 9999;
	for ( i = 0; i < steps.size; i++ )
	{
		sum += steps[ i ];
		mx = max( mx, steps[ i ] );
		mn = min( mn, steps[ i ] );
	}
	avg = sum / steps.size;
	dev = 0;
	for ( i = 0; i < steps.size; i++ )
		dev += abs( steps[ i ] - avg );
	dev = dev / steps.size;
	maps\_coop::log( "botstats " + name + " step avg " + avg + " min " + mn + " max " + mx + " meandev " + dev + " reanchors " + reanchors );
}

// the bot moves at exactly the anims' own speeds (walk 90 / run 181 / sprint 198 in this game), which sit
// below the human thresholds in gait_bits, so classify by which gait speed it is using
bot_gait( vel, yaw )
{
	v = length( ( vel[ 0 ], vel[ 1 ], 0 ) );
	sp = level.coop.anim_speed;
	if ( v < 15 )
		return 65536;
	g = 1;
	if ( v > ( sp[ "walk_f" ] + sp[ "run_f" ] ) * 0.5 )
		g = 2;
	if ( v > ( sp[ "run_f" ] + sp[ "sprint" ] ) * 0.5 )
		g = 3;
	va = vectortoangles( ( vel[ 0 ], vel[ 1 ], 0 ) );
	rel = maps\_coop_puppet::angle180( va[ 1 ] - yaw );
	dir = 0;
	if ( rel > 135 || rel < -135 )
		dir = 1;
	else if ( rel > 45 )
		dir = 2;
	else if ( rel < -45 )
		dir = 3;
	if ( g == 3 && dir != 0 )
		g = 2;
	return ( 1 + g * 4 + dir ) * 65536;
}

// ---------------------------------------------------------------------------------------------
// follow test (test cmd "botfollow"): the host glides backwards in a straight line facing the bot,
// at walk, run and sprint speed, then stops; the real bot brain chases. Logs per-segment smoothness
// ("botstats follow_<seg>") and takes timed screenshots. Test mode only (moves the player by script).
// ---------------------------------------------------------------------------------------------

follow_test( slot )
{
	c = level.coop;
	p = level.player;
	best = 0;
	bestd = -1;
	for ( y = 0; y < 360; y += 15 )
	{
		dir = anglestoforward( ( 0, y, 0 ) );
		d = 1000;
		for ( dy = -10; dy <= 10; dy += 10 )
		{
			tr = bullettrace( p.origin + ( 0, 0, 30 ), p.origin + ( 0, 0, 30 ) + vectorscale( anglestoforward( ( 0, y + dy, 0 ) ), 1000 ), true, p );
			d = min( d, tr[ "fraction" ] * 1000 );
		}
		if ( d > bestd )
		{
			bestd = d;
			best = y;
		}
	}
	dir = anglestoforward( ( 0, best, 0 ) );
	look = ( 8, best + 180, 0 );
	maps\_coop::log( "botfollow dir " + best + " room " + int( bestd ) );
	p setplayerangles( look );
	c.bot_place = ground_at( p.origin - vectorscale( dir, 110 ) );
	if ( isdefined( c.bot_ai ) && isdefined( c.bot_ai[ slot ] ) )
		c.bot_ai[ slot ] teleport( c.bot_place, ( 0, best, 0 ) );
	wait 1;
	segs = [];
	segs[ segs.size ] = "walk|90|50";
	segs[ segs.size ] = "run|185|40";
	segs[ segs.size ] = "sprint|230|30";
	segs[ segs.size ] = "stop|0|40";
	room = bestd - 60;
	moved = 0;
	for ( i = 0; i < segs.size; i++ )
	{
		t = strtok( segs[ i ], "|" );
		speed = int( t[ 1 ] );
		frames = int( t[ 2 ] ); // server frames (20 per second)
		steps = [];
		r0 = c.reanchors;
		last = undefined;
		maps\_coop::log( "botfollow " + t[ 0 ] );
		for ( k = 0; k < frames; k++ )
		{
			if ( moved + speed * 0.05 < room )
			{
				moved += speed * 0.05;
				p setorigin( ground_at( p.origin + vectorscale( dir, speed * 0.05 ) ) );
			}
			p setplayerangles( look );
			pup = c.puppets[ slot ];
			if ( isdefined( c.bot_ai ) && isdefined( c.bot_ai[ slot ] ) )
				pup = c.bot_ai[ slot ];
			if ( isdefined( pup ) )
			{
				body = pup gettagorigin( "j_mainroot" ); // where the skeleton is actually drawn
				if ( k % 2 == 0 && isdefined( pup.coop_pos ) )
					maps\_coop::log( "drawn " + t[ 0 ] + " k " + k + " gap " + int( distance( ( body[ 0 ], body[ 1 ], 0 ), ( pup.coop_pos[ 0 ], pup.coop_pos[ 1 ], 0 ) ) ) + " anim " + pup.coop_anim );
				if ( isdefined( last ) && k > 5 )
					steps[ steps.size ] = distance( ( body[ 0 ], body[ 1 ], 0 ), ( last[ 0 ], last[ 1 ], 0 ) );
				last = body;
			}
			if ( ( t[ 0 ] == "walk" && k >= 30 && k < 42 ) || ( t[ 0 ] == "run" && k >= 8 && k < 20 ) )
				openfile( "coop", "shot", "seq_" + t[ 0 ] + "_" + ( 100 + k ) );
			wait 0.05;
		}
		step_stats( "follow_" + t[ 0 ], steps, c.reanchors - r0 );
	}
	maps\_coop::log( "botfollow done" );
}

// ---------------------------------------------------------------------------------------------
// real-AI bot: borrow one of the level's friendly spawners the way the stock makerealai() does
// (move it, force-spawn, put it back), then let the game's own AI follow the host
// ---------------------------------------------------------------------------------------------

pick_spawner()
{
	list = getspawnerteamarray( "allies" );
	best = undefined;
	bestscore = -1;
	for ( i = 0; i < list.size; i++ )
	{
		sp = list[ i ];
		// prefer anonymous spawners: named ones can be waited on by the level's own scripts
		score = 1;
		if ( !isdefined( sp.targetname ) )
			score += 2;
		if ( !isdefined( sp.script_noteworthy ) )
			score += 2;
		if ( !isdefined( sp.script_friendname ) )
			score += 1;
		// a soldier with a rifle, not a pilot, civilian or scripted VIP model
		cn = tolower( sp.classname );
		if ( issubstr( cn, "pilot" ) || issubstr( cn, "civilian" ) || issubstr( cn, "vip" ) || issubstr( cn, "price" ) || issubstr( cn, "gaz" ) )
			score -= 10;
		if ( issubstr( cn, "m4" ) || issubstr( cn, "m16" ) || issubstr( cn, "ak" ) || issubstr( cn, "g3" ) || issubstr( cn, "mp5" ) || issubstr( cn, "saw" ) || issubstr( cn, "rifle" ) )
			score += 3;
		if ( score > bestscore )
		{
			best = sp;
			bestscore = score;
		}
	}
	return best;
}

spawn_real_bot( slot, idx )
{
	c = level.coop;
	wait 1; // let the level finish spawning its own squad first
	sp = pick_spawner();
	if ( !isdefined( sp ) )
	{
		maps\_coop::log( "bot " + slot + ": no friendly spawner in " + level.script + ", using the scripted bot" );
		return undefined;
	}
	p = level.player;
	// the host may still be dropping into the level: wait until they stand on something
	for ( i = 0; i < 100 && !( p isonground() ); i++ )
		wait 0.05;
	pa = p getplayerangles();
	pos = node_near( spot_behind_host( idx ), p.origin );
	org = sp.origin;
	ang = sp.angles;
	cnt = sp.count;
	sp.origin = pos;
	sp.angles = ( 0, pa[ 1 ], 0 );
	sp.count = 1;
	guy = sp stalingradspawn();
	sp.origin = org;
	sp.angles = ang;
	sp.count = cnt;
	if ( spawn_failed( guy ) )
	{
		maps\_coop::log( "bot " + slot + ": spawn failed, using the scripted bot" );
		return undefined;
	}
	guy.team = "allies";
	guy.name = c.names[ slot ];
	guy.coop_bot_slot = slot;
	guy thread magic_bullet_shield();
	guy thread disable_ai_color();
	guy.fixednode = false; // free to path anywhere, not just to cover nodes
	guy.goalradius = 160 + idx * 48;
	guy setgoalpos( p.origin ); // never setgoalentity( player ): fatal unless the player is on a friendly chain
	c.bot_ai[ slot ] = guy;
	maps\_coop::log( "bot " + slot + ": real AI '" + guy.classname + "' from spawner at " + org );
	return guy;
}

bot_ai_think( slot, idx, guy )
{
	c = level.coop;
	p = level.player;
	b = spawnstruct();
	b.origin = guy.origin;
	last = guy.origin;
	weapon = "";
	revive_start = undefined;
	tick = 0;
	still_since = gettime();
	still_at = guy.origin;
	for ( ;; )
	{
		if ( !isdefined( guy ) || !isalive( guy ) )
		{
			c.bot_ai[ slot ] = undefined;
			return;
		}
		// frozen by the level (it never moves although the host is far): hand over to the scripted bot
		if ( distance( guy.origin, still_at ) > 16 || distance( guy.origin, p.origin ) < 400 || isdefined( c.hidden ) || maps\_coop::player_linked() )
		{
			still_at = guy.origin;
			still_since = gettime();
		}
		else if ( gettime() - still_since > 5000 )
		{
			maps\_coop::log( "bot " + slot + ": real AI does not move in " + level.script + ", using the scripted bot" );
			c.bot_ai_frozen = true;
			c.bot_ai[ slot ] = undefined;
			guy stop_magic_bullet_shield();
			guy delete();
			return;
		}
		tick++;
		now = gettime();
		if ( tick % 20 == 1 && isdefined( guy.weapon ) && ( guy.weapon != weapon || tick % 100 == 1 ) )
		{
			weapon = guy.weapon;
			bot_send( slot, "W|" + weapon );
		}
		linked = isdefined( c.hidden ) || maps\_coop::player_linked();
		d = distance( guy.origin, p.origin );
		// left behind (host teleported or rode away): rejoin once the host is on foot again
		if ( !linked && d > 1500 )
			guy teleport( spot_behind_host( idx ), ( 0, guy.angles[ 1 ], 0 ) );
		// host down: go to them and revive, like a medic; then follow again
		if ( c.down )
		{
			guy.goalradius = 40;
			guy setgoalpos( p.origin );
			if ( d < 80 )
			{
				if ( !isdefined( revive_start ) )
					revive_start = now;
				if ( now - revive_start > 3000 )
				{
					bot_send( slot, "V|" + c.slot );
					revive_start = undefined;
				}
			}
		}
		else
		{
			if ( isdefined( revive_start ) || guy.goalradius == 40 )
			{
				revive_start = undefined;
				guy.goalradius = 160 + idx * 48;
			}
			// the level's spawn logic sets a huge goal radius (= "already there, stand still"): keep ours
		if ( !c.down && guy.goalradius != 160 + idx * 48 )
			guy.goalradius = 160 + idx * 48;
		// follow: re-target where the host is when they have moved off (the stock friendly follow does the same)
			if ( tick % 4 == 0 && ( !isdefined( guy.coop_goal ) || distance( guy.coop_goal, p.origin ) > 64 ) )
			{
				guy.coop_goal = p.origin;
				guy setgoalpos( p.origin );
			}
		}
		if ( tick % 20 == 0 && getdvar( "coop_debug" ) == "1" )
			maps\_coop::log( "botai " + slot + " at " + guy.origin + " host " + p.origin + " d " + int( d ) + " goalradius " + guy.goalradius + " fixednode " + guy.fixednode + " ignoreall " + guy.ignoreall + " pose " + guy.a.pose + " move " + guy.a.movement );
		// pose for remote friends (the host sees the real AI; the bot slot's puppet stays hidden here)
		vel = vectorscale( guy.origin - last, 20 );
		last = guy.origin;
		b.origin = guy.origin;
		stance = 0;
		if ( isdefined( guy.a ) && isdefined( guy.a.pose ) )
		{
			if ( guy.a.pose == "crouch" )
				stance = 1;
			else if ( guy.a.pose == "prone" )
				stance = 2;
		}
		flags = stance;
		if ( linked )
			flags += 32;
		flags += maps\_coop_puppet::gait_bits( vel, guy.angles[ 1 ] );
		bot_pose( slot, b, flags, 0, guy.angles[ 1 ] );
		wait 0.05;
	}
}

// the closest pathfinding node to want (AI must stand on the navigation graph), within reach of the host
node_near( want, host )
{
	nodes = getallnodes();
	best = undefined;
	bestd = 999999;
	for ( i = 0; i < nodes.size; i++ )
	{
		o = nodes[ i ].origin;
		if ( abs( o[ 2 ] - host[ 2 ] ) > 80 )
			continue;
		d = distancesquared( o, want );
		if ( d < bestd && distancesquared( o, host ) > 48 * 48 )
		{
			best = o;
			bestd = d;
		}
	}
	if ( !isdefined( best ) || bestd > 600 * 600 )
		return want;
	return best;
}
