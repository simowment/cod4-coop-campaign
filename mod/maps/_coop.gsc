// CoD4 SP Coop - core: session, event pump, replication of progression.
//
// Model: every player runs their own simulation of the level ("dual simulation"). The native proxy
// (d3d9.dll) carries a 20 Hz pose snapshot and a reliable ordered event stream. This file keeps the
// worlds in step: flags (union), trigger hits, AI deaths, checkpoints (host), mission fail (any), and
// level end (host). Remote players are drawn by maps\_coop_puppet. Downed/revive is maps\_coop_player.
//
// Bridge (repurposed stub builtins, see native/src/bridge.c):
//   openfile( "coop" [, cmd, arg] ), fprintln( str ), freadln(), fprintfields( ... ), fgetarg( slot, field ), closefile( "coop" )

#include maps\_utility;
#include common_scripts\utility;

// ---------------------------------------------------------------------------------------------
// entry points (called from the patched maps/_load.gsc)
// ---------------------------------------------------------------------------------------------

preinit()
{
	level.coop = spawnstruct();
	c = level.coop;
	c.version = "0.1.0";
	c.slot = openfile( "coop" );
	c.active = ( c.slot >= 0 );
	c.max = 4;
	c.names = [];
	c.downed = [];
	c.health = [];
	c.trig = [];
	c.ai = [];
	c.pending_flags = [];
	c.local_flags = [];
	c.handlers = [];
	c.shots = 0;
	c.down = false;

	if ( !c.active )
		return;

	c.ishost = openfile( "coop", "host" );
	c.max = openfile( "coop", "max" );
	for ( i = 0; i < c.max; i++ )
	{
		c.names[ i ] = openfile( "coop", "name", i );
		c.downed[ i ] = false;
		c.health[ i ] = 100;
	}

	// everything we draw must be precached before the level's first wait
	precacheShader( "white" );
	maps\_coop_puppet::precache();
	maps\_coop_player::precache();

	level.coop_flag_hook = ::on_flag;
	level.coop_fail_hook = ::on_missionfailed;
	level.coop_nextmission_hook = ::on_nextmission;
	level.coop_save_hook = ::on_tryautosave;
	level.coop_saved_hook = ::on_autosaved;
	level.coop_cansave_hook = ::can_save;

	register_handlers();
	maps\_coop_levels::init_local_flags();
	log( "preinit slot " + c.slot + " host " + c.ishost + " level " + getdvar( "mapname" ) );
}

postinit()
{
	c = level.coop;
	if ( !c.active )
		return;

	// --- first frame, before any wait: stable ids must be built identically on every machine ---
	build_trigger_ids();
	build_ai_ids();

	openfile( "coop", "level", level.script ); // tells the proxy which level we are in; may start the load barrier
	if ( openfile( "coop", "barrier" ) )
		thread barrier_hud();

	maps\_coop_levels::main();
	thread net_loop();
	thread // iw3sp has no islinked(): a linked player (rig, vehicle, scripted camera) moves without velocity,
// or hangs in the air without falling. Evaluated every frame from send_pose.
update_linked()
{
	c = level.coop;
	p = level.player;
	o = p.origin;
	v = p getvelocity();
	if ( !isdefined( c.last_origin ) )
		c.last_origin = o;
	moved = distance( o, c.last_origin );
	c.last_origin = o;
	vel = length( v );
	sign = 0;
	if ( moved > 1.5 && vel < 1 )
		sign = 1;
	else if ( !( p isonground() ) && abs( v[ 2 ] ) < 1 && vel < 1 )
		sign = 1;
	if ( !isdefined( c.link_score ) )
		c.link_score = 0;
	if ( sign )
		c.link_score = min( c.link_score + 1, 10 );
	else
		c.link_score = max( c.link_score - 1, 0 );
	c.linked = c.link_score >= 4;
}

player_linked()
{
	return isdefined( level.coop.linked ) && level.coop.linked;
}

track_shots();
	thread track_weapon();
	thread watch_death();
	maps\_coop_player::init();
	maps\_coop_puppet::init();
	log( "postinit: " + c.trig_count + " triggers, " + c.spawner_count + " spawners" );
}

// ---------------------------------------------------------------------------------------------
// utilities
// ---------------------------------------------------------------------------------------------

log( msg )
{
	openfile( "coop", "log", msg );
}

send( msg )
{
	if ( !level.coop.active )
		return;
	fprintln( level.script + "|" + msg ); // events are tagged with the level they belong to
}

players()
{
	return openfile( "coop", "count" );
}

in_coop()
{
	return level.coop.active && players() > 1;
}

slot_connected( slot )
{
	return openfile( "coop", "connected", slot );
}

sanitize( s )
{
	out = "";
	for ( i = 0; i < s.size; i++ )
	{
		ch = s[ i ];
		if ( ch == "|" || ch == "~" )
			ch = "_";
		out = out + ch;
	}
	return out;
}

// ---------------------------------------------------------------------------------------------
// net loop: pose out, events in
// ---------------------------------------------------------------------------------------------

net_loop()
{
	c = level.coop;
	for ( ;; )
	{
		send_pose();
		for ( i = 0; i < 64; i++ )
		{
			s = freadln();
			if ( !isdefined( s ) || s == "" )
				break;
			dispatch( s );
		}
		apply_pending_flags();
		maps\_coop_puppet::update_all();
		wait 0.05;
	}
}

send_pose()
{
	update_linked();
	p = level.player;
	o = p.origin;
	a = p getplayerangles();
	flags = 0;
	stance = p getstance();
	if ( stance == "crouch" )
		flags = 1;
	else if ( stance == "prone" )
		flags = 2;
	if ( p playerads() > 0.5 )
		flags += 4;
	if ( p isfiring() )
		flags += 8;
	if ( level.coop.down )
		flags += 16;
	if ( isdefined( level.coop.hidden ) || player_linked() )
		flags += 32;
	flags += ( level.coop.shots % 256 ) * 256;
	hp = 0;
	if ( isalive( p ) && p.maxhealth > 0 )
		hp = int( p.health * 100 / p.maxhealth );
	fprintfields( o[ 0 ], o[ 1 ], o[ 2 ], a[ 0 ], a[ 1 ], flags, hp, 0 );
}

// iw3sp has no islinked(): a linked player (rig, vehicle, scripted camera) moves without velocity,
// or hangs in the air without falling. Evaluated every frame from send_pose.
update_linked()
{
	c = level.coop;
	p = level.player;
	o = p.origin;
	v = p getvelocity();
	if ( !isdefined( c.last_origin ) )
		c.last_origin = o;
	moved = distance( o, c.last_origin );
	c.last_origin = o;
	vel = length( v );
	sign = 0;
	if ( moved > 1.5 && vel < 1 )
		sign = 1;
	else if ( !( p isonground() ) && abs( v[ 2 ] ) < 1 && vel < 1 )
		sign = 1;
	if ( !isdefined( c.link_score ) )
		c.link_score = 0;
	if ( sign )
		c.link_score = min( c.link_score + 1, 10 );
	else
		c.link_score = max( c.link_score - 1, 0 );
	c.linked = c.link_score >= 4;
}

player_linked()
{
	return isdefined( level.coop.linked ) && level.coop.linked;
}

track_shots()
{
	for ( ;; )
	{
		level.player waittill( "weapon_fired" );
		level.coop.shots++;
	}
}

track_weapon()
{
	last = "";
	for ( ;; )
	{
		w = level.player getcurrentweapon();
		if ( isdefined( w ) && w != last && w != "none" )
		{
			last = w;
			send( "W|" + w );
		}
		maps\_coop_puppet::learn_local_weapons();
		wait 0.25;
	}
}

register_handlers()
{
	h = level.coop.handlers;
	h[ "F" ] = ::ev_flag;
	h[ "T" ] = ::ev_trigger;
	h[ "K" ] = ::ev_kill;
	h[ "W" ] = maps\_coop_puppet::ev_weapon;
	h[ "S" ] = ::ev_save;
	h[ "X" ] = ::ev_fail;
	h[ "E" ] = ::ev_levelend;
	h[ "D" ] = maps\_coop_player::ev_downed;
	h[ "V" ] = maps\_coop_player::ev_revive;
	h[ "Y" ] = ::ev_teleport_to;
	h[ "Q" ] = maps\_coop_levels::ev_scene;
	level.coop.handlers = h;
}

dispatch( s )
{
	tok = strtok( s, "|" );
	if ( tok.size < 2 )
		return;
	origin = tok[ 0 ];
	type = tok[ 1 ];
	if ( origin == "s" )
	{
		sys_event( tok );
		return;
	}
	// "<origin>|<level>|<type>|args": drop events from a different level (a straggler, or a stale queue)
	if ( tok.size < 3 || type != level.script )
		return;
	t = [];
	t[ 0 ] = origin;
	for ( i = 2; i < tok.size; i++ )
		t[ t.size ] = tok[ i ];
	slot = int( origin );
	type = t[ 1 ];
	if ( isdefined( level.coop.handlers[ type ] ) )
		[[ level.coop.handlers[ type ] ]]( slot, t );
}

sys_event( tok )
{
	c = level.coop;
	type = tok[ 1 ];
	if ( type == "J" && tok.size >= 4 )
	{
		slot = int( tok[ 2 ] );
		c.names[ slot ] = tok[ 3 ];
		iprintln( tok[ 3 ] + " joined the squad" );
		log( "join " + slot + " " + tok[ 3 ] );
	}
	else if ( type == "P" && tok.size >= 3 )
	{
		slot = int( tok[ 2 ] );
		iprintln( c.names[ slot ] + " left the squad" );
		c.downed[ slot ] = false;
		maps\_coop_puppet::remove( slot );
	}
	else if ( type == "G" )
	{
		level notify( "coop_barrier_done" );
	}
	else if ( type == "L" && tok.size >= 3 )
	{
		// a player loaded our level late: bring them up to speed
		thread send_catchup( int( tok[ 2 ] ) );
	}
	else if ( type == "H" )
	{
		iprintlnbold( "Lost connection to the host" );
		c.active = false;
		maps\_coop_puppet::remove_all();
	}
	else if ( type == "W" )
	{
		c.slot = int( tok[ 2 ] );
	}
}

barrier_hud()
{
	hud = newHudElem();
	hud.alignX = "center";
	hud.alignY = "middle";
	hud.horzAlign = "center";
	hud.vertAlign = "middle";
	hud.y = -60;
	hud.fontscale = 1.6;
	hud.alpha = 1;
	hud.foreground = true;
	hud settext( "Waiting for your squad to load..." );
	level thread notify_after( 95, "coop_barrier_done" );
	level waittill( "coop_barrier_done" );
	hud destroy();
}

notify_after( t, msg )
{
	wait t;
	self notify( msg );
}

// ---------------------------------------------------------------------------------------------
// flags: union merge. Any player's set is applied everywhere; clears only from the host.
// ---------------------------------------------------------------------------------------------

on_flag( msg, value )
{
	c = level.coop;
	if ( !c.active )
		return;
	if ( isdefined( c.applying_flag ) && c.applying_flag == msg )
		return;
	if ( isdefined( c.local_flags[ msg ] ) || maps\_coop_levels::is_local_flag( msg ) )
		return;
	if ( !value && !c.ishost )
		return;
	v = "0";
	if ( value )
		v = "1";
	send( "F|" + msg + "|" + v );
}

ev_flag( slot, tok )
{
	if ( tok.size < 4 )
		return;
	apply_flag( tok[ 2 ], tok[ 3 ] == "1" );
}

apply_flag( msg, value )
{
	c = level.coop;
	if ( !isdefined( level.flag ) || !isdefined( level.flag[ msg ] ) )
	{
		c.pending_flags[ msg ] = value; // not flag_init'ed here yet
		return;
	}
	if ( level.flag[ msg ] == value )
		return;
	if ( isdefined( c.local_flags[ msg ] ) || maps\_coop_levels::is_local_flag( msg ) )
		return;
	c.applying_flag = msg;
	if ( value )
		flag_set( msg );
	else
		flag_clear( msg );
	c.applying_flag = undefined;
}

apply_pending_flags()
{
	c = level.coop;
	if ( !c.pending_flags.size )
		return;
	keys = getarraykeys( c.pending_flags );
	for ( i = 0; i < keys.size; i++ )
	{
		k = keys[ i ];
		if ( isdefined( level.flag[ k ] ) )
		{
			v = c.pending_flags[ k ];
			c.pending_flags[ k ] = undefined;
			apply_flag( k, v );
		}
	}
}

// ---------------------------------------------------------------------------------------------
// triggers: a local player's hit is replayed on everyone else's copy of that trigger
// ---------------------------------------------------------------------------------------------

build_trigger_ids()
{
	c = level.coop;
	classes = [];
	classes[ classes.size ] = "trigger_multiple";
	classes[ classes.size ] = "trigger_once";
	classes[ classes.size ] = "trigger_use";
	classes[ classes.size ] = "trigger_use_touch";
	classes[ classes.size ] = "trigger_radius";
	classes[ classes.size ] = "trigger_lookat";
	classes[ classes.size ] = "trigger_damage";
	c.trig_count = 0;
	for ( ci = 0; ci < classes.size; ci++ )
	{
		ents = getentarray( classes[ ci ], "classname" );
		for ( i = 0; i < ents.size; i++ )
		{
			id = ci + "." + i;
			ents[ i ].coop_id = id;
			ents[ i ].coop_last = -100000;
			c.trig[ id ] = ents[ i ];
			ents[ i ] thread watch_trigger();
			c.trig_count++;
		}
	}
}

watch_trigger()
{
	self endon( "death" );
	for ( ;; )
	{
		self waittill( "trigger", other );
		if ( !isdefined( other ) || other != level.player )
			continue;
		if ( isdefined( self.coop_local ) )
			continue; // level module marked it player-local (kill volumes, per-player hints...)
		now = gettime();
		if ( isdefined( self.coop_remote_time ) && self.coop_remote_time == now )
			continue; // our own replay of a remote hit
		if ( now - self.coop_last < 1000 )
			continue;
		self.coop_last = now;
		send( "T|" + self.coop_id );
		if ( self.classname == "trigger_once" )
			return;
	}
}

ev_trigger( slot, tok )
{
	if ( tok.size < 3 )
		return;
	t = level.coop.trig[ tok[ 2 ] ];
	if ( !isdefined( t ) )
		return;
	now = gettime();
	if ( now - t.coop_last < 1000 )
		return; // we hit it ourselves a moment ago
	if ( isdefined( t.coop_done ) || isdefined( t.coop_local ) )
		return;
	t.coop_last = now;
	t.coop_remote_time = now;
	t notify( "trigger", level.player );
	if ( isdefined( t ) && t.classname == "trigger_once" )
	{
		t.coop_done = true;
		t trigger_off(); // keep our own player from firing it a second time
	}
}

// ---------------------------------------------------------------------------------------------
// AI deaths: host reports every death, clients report kills by their player. Keys are spawner
// export + spawn sequence, identical on each machine for scripted spawns.
// ---------------------------------------------------------------------------------------------

build_ai_ids()
{
	c = level.coop;
	spawners = getspawnerarray();
	c.spawner_count = spawners.size;
	for ( i = 0; i < spawners.size; i++ )
	{
		sp = spawners[ i ];
		if ( isdefined( sp.export ) )
			sp.coop_key = "e" + sp.export;
		else
			sp.coop_key = "s" + i;
		sp.coop_seq = 0;
		sp thread watch_spawner();
	}
	ai = getaiarray();
	for ( i = 0; i < ai.size; i++ )
	{
		if ( isdefined( ai[ i ].export ) )
			ai[ i ] register_ai( "a" + ai[ i ].export );
		else
			ai[ i ] register_ai( "m" + i );
	}
}

watch_spawner()
{
	self endon( "death" );
	for ( ;; )
	{
		self waittill( "spawned", guy );
		self.coop_seq++;
		if ( !isdefined( guy ) || !isalive( guy ) )
			continue;
		guy register_ai( self.coop_key + "#" + self.coop_seq );
	}
}

register_ai( id )
{
	self.coop_id = id;
	level.coop.ai[ id ] = self;
	self thread watch_ai_death();
}

watch_ai_death()
{
	id = self.coop_id;
	self waittill( "death", attacker );
	level.coop.ai[ id ] = undefined;
	if ( isdefined( self ) && isdefined( self.coop_remote_kill ) )
		return;
	if ( !level.coop.active )
		return;
	if ( level.coop.ishost || ( isdefined( attacker ) && attacker == level.player ) )
		send( "K|" + id );
}

ev_kill( slot, tok )
{
	if ( tok.size < 3 )
		return;
	ai = level.coop.ai[ tok[ 2 ] ];
	if ( !isdefined( ai ) || !isalive( ai ) )
		return;
	if ( isdefined( ai.magic_bullet_shield ) && ai.magic_bullet_shield )
		return; // heroes are never killed remotely
	ai.coop_remote_kill = true;
	ai dodamage( ai.health + 500, ai.origin );
}

// ---------------------------------------------------------------------------------------------
// checkpoints: only the host decides; everyone saves when it does
// ---------------------------------------------------------------------------------------------

on_tryautosave( filename )
{
	c = level.coop;
	if ( !c.active || c.ishost )
		return false;
	if ( players() < 2 )
		return false;
	if ( isdefined( c.allow_save ) )
		return false;
	return true; // client: wait for the host's checkpoint
}

on_autosaved( filename )
{
	if ( level.coop.active && level.coop.ishost )
		send( "S|" + filename );
}

can_save()
{
	c = level.coop;
	if ( !c.active )
		return true;
	if ( c.down )
		return false;
	for ( i = 0; i < c.max; i++ )
		if ( c.downed[ i ] && slot_connected( i ) )
			return false;
	return true;
}

ev_save( slot, tok )
{
	if ( level.coop.ishost || tok.size < 3 )
		return;
	thread client_save( tok[ 2 ] );
}

client_save( filename )
{
	c = level.coop;
	if ( c.down || !isalive( level.player ) || level.missionfailed )
		return;
	if ( flag( "game_saving" ) )
		return;
	flag_set( "game_saving" );
	saveId = saveGameNoCommit( filename, maps\_autosave::getDescription() );
	if ( saveId >= 0 )
	{
		wait 0.05;
		if ( !isSaveRecentlyLoaded() )
		{
			commitSave( saveId );
			level.lastSaveTime = gettime();
			log( "checkpoint " + filename );
		}
	}
	flag_clear( "game_saving" );
}

// ---------------------------------------------------------------------------------------------
// mission fail: whoever fails, the whole squad fails (and everyone reloads the shared checkpoint)
// ---------------------------------------------------------------------------------------------

on_missionfailed()
{
	c = level.coop;
	if ( !c.active )
		return false;
	if ( isdefined( c.fail_from_net ) || level.missionfailed )
		return false;
	c.fail_sent = true;
	send( "X|" + sanitize( getdvar( "ui_deadquote" ) ) );
	return false;
}

ev_fail( slot, tok )
{
	c = level.coop;
	if ( level.missionfailed || !isalive( level.player ) )
		return;
	if ( tok.size >= 3 && tok[ 2 ] != "" )
		setdvar( "ui_deadquote", tok[ 2 ] );
	c.fail_from_net = true;
	iprintlnbold( c.names[ slot ] + " - mission failed" );
	thread maps\_utility::missionFailedWrapper();
}

watch_death()
{
	level.player waittill( "death" );
	c = level.coop;
	if ( c.active && !isdefined( c.fail_from_net ) && !isdefined( c.fail_sent ) )
		send( "X|" + sanitize( getdvar( "ui_deadquote" ) ) );
}

// ---------------------------------------------------------------------------------------------
// level end: the host ends the level; clients that got there first wait for it
// ---------------------------------------------------------------------------------------------

on_nextmission()
{
	c = level.coop;
	if ( !c.active || players() < 2 )
		return false;
	if ( c.ishost )
	{
		if ( !isdefined( c.end_sent ) )
		{
			c.end_sent = true;
			send( "E|" + level.script );
		}
		return false;
	}
	if ( isdefined( c.end_ok ) )
		return false;
	if ( !isdefined( c.end_waiting ) )
	{
		c.end_waiting = true;
		level.player enableinvulnerability();
		iprintlnbold( "Waiting for the host to finish the mission..." );
	}
	return true;
}

ev_levelend( slot, tok )
{
	c = level.coop;
	if ( c.ishost || isdefined( c.end_ok ) )
		return;
	if ( tok.size >= 3 && tok[ 2 ] != level.script )
		return;
	c.end_ok = true;
	thread maps\_endmission::_nextmission();
}

// ---------------------------------------------------------------------------------------------
// late join: replay set flags, then move the newcomer to the host
// ---------------------------------------------------------------------------------------------

send_catchup( slot )
{
	if ( !level.coop.ishost )
		return;
	log( "catch-up for slot " + slot );
	keys = getarraykeys( level.flag );
	n = 0;
	for ( i = 0; i < keys.size; i++ )
	{
		k = keys[ i ];
		if ( !level.flag[ k ] || maps\_coop_levels::is_local_flag( k ) )
			continue;
		send( "F|" + k + "|1" );
		n++;
		if ( n % 40 == 0 )
			wait 0.05;
	}
	o = level.player.origin;
	send( "Y|" + slot + "|" + int( o[ 0 ] ) + "|" + int( o[ 1 ] ) + "|" + int( o[ 2 ] ) );
}

ev_teleport_to( slot, tok )
{
	if ( tok.size < 6 || int( tok[ 2 ] ) != level.coop.slot )
		return;
	if ( player_linked() )
		return;
	pos = ( int( tok[ 3 ] ), int( tok[ 4 ] ), int( tok[ 5 ] ) );
	level.player setorigin( maps\_coop_player::safe_spot_near( pos ) );
	iprintlnbold( "Joined in progress - moved to " + level.coop.names[ slot ] );
}
