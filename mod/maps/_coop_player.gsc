// CoD4 SP Coop - player experience: downed / revive / bleed-out, squad HUD.
//
// With a squad, lethal damage puts you DOWN instead of killing you: you drop prone and invulnerable,
// enemies ignore you, and you can still fire your sidearm. A squadmate holds [Use] next to you to
// revive. If you bleed out while someone is still up, you respawn next to them. The mission is only
// lost when everyone is down at once (or when the level fails it on purpose).

#include maps\_utility;
#include common_scripts\utility;

precache()
{
}

init()
{
	c = level.coop;
	c.bleedout_time = 45;
	c.revive_time = 3;
	c.revive_dist = 80;
	thread watch_health();
	thread revive_others();
	thread squad_hud();
}

in_squad()
{
	return level.coop.active && maps\_coop::players() > 1;
}

// ---------------------------------------------------------------------------------------------
// going down
// ---------------------------------------------------------------------------------------------

watch_health()
{
	level.player endon( "death" );
	for ( ;; )
	{
		level.player waittill_either_damage_or_frame();
		c = level.coop;
		if ( c.down || !in_squad() || isdefined( c.allow_death ) )
			continue;
		if ( !isalive( level.player ) )
			return;
		// the engine leaves the player at 1-2 hp with a short invulnerability window on a lethal hit
		if ( level.player.health <= max( 2, level.player.maxhealth * 0.12 ) )
			go_down();
	}
}

waittill_either_damage_or_frame()
{
	self endon( "death" );
	self thread notify_next_frame( "coop_tick" );
	self waittill_any( "damage", "coop_tick" );
}

notify_next_frame( msg )
{
	wait 0.05;
	self notify( msg );
}

go_down()
{
	c = level.coop;
	p = level.player;
	c.down = true;
	c.down_since = gettime();
	p enableinvulnerability();
	p.ignoreme = true;
	p allowstand( false );
	p allowcrouch( false );
	p allowsprint( false );
	p setstance( "prone" );
	p shellshock( "default", 3 );
	maps\_coop::send( "D|1" );
	maps\_coop::log( "downed" );
	thread downed_hud();
	thread bleed_out();
	check_wipe();
}

get_up( reason )
{
	c = level.coop;
	p = level.player;
	if ( !c.down )
		return;
	c.down = false;
	level notify( "coop_up" );
	p allowstand( true );
	p allowcrouch( true );
	p allowsprint( true );
	p setstance( "stand" );
	p.ignoreme = false;
	p.health = int( p.maxhealth * 0.5 );
	p disableinvulnerability();
	maps\_coop::send( "D|0" );
	maps\_coop::log( "up: " + reason );
}

bleed_out()
{
	level endon( "coop_up" );
	wait level.coop.bleedout_time;
	c = level.coop;
	// respawn on a squadmate who is still standing
	for ( s = 0; s < c.max; s++ )
	{
		if ( s == c.slot || !maps\_coop::slot_connected( s ) || c.downed[ s ] )
			continue;
		pos = ( fgetarg( s, 0 ), fgetarg( s, 1 ), fgetarg( s, 2 ) );
		level.player setorigin( safe_spot_near( pos ) );
		iprintlnbold( "You regrouped with " + c.names[ s ] );
		get_up( "bleed out respawn" );
		return;
	}
	wipe();
}

// everyone down at the same time -> the squad loses
check_wipe()
{
	c = level.coop;
	if ( !c.down )
		return;
	for ( s = 0; s < c.max; s++ )
	{
		if ( s == c.slot || !maps\_coop::slot_connected( s ) )
			continue;
		if ( !c.downed[ s ] )
			return;
	}
	wipe();
}

wipe()
{
	c = level.coop;
	if ( isdefined( c.wiped ) )
		return;
	c.wiped = true;
	maps\_coop::log( "squad wiped" );
	c.allow_death = true;
	level.player disableinvulnerability();
	level.player enablehealthshield( false );
	level.player dodamage( level.player.health + 10000, level.player.origin );
}

ev_downed( slot, tok )
{
	c = level.coop;
	if ( tok.size < 3 )
		return;
	c.downed[ slot ] = ( tok[ 2 ] == "1" );
	if ( c.downed[ slot ] )
		iprintln( c.names[ slot ] + " is down!" );
	else
		iprintln( c.names[ slot ] + " is back up" );
	check_wipe();
}

// ---------------------------------------------------------------------------------------------
// reviving
// ---------------------------------------------------------------------------------------------

revive_others()
{
	c = level.coop;
	hint = undefined;
	progress = 0;
	target = -1;
	for ( ;; )
	{
		wait 0.05;
		best = -1;
		if ( !c.down && isalive( level.player ) )
		{
			for ( s = 0; s < c.max; s++ )
			{
				if ( s == c.slot || !c.downed[ s ] || !maps\_coop::slot_connected( s ) )
					continue;
				pos = ( fgetarg( s, 0 ), fgetarg( s, 1 ), fgetarg( s, 2 ) );
				if ( distance( level.player.origin, pos ) < c.revive_dist )
				{
					best = s;
					break;
				}
			}
		}
		if ( best != target )
		{
			progress = 0;
			target = best;
		}
		if ( target < 0 )
		{
			if ( isdefined( hint ) )
			{
				hint destroy();
				hint = undefined;
			}
			continue;
		}
		if ( !isdefined( hint ) )
			hint = make_center_text( 50, 1.4 );
		if ( level.player usebuttonpressed() )
		{
			progress += 0.05;
			pct = int( progress * 100 / c.revive_time );
			hint settext( "Reviving " + c.names[ target ] + "..." );
			if ( progress >= c.revive_time )
			{
				maps\_coop::send( "V|" + target );
				iprintln( "You revived " + c.names[ target ] );
				c.downed[ target ] = false;
				progress = 0;
			}
		}
		else
		{
			progress = 0;
			hint settext( "Hold [USE] to revive " + c.names[ target ] );
		}
	}
}

ev_revive( slot, tok )
{
	c = level.coop;
	if ( tok.size < 3 || int( tok[ 2 ] ) != c.slot )
		return;
	if ( !c.down )
		return;
	iprintlnbold( c.names[ slot ] + " revived you" );
	get_up( "revived by " + slot );
}

// a point next to a squadmate that we can stand on
safe_spot_near( pos )
{
	offsets = [];
	offsets[ 0 ] = ( 40, 0, 0 );
	offsets[ 1 ] = ( -40, 0, 0 );
	offsets[ 2 ] = ( 0, 40, 0 );
	offsets[ 3 ] = ( 0, -40, 0 );
	for ( i = 0; i < offsets.size; i++ )
	{
		p = pos + offsets[ i ];
		if ( !bullettracepassed( pos + ( 0, 0, 40 ), p + ( 0, 0, 40 ), false, undefined ) )
			continue;
		tr = bullettrace( p + ( 0, 0, 40 ), p - ( 0, 0, 100 ), false, undefined );
		if ( tr[ "fraction" ] < 1 )
			return tr[ "position" ];
	}
	return pos;
}

// ---------------------------------------------------------------------------------------------
// HUD
// ---------------------------------------------------------------------------------------------

make_center_text( y, scale )
{
	h = newHudElem();
	h.alignX = "center";
	h.alignY = "middle";
	h.horzAlign = "center";
	h.vertAlign = "middle";
	h.y = y;
	h.fontscale = scale;
	h.foreground = true;
	h.alpha = 1;
	return h;
}

downed_hud()
{
	c = level.coop;
	h = make_center_text( -40, 1.6 );
	h.color = ( 1, 0.3, 0.3 );
	h settext( "YOU ARE DOWN - a squadmate can revive you" );
	t = make_center_text( -20, 1.3 );
	t.label = &"";
	start = gettime();
	while ( c.down )
	{
		left = int( c.bleedout_time - ( gettime() - start ) / 1000 );
		if ( left < 0 )
			left = 0;
		t setvalue( left );
		wait 0.25;
	}
	h destroy();
	t destroy();
}

// top-left: one row per squadmate - name, health bar, status
squad_hud()
{
	c = level.coop;
	rows = [];
	for ( ;; )
	{
		wait 0.25;
		y = 110;
		for ( s = 0; s < c.max; s++ )
		{
			show = s != c.slot && maps\_coop::slot_connected( s );
			if ( !show )
			{
				if ( isdefined( rows[ s ] ) )
				{
					rows[ s ].name destroy();
					rows[ s ].bg destroy();
					rows[ s ].bar destroy();
					rows[ s ] = undefined;
				}
				continue;
			}
			if ( !isdefined( rows[ s ] ) )
			{
				r = spawnstruct();
				r.name = newHudElem();
				r.name.x = 8;
				r.name.alignX = "left";
				r.name.horzAlign = "left";
				r.name.vertAlign = "top";
				r.name.fontscale = 1.2;
				r.name.foreground = true;
				r.name settext( c.names[ s ] );
				r.bg = newHudElem();
				r.bg.x = 8;
				r.bg.horzAlign = "left";
				r.bg.vertAlign = "top";
				r.bg.alpha = 0.4;
				r.bg.color = ( 0, 0, 0 );
				r.bg setshader( "white", 82, 5 );
				r.bar = newHudElem();
				r.bar.x = 9;
				r.bar.horzAlign = "left";
				r.bar.vertAlign = "top";
				r.bar.alpha = 0.85;
				r.bar setshader( "white", 80, 3 );
				r.last = -1;
				rows[ s ] = r;
			}
			r = rows[ s ];
			r.name.y = y;
			r.bg.y = y + 14;
			r.bar.y = y + 15;
			hp = c.health[ s ];
			if ( c.downed[ s ] )
			{
				r.name.color = ( 1, 0.3, 0.3 );
				r.bar.color = ( 1, 0.2, 0.2 );
				hp = 100;
			}
			else
			{
				r.name.color = ( 1, 1, 1 );
				r.bar.color = ( 0.4, 1, 0.4 );
			}
			w = int( max( 1, min( 80, hp * 0.8 ) ) );
			if ( w != r.last )
			{
				r.bar setshader( "white", w, 3 );
				r.last = w;
			}
			y += 26;
		}
	}
}
