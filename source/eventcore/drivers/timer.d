/**
	Efficient generic management of large numbers of timers.
*/
module eventcore.drivers.timer;

import eventcore.driver;
import eventcore.internal.consumablequeue;
import eventcore.internal.dlist;
import eventcore.internal.utils : mallocT, freeT, nogc_assert;
import core.time : Duration, MonoTime, hnsecs, seconds;

//debug = EventCoreTimingWheels;


final class LoopTimeoutTimerDriver : EventDriverTimers {
	import std.experimental.allocator.mallocator;
	import std.experimental.allocator : dispose, make;
	import std.container.array;
	import std.datetime : Clock;
	import std.range : SortedRange, assumeSorted, take;
	import core.memory : GC;

	private {
		StackDList!TimerSlot m_freeList;
		TimingWheels!(TimerSlot, 3, 64, getTimeSlotTimeIndex) m_wheels;
		TimerID m_lastTimerID;
		ConsumableQueue!(TimerSlot*) m_firedTimers;
	}

	this()
	@nogc @safe nothrow {
		m_firedTimers = mallocT!(ConsumableQueue!(TimerSlot*));
		m_wheels.initialize(getTimeIndex(MonoTime.currTime()));
	}

	~this()
	@nogc @trusted nothrow {
		// TODO: remove/deallocate all timer slots!

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

	package @property size_t pendingCount() const @safe nothrow { return m_wheels.activeCount; }

	final package Duration getNextTimeout(MonoTime time)
	@safe nothrow {
		if (!pendingCount)
			return Duration.max;

		Duration mindur = Duration.max;
		m_wheels.iterateFirstNonEmptySlot((s) {
			if (s.timeout - time < mindur)
				mindur = s.timeout - time;
		});
		return mindur;
	}

	final package bool process(MonoTime time)
	@trusted nothrow {
		void fire(TimerSlot* tm) @safe {
			if (tm.repeatDuration > Duration.zero) {
				do tm.timeout += tm.repeatDuration;
				while (tm.timeout <= time);
			} else tm.pending = false;
			m_firedTimers.put(tm);
		}

		m_wheels.advance(getTimeIndex(time), &fire);
		m_wheels.filterCurrentSlot((TimerSlot* tm) @safe {
			if (tm.timeout > time)
				return true;
			fire(tm);
			return false;
		});

		auto processed_timers = m_firedTimers.consume();

		foreach (tm; processed_timers) {
			if (tm.repeatDuration > Duration.zero)
				m_wheels.add(tm);
		}

		foreach (tm; processed_timers) {
			auto cb = tm.callback;
			tm.callback = null;
			if (cb) {
				cb(toID(tm), true);
				releaseRef(toID(tm));
			}
		}

		return processed_timers.length > 0;
	}

	final override TimerID create()
	@trusted {
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
		if (!++tm.validationCounter)
			tm.validationCounter++;
		tm.refCount = 1;
		tm.pending = false;
		tm.timeout = MonoTime.max;
		tm.repeatDuration = Duration.zero;
		tm.callback = null;
		tm.userDataDestructor = null;
		auto ret = toID(tm);
		assert(isValid(ret));
		return ret;
	}

	final override void set(TimerID timer, Duration timeout, Duration repeat)
	@trusted {
		if (!isValid(timer)) return;

		scope (failure) assert(false);
		auto tm = fromID(timer);
		if (tm.pending) stop(timer);
		tm.timeout = MonoTime.currTime + timeout;
		tm.repeatDuration = repeat;
		tm.pending = true;
		m_wheels.add(tm);
	}

	final override void stop(TimerID timer)
	@trusted {
		import std.algorithm.mutation : swap;

		if (!isValid(timer)) return;

		auto tm = fromID(timer);
		if (!tm.pending) return;
		TimerCallback2 cb;
		swap(cb, tm.callback);
		if (cb) {
			cb(timer, false);
			releaseRef(timer);
		}
		if (tm.pending) {
			tm.pending = false;
			m_wheels.remove(tm);
		}
	}

	final override bool isPending(TimerID descriptor)
	{
		if (!isValid(descriptor)) return false;

		return fromID(descriptor).pending;
	}

	final override bool isPeriodic(TimerID descriptor)
	{
		if (!isValid(descriptor)) return false;

		return fromID(descriptor).repeatDuration > Duration.zero;
	}

	final override void wait(TimerID timer, TimerCallback2 callback)
	{
		if (!isValid(timer)) return;

		assert(!fromID(timer).callback, "Calling wait() on a timer that is already waiting.");
		fromID(timer).callback = callback;
		addRef(timer);
	}
	alias wait = EventDriverTimers.wait;

	final override void cancelWait(TimerID timer)
	{
		if (!isValid(timer)) return;

		auto pt = fromID(timer);
		assert(pt.callback);
		pt.callback = null;
		releaseRef(timer);
	}

	override bool isValid(TimerID descriptor)
	const {
		return fromID(descriptor) !is null;
	}

	final override void addRef(TimerID descriptor)
	{
		if (!isValid(descriptor)) return;

		fromID(descriptor).refCount++;
	}

	final override bool releaseRef(TimerID descriptor)
	{
		if (!isValid(descriptor)) return true;

		auto tm = fromID(descriptor);
		tm.refCount--;

		// cancel starved timer waits
		if (tm.callback && tm.refCount == 1 && !tm.pending) {
			debug addRef(descriptor);
			cancelWait(toID(tm));
			debug {
				assert(tm.refCount == 1);
				releaseRef(descriptor);
			}
			return false;
		}

		if (!tm.refCount) {
			if (tm.pending) stop(toID(tm));
			tm.validationCounter = 0;
			assert(!isValid(descriptor));
			m_freeList.insertFront(tm);

			return false;
		}

		return true;
	}

	final bool isUnique(TimerID descriptor)
	const {
		if (!isValid(descriptor)) return false;

		return fromID(descriptor).refCount == 1;
	}

	protected final override void* rawUserData(TimerID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;

		TimerSlot* fds = fromID(descriptor);
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

	private static TimerID toID(TimerSlot* slot)
	@trusted nothrow @nogc {
		assert(slot.validationCounter != 0);
		return TimerID(cast(size_t)cast(void*)slot, slot.validationCounter);
	}

	private static TimerSlot* fromID(TimerID id)
	@trusted nothrow @nogc {
		if (id == TimerID.invalid) return null;
		auto slot = cast(TimerSlot*)cast(void*)id.value;
		if (slot.validationCounter != id.validationCounter)
			return null;
		return slot;
	}
}

private struct TimerSlot {
	TimerSlot* prev, next;
	uint refCount;
	uint validationCounter;
	bool pending;
	MonoTime timeout;
	Duration repeatDuration;
	TimerCallback2 callback; // TODO: use a list with small-value optimization

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}

private ulong getTimeSlotTimeIndex(const TimerSlot* slot)
@safe @nogc nothrow {
	return getTimeIndex(slot.timeout);
}

private ulong getTimeIndex(MonoTime timestamp)
@safe @nogc nothrow {
	return (timestamp - MonoTime.zero).total!"seconds";
}


/*
	Hierarchical timing wheel configuration, e.g. for wheelCount=3 and
	slotCount=4:

	wheel 0    wheel 1   wheel 2
	  [0]    [ 4 ..  8] [20 .. 36]
	  [1]    [ 8 .. 12] [36 .. 52]
	  [2]    [12 .. 16] [52 .. 68]
	  [3]    [16 .. 20] [68 .. 84]

	Each index (range) is relative to the current time index.

	Everytime a wheel has been rotated a full rotation and is thus empty, the
	next wheel will be rotated by one step, and the contents of its first slot
	will be redistributed to the previous empty wheel.

	Any indexes outside of the possible range of all wheels will be stored in a
	separate overflow list.
*/
private struct TimingWheels(Slot, size_t wheelCount, size_t slotCount, alias getTimeIndex)
{
	private {
		ulong m_timeIndex = 0;
		StackDList!Slot m_overflowList;
		Wheel!(StackDList!Slot, slotCount)[wheelCount] m_wheels;
		size_t m_activeCount = 0;
	}

	void initialize(ulong start_time_index)
	{
		m_timeIndex = start_time_index;
	}

	@property size_t activeCount() const { return m_activeCount; }

	void add(Slot* slot)
	{
		size_t idx;
		size_t wheelidx = 0;
		getTargetSlot(getTimeIndex(slot), idx, wheelidx);
		if (wheelidx < wheelCount) {
			debug (EventCoreTimingWheels) debugLog("ADD %s/%s to SLOT %s of wheel %s", getTimeIndex(slot), m_timeIndex, idx, wheelidx);
			m_wheels[wheelidx][idx].insertBack(slot);
		} else {
			debug (EventCoreTimingWheels) debugLog("ADD %s/%s to OVERFLOW", getTimeIndex(slot), m_timeIndex);
			m_overflowList.insertBack(slot);
		}

		m_activeCount++;
	}

	void remove(Slot* slot)
	{
		m_activeCount--;

		size_t index, wheel_index;
		getTargetSlot(getTimeIndex(slot), index, wheel_index);

		if (wheel_index < wheelCount)
			m_wheels[wheel_index][index].remove(slot);
		else m_overflowList.remove(slot);
	}

	void advance(ulong time_index, scope void delegate(Slot*) @safe nothrow del)
	{
		assert(long(time_index - m_timeIndex) >= 0, "Invoking TimingWheels.advance with past time slot");

		while (time_index > m_timeIndex && this.activeCount > 0) {
			while (!m_wheels[0][0].empty) {
				auto s = m_wheels[0][0].front;
				m_wheels[0][0].removeFront();
				m_activeCount--;
				debugLog("TRIGGER %s/%s", getTimeIndex(s), m_timeIndex);
				del(s);
			}
			rotate();
		}
		m_timeIndex = time_index;
	}

	void iterateFirstNonEmptySlot(scope void delegate(Slot*) @safe nothrow del)
	{
		foreach (i; 0 .. wheelCount)
			foreach (ref list; m_wheels[i])
				if (!list.empty) {
					foreach (s; list)
						del(s);
					return;
				}

		foreach (s; m_overflowList)
			del(s);
	}

	void filterCurrentSlot(scope bool delegate(Slot*) @safe nothrow del)
	{
		Slot* sn;
		for (auto s = m_wheels[0][0].front; s; s = sn) {
			sn = s.next;
			if (!del(s)) {
				m_wheels[0][0].remove(s);
				m_activeCount--;
			}
		}
	}

	private void rotate()
	{
		debugLog("ROTATE %s -> ", m_timeIndex, m_timeIndex + 1);
		assert(m_wheels[0][0].empty);
		m_wheels[0].popFront();

		m_timeIndex++;

		scope (exit) debugLog(" -> WHEELS: %s %s %s", m_wheels[0].index, m_wheels[1].index, m_wheels[2].index);

		foreach (i; 1 .. wheelCount) {
			if (m_wheels[i-1].index != 0) return;

			debugLog("WRAP %s", i);

			while (!m_wheels[i].front.empty)
				redistribute(m_wheels[i].front.front, m_wheels[i].front);
			m_wheels[i].popFront();
		}

		if (m_wheels[$-1].index == 0) {
			debugLog("REDISTRIBUTE OVERFLOW");
			Slot* sn;
			for (Slot* s = m_overflowList.front; s; s = sn) {
				sn = s.next;
				size_t idx, wheelidx;
				getTargetSlot(getTimeIndex(s), idx, wheelidx);
				if (wheelidx < wheelCount)
					redistribute(s, m_overflowList);
			}
		}
	}

	private void redistribute(Slot* slot, ref StackDList!Slot list)
	{
		debugLog("REDISTRIBUTE %s/%s", getTimeIndex(slot), m_timeIndex);
		list.remove(slot);
		m_activeCount--;
		add(slot);
		assert(list.back !is slot, "redistributed to same list");
	}

	private void getTargetSlot(ulong time_index, out size_t index, out size_t wheel_index)
	out { assert(wheel_index >= wheelCount || index < slotCount - m_wheels[wheel_index].index); }
	do {
		auto idx = long(time_index - m_timeIndex);
		assert(idx >= 0, "Adding timer that was due in the past");

		while (wheel_index < wheelCount && idx >= slotCount - m_wheels[wheel_index].index) {
			idx = (idx + m_wheels[wheel_index].index) / slotCount - 1;
			wheel_index++;
		}
		if (wheel_index < wheelCount)
			index = cast(size_t)idx;
	}
}

private struct Wheel(T, int N) {
	private {
		T[N] m_buffer;
		size_t m_index;
	}

	@property ref inout(T) front() inout { return m_buffer[m_index]; }

	@property size_t index() const { return m_index; }

	void popFront() {  m_buffer[m_index] = T.init; m_index = (m_index + 1) % N; }

	ref inout(T) opIndex(size_t idx) inout { return m_buffer[idx + m_index]; }

	int opApply(scope int delegate(ref T) @safe nothrow del)
	{
		foreach (i; m_index .. N)
			if (auto ret = del(m_buffer[i]))
				return ret;
		return 0;
	}
}

private void debugLog(ARGS...)(string format, ARGS args)
{
	import eventcore.internal.utils : print;
	debug (EventCoreTimingWheels) print(format, args);
}

unittest {
	import std.algorithm.sorting : sort;
	import std.format : format;

	static struct Timer {
		ulong index;
		Timer* prev, next;
	}

	TimingWheels!(Timer, 3, 4, s => s.index) wheels;


	void advance(ulong time_index, ulong[] expected_slots...)
	{
		ulong[] slots;
		wheels.advance(time_index, (s) { slots ~= s.index; });
		slots.sort();
		assert(slots == expected_slots, format("Timers triggered: %(%s, %) instead of %(%s, %)", slots, expected_slots));
	}

	void testFirstEmptySlot(ulong[] expected_slots...)
	{
		ulong[] slots;
		wheels.iterateFirstNonEmptySlot((s) { slots ~= s.index; });
		slots.sort();
		assert(slots == expected_slots, format("Timers in first non-empty wheel slot: %(%s, %) instead of %(%s, %)", slots, expected_slots));
	}

	void testCurrentSlot(ulong[] expected_slots...)
	{
		ulong[] slots;
		wheels.filterCurrentSlot((s) { slots ~= s.index; return true; });
		slots.sort();
		assert(slots == expected_slots, format("Timers in first wheel slot: %(%s, %) instead of %(%s, %)", slots, expected_slots));
	}

	// initial time offset
	wheels.initialize(10);

	// simple timer + trigger
	wheels.add(new Timer(10));
	assert(wheels.activeCount == 1);
	testFirstEmptySlot(10);
	advance(11, 10);
	assert(wheels.activeCount == 0);

	// timer further in the future, outside of the first wheel
	wheels.add(new Timer(11 + 8));
	assert(wheels.activeCount == 1);
	testFirstEmptySlot(11+8);
	advance(11+8);
	assert(wheels.activeCount == 1);
	advance(11+9, 11+8);
	assert(wheels.activeCount == 0);

	// bunch of timers distributed over the wheels and the overflow líst
	wheels.add(new Timer(21));
	wheels.add(new Timer(21));
	wheels.add(new Timer(22));
	wheels.add(new Timer(30));
	wheels.add(new Timer(40));
	wheels.add(new Timer(63));
	wheels.add(new Timer(64));
	wheels.add(new Timer(83));
	wheels.add(new Timer(84));
	wheels.add(new Timer(100));
	wheels.add(new Timer(1000));
	assert(wheels.activeCount == 11);
	testCurrentSlot();

	advance(21);
	testCurrentSlot(21, 21);
	advance(22, 21, 21);
	assert(wheels.activeCount == 9);

	testCurrentSlot(22);
	wheels.filterCurrentSlot(tm => tm.index != 22);
	testCurrentSlot();
	assert(wheels.activeCount == 8);

	advance(31, 30);
	advance(90, 40, 63, 64, 83, 84);
	advance(120, 100);
	assert(wheels.activeCount == 1);

	wheels.add(new Timer(120));
	wheels.add(new Timer(130));
	testCurrentSlot(120);
	assert(wheels.activeCount == 3);
	advance(1001, 120, 130, 1000);
	assert(wheels.activeCount == 0);
}
