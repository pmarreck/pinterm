## Ball physics primitives for the pinball table: 2D vector math, circle-vs-
## capsule contact (static walls and rotating flippers) and circle-vs-circle
## contact with restitution and active kick impulses.
Physics :: [].{
	vec : F64, F64 -> V
	vec = |x, y| { x, y }

	add : V, V -> V
	add = |a, b| { x: a.x + b.x, y: a.y + b.y }

	sub : V, V -> V
	sub = |a, b| { x: a.x - b.x, y: a.y - b.y }

	scale : V, F64 -> V
	scale = |a, k| { x: a.x * k, y: a.y * k }

	dot : V, V -> F64
	dot = |a, b| a.x * b.x + a.y * b.y

	length : V -> F64
	length = |a| (a.x * a.x + a.y * a.y).sqrt()

	clamp : F64, F64, F64 -> F64
	clamp = |v, lo, hi| if v < lo lo else if v > hi hi else v

	## Closest point to `p` on segment a-b (projection clamped to the endpoints).
	closest_on_segment : V, V, V -> V
	closest_on_segment = |p, a, b| {
		ab = sub(b, a)
		len2 = dot(ab, ab)
		t = if len2 <= 0.0 0.0 else clamp(dot(sub(p, a), ab) / len2, 0.0, 1.0)
		add(a, scale(ab, t))
	}

	## Static wall contact: capsule a-b of zero thickness.
	collide_segment : Ball, Seg, F64 -> Contact
	collide_segment = |ball, seg, restitution| contact_point(ball, closest_on_segment(ball.pos, seg.a, seg.b), 0.0, { x: 0.0, y: 0.0 }, restitution, 0.0)

	## Rotating capsule (flipper): pivot-relative angular velocity `omega`
	## (radians/s, positive clockwise in screen coordinates) moves the surface.
	collide_flipper : Ball, V, V, F64, F64, F64 -> Contact
	collide_flipper = |ball, pivot, tip, thickness, omega, restitution| {
		c = closest_on_segment(ball.pos, pivot, tip)
		rel = sub(c, pivot)
		surface = { x: -omega * rel.y, y: omega * rel.x }
		contact_point(ball, c, thickness, surface, restitution, 0.0)
	}

	## Moving wall segment (sliding bar): reflect relative to its velocity.
	collide_moving : Ball, Seg, F64, V, F64 -> Contact
	collide_moving = |ball, seg, thickness, surface, restitution| contact_point(ball, closest_on_segment(ball.pos, seg.a, seg.b), thickness, surface, restitution, 0.0)

	## Round bumper: reflect, then add an outward `kick` speed when struck.
	collide_circle : Ball, V, F64, F64, F64 -> Contact
	collide_circle = |ball, center, radius, restitution, kick| contact_point(ball, center, radius, { x: 0.0, y: 0.0 }, restitution, kick)

	## Kicking wall (slingshot): a segment that adds outward speed on impact.
	collide_kicker : Ball, Seg, F64, F64 -> Contact
	collide_kicker = |ball, seg, restitution, kick| contact_point(ball, closest_on_segment(ball.pos, seg.a, seg.b), 0.0, { x: 0.0, y: 0.0 }, restitution, kick)

	## Advance a ball by one fixed substep under gravity with a speed cap.
	integrate : Ball, F64, F64, F64 -> Ball
	integrate = |ball, gravity, dt, max_speed| {
		v1 = { x: ball.vel.x, y: ball.vel.y + gravity * dt }
		speed = length(v1)
		v2 = if speed > max_speed scale(v1, max_speed / speed) else v1
		{ ..ball, vel: v2, pos: add(ball.pos, scale(v2, dt)) }
	}
}

## Shared contact resolution against the nearest surface point `c` of a shape
## with extra radius `extra`: positional push-out along the contact normal, then
## an impulse reflecting the approach speed relative to the moving surface.
contact_point = |ball, c, extra, surface, restitution, kick| {
	d = Physics.sub(ball.pos, c)
	dist = Physics.length(d)
	reach = ball.r + extra
	if dist >= reach or dist <= 0.000001 {
		{ ball, hit: Bool.False, impact: 0.0 }
	} else {
		n = Physics.scale(d, 1.0 / dist)
		pos = Physics.add(c, Physics.scale(n, reach))
		rel = Physics.sub(ball.vel, surface)
		vn = Physics.dot(rel, n)
		if vn < 0.0 {
			bounced = Physics.sub(ball.vel, Physics.scale(n, (1.0 + restitution) * vn))
			vel = Physics.add(bounced, Physics.scale(n, kick))
			{ ball: { ..ball, pos, vel }, hit: Bool.True, impact: -vn }
		} else {
			{ ball: { ..ball, pos }, hit: Bool.True, impact: 0.0 }
		}
	}
}

V : { x : F64, y : F64 }

Ball : { pos : V, vel : V, r : F64 }

Seg : { a : V, b : V }

Contact : { ball : Ball, hit : Bool, impact : F64 }
