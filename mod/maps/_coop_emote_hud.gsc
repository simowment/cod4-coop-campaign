// CoD4 SP Coop - emote wheel HUD: 8 tiles on a ring around the crosshair (slice 1 at the top, then
// clockwise), the lit one gold, a centre tile naming the pick and a dot that follows the cursor.
// Only the "white" shader (precached in _coop::preinit) and plain strings (loc_warnings is 0).

show()
{
	hide();
	c = level.coop;
	h = spawnstruct();
	h.bg = [];
	h.tx = [];
	h.sel = -2;
	for ( i = 0; i < 8; i++ )
	{
		ang = i * 45;
		x = sin( ang ) * 150;
		y = 0 - cos( ang ) * 108;
		b = elem( x, y, 10 );
		b setshader( "white", 118, 30 );
		b.color = ( 0, 0, 0 );
		b.coop_alpha = 0.6;
		h.bg[ i ] = b;
		t = elem( x, y, 12 );
		t.fontscale = 1.25;
		t settext( ( i + 1 ) + "  " + c.emotes[ c.wheel_ids[ i ] ].name );
		t.color = ( 1, 1, 1 );
		t.coop_alpha = 1;
		h.tx[ i ] = t;
	}
	h.cbg = elem( 0, 0, 10 );
	h.cbg setshader( "white", 132, 40 );
	h.cbg.color = ( 0.05, 0.05, 0.05 );
	h.cbg.coop_alpha = 0.75;
	h.ctx = elem( 0, 0, 12 );
	h.ctx.fontscale = 1.5;
	h.ctx settext( "EMOTES" );
	h.ctx.color = ( 1, 0.82, 0.3 );
	h.ctx.coop_alpha = 1;
	h.dot = elem( 0, 0, 14 );
	h.dot setshader( "white", 6, 6 );
	h.dot.color = ( 1, 0.82, 0.3 );
	h.dot.coop_alpha = 0.9;
	h.hint = elem( 0, 172, 12 );
	h.hint.fontscale = 1.0;
	h.hint settext( "Look at an emote and release  -  1-8 pick  -  Aim cancels" );
	h.hint.color = ( 0.85, 0.85, 0.85 );
	h.hint.coop_alpha = 0.9;
	c.wheel_hud = h;
	all = elems( h );
	for ( i = 0; i < all.size; i++ )
	{
		all[ i ].alpha = 0;
		all[ i ] fadeovertime( 0.12 );
		all[ i ].alpha = all[ i ].coop_alpha;
	}
}

elem( x, y, sort )
{
	e = newHudElem();
	e.alignX = "center";
	e.alignY = "middle";
	e.horzAlign = "center";
	e.vertAlign = "middle";
	e.x = x;
	e.y = y;
	e.sort = sort;
	e.foreground = true;
	e.alpha = 0;
	return e;
}

elems( h )
{
	a = [];
	for ( i = 0; i < 8; i++ )
	{
		a[ a.size ] = h.bg[ i ];
		a[ a.size ] = h.tx[ i ];
	}
	a[ a.size ] = h.cbg;
	a[ a.size ] = h.ctx;
	a[ a.size ] = h.dot;
	a[ a.size ] = h.hint;
	return a;
}

update( w )
{
	h = level.coop.wheel_hud;
	if ( !isdefined( h ) )
		return;
	h.dot.x = w.cx * 6;
	h.dot.y = 0 - w.cy * 6;
	if ( w.sel == h.sel )
		return;
	if ( h.sel >= 0 )
		paint( h, h.sel, false );
	h.sel = w.sel;
	if ( h.sel >= 0 )
	{
		paint( h, h.sel, true );
		h.ctx settext( level.coop.emotes[ level.coop.wheel_ids[ h.sel ] ].name );
		h.ctx.color = ( 1, 1, 1 );
	}
	else
	{
		h.ctx settext( "EMOTES" );
		h.ctx.color = ( 1, 0.82, 0.3 );
	}
}

paint( h, i, lit )
{
	if ( lit )
	{
		h.bg[ i ].color = ( 1, 0.76, 0.2 );
		h.bg[ i ].alpha = 0.92;
		h.bg[ i ] scaleovertime( 0.08, 130, 34 );
		h.tx[ i ].color = ( 0.08, 0.06, 0.02 );
	}
	else
	{
		h.bg[ i ].color = ( 0, 0, 0 );
		h.bg[ i ].alpha = 0.6;
		h.bg[ i ] scaleovertime( 0.08, 118, 30 );
		h.tx[ i ].color = ( 1, 1, 1 );
	}
}

hide()
{
	c = level.coop;
	if ( !isdefined( c.wheel_hud ) )
		return;
	all = elems( c.wheel_hud );
	for ( i = 0; i < all.size; i++ )
		all[ i ] destroy();
	c.wheel_hud = undefined;
}
