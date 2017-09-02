module eventcore.drivers.posix.events;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.consumablequeue : ConsumableQueue;

import std.socket : InternetAddress;

version (linux) {
	nothrow @nogc extern (C) int eventfd(uint initval, int flags);
	import core.sys.posix.unistd : close, read, write;
	enum EFD_NONBLOCK = 0x800;
}


final class PosixEventDriverEvents(Loop : PosixEventLoop, Sockets : EventDriverSockets) : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	private {
		Loop m_loop;
		Sockets m_sockets;
		version (linux) {}
		else {
			EventSlot[DatagramSocketFD] m_events;
			ubyte[long.sizeof] m_buf;
		}
	}

	this(Loop loop, Sockets sockets)
	{
		m_loop = loop;
		m_sockets = sockets;
	}

	package @property Loop loop() { return m_loop; }

	final override EventID create()
	{
		return createInternal(false);
	}

	package(eventcore) EventID createInternal(bool is_internal = true)
	{
		version (linux) {
			auto eid = eventfd(0, EFD_NONBLOCK);
			if (eid == -1) return EventID.invalid;
			auto id = cast(EventID)eid;
			m_loop.initFD(id, FDFlags.internal);
			m_loop.m_fds[id].specific = EventSlot(new ConsumableQueue!EventCallback, false, is_internal); // FIXME: avoid dynamic memory allocation
			m_loop.registerFD(id, EventMask.read);
			m_loop.setNotifyCallback!(EventType.read)(id, &onEvent);
			return id;
		} else {
			auto addr = new InternetAddress(0x7F000001, 0);
			auto s = m_sockets.createDatagramSocketInternal(addr, addr, true);
			if (s == DatagramSocketFD.invalid) return EventID.invalid;
			m_sockets.receive(s, m_buf, IOMode.once, &onSocketData);
			m_events[s] = EventSlot(new ConsumableQueue!EventCallback, false, is_internal); // FIXME: avoid dynamic memory allocation
			return cast(EventID)s;
		}
	}

	final override void trigger(EventID event, bool notify_all)
	{
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
	shared @trusted {
		import core.atomic : atomicStore;
		auto thisus = cast(PosixEventDriverEvents)this;
		assert(event < thisus.m_loop.m_fds.length, "Invalid event ID passed to shared triggerEvent.");
		long one = 1;
		//log("emitting for all threads");
		if (notify_all) atomicStore(thisus.getSlot(event).triggerAll, true);
		version (linux) () @trusted { .write(cast(int)event, &one, one.sizeof); } ();
		else thisus.m_sockets.send(cast(DatagramSocketFD)event, thisus.m_buf, IOMode.once, null, &thisus.onSocketDataSent);
	}

	final override void wait(EventID event, EventCallback on_event)
	{
		if (!isInternal(event)) m_loop.m_waiterCount++;
		getSlot(event).waiters.put(on_event);
	}

	final override void cancelWait(EventID event, EventCallback on_event)
	{
		import std.algorithm.searching : countUntil;
		import std.algorithm.mutation : remove;

		if (!isInternal(event)) m_loop.m_waiterCount--;
		getSlot(event).waiters.removePending(on_event);
	}

	private bool onEvent(FD fd)
	@trusted {
		EventID event = cast(EventID)fd;
		version (linux) {
			ulong cnt;
			() @trusted { .read(cast(int)event, &cnt, cnt.sizeof); } ();
		}
		import core.atomic : cas;
		auto all = cas(&getSlot(event).triggerAll, true, false);
		trigger(event, all);
		return false;
	}

	version (linux) {}
	else {
		private void onSocketDataSent(DatagramSocketFD s, IOStatus status, size_t, scope RefAddress)
		{
		}
		private void onSocketData(DatagramSocketFD s, IOStatus, size_t, scope RefAddress)
		{
			onEvent(cast(EventID)s);
			m_sockets.receive(s, m_buf, IOMode.once, &onSocketData);
		}
	}

	final override void addRef(EventID descriptor)
	{
		assert(getRC(descriptor) > 0, "Adding reference to unreferenced event FD.");
		getRC(descriptor)++;
	}

	final override bool releaseRef(EventID descriptor)
	{
		assert(getRC(descriptor) > 0, "Releasing reference to unreferenced event FD.");
		void destroy() {
			() @trusted nothrow {
				scope (failure) assert(false);
				.destroy(getSlot(descriptor).waiters);
				assert(getSlot(descriptor).waiters is null);
			} ();
		}
		version (linux) {
			if (--getRC(descriptor) == 0) {
				destroy();
				m_loop.unregisterFD(descriptor, EventMask.read);
				m_loop.clearFD(descriptor);
				close(cast(int)descriptor);
				return false;
			}
		} else {
			if (!m_sockets.releaseRef(cast(DatagramSocketFD)descriptor)) {
				destroy();
				m_events.remove(cast(DatagramSocketFD)descriptor);
				return false;
			}
		}
		return true;
	}

	private EventSlot* getSlot(EventID id)
	{
		version (linux) {
			assert(id < m_loop.m_fds.length, "Invalid event ID.");
			return () @trusted { return &m_loop.m_fds[id].event(); } ();
		} else {
			assert(cast(DatagramSocketFD)id in m_events, "Invalid event ID.");
			return &m_events[cast(DatagramSocketFD)id];
		}
	}

	private ref uint getRC(EventID id)
	{
		return m_loop.m_fds[id].common.refCount;
	}

	private bool isInternal(EventID id)
	{
		return getSlot(id).isInternal;
	}
}

package struct EventSlot {
	alias Handle = EventID;
	ConsumableQueue!EventCallback waiters;
	shared bool triggerAll;
	bool isInternal;
}
