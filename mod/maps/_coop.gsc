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
	if ( !isdefined( c.slot ) )
		c.slot = -1; // no native proxy (or unsupported exe): plain single player
	c.active = ( c.slot >= 0 );
	c.max = 4;
	c.names = [];
	c.downed = [];
	c.health = [];
	c.ai = [];
	c.pending_flags = [];
	c.local_flags = [];
	c.shared_flags = [];
	c.cleared_at = [];
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
	maps\_coop_puppet::puppet_precache();
	maps\_coop_player::player_precache();

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

	maps\_coop_levels::levels_main();
	openfile( "coop", "tick", 0 ); // new level: level time restarts, that is not a checkpoint reload
	thread net_loop();
	thread track_shots();
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
		// a loaded checkpoint rewinds level time; events still queued belong to the dead timeline
		if ( openfile( "coop", "tick", gettime() ) > gettime() + 500 )
			drain_stale_events();
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

drain_stale_events()
{
	n = 0;
	for ( i = 0; i < 512; i++ )
	{
		s = freadln();
		if ( !isdefined( s ) || s == "" )
			break;
		tok = strtok( s, "|" );
		if ( tok.size >= 2 && tok[ 0 ] == "s" )
			sys_event( tok ); // joins/leaves still matter
		else
			n++;
	}
	level.coop.fail_from_net = undefined;
	level.coop.fail_sent = undefined;
	log( "checkpoint reload: dropped " + n + " stale events" );
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
		if ( isdefined( c.end_waiting ) && !isdefined( c.end_ok ) )
		{
			c.end_ok = true;
			thread maps\_endmission::_nextmission();
		}
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
	if ( !value )
		c.cleared_at[ msg ] = gettime();
	v = "0";
	if ( value )
		v = "1";
	send( "F|" + msg + "|" + v );
}

ev_flag( slot, tok )
{
	if ( tok.size < 4 )
		return;
	c = level.coop;
	if ( c.ishost && tok[ 3 ] == "1" && isdefined( c.cleared_at[ tok[ 2 ] ] ) && gettime() - c.cleared_at[ tok[ 2 ] ] < 10000 )
		return; // stale set from a client that has not caught up with our clear yet
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
// triggers: a local player's hit is replayed on everyone else's copy of that trigger.
//
// Budget: the SP script VM has a small fixed variable pool and big levels (bog_a: 337 triggers,
// 260 spawners) already use most of it. So no thread or field per trigger: one poller tests
// "level.player istouching" against the touch triggers, and the network id is the entity number
// (map entities get the same number on every machine; getentnum/getentbynum are dev builtins the
// proxy enables). Only the few use/lookat/damage triggers get a waiter, since touch says nothing there.
// State lives in small sparse arrays keyed by entity number, holding only triggers that fired.
// ---------------------------------------------------------------------------------------------

build_trigger_ids()
{
	c = level.coop;
	c.trig_last = [];    // entnum -> last local/remote fire time
	c.trig_inside = [];  // entnum -> true while the local player is inside
	c.trig_done = [];    // entnum -> replayed trigger_once
	c.trig_count = 0;
	waiters = 0;
	classes = [];
	classes[ 0 ] = "trigger_use";
	classes[ 1 ] = "trigger_use_touch";
	classes[ 2 ] = "trigger_lookat";
	classes[ 3 ] = "trigger_damage";
	for ( ci = 0; ci < classes.size; ci++ )
	{
		ents = getentarray( classes[ ci ], "classname" );
		for ( i = 0; i < ents.size && waiters < 48; i++ )
		{
			ents[ i ] thread watch_event_trigger();
			waiters++;
		}
	}
	c.trig_count = waiters;
	thread poll_touch_triggers();
}

poll_touch_triggers()
{
	c = level.coop;
	classes = [];
	classes[ 0 ] = "trigger_multiple";
	classes[ 1 ] = "trigger_once";
	classes[ 2 ] = "trigger_radius";
	for ( ;; )
	{
		wait 0.1;
		if ( !c.active || !isalive( level.player ) )
			continue;
		for ( ci = 0; ci < classes.size; ci++ )
		{
			ents = getentarray( classes[ ci ], "classname" );
			for ( i = 0; i < ents.size; i++ )
			{
				t = ents[ i ];
				if ( !( level.player istouching( t ) ) )
					continue;
				n = t getentnum();
				if ( isdefined( c.trig_inside[ n ] ) )
					continue; // still inside since last poll: only entering counts
				c.trig_inside[ n ] = gettime();
				local_trigger_hit( t, n );
			}
			ents = undefined;
		}
		// forget triggers we have left (sparse: only the few we touched are in the array)
		keys = getarraykeys( c.trig_inside );
		for ( k = 0; k < keys.size; k++ )
		{
			t = getentbynum( keys[ k ] );
			if ( !isdefined( t ) || !( level.player istouching( t ) ) )
				c.trig_inside[ keys[ k ] ] = undefined;
		}
	}
}

watch_event_trigger()
{
	self endon( "death" );
	for ( ;; )
	{
		self waittill( "trigger", other );
		if ( isdefined( other ) && other == level.player )
			local_trigger_hit( self, self getentnum() );
	}
}

local_trigger_hit( t, n )
{
	c = level.coop;
	if ( isdefined( t.coop_local ) || isdefined( c.trig_done[ n ] ) )
		return; // level module marked it player-local (kill volumes, hints...), or already replayed
	now = gettime();
	if ( isdefined( c.trig_last[ n ] ) && now - c.trig_last[ n ] < 1000 )
		return; // includes our own replay of a remote hit this frame
	c.trig_last[ n ] = now;
	send( "T|" + n );
}

ev_trigger( slot, tok )
{
	c = level.coop;
	if ( tok.size < 3 )
		return;
	n = int( tok[ 2 ] );
	t = getentbynum( n );
	if ( !isdefined( t ) || !isdefined( t.classname ) || getsubstr( t.classname, 0, 8 ) != "trigger_" )
		return;
	if ( isdefined( t.coop_local ) || isdefined( c.trig_done[ n ] ) )
		return;
	now = gettime();
	if ( isdefined( c.trig_last[ n ] ) && now - c.trig_last[ n ] < 1000 )
		return; // we hit it ourselves a moment ago
	c.trig_last[ n ] = now;
	t notify( "trigger", level.player );
	if ( isdefined( t ) && t.classname == "trigger_once" )
	{
		c.trig_done[ n ] = true;
		t trigger_off(); // keep our own player from firing it a second time
	}
}

// ---------------------------------------------------------------------------------------------
// AI deaths: host reports every death, clients report kills by their player. Ids are the spawner's
// Radiant export number + how many AI that export has spawned so far, identical on every machine for
// scripted spawns. Assigned from the stock global spawn-function list (no thread per spawner).
// ---------------------------------------------------------------------------------------------

build_ai_ids()
{
	c = level.coop;
	c.ai_seq = [];
	c.spawner_count = 0;
	teams = [];
	teams[ 0 ] = "axis";
	teams[ 1 ] = "allies";
	teams[ 2 ] = "neutral";
	for ( i = 0; i < teams.size; i++ )
		if ( isdefined( level.spawn_funcs ) && isdefined( level.spawn_funcs[ teams[ i ] ] ) )
			add_global_spawn_function( teams[ i ], ::on_ai_spawned );
	ai = getaiarray();
	for ( i = 0; i < ai.size; i++ )
		if ( isdefined( ai[ i ].export ) )
			ai[ i ] register_ai( "a" + ai[ i ].export );
}

on_ai_spawned()
{
	if ( !isdefined( self.export ) || isdefined( self.coop_id ) )
		return;
	c = level.coop;
	if ( !isdefined( c.ai_seq[ self.export ] ) )
		c.ai_seq[ self.export ] = 0;
	c.ai_seq[ self.export ]++;
	self register_ai( "e" + self.export + "#" + c.ai_seq[ self.export ] );
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
	if ( c.down || !isalive( level.player ) || level.missionfailed || isdefined( level.nextmission ) )
		return;
	if ( flag( "game_saving" ) || !flag( "can_save" ) )
		return;
	if ( level.player.health < level.player.maxhealth * 0.3 )
		return; // would trap us in a fail/reload loop; the next host checkpoint will catch us
	
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
	if ( isdefined( level.nextmission ) || isdefined( c.end_waiting ) )
		return true; // the mission is already won
	if ( isdefined( c.fail_from_net ) || level.missionfailed )
		return false;
	c.fail_sent = true;
	send( "X|" + sanitize( getdvar( "ui_deadquote" ) ) );
	return false;
}

ev_fail( slot, tok )
{
	c = level.coop;
	if ( level.missionfailed || !isalive( level.player ) || isdefined( level.nextmission ) || isdefined( c.end_waiting ) )
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
