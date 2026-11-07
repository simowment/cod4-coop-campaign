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
}

init()
{
	a = [];
	a[ "stand_idle" ] = %exposed_idle_alert_v1;
	a[ "stand_aim" ] = %exposed_aim_5;
	a[ "crouch_idle" ] = %exposed_crouch_idle_alert_v1;
	a[ "crouch_aim" ] = %exposed_crouch_aim_5;
	a[ "prone" ] = %prone_aim_5;
	a[ "crawl" ] = %prone_crawl;
	a[ "walk_f" ] = %walk_lowready_f;
	a[ "walk_b" ] = %walk_lowready_b;
	a[ "walk_l" ] = %walk_lowready_l;
	a[ "walk_r" ] = %walk_lowready_r;
	a[ "run_f" ] = %run_lowready_f;
	a[ "run_b" ] = %run_lowready_b;
	a[ "run_l" ] = %run_lowready_l;
	a[ "run_r" ] = %run_lowready_r;
	a[ "crouch_f" ] = %crouch_fastwalk_f;
	a[ "crouch_b" ] = %crouch_fastwalk_b;
	a[ "crouch_l" ] = %crouch_fastwalk_l;
	a[ "crouch_r" ] = %crouch_fastwalk_r;
	a[ "sprint" ] = %sprint1_loop;
	a[ "downed" ] = %prone_aim_5;
	level.coop.puppet_anims = a;
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
		if ( !openfile( "coop", "connected", slot ) || fgetarg( slot, 10 ) > 3000 )
		{
			if ( isdefined( c.puppets[ slot ] ) )
				c.puppets[ slot ] hide_puppet();
			continue;
		}
		p = c.puppets[ slot ];
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
	p setmodel( c.character.model );
	p useAnimTree( #animtree );
	p makefakeai();
	for ( i = 0; i < c.character.attach_models.size; i++ )
		p attach( c.character.attach_models[ i ], c.character.attach_tags[ i ], true );
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
	self.origin = pos;
	self.angles = ( 0, yaw, 0 );

	self set_puppet_anim( choose_anim( flags, delta, yaw ) );
	self replay_shots( slot, flags, pos, pitch, yaw );
}

choose_anim( flags, delta, yaw )
{
	stance = flags & 3;
	downed = ( flags & 16 ) != 0;
	ads = ( flags & 12 ) != 0;
	speed = self.coop_speed;
	if ( downed )
		return "downed";
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
	if ( speed > 230 && dir == "f" )
		return "sprint";
	if ( speed > 130 )
		return "run_" + dir;
	if ( speed > 15 )
		return "walk_" + dir;
	if ( ads )
		return "stand_aim";
	return "stand_idle";
}

set_puppet_anim( name )
{
	if ( self.coop_anim == name )
		return;
	self.coop_anim = name;
	rate = 1;
	if ( name == "walk_f" || name == "walk_b" || name == "walk_l" || name == "walk_r" )
		rate = clamp_f( self.coop_speed / 90, 0.6, 1.4 );
	else if ( issubstr( name, "run_" ) )
		rate = clamp_f( self.coop_speed / 190, 0.7, 1.3 );
	self setflaggedanimknoball( "coop_anim", level.coop.puppet_anims[ name ], %body, 1, 0.2, rate );
}

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
	if ( w != self.coop_weapon )
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
