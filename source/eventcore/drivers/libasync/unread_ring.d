/**
	Libasync leftover store — `UnreadRingMixin` in memutils. Botan
	`TLSBlockingChannel` mixes the SecureMem instantiation; this
	driver holds `UnreadRing` (malloc). `drainTCP` parks kernel
	leftover only when no user read buffer is waiting. Do not switch
	the driver to SecureMem.
*/
module eventcore.drivers.libasync.unread_ring;

version (EventcoreLibasyncDriver):

public import memutils.unreadring : UnreadRing, UnreadRingMixin, unreadRingInitCap, unreadRingMove;
