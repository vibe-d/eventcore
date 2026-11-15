module eventcore.drivers.libasync.events;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.core;
import eventcore.internal.utils : ChoppedVector, print;
import libasync.signal : AsyncSignal;
import std.algorithm : remove;


final class LibasyncEventDriverEvents : EventDriverEvents {
@safe: /*@nogc:*/ nothrow:

	private {
		struct Slot {
			uint refCount;
			uint validation;
			shared AsyncSignal signal;
			EventCallback[] waiters;
			uint pending;
			bool all;
			DataInitializer userDataDestructor;
			ubyte[16 * size_t.sizeof] userData;
		}

		LibasyncEventDriverCore m_core;
		ChoppedVector!Slot m_slots;
		size_t[] m_free;
		size_t m_live;
	}

	this(LibasyncEventDriverCore core)
	{
		m_core = core;
	}

	package @property bool hasLeakedHandles()
	{
		if (!m_live) return false;
		print("Warning: %s event handles leaked at libasync driver shutdown.", m_live);
		return true;
	}

	void dispose()
	{
		foreach (i; 0 .. m_slots.length) {
			if (m_slots[i].refCount) killSlot(i);
		}
	}

	override EventID create()
	@trusted {
		auto id = allocSlot();
		auto sig = new shared AsyncSignal(m_core.evloop);
		auto idx = cast(size_t)id;
		if (!sig.run({ onSignal(EventID(idx, m_slots[idx].validation)); })) {
			freeSlot(idx);
			return EventID.invalid;
		}
		m_slots[idx].signal = sig;
		return id;
	}

	override void trigger(EventID event, bool notify_all)
	{
		if (!isValid(event)) return;
		with (m_slots[cast(size_t)event]) {
			pending++;
			all = notify_all;
		}
		onSignal(event);
	}

	override void trigger(EventID event, bool notify_all)
	shared {
		auto inst = () @trusted { return cast()this; } ();
		if (!inst.isValid(event)) return;
		auto sig = inst.m_slots[cast(size_t)event].signal;
		inst.m_slots[cast(size_t)event].all = notify_all;
		try {
			if (sig) () @trusted { sig.trigger(); } ();
		} catch (Exception) {}
	}

	override void wait(EventID event, EventCallback on_event)
	{
		if (!isValid(event)) return;
		with (m_slots[cast(size_t)event]) {
			waiters ~= on_event;
			m_core.addWaiter();
		}
		if (m_slots[cast(size_t)event].pending)
			onSignal(event);
	}

	override void cancelWait(EventID event, EventCallback on_event)
	{
		if (!isValid(event)) return;
		with (m_slots[cast(size_t)event]) {
			foreach (i, w; waiters) {
				if (w is on_event) {
					waiters = waiters.remove(i);
					m_core.removeWaiter();
					return;
				}
			}
		}
	}

	override bool isValid(EventID handle)
	const @nogc {
		if (handle == EventID.invalid) return false;
		auto v = cast(size_t)handle;
		if (v >= m_slots.length) return false;
		auto s = &m_slots[v];
		return s.refCount > 0 && s.validation == handle.validationCounter;
	}

	override void addRef(EventID descriptor)
	{
		if (!isValid(descriptor)) return;
		m_slots[cast(size_t)descriptor].refCount++;
	}

	override bool releaseRef(EventID descriptor)
	{
		if (!isValid(descriptor)) return true;
		auto s = &m_slots[cast(size_t)descriptor];
		if (--s.refCount) return true;
		foreach (_; s.waiters) m_core.removeWaiter();
		killSlot(cast(size_t)descriptor);
		return false;
	}

	protected override void* rawUserData(EventID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		auto s = &m_slots[cast(size_t)descriptor];
		assert(s.userDataDestructor is null || s.userDataDestructor is destroy);
		assert(size <= s.userData.length);
		if (!s.userDataDestructor) {
			initialize(s.userData.ptr);
			s.userDataDestructor = destroy;
		}
		return s.userData.ptr;
	}

	private void onSignal(EventID event)
	{
		if (!isValid(event)) return;
		auto s = &m_slots[cast(size_t)event];
		if (!s.pending && !s.waiters.length) return;
		if (s.pending) s.pending--;

		auto waiters = s.waiters;
		if (s.all) {
			s.waiters = null;
			foreach (_; waiters) m_core.removeWaiter();
			foreach (w; waiters)
				if (w) w(event);
		} else if (waiters.length) {
			auto w = waiters[0];
			s.waiters = waiters[1 .. $];
			m_core.removeWaiter();
			if (w) w(event);
		}
	}

	private EventID allocSlot()
	{
		size_t idx;
		if (m_free.length) {
			idx = m_free[$ - 1];
			m_free = m_free[0 .. $ - 1];
			m_free = m_free[0 .. $]; // length already truncated
		} else {
			idx = m_slots.length;
		}
		m_slots[idx] = Slot.init;
		m_slots[idx].refCount = 1;
		m_slots[idx].validation++;
		m_live++;
		return EventID(idx, m_slots[idx].validation);
	}

	private void killSlot(size_t idx)
	@trusted {
		auto s = &m_slots[idx];
		if (s.signal) {
			s.signal.kill();
			s.signal = null;
		}
		if (s.userDataDestructor)
			s.userDataDestructor(s.userData.ptr);
		*s = Slot.init;
		s.validation++; // invalidate outstanding handles
		m_free ~= idx;
		if (m_live) m_live--;
	}

	private void freeSlot(size_t idx)
	{
		killSlot(idx);
	}
}
