/**
	memutils CircularBuffer leftover store, same peekDst/putN/take surface
	as UnreadRing so sockets.d can A/B the two implementations.

	The buffer lives behind a pointer. Embedding CircularBuffer in Slot
	would give Slot a destructor (ThreadMem freeArray) that ChoppedVector
	cannot call from its @nogc nothrow clear.
*/
module eventcore.drivers.libasync.circ_unread;

version (EventcoreLibasyncDriver):
version (LibasyncUseCircBuf):

import memutils.circularbuffer;
import memutils.utils : ThreadMem;
import core.stdc.stdlib : free, malloc;

enum size_t circUnreadInitCap = 64 * 1024;

private alias Circ = CircularBuffer!(ubyte, 0, ThreadMem);

struct CircUnread {
	private Circ* inner;

@safe: nothrow:

	@property size_t length() const { return inner ? inner.length : 0; }
	@property bool empty() const { return !inner || inner.empty; }
	@property size_t freeSpace() const { return inner ? inner.freeSpace : 0; }
	@property size_t cap() const { return inner ? inner.capacity : 0; }

	void dispose()
	@trusted {
		if (!inner) return;
		try destroy(*inner);
		catch (Exception e) assert(false, e.msg);
		free(inner);
		inner = null;
	}

	void reserve(size_t extra)
	@trusted {
		if (!inner) {
			import core.stdc.string : memset;
			inner = cast(Circ*)malloc(Circ.sizeof);
			if (!inner) assert(false, "CircUnread OOM");
			memset(inner, 0, Circ.sizeof);
		}
		auto need = inner.length + extra;
		if (need <= inner.capacity) return;
		auto ncap = inner.capacity ? inner.capacity : circUnreadInitCap;
		while (ncap < need) ncap *= 2;
		try inner.capacity = ncap;
		catch (Exception e) assert(false, e.msg);
	}

	ubyte[] peekDst()
	@trusted {
		if (!inner || !inner.capacity || inner.full) return null;
		import std.exception : assumeWontThrow;
		return assumeWontThrow(inner.peekDst());
	}

	void putN(size_t n)
	{
		debug assert(inner);
		inner.putN(n);
	}

	size_t take(scope ubyte[] dst)
	@trusted {
		if (!inner) return 0;
		auto n = dst.length;
		if (n > inner.length) n = inner.length;
		if (!n) return 0;
		import core.stdc.string : memcpy;
		import std.exception : assumeWontThrow;
		size_t done;
		while (done < n) {
			auto p = assumeWontThrow(inner.peek());
			auto k = p.length;
			if (k > n - done) k = n - done;
			if (!k) break;
			memcpy(dst.ptr + done, p.ptr, k);
			assumeWontThrow(inner.popFrontN(k));
			done += k;
		}
		return done;
	}

	/// Same leftover drain as `UnreadRingMixin.unreadDrainRecv`.
	size_t drainRecv(Recv)(scope Recv recv, ref bool sockMaybeMore,
			size_t drainCap = circUnreadInitCap, int retryLimit = 100)
	{
		if (!sockMaybeMore) return 0;
		if (!cap) reserve(circUnreadInitCap);
		size_t got;
		int retries;
		for (;;) {
			if (!freeSpace || got >= drainCap)
				break;
			ubyte[] dst = peekDst();
			if (!dst.length) {
				sockMaybeMore = false;
				break;
			}
			if (dst.length > drainCap - got)
				dst = dst[0 .. drainCap - got];
			auto n = recv(dst);
			if (n > 0) {
				putN(cast(size_t) n);
				got += cast(size_t) n;
				retries = 0;
				continue;
			}
			if (n < 0 && ++retries < retryLimit)
				continue;
			sockMaybeMore = false;
			break;
		}
		return got;
	}
}
