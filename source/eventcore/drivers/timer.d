/**
	Efficient generic management of large numbers of timers.
*/
module eventcore.drivers.timer;

import eventcore.driver;
import eventcore.internal.consumablequeue;
import eventcore.internal.dlist;
import eventcore.internal.utils : mallocT, freeT, nogc_assert;
import core.time : Duration, MonoTime, hnsecs;

final class LoopTimeoutTimerDriver : EventDriverTimers {
	import std.experimental.allocator.mallocator;
	import std.experimental.allocator : dispose, make;
	import std.container.array;
	import std.datetime : Clock;
	import std.range : SortedRange, assumeSorted, take;
	import core.memory : GC;

	private {
		TimerSlot*[TimerID] m_timers;
		StackDList!TimerSlot m_timerQueue;
		StackDList!TimerSlot m_freeList;
		TimerID m_lastTimerID;
		ConsumableQueue!(TimerSlot*) m_firedTimers;
	}

	this()
	@nogc @safe nothrow {
		m_firedTimers = mallocT!(ConsumableQueue!(TimerSlot*));
	}

	~this()
	@nogc @trusted nothrow {
		while (!m_freeList.empty) {
			auto tm = m_freeList.front;
			m_freeList.removeFront();
			() @trusted {
				scope (failure) assert(false);
				Mallocator.instance.dispose(tm);
				GC.removeRange(tm);
			} ();
		}

		try freeT(m_firedTimers);
		catch (Exception e) assert(false, e.msg);
	}

	package @property size_t pendingCount() const @safe nothrow { return m_timerQueue.length; }

	final package Duration getNextTimeout(MonoTime time)
	@safe nothrow {
		if (m_timerQueue.empty) return Duration.max;
		return m_timerQueue.front.timeout - time;
	}

	final package bool process(MonoTime time)
	@trusted nothrow {
		assert(m_firedTimers.length == 0);
		if (m_timerQueue.empty) return false;

		foreach (tm; m_timerQueue[]) {
			if (tm.timeout > time) break;
			if (tm.repeatDuration > Duration.zero) {
				do tm.timeout += tm.repeatDuration;
				while (tm.timeout <= time);
			} else tm.pending = false;
			m_firedTimers.put(tm);
		}

		auto processed_timers = m_firedTimers.consume();

		foreach (tm; processed_timers) {
			m_timerQueue.remove(tm);
			if (tm.repeatDuration > Duration.zero)
				enqueueTimer(tm);
		}

		foreach (tm; processed_timers) {
			auto cb = tm.callback;
			tm.callback = null;
			if (cb) {
				cb(tm.id, true);
				releaseRef(tm.id);
			}
		}

		return processed_timers.length > 0;
	}

	final override TimerID create()
	@trusted {
		auto id = TimerID(++m_lastTimerID, 0);
		TimerSlot* tm;
		if (m_freeList.empty) {
			try tm = Mallocator.instance.make!TimerSlot;
			catch (Exception e) return TimerID.invalid;
			assert(tm !is null);
			GC.addRange(tm, TimerSlot.sizeof, typeid(TimerSlot));
		} else {
			tm = m_freeList.front;
			m_freeList.removeFront();
		}
		tm.id = id;
		tm.refCount = 1;
		tm.pending = false;
		tm.timeout = MonoTime.max;
		tm.repeatDuration = Duration.zero;
		tm.callback = null;
		tm.userDataDestructor = null;
		m_timers[id] = tm;
		return id;
	}

	final override void set(TimerID timer, Duration timeout, Duration repeat)
	@trusted {
		if (!isValid(timer)) return;

		scope (failure) assert(false);
		auto tm = m_timers[timer];
		if (tm.pending) stop(timer);
		tm.timeout = MonoTime.currTime + timeout;
		tm.repeatDuration = repeat;
		tm.pending = true;
		enqueueTimer(tm);
	}

	final override void stop(TimerID timer)
	@trusted {
		import std.algorithm.mutation : swap;

		if (!isValid(timer)) return;

		auto tm = m_timers[timer];
		if (!tm.pending) return;
		TimerCallback2 cb;
		swap(cb, tm.callback);
		if (cb) {
			cb(timer, false);
			releaseRef(timer);
		}
		tm.pending = false;
		m_timerQueue.remove(tm);
	}

	final override bool isPending(TimerID descriptor)
	{
		if (!isValid(descriptor)) return false;

		return m_timers[descriptor].pending;
	}

	final override bool isPeriodic(TimerID descriptor)
	{
		if (!isValid(descriptor)) return false;

		return m_timers[descriptor].repeatDuration > Duration.zero;
	}

	final override void wait(TimerID timer, TimerCallback2 callback)
	{
		if (!isValid(timer)) return;

		assert(!m_timers[timer].callback, "Calling wait() on a timer that is already waiting.");
		m_timers[timer].callback = callback;
		addRef(timer);
	}
	alias wait = EventDriverTimers.wait;

	final override void cancelWait(TimerID timer)
	{
		if (!isValid(timer)) return;

		auto pt = m_timers[timer];
		assert(pt.callback);
		pt.callback = null;
		releaseRef(timer);
	}

	override bool isValid(TimerID handle)
	const {
		return (handle in m_timers) !is null;
	}

	final override void addRef(TimerID descriptor)
	{
		if (!isValid(descriptor)) return;

		m_timers[descriptor].refCount++;
	}

	final override bool releaseRef(TimerID descriptor)
	{
		if (!isValid(descriptor)) return true;

		auto tm = m_timers[descriptor];
		tm.refCount--;

		// cancel starved timer waits
		if (tm.callback && tm.refCount == 1 && !tm.pending) {
			debug addRef(descriptor);
			cancelWait(tm.id);
			debug {
				assert(tm.refCount == 1);
				releaseRef(descriptor);
			}
			return false;
		}

		if (!tm.refCount) {
			if (tm.pending) stop(tm.id);
			m_timers.remove(descriptor);
			m_freeList.insertFront(tm);

			return false;
		}

		return true;
	}

	final bool isUnique(TimerID descriptor)
	const {
		if (!isValid(descriptor)) return false;

		return m_timers[descriptor].refCount == 1;
	}

	protected final override void* rawUserData(TimerID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;

		TimerSlot* fds = m_timers[descriptor];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= TimerSlot.userData.length, "Requested user data is too large.");
		if (size > TimerSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return fds.userData.ptr;
	}

	private void enqueueTimer(TimerSlot* tm)
	nothrow {
		TimerSlot* ns;
		foreach_reverse (t; m_timerQueue[])
			if (t.timeout <= tm.timeout) {
				ns = t;
				break;
			}

		if (ns) m_timerQueue.insertAfter(tm, ns);
		else m_timerQueue.insertFront(tm);
	}
}

struct TimerSlot {
	TimerSlot* prev, next;
	TimerID id;
	uint refCount;
	bool pending;
	MonoTime timeout;
	Duration repeatDuration;
	TimerCallback2 callback; // TODO: use a list with small-value optimization

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}
