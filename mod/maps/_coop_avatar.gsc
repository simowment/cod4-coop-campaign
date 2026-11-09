// CoD4 coop: remote players drawn as real AI "avatars".
//
// The scripted puppet (_coop_puppet.gsc) has to fake locomotion with animscripted, which cannot blend:
// gait changes, turns and cycle restarts can pop. An avatar is a real friendly soldier that is *steered*
// to the remote player's network pose (setgoalpos, orientmode face angle, allowedstances); the engine's
// own animscripts pick and blend walk, run, strafe, stop and turn anims, like any campaign AI. It does not
// think for itself (ignoreall, pacifist), cannot die, carries no friendly-fire penalty, and the remote
// player's real shots are replayed from it. Levels where AI cannot be borrowed or is held still fall back
// to the puppet.

#include maps\_utility;
#include common_scripts\utility;

init()
{
	c = level.coop;
	c.avatars = [];
	c.avatar_thread = [];
	// killhouse scripts hold every extra soldier still
	// off by default: the blended puppet works on every map (avatars need path nodes, e.g. none in killhouse)
	c.no_avatar = getdvar( "coop_avatar" ) != "1";
}

// true while slot is drawn by a live avatar (the puppet stays hidden)
active( slot )
{
	c = level.coop;
	return isdefined( c.avatars ) && isdefined( c.avatars[ slot ] ) && isalive( c.avatars[ slot ] );
}

ensure( slot )
{
	c = level.coop;
	if ( !isdefined( c.avatars ) || c.no_avatar || isdefined( c.avatar_thread[ slot ] ) )
		return;
	c.avatar_thread[ slot ] = true;
	level thread avatar_think( slot );
}

avatar_think( slot )
{
	level endon( "coop_stop" );
	c = level.coop;
	fails = 0;
	a = undefined;
	still_since = gettime();
	still_at = ( 0, 0, 0 );
	for ( ;; )
	{
		if ( c.no_avatar )
			break;
		connected = openfile( "coop", "connected", slot ) && fgetarg( slot, 10 ) < 3000;
		pos = ( fgetarg( slot, 0 ), fgetarg( slot, 1 ), fgetarg( slot, 2 ) );
		yaw = fgetarg( slot, 4 );
		if ( !connected || ( pos[ 0 ] == 0 && pos[ 1 ] == 0 ) )
		{
			if ( isdefined( a ) && isalive( a ) && !a.coop_hidden )
			{
				a hide();
				a.coop_hidden = true;
			}
			wait 0.25;
			continue;
		}
		if ( !isdefined( a ) || !isalive( a ) )
		{
			c.avatars[ slot ] = undefined;
			a = maps\_coop_bot::spawn_ally_ai( maps\_coop_bot::node_near( pos, pos ), yaw, c.names[ slot ] );
			if ( !isdefined( a ) )
			{
				fails++;
				if ( fails >= 3 )
				{
					maps\_coop::log( "avatar " + slot + ": no AI can be spawned in " + level.script + ", using the puppet" );
					c.no_avatar = true;
					break;
				}
				wait 2;
				continue;
			}
			a.ignoreall = true;
			a.pacifist = true;
			a.goalradius = 12;
			a.coop_avatar = slot;
			a.coop_hidden = false;
			a.coop_stance = "";
			a.coop_weapon = "";
			a teleport( pos, ( 0, yaw, 0 ) );
			c.avatars[ slot ] = a;
			still_at = a.origin;
			still_since = gettime();
			maps\_coop::log( "avatar " + slot + ": real AI '" + a.classname + "'" );
		}
		a avatar_step( slot, pos, yaw );
		// held still by the level although the player is elsewhere: give the slot back to the puppet
		if ( a.coop_hidden || distance( a.origin, still_at ) > 16 || distance( a.origin, pos ) < 64 )
		{
			still_at = a.origin;
			still_since = gettime();
		}
		else if ( gettime() - still_since > 2500 )
		{
			maps\_coop::log( "avatar " + slot + ": AI does not move in " + level.script + ", using the puppet" );
			c.no_avatar = true;
			c.avatars[ slot ] = undefined;
			a stop_magic_bullet_shield();
			a delete();
			break;
		}
		wait 0.05;
	}
	c.avatar_thread[ slot ] = undefined;
}

avatar_step( slot, pos, yaw )
{
	flags = int( fgetarg( slot, 5 ) );
	hidden = ( flags & 32 ) != 0 || maps\_coop_levels::hide_puppets();
	if ( hidden )
	{
		if ( !self.coop_hidden )
		{
			self hide();
			self.coop_hidden = true;
		}
		self.coop_shots_skip = true;
		return;
	}
	if ( self.coop_hidden || distance( self.origin, pos ) > 300 )
	{
		// back from a ride, or left far behind: place it, then steer again
		self teleport( pos, ( 0, yaw, 0 ) );
		if ( self.coop_hidden )
		{
			self show();
			self.coop_hidden = false;
		}
		self.coop_goal = undefined;
	}
	stance = "stand";
	if ( ( flags & 16 ) != 0 || ( flags & 3 ) == 2 )
		stance = "prone";
	else if ( ( flags & 3 ) == 1 )
		stance = "crouch";
	if ( stance != self.coop_stance )
	{
		self allowedstances( stance );
		self.coop_stance = stance;
	}
	if ( !isdefined( self.coop_goal ) || distance( self.coop_goal, pos ) > 8 )
	{
		self setgoalpos( pos );
		self.coop_goal = pos;
	}
	if ( !isdefined( self.coop_face ) || abs( maps\_coop_puppet::angle180( self.coop_face - yaw ) ) > 3 )
	{
		self orientmode( "face angle", yaw );
		self.coop_face = yaw;
	}
	self maps\_coop_puppet::replay_shots( slot, flags, self.origin, fgetarg( slot, 3 ), yaw );
}
