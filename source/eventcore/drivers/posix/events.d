module eventcore.drivers.posix.events;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.consumablequeue : ConsumableQueue;
import eventcore.internal.utils : nogc_assert, mallocT, freeT;


version (linux) {
	nothrow @nogc extern (C) int eventfd(uint initval, int flags);
    import core.sys.linux.sys.eventfd : EFD_NONBLOCK, EFD_CLOEXEC;
}
version (Posix) {
	import core.sys.posix.unistd : close, read, write;
} else {
	import core.sys.windows.winsock2 : closesocket, AF_INET, SOCKET, SOCK_DGRAM,
		bind, connect, getsockname, send, socket;
}


final class PosixEventDriverEvents(Loop : PosixEventLoop, Sockets : EventDriverSockets) : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	private {
		Loop m_loop;
		Sockets m_sockets;
		ubyte[ulong.sizeof] m_buf;
	}

	this(Loop loop, Sockets sockets)
	@nogc {
		m_loop = loop;
		m_sockets = sockets;
	}

	package @property Loop loop() { return m_loop; }

	final override EventID create()
	{
		return createInternal(false);
	}

	package(eventcore) EventID createInternal(bool is_internal = true)
	@nogc {
		version (linux) {
			auto eid = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
			if (eid == -1) return EventID.invalid;
			// FIXME: avoid dynamic memory allocation for the queue
			auto id = m_loop.initFD!EventID(eid, FDFlags.internal,
				EventSlot(mallocT!(ConsumableQueue!EventCallback), is_internal));
			m_loop.registerFD(id, EventMask.read);
			m_loop.setNotifyCallback!(EventType.read)(id, &onEvent);
			releaseRef(id); // setNotifyCallback increments the reference count, but we need a value of 1 upon return
			assert(getRC(id) == 1);
			return id;
		} else {
			sock_t[2] fd;
			version (Posix) {
				import core.sys.posix.fcntl : fcntl, F_SETFL;
				import eventcore.drivers.posix.sockets : O_CLOEXEC;

				// create a pair of sockets to communicate between threads
				import core.sys.posix.sys.socket : SOCK_DGRAM, AF_UNIX, socketpair;
				if (() @trusted { return socketpair(AF_UNIX, SOCK_DGRAM, 0, fd); } () != 0)
					return EventID.invalid;

				assert(fd[0] != fd[1]);

				// use the first socket as the async receiver
				auto s = m_sockets.adoptDatagramSocketInternal(fd[0], true, true);

				() @trusted { fcntl(fd[1], F_SETFL, O_CLOEXEC); } ();
			} else {
				// fake missing socketpair support on Windows
				import std.socket : InternetAddress;
				scope addr = new InternetAddress(0x7F000001, 0);
				auto s = m_sockets.createDatagramSocketInternal(addr, null, DatagramCreateOptions.none, true);
				if (s == DatagramSocketFD.invalid) return EventID.invalid;
				fd[0] = cast(sock_t)s;
				if (!() @trusted {
					fd[1] = socket(AF_INET, SOCK_DGRAM, 0);
					int nl = addr.nameLen;
					import eventcore.internal.utils : print;
					if (bind(fd[1], addr.name, addr.nameLen) != 0)
						return false;
					assert(nl == addr.nameLen);
					if (getsockname(fd[0], addr.name, &nl) != 0)
						return false;
					if (connect(fd[1], addr.name, addr.nameLen) != 0)
						return false;
					return true;
				} ())
				{
					m_sockets.releaseRef(s);
					return EventID.invalid;
				}
			}

			m_sockets.receiveNoGC(s, m_buf, IOMode.once, &onSocketData);

			// use the second socket as the event ID and as the sending end for
			// other threads
			// FIXME: avoid dynamic memory allocation for the queue
			auto id = m_loop.initFD!EventID(fd[1], FDFlags.internal,
				EventSlot(mallocT!(ConsumableQueue!EventCallback), is_internal, s));
			assert(getRC(id) == 1);
			try m_sockets.userData!EventID(s) = id;
			catch (Exception e) assert(false, e.msg);
			return id;
		}
	}

	final override void trigger(EventID event, bool notify_all)
	{
		if (!isValid(event)) return;

		// make sure the event stays alive until all waiters have been notified.
		addRef(event);
		scope (exit) releaseRef(event);

		auto slot = getSlot(event);
		if (notify_all) {
			//log("emitting only for this thread (%s waiters)", m_fds[event].waiters.length);
			foreach (w; slot.waiters.consume) {
				//log("emitting waiter %s %s", cast(void*)w.funcptr, w.ptr);
				if (!isInternal(event)) m_loop.m_waiterCount--;
				w(event);
			}
		} else {
			if (!slot.waiters.empty) {
				if (!isInternal(event)) m_loop.m_waiterCount--;
				slot.waiters.consumeOne()(event);
			}
		}
	}

	final override void trigger(EventID event, bool notify_all)
	shared @trusted @nogc {
		import core.atomic : atomicStore;
		long count = notify_all ? long.max : 1;
		//log("emitting for all threads");
		version (Posix) .write(cast(int)event, &count, count.sizeof);
		else assert(send(cast(int)event, cast(const(ubyte*))&count, count.sizeof, 0) == count.sizeof);
	}

	final override void wait(EventID event, EventCallback on_event)
	@nogc {
		if (!isValid(event)) return;

		if (!isInternal(event)) m_loop.m_waiterCount++;
		getSlot(event).waiters.put(on_event);
	}

	final override void cancelWait(EventID event, EventCallback on_event)
	{
		import std.algorithm.searching : countUntil;
		import std.algorithm.mutation : remove;

		if (!isValid(event)) return;

		if (!isInternal(event)) m_loop.m_waiterCount--;
		getSlot(event).waiters.removePending(on_event);
	}

	version (linux) {
		private void onEvent(FD fd)
		@trusted {
			EventID event = cast(EventID)fd;
			ulong cnt;
			() @trusted { .read(cast(int)event, &cnt, cnt.sizeof); } ();
			trigger(event, cnt > 0);
		}
	} else {
		private void onSocketData(DatagramSocketFD s, IOStatus st, size_t, scope RefAddress)
		@nogc {
			// avoid infinite recursion in case of errors
			if (st == IOStatus.ok)
				m_sockets.receiveNoGC(s, m_buf, IOMode.once, &onSocketData);

			try {
				EventID evt = m_sockets.userData!EventID(s);
				scope doit = {
					trigger(evt, (cast(long[])m_buf)[0] > 1);
				}; // cast to nogc
				() @trusted { (cast(void delegate() @nogc)doit)(); } ();
			} catch (Exception e) assert(false, e.msg);
		}
	}

	override bool isValid(EventID handle)
	const {
		if (handle.value >= m_loop.m_fds.length) return false;
		return m_loop.m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	final override void addRef(EventID descriptor)
	{
		if (!isValid(descriptor)) return;

		assert(getRC(descriptor) > 0, "Adding reference to unreferenced event FD.");
		getRC(descriptor)++;
	}

	final override bool releaseRef(EventID descriptor)
	@nogc {
		if (!isValid(descriptor)) return true;

		nogc_assert(getRC(descriptor) > 0, "Releasing reference to unreferenced event FD.");
		if (--getRC(descriptor) == 0) {
			if (!isInternal(descriptor))
		 		m_loop.m_waiterCount -= getSlot(descriptor).waiters.length;
			() @trusted nothrow {
				try freeT(getSlot(descriptor).waiters);
				catch (Exception e) nogc_assert(false, e.msg);
			} ();
			version (linux) {
				m_loop.unregisterFD(descriptor, EventMask.read);
			} else {
				auto rs = getSlot(descriptor).recvSocket;
				m_sockets.cancelReceive(rs);
				m_sockets.releaseRef(rs);
			}
			m_loop.clearFD!EventSlot(descriptor);
			version (Posix) close(cast(int)descriptor);
			else () @trusted { closesocket(cast(SOCKET)descriptor); } ();
			return false;
		}
		return true;
	}

	final protected override void* rawUserData(EventID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	private EventSlot* getSlot(EventID id)
	@nogc {
		nogc_assert(id < m_loop.m_fds.length, "Invalid event ID.");
		return () @trusted @nogc { return &m_loop.m_fds[id].event(); } ();
	}

	private ref uint getRC(EventID id)
	{
		return m_loop.m_fds[id].common.refCount;
	}

	private bool isInternal(EventID id)
	@nogc {
		return getSlot(id).isInternal;
	}
}

package struct EventSlot {
	alias Handle = EventID;
	ConsumableQueue!EventCallback waiters;
	bool isInternal;
	version (linux) {}
	else {
		DatagramSocketFD recvSocket;
	}
}
