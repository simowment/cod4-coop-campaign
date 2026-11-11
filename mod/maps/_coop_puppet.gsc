// CoD4 SP Coop - remote player puppets.
//
// A remote player is drawn as a fake-AI script_model (the stock drone technique) wearing a friendly
// soldier model borrowed from the level, so nothing extra has to be precached. It is driven from the
// interpolated pose the proxy gives us (fgetarg). Remote shots are replayed with magicbullet so the
// muzzle, tracer, sound and impacts are seen; real kills come through the K events in _coop.gsc.

#include maps\_utility;
#include common_scripts\utility;
#using_animtree( "generic_human" );

puppet_precache()
{
	level.coop.puppets = [];
	level.coop.remote_weapon = [];
	level.coop.known_weapons = [];
	level.coop.shot_seen = [];
	// character skins from the mod's skin pack (mod.ff, tools/skin): every skin in the pack is precached
	// (before the level's first wait) so any player's choice can be shown; skins[ slot ] = what each
	// player asked for ("" = the borrowed soldier)
	c = level.coop;
	c.skin_list = maps\_coop_skins::list();
	for ( i = 0; i < c.skin_list.size; i++ )
		precachemodel( c.skin_list[ i ] );
	c.skins = [];
	c.my_skin = valid_skin( getdvar( "coop_myskin" ) );
	c.bot_skin = valid_skin( getdvar( "coop_botskin" ) );
}

init()
{
	a = [];
	// real generic_human anims from common.ff (the drone_stand_* anims are not in the game: they fell back
	// to a junk pose). All are full-body loops, which is what animscripted needs on a fake-AI model.
	a[ "stand_idle" ] = %casual_stand_idle;
	a[ "stand_aim" ] = %exposed_aim_5;
	a[ "crouch_idle" ] = %casual_crouch_idle;
	a[ "crouch_aim" ] = %exposed_crouch_aim_5;
	a[ "prone" ] = %prone_aim_5;
	a[ "crawl" ] = %prone_crawl;
	a[ "walk_f" ] = %walk_lowready_F;
	a[ "walk_b" ] = %walk_lowready_B;
	a[ "walk_l" ] = %walk_lowready_L;
	a[ "walk_r" ] = %walk_lowready_R;
	a[ "run_f" ] = %run_lowready_F;
	a[ "run_b" ] = %run_lowready_B;
	a[ "run_l" ] = %run_lowready_L;
	a[ "run_r" ] = %run_lowready_R;
	a[ "crouch_f" ] = %crouch_fastwalk_F;
	a[ "crouch_b" ] = %crouch_fastwalk_B;
	a[ "crouch_l" ] = %crouch_fastwalk_L;
	a[ "crouch_r" ] = %crouch_fastwalk_R;
	a[ "sprint" ] = %sprint1_loop;
	a[ "downed" ] = %prone_aim_5;
	level.coop.puppet_anims = a;
	// natural ground speed of each anim (root motion per second): the bot moves at exactly these speeds,
	// and the anim choice uses them, so the body's own motion and the network position agree
	sp = [];
	keys = getarraykeys( a );
	for ( i = 0; i < keys.size; i++ )
	{
		md = getmovedelta( a[ keys[ i ] ], 0, 1 );
		len = getanimlength( a[ keys[ i ] ] );
		sp[ keys[ i ] ] = 0;
		if ( len > 0 )
			sp[ keys[ i ] ] = length( ( md[ 0 ], md[ 1 ], 0 ) ) / len;
	}
	level.coop.anim_speed = sp;
	level.coop.reanchors = 0;
	maps\_coop::log( "anim speeds walk " + int( sp[ "walk_f" ] ) + " run " + int( sp[ "run_f" ] ) + " sprint " + int( sp[ "sprint" ] ) + " crouch " + int( sp[ "crouch_f" ] ) + " crawl " + int( sp[ "crawl" ] ) + " run_b " + int( sp[ "run_b" ] ) + " walk_l " + int( sp[ "walk_l" ] ) );
	thread find_character();
	// levels whose scripts drive AI with setentitytarget themselves: leave their targeting alone
	if ( level.script != "ambush" && level.script != "bog_a" && level.script != "blackout" && level.script != "cargoship" )
		thread share_enemy_attention();
}

// ---------------------------------------------------------------------------------------------
// character model: copy a friendly that the level already loaded
// ---------------------------------------------------------------------------------------------

find_character()
{
	c = level.coop;

	for ( tries = 0; tries < 200 && !isdefined( c.character ); tries++ )
	{
		allies = getaiarray( "allies" );
		best = undefined;
		for ( i = 0; i < allies.size; i++ )
		{
			if ( !isdefined( allies[ i ].model ) || allies[ i ].model == "" )
				continue;
			// prefer a regular soldier over a named hero (Price, Gaz...) so the buddy is not a clone
			m = tolower( allies[ i ].model );
			if ( issubstr( m, "vip" ) || issubstr( m, "civilian" ) || issubstr( m, "price" ) || issubstr( m, "gaz" ) || issubstr( m, "griggs" ) || issubstr( m, "nikolai" ) )
				continue; // never dress the squadmate as a story character
			if ( !isdefined( allies[ i ].animname ) && !isdefined( allies[ i ].magic_bullet_shield ) )
			{
				best = allies[ i ];
				break;
			}
			if ( !isdefined( best ) )
				best = allies[ i ];
		}
		if ( isdefined( best ) )
		{
			ch = spawnstruct();
			ch.model = best.model;
			ch.attach_models = [];
			ch.attach_tags = [];
			n = best getattachsize();
			for ( i = 0; i < n; i++ )
			{
				m = best getattachmodelname( i );
				t = best getattachtagname( i );
				// skip weapons; we attach the remote player's own
				if ( issubstr( t, "weapon" ) )
					continue;
				ch.attach_models[ ch.attach_models.size ] = m;
				ch.attach_tags[ ch.attach_tags.size ] = t;
			}
			c.character = ch;
			maps\_coop::log( "puppet character " + ch.model + " (" + ch.attach_models.size + " parts)" );
			return;
		}
		wait 0.25;
	}
	if ( !isdefined( c.character ) )
		maps\_coop::log( "no friendly to borrow a character model from; puppets disabled in this level" );
}

// ---------------------------------------------------------------------------------------------
// per-frame update (called from _coop::net_loop)
// ---------------------------------------------------------------------------------------------

update_all()
{
	c = level.coop;
	if ( !isdefined( c.puppet_anims ) )
		return;
	for ( slot = 0; slot < c.max; slot++ )
	{
		if ( slot == c.slot )
			continue;
		// a bot that is a real AI in this world needs no puppet here
		real_bot = isdefined( c.bot_ai ) && isdefined( c.bot_ai[ slot ] ) && isalive( c.bot_ai[ slot ] );
		// everyone else is drawn by a real AI avatar where the level allows it
		if ( !real_bot && openfile( "coop", "connected", slot ) )
			maps\_coop_avatar::ensure( slot );
		if ( real_bot || maps\_coop_avatar::active( slot ) || !openfile( "coop", "connected", slot ) || fgetarg( slot, 10 ) > 3000 )
		{
			if ( isdefined( c.puppets[ slot ] ) )
				c.puppets[ slot ] hide_puppet();
			continue;
		}
		p = c.puppets[ slot ];
		if ( isdefined( p ) && p.coop_model != skin_of( slot ) )
		{
			remove( slot ); // the player picked another skin: dress a fresh puppet
			p = undefined;
		}
		if ( !isdefined( p ) )
		{
			if ( !isdefined( c.character ) )
				continue;
			p = spawn_puppet( slot );
		}
		p update_puppet( slot );
	}
}

spawn_puppet( slot )
{
	c = level.coop;
	org = ( fgetarg( slot, 0 ), fgetarg( slot, 1 ), fgetarg( slot, 2 ) );
	p = spawn( "script_model", org );
	skin = skin_of( slot );
	p.coop_model = skin;
	if ( skin != "" )
		p setmodel( skin ); // a skin is one complete model, no head or gear attachments
	else
	{
		p setmodel( c.character.model );
		for ( i = 0; i < c.character.attach_models.size; i++ )
			p attach( c.character.attach_models[ i ], c.character.attach_tags[ i ], true );
	}
	p useAnimTree( #animtree );
	p notsolid(); // a squadmate never blocks you (it spawns right next to you)
	p.team = "allies";
	p.NoFriendlyfire = true;
	p.no_friendly_fire_penalty = true;
	p.coop_slot = slot;
	p.coop_anim = "";
	p.coop_hidden = false;
	p.coop_lastpos = org;
	p.coop_speed = 0;
	p.coop_weapon = "";
	p.health = 100000;
	p setcandamage( true );
	p thread absorb_damage();
	p setlookattext( c.names[ slot ], &"" );
	c.puppets[ slot ] = p;
	c.shot_seen[ slot ] = int( fgetarg( slot, 5 ) ) >> 8;
	maps\_coop::log( "spawned puppet for slot " + slot );
	return p;
}

absorb_damage()
{
	self endon( "death" );
	for ( ;; )
	{
		self waittill( "damage" );
		self.health = 100000; // the remote player takes damage in their own world, not here
	}
}

update_puppet( slot )
{
	c = level.coop;
	pos = ( fgetarg( slot, 0 ), fgetarg( slot, 1 ), fgetarg( slot, 2 ) );
	pitch = fgetarg( slot, 3 );
	yaw = fgetarg( slot, 4 );
	flags = int( fgetarg( slot, 5 ) );
	c.health[ slot ] = int( fgetarg( slot, 6 ) );

	hidden = ( flags & 32 ) != 0 || maps\_coop_levels::hide_puppets();
	if ( hidden )
	{
		self hide_puppet();
		self.origin = pos;
		self.coop_lastpos = pos;
		self.coop_shots_skip = true;
		return;
	}
	if ( self.coop_hidden )
	{
		self show();
		self.coop_hidden = false;
	}

	delta = pos - self.coop_lastpos;
	dist = length( ( delta[ 0 ], delta[ 1 ], 0 ) );
	if ( dist > 600 )
		dist = 0; // teleport, not movement
	speed = dist / 0.05;
	self.coop_speed = self.coop_speed * 0.6 + speed * 0.4;
	self.coop_lastpos = pos;
	self.coop_pos = pos;
	self.coop_delta = delta;
	self.coop_yaw = yaw;

	// debounce: a new anim must be asked for on 2 updates in a row (a one-frame gait flicker would snap
	// the pose twice); the first anim and downed/prone changes apply at once
	want = choose_anim( flags, delta, yaw );
	if ( isdefined( self.coop_anim ) && want != self.coop_anim && want != "downed" && self.coop_anim != "downed" )
	{
		if ( !isdefined( self.coop_want ) || self.coop_want != want )
		{
			self.coop_want = want;
			want = self.coop_anim;
		}
	}
	else
		self.coop_want = undefined;
	self set_puppet_anim( want );
	self replay_shots( slot, flags, pos, pitch, yaw );
}

// The sender's exact gait, packed into pose flags bits 16-20 as (1 + gait * 4 + dir):
// gait 0 still / 1 walk / 2 run / 3 sprint, dir 0 forward / 1 back / 2 left / 3 right (relative to yaw).
// Guessing the gait here from interpolated positions flickered between anims (stutter), so we don't.
gait_bits( vel, yaw )
{
	v = length( ( vel[ 0 ], vel[ 1 ], 0 ) );
	if ( v < 15 )
		return 65536;
	g = 1;
	if ( v > 125 )
		g = 2;
	if ( v > 215 )
		g = 3;
	va = vectortoangles( ( vel[ 0 ], vel[ 1 ], 0 ) );
	rel = angle180( va[ 1 ] - yaw );
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

choose_anim( flags, delta, yaw )
{
	stance = flags & 3;
	downed = ( flags & 16 ) != 0;
	ads = ( flags & 12 ) != 0;
	speed = self.coop_speed;
	if ( downed )
		return "downed";
	code = int( flags / 65536 ) % 32;
	if ( code > 0 )
	{
		code = code - 1;
		g = int( code / 4 );
		d = "f";
		if ( code % 4 == 1 )
			d = "b";
		else if ( code % 4 == 2 )
			d = "l";
		else if ( code % 4 == 3 )
			d = "r";
		if ( stance == 2 )
		{
			if ( g > 0 )
				return "crawl";
			return "prone";
		}
		if ( stance == 1 )
		{
			if ( g > 0 )
				return "crouch_" + d;
			if ( ads )
				return "crouch_aim";
			return "crouch_idle";
		}
		if ( g == 3 )
			return "sprint";
		if ( g == 2 )
			return "run_" + d;
		if ( g == 1 )
			return "walk_" + d;
		if ( ads )
			return "stand_aim";
		return "stand_idle";
	}
	if ( stance == 2 )
	{
		if ( speed > 15 )
			return "crawl";
		return "prone";
	}
	dir = "f";
	if ( speed > 15 )
	{
		move_yaw = vectortoangles( ( delta[ 0 ], delta[ 1 ], 0 ) )[ 1 ];
		rel = angle180( move_yaw - yaw );
		if ( rel > 135 || rel < -135 )
			dir = "b";
		else if ( rel > 45 )
			dir = "l";
		else if ( rel < -45 )
			dir = "r";
	}
	if ( stance == 1 )
	{
		if ( speed > 15 )
			return "crouch_" + dir;
		if ( ads )
			return "crouch_aim";
		return "crouch_idle";
	}
	sp = level.coop.anim_speed;
	if ( dir == "f" && speed > ( sp[ "run_f" ] + sp[ "sprint" ] ) * 0.5 )
		return "sprint";
	if ( speed > ( sp[ "walk_f" ] + sp[ "run_f" ] ) * 0.5 )
		return "run_" + dir;
	if ( speed > 15 )
		return "walk_" + dir;
	if ( ads )
		return "stand_aim";
	return "stand_idle";
}

// Fake-AI script models only animate through animscripted (the drone technique), and a scripted anim is
// drawn at its anchor, not at the entity origin. So the anim is re-anchored on the network pose whenever
// that moves or turns, continuing from the same point in the cycle (getanimtime/setanimtime).
// A small loop restarts it when a non-looping anim reaches its end.


angle180( a )
{
	while ( a > 180 )
		a -= 360;
	while ( a < -180 )
		a += 360;
	return a;
}

clamp_f( v, lo, hi )
{
	if ( v < lo )
		return lo;
	if ( v > hi )
		return hi;
	return v;
}

hide_puppet()
{
	if ( self.coop_hidden )
		return;
	self hide();
	self.coop_hidden = true;
}

remove( slot )
{
	if ( isdefined( level.coop.puppets[ slot ] ) )
	{
		level.coop.puppets[ slot ] delete();
		level.coop.puppets[ slot ] = undefined;
	}
}

remove_all()
{
	for ( i = 0; i < level.coop.max; i++ )
		remove( i );
}

// ---------------------------------------------------------------------------------------------
// weapons and shots
// ---------------------------------------------------------------------------------------------

learn_local_weapons()
{
	list = level.player getweaponslist();
	for ( i = 0; i < list.size; i++ )
		level.coop.known_weapons[ list[ i ] ] = true;
}

is_known_weapon( w )
{
	return isdefined( w ) && w != "" && w != "none" && isdefined( level.coop.known_weapons[ w ] );
}

ev_weapon( slot, tok )
{
	if ( tok.size < 3 )
		return;
	level.coop.remote_weapon[ slot ] = tok[ 2 ];
}

// weapon actually drawn on the puppet: theirs if this level has it loaded, else our own primary
display_weapon( slot )
{
	w = level.coop.remote_weapon[ slot ];
	if ( is_known_weapon( w ) )
		return w;
	cur = level.player getcurrentweapon();
	if ( is_known_weapon( cur ) )
		return cur;
	return "";
}

replay_shots( slot, flags, pos, pitch, yaw )
{
	c = level.coop;
	w = display_weapon( slot );
	if ( w != self.coop_weapon && !isai( self ) ) // an avatar holds its own gun
	{
		if ( self.coop_weapon != "" )
			self detach( getweaponmodel( self.coop_weapon ), "tag_weapon_right" );
		self.coop_weapon = w;
		if ( w != "" )
			self attach( getweaponmodel( w ), "tag_weapon_right" );
	}

	count = ( flags >> 8 ) & 255;
	if ( !isdefined( c.shot_seen[ slot ] ) )
		c.shot_seen[ slot ] = count;
	n = ( count - c.shot_seen[ slot ] + 256 ) % 256;
	c.shot_seen[ slot ] = count;
	if ( isdefined( self.coop_shots_skip ) )
	{
		self.coop_shots_skip = undefined;
		return;
	}
	if ( n <= 0 || n > 6 )
		return; // nothing new, or a stale burst after a hitch

	rw = c.remote_weapon[ slot ];
	if ( !is_known_weapon( rw ) )
		return;
	wc = weaponclass( rw );
	// bullets only: replaying a rocket or grenade launcher would detonate real explosives here
	if ( wc != "rifle" && wc != "smg" && wc != "mg" && wc != "pistol" && wc != "spread" && wc != "sniper" )
		return;
	if ( issubstr( rw, "gl_" ) || issubstr( rw, "rpg" ) || issubstr( rw, "at4" ) || issubstr( rw, "m203" ) || issubstr( rw, "gp25" ) )
		return;

	stance = flags & 3;
	eye_h = 60;
	if ( stance == 1 )
		eye_h = 40;
	else if ( stance == 2 )
		eye_h = 11;
	eye = pos + ( 0, 0, eye_h );
	fwd = anglestoforward( ( pitch, yaw, 0 ) );
	trace = bullettrace( eye, eye + vectorscale( fwd, 8000 ), true, self );
	dest = trace[ "position" ];
	start = eye + vectorscale( fwd, 24 );

	// never let a replayed shot hit the local player
	if ( distance_to_segment( level.player geteye(), start, dest ) < 40 )
		return;
	if ( distance_to_segment( level.player.origin + ( 0, 0, 30 ), start, dest ) < 40 )
		return;
	for ( i = 0; i < n; i++ )
		magicbullet( rw, start, dest );
}

distance_to_segment( p, a, b )
{
	ab = b - a;
	len2 = vectordot( ab, ab );
	if ( len2 <= 0 )
		return distance( p, a );
	t = vectordot( p - a, ab ) / len2;
	if ( t < 0 )
		t = 0;
	else if ( t > 1 )
		t = 1;
	return distance( p, a + vectorscale( ab, t ) );
}

// ---------------------------------------------------------------------------------------------
// make some nearby enemies shoot at the buddy, so the fight looks shared (cosmetic in this world)
// ---------------------------------------------------------------------------------------------

share_enemy_attention()
{
	level endon( "coop_stop" );
	for ( ;; )
	{
		wait 1;
		c = level.coop;
		if ( !c.active )
			continue;
		axis = getaiarray( "axis" );
		for ( s = 0; s < c.max; s++ )
		{
			p = c.puppets[ s ];
			if ( !isdefined( p ) || p.coop_hidden || c.downed[ s ] )
				continue;
			used = 0;
			for ( i = 0; i < axis.size && used < 2; i++ )
			{
				ai = axis[ i ];
				if ( !isalive( ai ) || isdefined( ai.coop_target_until ) )
					continue;
				if ( !isdefined( ai.enemy ) || ai.enemy != level.player )
					continue;
				dp = distance( ai.origin, p.origin );
				if ( dp > 1200 || dp > distance( ai.origin, level.player.origin ) * 0.7 )
					continue;
				if ( !sighttracepassed( ai geteye(), p.origin + ( 0, 0, 48 ), false, p ) )
					continue;
				ai thread target_puppet_for( p, 3 + randomfloat( 3 ) );
				used++;
			}
		}
	}
}

target_puppet_for( p, t )
{
	self endon( "death" );
	self.coop_target_until = gettime() + t * 1000;
	self setentitytarget( p, 0.6 );
	wait t;
	if ( isalive( self ) )
		self clearentitytarget();
	self.coop_target_until = undefined;
}





// Blended puppet, the way the stock vehicles animate their script models (_vehicle.gsc): the anims play
// in place on the model's animtree, a gait change is a 0.2 s crossfade (setanim/clearanim), the
// locomotion playback rate follows the real ground speed, and the model glides to each network pose with
// moveto/rotateto, which the engine interpolates. No animscripted, no anchors, no restarts: nothing in
// this path can pop.
set_puppet_anim( name )
{
	if ( !isdefined( self.coop_pos ) )
		return;
	pos = self.coop_pos;
	ang = ( 0, self.coop_yaw, 0 );
	if ( !isdefined( self.coop_placed ) || distance( self.origin, pos ) > 300 )
	{
		self.origin = pos; // first frame or a teleport: no glide across the map
		self.angles = ang;
		self.coop_placed = true;
	}
	else
	{
		self moveto( pos, 0.1 );
		self rotateto( ang, 0.1 );
	}
	sp = level.coop.anim_speed[ name ];
	rate = 1;
	if ( sp > 1 )
	{
		rate = self.coop_speed / sp;
		if ( rate < 0.6 )
			rate = 0.6;
		else if ( rate > 1.6 )
			rate = 1.6;
	}
	pa = level.coop.puppet_anims[ name ];
	if ( self.coop_anim != name )
	{
		blend = 0.2;
		if ( self.coop_anim != "" )
		{
			old = level.coop.puppet_anims[ self.coop_anim ];
			if ( sp <= 1 && level.coop.anim_speed[ self.coop_anim ] > 1 )
			{
				// stopping: freeze the stride where it is (the body no longer moves, so walking legs
				// during the blend looked like a moonwalk) and settle into the idle a bit more slowly
				self setanim( old, 1, 0, 0 );
				blend = 0.3;
			}
		}
		// like the AI's own animscripts (run.gsc): one call fades the new anim in and everything else under
		// %body out. Fading a single leaf did not blend: the engine renormalises weights inside each parent
		// node, so the old anim stayed at full strength until its weight hit zero and then snapped off.
		self setanimknoball( pa, %body, 1, blend, rate );
		self.coop_anim = name;
		self.coop_rate = rate;
		return;
	}
	// non-looping idle anims: start them again near the end (the crossfade hides the seam)
	if ( sp <= 1 && self getanimtime( pa ) > 0.97 )
	{
		self setanimrestart( pa, 1, 0.2, 1 );
		return;
	}
	if ( abs( rate - self.coop_rate ) > 0.05 )
	{
		self setanim( pa, 1, 0.2, rate );
		self.coop_rate = rate;
	}
}

// ---------------------------------------------------------------------------------------------
// skins: "Z|<model>" announces a player's skin ("-" = none); repeated every few seconds like weapons
// ---------------------------------------------------------------------------------------------

valid_skin( name )
{
	c = level.coop;
	for ( i = 0; i < c.skin_list.size; i++ )
		if ( c.skin_list[ i ] == name )
			return name;
	return "";
}

skin_of( slot )
{
	c = level.coop;
	if ( isdefined( c.skins[ slot ] ) )
		return c.skins[ slot ];
	return "";
}

ev_skin( slot, tok )
{
	if ( tok.size < 3 )
		return;
	// a skin this game does not have in its pack falls back to the normal soldier
	level.coop.skins[ slot ] = valid_skin( tok[ 2 ] );
}

announce_skin()
{
	c = level.coop;
	if ( c.my_skin != "" )
		maps\_coop::send( "Z|" + c.my_skin );
	else
		maps\_coop::send( "Z|-" );
}
