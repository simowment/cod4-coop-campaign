// CoD4 SP Coop - emotes.
//
// Hold the emote key (default B, "+set coop_emote_key h" to change, "none" to not bind it): a radial
// wheel opens. Look toward a slice (or press 1-8) and release to play it; release in the middle closes.
// Fire while the wheel is open also picks, aim closes it.
//
// Input: the key is bound to "+coop_emote" (a do-nothing command the proxy registers). notifyOnCommand
// matches argv[0] before the command lookup, so press/release arrive as player notifies; a bind only runs
// while the game has the keyboard (never in the console or a menu). The release is also polled through
// the proxy (bindheld, which reads nothing while the console or a menu is open) in case the key-up is lost.
// The bind is for this session only: the proxy keeps it out of the player's config.cfg, and the key gets
// its previous binding back when coop_emote_key changes or is set to "none".
// Damage cancels an emote on purpose: while emoting the player entity sits at the camera spot and the
// player cannot react, so any hit (stray fire included) hands control back.
//
// While emoting you see yourself from the front: a copy of your character plays the emote at your spot
// and the player view is linked to a camera (iw3sp has no cg_thirdperson). Moving, jumping, firing, aim,
// melee, grenades, damage, going down, death, level end and the emote key all cancel it; the player is
// put back exactly where they stood. Squadmates see the same emote on your puppet ("EM|id|ms", "EM|-1").
// Every anim and sound used here is in common.ff, so it works in every level.

#include maps\_utility;
#include common_scripts\utility;
#using_animtree( "generic_human" );

init()
{
	c = level.coop;
	c.emotes = [];
	//         name           rate  hold(ms) sound                          anims (played in turn)
	add_emote( "Wave",        1.0,  0,       undefined,                     %coverstand_hide_idle_wave01 );
	add_emote( "On Me",       1.0,  0,       undefined,                     %coverstand_hide_idle_wave02 );
	add_emote( "Radio",       1.0,  0,       undefined,                     %casual_stand_v2_twitch_radio );
	add_emote( "Point",       1.0,  4400,    undefined,                     %casual_crouch_point );
	add_emote( "Celebrate",   1.0,  0,       "arcademode_kill_streak_won",  %casual_stand_v2_twitch_talk, %casual_stand_v2_twitch_shift );
	add_emote( "Dance",       1.7,  11000,   "cheat_chaplin_music",         %casual_stand_v2_twitch_shift, %patrolstand_twitch, %casual_stand_v2_twitch_talk, %patrolstand_look );
	add_emote( "Take a Knee", 1.0,  8000,    undefined,                     %casual_crouch_idle );
	add_emote( "Play Dead",   1.0,  7000,    undefined,                     %death_stand_dropinplace );
	c.emote = undefined; // struct while the local player is emoting
	c.wheel = undefined; // struct while the wheel is open
	c.emote_seq = 0;

	key = clean_key( getdvar( "coop_emote_key" ) );
	if ( key == "" )
		key = "b";
	// session-only bind: the proxy keeps it out of the player's config and gives the key its old
	// binding back when coop_emote_key changes or is "none"
	if ( openfile( "coop", "bindemote", key ) != 1 && key != "none" )
		maps\_coop::log( "emotes: cannot bind key '" + key + "'" );
	// the notify table is cleared on every map load (and saved with checkpoints): register once per level
	level.player notifyOnCommand( "coop_emote_down", "+coop_emote" );
	level.player notifyOnCommand( "coop_emote_up", "-coop_emote" );
	level thread watch_key();
	maps\_coop::log( "emotes: " + c.emotes.size + " on key '" + key + "'" );
}

add_emote( name, rate, hold, snd, a0, a1, a2, a3 )
{
	e = spawnstruct();
	e.name = name;
	e.rate = rate;
	e.snd = snd;
	e.anims = [];
	e.anims[ 0 ] = a0;
	if ( isdefined( a1 ) )
		e.anims[ e.anims.size ] = a1;
	if ( isdefined( a2 ) )
		e.anims[ e.anims.size ] = a2;
	if ( isdefined( a3 ) )
		e.anims[ e.anims.size ] = a3;
	total = 0;
	for ( i = 0; i < e.anims.size; i++ )
		total += getanimlength( e.anims[ i ] ) / rate;
	e.dur_ms = int( total * 1000 );
	if ( hold > e.dur_ms )
		e.dur_ms = hold; // looping (or last-frame holding) emotes last this long
	level.coop.emotes[ level.coop.emotes.size ] = e;
}

// key names only: letters, digits, F-keys, MOUSE4... (the dvar ends up in a console command)
clean_key( k )
{
	out = "";
	for ( i = 0; i < k.size && i < 12; i++ )
		if ( issubstr( "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_", k[ i ] ) )
			out = out + k[ i ];
	return tolower( out );
}

// ---------------------------------------------------------------------------------------------
// key and wheel
// ---------------------------------------------------------------------------------------------

watch_key()
{
	level endon( "coop_stop" );
	p = level.player;
	for ( ;; )
	{
		p waittill( "coop_emote_down" );
		c = level.coop;
		if ( isdefined( c.emote ) )
		{
			stop_emote( "key" );
			continue;
		}
		if ( !isdefined( c.wheel ) )
			thread open_wheel( "key" );
	}
}

can_emote()
{
	c = level.coop;
	p = level.player;
	if ( !isalive( p ) || c.down || isdefined( c.hidden ) )
		return false;
	if ( level.missionfailed || isdefined( level.nextmission ) || isdefined( c.end_waiting ) )
		return false;
	if ( openfile( "coop", "barrier" ) )
		return false;
	if ( !isdefined( c.emote ) && maps\_coop::player_linked() )
		return false; // on a rig, in a vehicle, in a scripted camera: leave the level's control alone
	return true;
}

busy()
{
	return isdefined( level.coop.emote ) || isdefined( level.coop.wheel );
}

open_wheel( mode )
{
	c = level.coop;
	p = level.player;
	if ( busy() || !can_emote() )
		return;
	w = spawnstruct();
	w.mode = mode;
	w.sel = -1;
	w.cx = 0;
	w.cy = 0;
	w.base = p getplayerangles();
	w.open_angles = w.base; // the cursor turns the real view: the emote (or a cancel) goes back to this
	c.wheel = w;
	// weapons are lowered (no shots, fire picks); the player may keep walking. Controls are never frozen
	// here, so a level's own freezecontrols is never undone by the wheel.
	weapons_off();
	maps\_coop_emote_hud::show();
	maps\_coop::log( "emote wheel open (" + mode + ")" );
	p thread wait_key_up( w );
	fire_armed = !( p attackbuttonpressed() );
	ads_armed = !( p adsbuttonpressed() );
	up_polls = 0;
	for ( ;; )
	{
		wait 0.05;
		if ( !isdefined( c.wheel ) || c.wheel != w )
			return; // closed elsewhere (test hook, emote started)
		if ( !can_emote() )
		{
			close_wheel( -1 );
			return;
		}
		update_cursor( w );
		maps\_coop_emote_hud::update( w );
		for ( i = 0; i < 8; i++ )
			if ( p buttonpressed( "" + ( i + 1 ) ) )
			{
				close_wheel( i );
				return;
			}
		if ( p attackbuttonpressed() )
		{
			if ( fire_armed )
			{
				close_wheel( w.sel );
				return;
			}
		}
		else
			fire_armed = true;
		if ( p adsbuttonpressed() )
		{
			if ( ads_armed )
			{
				close_wheel( -1 );
				return;
			}
		}
		else
			ads_armed = true;
		if ( mode == "key" )
		{
			if ( isdefined( w.released ) )
			{
				close_wheel( w.sel );
				return;
			}
			if ( openfile( "coop", "bindheld", "+coop_emote" ) == 0 )
				up_polls++;
			else
				up_polls = 0;
			if ( up_polls >= 4 )
			{
				close_wheel( w.sel ); // the key-up never came (console opened while holding it...)
				return;
			}
		}
	}
}

wait_key_up( w )
{
	self endon( "coop_wheel_closed" );
	self waittill( "coop_emote_up" );
	w.released = true;
}

// the view offset since the wheel opened is the cursor; it is capped, so turning further just drags
// the centre along (no need to turn back a long way)
update_cursor( w )
{
	p = level.player;
	cur = p getplayerangles();
	dx = maps\_coop_puppet::angle180( w.base[ 1 ] - cur[ 1 ] ); // right
	dy = w.base[ 0 ] - cur[ 0 ]; // up
	if ( dx != 0 || dy != 0 )
		p setplayerangles( w.base ); // the view stays where the wheel opened; the mouse only moves the cursor
	x = w.cx + dx;
	y = w.cy + dy;
	len = length( ( x, y, 0 ) );
	maxr = 14;
	if ( len > maxr )
	{
		x = x * maxr / len;
		y = y * maxr / len;
		len = maxr;
	}
	w.cx = x;
	w.cy = y;
	if ( len >= 5 )
		w.sel = slice_at( x, y );
	else if ( len < 3 )
		w.sel = -1; // between 3 and 5 the last slice stays lit
}

slice_at( x, y )
{
	a = vectortoangles( ( x, y, 0 ) )[ 1 ]; // counter-clockwise from "right"
	compass = 90 - a; // clockwise from "up"
	while ( compass < 0 )
		compass += 360;
	return int( ( compass + 22.5 ) / 45 ) % 8;
}

close_wheel( sel )
{
	c = level.coop;
	w = c.wheel;
	if ( !isdefined( w ) )
		return;
	c.wheel = undefined;
	level.player notify( "coop_wheel_closed" );
	maps\_coop_emote_hud::hide();
	if ( getdvar( "coop_debug" ) == "1" )
		maps\_coop::log( "emote wheel close, pick " + sel + " key up " + isdefined( w.released ) );
	if ( isdefined( sel ) && sel >= 0 && isdefined( c.emotes[ sel ] ) )
		play_emote( sel, w.open_angles );
	else
	{
		if ( can_emote() )
			level.player setplayerangles( w.open_angles ); // undo the cursor's view turn
		weapons_on();
	}
}

// disable weapons only if we are the ones doing it (a level that already lowered them keeps them down)
weapons_off()
{
	c = level.coop;
	if ( isdefined( c.emote_wpn ) )
		return;
	w = level.player getcurrentweapon();
	if ( !isdefined( w ) || w == "none" )
		return;
	c.emote_wpn = w;
	level.player disableweapons();
}

weapons_on()
{
	c = level.coop;
	if ( !isdefined( c.emote_wpn ) )
		return;
	c.emote_wpn = undefined;
	if ( isalive( level.player ) )
		level.player enableweapons();
}

// ---------------------------------------------------------------------------------------------
// playing an emote (local player)
// ---------------------------------------------------------------------------------------------

// angles: the view to face during and after the emote (the wheel passes the view from before its cursor)
play_emote( id, angles )
{
	c = level.coop;
	p = level.player;
	if ( !isdefined( c.emotes[ id ] ) )
		return;
	if ( isdefined( c.wheel ) )
	{
		if ( !isdefined( angles ) )
			angles = c.wheel.open_angles;
		c.wheel = undefined;
		p notify( "coop_wheel_closed" );
		maps\_coop_emote_hud::hide();
	}
	replaced = false;
	if ( isdefined( c.emote ) )
	{
		// it put us back where we stood (on the ground); isonground() only catches up next frame
		replaced = true;
		stop_emote( "replaced" );
	}
	if ( !can_emote() || ( !replaced && !( p isonground() ) ) )
	{
		weapons_on();
		return;
	}
	if ( !isdefined( angles ) )
		angles = p getplayerangles();
	e = c.emotes[ id ];
	c.emote_seq++;
	st = spawnstruct();
	st.id = id;
	st.origin = p.origin;
	st.angles = ( angles[ 0 ], angles[ 1 ], 0 );
	st.end = gettime() + e.dur_ms;
	weapon = p getcurrentweapon();
	if ( isdefined( c.emote_wpn ) )
		weapon = c.emote_wpn;
	c.emote = st;
	weapons_off();
	st.avatar = spawn_avatar( st.origin, st.angles[ 1 ], weapon );
	if ( isdefined( st.avatar ) )
	{
		st.avatar thread play_sequence( e, e.dur_ms, true );
		st.cam = start_camera( st );
	}
	maps\_coop::send( "EM|" + id + "|" + e.dur_ms );
	thread bots_join( id, e.dur_ms );
	p thread watch_cancel( st );
	p thread watch_damage( st );
	maps\_coop::log( "emote start " + e.name + " (" + e.dur_ms + " ms) avatar " + isdefined( st.avatar ) );
}

spawn_avatar( org, yaw, weapon )
{
	c = level.coop;
	if ( c.my_skin == "" && !isdefined( c.character ) )
		return undefined; // nothing to dress it with: the emote still plays for the squad
	a = spawn( "script_model", org );
	a.angles = ( 0, yaw, 0 );
	if ( c.my_skin != "" )
		a setmodel( c.my_skin );
	else
	{
		a setmodel( c.character.model );
		for ( i = 0; i < c.character.attach_models.size; i++ )
			a attach( c.character.attach_models[ i ], c.character.attach_tags[ i ], true );
	}
	if ( isdefined( weapon ) && weapon != "none" && weapon != "" )
		a attach( getweaponmodel( weapon ), "tag_weapon_right" );
	a useAnimTree( #animtree );
	a notsolid();
	return a;
}

// a camera in front of the avatar (a little to one side), looking back at it. The player is linked to
// it, so the player entity sits at the camera spot until the emote ends (send_pose keeps sending st.origin).
start_camera( st )
{
	p = level.player;
	eye_h = p geteye()[ 2 ] - p.origin[ 2 ];
	yaw = st.angles[ 1 ];
	head = st.origin + ( 0, 0, 58 );
	// front-left first; if a wall is in the way try other sides and keep the clearest
	offs = [];
	offs[ 0 ] = 28;
	offs[ 1 ] = -28;
	offs[ 2 ] = 70;
	offs[ 3 ] = -70;
	offs[ 4 ] = 120;
	offs[ 5 ] = -120;
	offs[ 6 ] = 180;
	best_f = -1;
	best = undefined;
	for ( i = 0; i < offs.size && best_f < 0.95; i++ )
	{
		want = head + vectorscale( anglestoforward( ( 0, yaw + offs[ i ], 0 ) ), 130 ) + ( 0, 0, 6 );
		tr = bullettrace( head, want, false, st.avatar );
		if ( tr[ "fraction" ] > best_f + 0.05 )
		{
			best_f = tr[ "fraction" ];
			best = want;
		}
	}
	campos = best;
	if ( best_f < 1 )
	{
		f = best_f - 0.12;
		if ( f < 0.2 )
			f = 0.2;
		campos = head + vectorscale( best - head, f );
	}
	look = st.origin + ( 0, 0, 38 );
	cam = spawn( "script_model", campos - ( 0, 0, eye_h ) );
	cam setmodel( "tag_origin" );
	cam.angles = vectortoangles( look - campos );
	p playerlinktoabsolute( cam, "tag_origin" );
	hud_off();
	return cam;
}

// the player HUD (compass, ammo, stance, action slots) would be drawn over the third-person view
hud_off()
{
	c = level.coop;
	if ( isdefined( c.emote_hud ) )
		return;
	names = [];
	vals = [];
	names[ 0 ] = "compass";
	vals[ 0 ] = "0";
	names[ 1 ] = "ammoCounterHide";
	vals[ 1 ] = "1";
	names[ 2 ] = "hud_showStance";
	vals[ 2 ] = "0";
	names[ 3 ] = "actionSlotsHide";
	vals[ 3 ] = "1";
	names[ 4 ] = "hud_drawhud";
	vals[ 4 ] = "0";
	h = spawnstruct();
	h.names = names;
	h.vals = vals;
	h.old = [];
	for ( i = 0; i < names.size; i++ )
	{
		h.old[ i ] = getdvar( names[ i ] );
		setsaveddvar( names[ i ], vals[ i ] );
	}
	c.emote_hud = h;
}

// put back only what still has our value (a level that changed one meanwhile keeps its own)
hud_on()
{
	c = level.coop;
	h = c.emote_hud;
	if ( !isdefined( h ) )
		return;
	c.emote_hud = undefined;
	for ( i = 0; i < h.names.size; i++ )
		if ( getdvar( h.names[ i ] ) == h.vals[ i ] && h.old[ i ] != "" )
			setsaveddvar( h.names[ i ], h.old[ i ] );
}

// on the avatar (local) or a puppet (remote): play the emote's anims in turn for dur ms
play_sequence( e, dur, is_local )
{
	self endon( "death" );
	self endon( "coop_emote_end" );
	if ( isdefined( e.snd ) )
	{
		// a "_music" alias is a streamed song: playsound could not stop it, so it is real music, local only
		if ( !is_music( e.snd ) )
			self playsound( e.snd );
		else if ( isdefined( is_local ) )
		{
			musicplay( e.snd );
			level.coop.emote_music = true;
		}
	}
	t_end = gettime() + dur;
	for ( i = 0; gettime() < t_end; i++ )
	{
		a = e.anims[ i % e.anims.size ];
		self setanimknoball( a, %body, 1, 0.2, e.rate );
		if ( e.anims.size == 1 )
			return; // one anim: it loops by itself, or holds its last frame
		t = getanimlength( a ) / e.rate - 0.15;
		if ( t < 0.1 )
			t = 0.1;
		wait t;
	}
}

watch_cancel( st )
{
	c = level.coop;
	cmds = [];
	cmds[ 0 ] = "+forward";
	cmds[ 1 ] = "+back";
	cmds[ 2 ] = "+moveleft";
	cmds[ 3 ] = "+moveright";
	cmds[ 4 ] = "+gostand";
	cmds[ 5 ] = "+frag";
	cmds[ 6 ] = "+smoke";
	cmds[ 7 ] = "+moveup";
	// a button still held from the wheel (fire-to-pick, walking key) must be let go before it counts
	fire_armed = false;
	ads_armed = false;
	melee_armed = false;
	move_armed = false;
	for ( ;; )
	{
		wait 0.05;
		if ( !isdefined( c.emote ) || c.emote != st )
			return;
		reason = undefined;
		if ( !isalive( self ) )
			reason = "death";
		else if ( isdefined( st.cam ) && distance( self.origin, st.cam.origin ) > 16 )
			reason = "scene"; // the level linked or moved the player itself: leave it there
		else if ( c.down )
			reason = "down";
		else if ( level.missionfailed || isdefined( level.nextmission ) || isdefined( c.end_waiting ) )
			reason = "level end";
		else if ( gettime() >= st.end )
			reason = "done";
		else
		{
			moving = false;
			for ( i = 0; i < cmds.size && !moving; i++ )
				if ( openfile( "coop", "bindheld", cmds[ i ] ) == 1 )
					moving = true;
			fire = self attackbuttonpressed();
			ads = self adsbuttonpressed();
			melee = self meleebuttonpressed();
			if ( ( moving && move_armed ) || ( fire && fire_armed ) || ( ads && ads_armed ) || ( melee && melee_armed ) )
				reason = "input";
			if ( !moving )
				move_armed = true;
			if ( !fire )
				fire_armed = true;
			if ( !ads )
				ads_armed = true;
			if ( !melee )
				melee_armed = true;
		}
		if ( isdefined( reason ) )
		{
			stop_emote( reason );
			return;
		}
	}
}

watch_damage( st )
{
	self endon( "coop_emote_over" );
	self endon( "death" );
	self waittill( "damage" );
	if ( isdefined( level.coop.emote ) && level.coop.emote == st )
		level thread stop_emote( "damage" ); // not on this thread: stop_emote's notify ends it
}

stop_emote( reason )
{
	c = level.coop;
	st = c.emote;
	if ( !isdefined( st ) )
		return;
	c.emote = undefined;
	p = level.player;
	p notify( "coop_emote_over" );
	if ( isdefined( st.cam ) )
	{
		// only undo our own link: if the level took the player meanwhile (scene, rig) it keeps them
		on_cam = distance( p.origin, st.cam.origin ) <= 16;
		if ( on_cam )
		{
			p unlink();
			if ( isalive( p ) )
			{
				p setorigin( st.origin );
				p setplayerangles( st.angles );
			}
			// the link guess (_coop::update_linked) must not read the jump back as a level link
			c.link_score = 0;
			c.linked = false;
			c.last_origin = st.origin;
		}
		st.cam delete();
		hud_on();
	}
	if ( isdefined( st.avatar ) )
	{
		st.avatar notify( "coop_emote_end" );
		st.avatar stopsounds();
		if ( isdefined( level.coop.emote_music ) )
		{
			musicstop( 0.5 );
			level.coop.emote_music = undefined;
		}
		st.avatar delete();
	}
	weapons_on();
	maps\_coop::send( "EM|-1" );
	maps\_coop::log( "emote stop (" + reason + ")" );
}

// called by _coop::net_loop when a checkpoint was loaded (saves are refused while emoting, so this only
// matters for a level's own forced save): put everything back and tell the squad
on_checkpoint_load()
{
	c = level.coop;
	if ( isdefined( c.wheel ) )
		close_wheel( -1 );
	if ( isdefined( c.emote ) )
		stop_emote( "checkpoint load" );
	else
		maps\_coop::send( "EM|-1" );
}

// the host's bots sometimes join in (they play it on their puppet; a moving bot stops at once)
bots_join( id, dur )
{
	c = level.coop;
	if ( !c.ishost )
		return;
	for ( s = 0; s < c.max; s++ )
		if ( s != c.slot && maps\_coop_bot::is_bot( s ) && randomint( 100 ) < 60 )
			thread bot_emote_later( s, id, dur );
}

bot_emote_later( s, id, dur )
{
	wait 0.4 + randomfloat( 1.2 );
	if ( isdefined( level.coop.emote ) )
		maps\_coop_bot::bot_send( s, "EM|" + id + "|" + dur );
}

// ---------------------------------------------------------------------------------------------
// squadmates: "EM|<id>|<ms>" starts an emote on that player's puppet, "EM|-1" stops it
// ---------------------------------------------------------------------------------------------

ev_emote( slot, tok )
{
	if ( tok.size < 3 || !isdefined( level.coop.puppets ) )
		return;
	p = level.coop.puppets[ slot ];
	if ( !isdefined( p ) )
		return; // no puppet here (not spawned yet, or an avatar / real AI draws them)
	id = int( tok[ 2 ] );
	if ( id < 0 || !isdefined( level.coop.emotes[ id ] ) )
	{
		p puppet_emote_stop();
		return;
	}
	e = level.coop.emotes[ id ];
	dur = e.dur_ms;
	if ( tok.size >= 4 && int( tok[ 3 ] ) > 0 && int( tok[ 3 ] ) <= 30000 )
		dur = int( tok[ 3 ] );
	p puppet_emote_start( id, dur );
}

puppet_emote_start( id, dur )
{
	e = level.coop.emotes[ id ];
	self puppet_emote_stop();
	self.coop_emote_until = gettime() + dur;
	if ( isdefined( e.snd ) && !is_music( e.snd ) )
		self.coop_emote_snd = true;
	self thread play_sequence( e, dur );
}

// back to the gait anim on the next puppet update (set_puppet_anim blends from whatever is playing)
puppet_emote_stop()
{
	if ( !isdefined( self.coop_emote_until ) )
		return;
	self.coop_emote_until = undefined;
	self notify( "coop_emote_end" );
	if ( isdefined( self.coop_emote_snd ) )
	{
		self stopsounds();
		self.coop_emote_snd = undefined;
	}
	self.coop_anim = "";
}

// ---------------------------------------------------------------------------------------------
// test hooks (set coop_test_cmd "emote <1-8|stop>", "emotewheel <open|close|aim N|pick>", "botemote <1-8>")
// ---------------------------------------------------------------------------------------------

test_emote( arg )
{
	if ( arg == "stop" )
	{
		stop_emote( "test" );
		return;
	}
	if ( arg == "view" )
	{
		// look at the nearest squadmate's puppet (remote emote screenshots)
		c = level.coop;
		best = undefined;
		for ( s = 0; s < c.max; s++ )
			if ( s != c.slot && isdefined( c.puppets[ s ] ) && !maps\_coop_bot::is_bot( s ) )
				if ( !isdefined( best ) || distance( c.puppets[ s ].origin, level.player.origin ) < distance( best.origin, level.player.origin ) )
					best = c.puppets[ s ];
		if ( isdefined( best ) )
		{
			if ( distance( best.origin, level.player.origin ) < 100 )
				for ( k = 0; k < 8; k++ )
				{
					spot = best.origin + vectorscale( anglestoforward( ( 0, k * 45, 0 ) ), 170 );
					if ( bullettracepassed( best.origin + ( 0, 0, 50 ), spot + ( 0, 0, 50 ), false, best ) )
					{
						level.player setorigin( spot );
						break;
					}
				}
			level.player setplayerangles( vectortoangles( best.origin + ( 0, 0, 40 ) - level.player geteye() ) );
		}
		maps\_coop::log( "test emote view: puppet " + isdefined( best ) + " at " + level.player.origin );
		return;
	}
	n = int( arg ) - 1;
	maps\_coop::log( "test emote " + n );
	thread play_emote( n );
}

test_wheel( arg )
{
	c = level.coop;
	if ( arg == "open" )
		thread open_wheel( "test" );
	else if ( arg == "close" )
		close_wheel( -1 );
	else if ( arg == "pick" )
	{
		if ( isdefined( c.wheel ) )
			close_wheel( c.wheel.sel );
	}
	else if ( getsubstr( arg, 0, 4 ) == "aim " && isdefined( c.wheel ) )
	{
		// turn the view so the cursor points at slice N (as the mouse would)
		compass = ( int( getsubstr( arg, 4, arg.size ) ) - 1 ) * 45;
		x = sin( compass ) * 10;
		y = cos( compass ) * 10;
		b = c.wheel.base;
		level.player setplayerangles( ( b[ 0 ] - y, b[ 1 ] - x, 0 ) );
	}
	sel = -1;
	if ( isdefined( c.wheel ) )
		sel = c.wheel.sel;
	maps\_coop::log( "test wheel " + arg + ": open " + isdefined( c.wheel ) + " sel " + sel );
}

// "botemote N": the host's first bot plays emote N on its puppet (the EM event goes through the same
// queue as a squadmate's) and the player looks at it. "botemote view": first step back from the bot.
test_bot_emote( arg )
{
	c = level.coop;
	for ( s = 0; s < c.max; s++ )
		if ( s != c.slot && maps\_coop_bot::is_bot( s ) )
			break;
	if ( s >= c.max )
	{
		maps\_coop::log( "test bot emote: no bot" );
		return;
	}
	pp = c.puppets[ s ];
	if ( arg == "view" )
	{
		if ( !isdefined( pp ) )
			return;
		for ( k = 0; k < 8; k++ )
		{
			spot = pp.origin + vectorscale( anglestoforward( ( 0, k * 45, 0 ) ), 150 );
			if ( bullettracepassed( pp.origin + ( 0, 0, 50 ), spot + ( 0, 0, 50 ), false, pp ) )
			{
				level.player setorigin( spot );
				break;
			}
		}
		level.player setplayerangles( vectortoangles( pp.origin + ( 0, 0, 40 ) - level.player geteye() ) );
		maps\_coop::log( "test bot view: puppet at " + pp.origin + " me at " + level.player.origin );
		return;
	}
	id = int( arg ) - 1;
	if ( !isdefined( c.emotes[ id ] ) )
		return;
	maps\_coop_bot::bot_send( s, "EM|" + id + "|" + c.emotes[ id ].dur_ms );
	if ( isdefined( pp ) )
		level.player setplayerangles( vectortoangles( pp.origin + ( 0, 0, 40 ) - level.player geteye() ) );
	maps\_coop::log( "test bot emote slot " + s + " id " + id + " puppet " + isdefined( pp ) );
}

is_music( alias )
{
	n = alias.size;
	return n > 6 && getsubstr( alias, n - 6, n ) == "_music";
}
