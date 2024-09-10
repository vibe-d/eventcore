module eventcore.drivers.winapi.core;

version (Windows):

import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.internal.consumablequeue;
import eventcore.internal.utils : mallocT, freeT, nogc_assert, print, printStackTrace;
import eventcore.internal.win32;
import core.sync.mutex : Mutex;
import core.time : Duration;
import taggedalgebraic;
import std.stdint : intptr_t;
import std.typecons : Tuple, tuple;


final class WinAPIEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:
	private alias ThreadCallbackEntry = Tuple!(ThreadCallbackGen, ThreadCallbackGenParams);

	private {
		bool m_exit;
		size_t m_waiterCount;
		DWORD m_tid;
		LoopTimeoutTimerDriver m_timers;
		HANDLE[MAXIMUM_WAIT_OBJECTS] m_registeredEvents;
		void delegate() @safe nothrow[MAXIMUM_WAIT_OBJECTS] m_registeredEventCallbacks;
		DWORD m_registeredEventCount = 0;
		HANDLE m_fileCompletionEvent;
		uint m_validationCounter;
		ConsumableQueue!IOEvent m_ioEvents;

		shared Mutex m_threadCallbackMutex;
		ConsumableQueue!ThreadCallbackEntry m_threadCallbacks;
	}

	package {
		HandleSlot[HANDLE] m_handles; // FIXME: use allocator based hash map
	}

	this(LoopTimeoutTimerDriver timers)
	@nogc {
		m_timers = timers;
		m_tid = () @trusted { return GetCurrentThreadId(); } ();
		m_fileCompletionEvent = () @trusted { return CreateEventW(null, false, false, null); } ();
		registerEvent(m_fileCompletionEvent);
		m_ioEvents = mallocT!(ConsumableQueue!IOEvent);
        m_threadCallbackMutex = mallocT!(shared(Mutex));
		m_threadCallbacks = mallocT!(ConsumableQueue!ThreadCallbackEntry);
		m_threadCallbacks.reserve(1000);
	}

	void dispose()
	@trusted {
		if (m_waiterCount > 0)
			print("Warning (thread: %s): Disposing eventcore driver with active waiters still present", getThreadName());

		try {
			freeT(m_threadCallbacks);
			freeT(m_threadCallbackMutex);
			freeT(m_ioEvents);
		} catch (Exception e) assert(false, e.msg);
	}

	package bool checkForLeakedHandles()
	@trusted {
		foreach (k; m_handles.byKey) {
			print("Warning (thread: %s): Leaked handles detected at driver shutdown", getThreadName());
			foreach (ks; m_handles.byKeyValue)
				if (!ks.value.specific.hasType!(typeof(null))) {
					print("   FD %04X (%s)", ks.key, ks.value.specific.kind);
					debug (EventCoreLeakTrace) {
						print("    Created by:");
						printStackTrace(ks.value.origin);
					}
				}
			return true;
		}

		return false;
	}

	private static string getThreadName()
	{
		import core.thread : Thread;

		string thname;
		try thname = Thread.getThis().name;
		catch (Exception e) assert(false, e.msg);
		return thname.length ? thname : "unknown";
	}

	override size_t waiterCount() { return m_waiterCount + m_timers.pendingCount; }

	package void addWaiter() @nogc { m_waiterCount++; }
	package void removeWaiter()
	@nogc {
		assert(m_waiterCount > 0, "Decrementing waiter count below zero.");
		m_waiterCount--;
	}

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		import std.algorithm : min;
		import core.time : MonoTime, seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) return ExitReason.outOfWaiters;

		bool got_event;
		auto now = MonoTime.currTime;
		do {
			auto nextto = min(m_timers.getNextTimeout(now), timeout);
			got_event |= doProcessEvents(nextto);
			auto prev_step = now;
			now = MonoTime.currTime;
			got_event |= m_timers.process(now);

			if (m_exit) {
				m_exit = false;
				return ExitReason.exited;
			} else if (got_event) break;
			if (timeout != Duration.max)
				timeout -= now - prev_step;
		} while (timeout > 0.seconds);

		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_event) return ExitReason.idle;
		return ExitReason.timeout;
	}

	override void exit()
	@trusted {
		m_exit = true;
		PostThreadMessageW(m_tid, WM_QUIT, 0, 0);
	}

	override void clearExitFlag()
	{
		m_exit = false;
	}

	override void runInOwnerThread(ThreadCallbackGen del,
		ref ThreadCallbackGenParams params)
	shared {
		import core.atomic : atomicLoad;

		auto m = atomicLoad(m_threadCallbackMutex);
		// NOTE: This case must be handled gracefully to avoid hazardous
		//       race-conditions upon unexpected thread termination. The mutex
		//       and the map will stay valid even after the driver has been
		//       disposed, so no further synchronization is required.
		if (!m) return;

		try {
			synchronized (m)
				() @trusted { return (cast()this).m_threadCallbacks; } ()
					.put(ThreadCallbackEntry(del, params));
		} catch (Exception e) assert(false, e.msg);

		() @trusted { PostThreadMessageW(m_tid, WM_APP, 0, 0); } ();
	}

	alias runInOwnerThread = EventDriverCore.runInOwnerThread;

	package void* rawUserDataImpl(HANDLE handle, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		HandleSlot* fds = &m_handles[handle];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= HandleSlot.userData.length, "Requested user data is too large.");
		if (size > HandleSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return fds.userData.ptr;
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system
	{
		assert(false, "TODO!");
	}

	private bool doProcessEvents(Duration max_wait)
	{
		import core.time : seconds;
		import std.algorithm.comparison : min, max;

		executeThreadCallbacks();

		bool got_event;

		DWORD timeout_msecs = max_wait == Duration.max ? INFINITE : cast(DWORD)min(max(max_wait.total!"msecs", 0), DWORD.max);
		auto ret = () @trusted { return MsgWaitForMultipleObjectsEx(m_registeredEventCount, m_registeredEvents.ptr,
			timeout_msecs, QS_ALLINPUT, MWMO_ALERTABLE|MWMO_INPUTAVAILABLE); } ();

		while (!m_ioEvents.empty) {
			auto evt = m_ioEvents.consumeOne();
			evt.process(evt.error, evt.bytesTransferred, evt.overlapped);
		}

		if (ret == WAIT_IO_COMPLETION) got_event = true;
		else if (ret >= WAIT_OBJECT_0 && ret < WAIT_OBJECT_0 + m_registeredEventCount) {
			if (auto cb = m_registeredEventCallbacks[ret - WAIT_OBJECT_0]) {
				cb();
				got_event = true;
			}
		}

		/*if (ret == WAIT_OBJECT_0) {
			got_event = true;
			Win32TCPConnection[] to_remove;
			foreach (fw; m_fileWriters.byKey)
				if (fw.testFileWritten())
					to_remove ~= fw;
			foreach (fw; to_remove)
			m_fileWriters.remove(fw);
		}*/

		MSG msg;
		//uint cnt = 0;
		while (() @trusted { return PeekMessageW(&msg, null, 0, 0, PM_REMOVE); } ()) {
			if (msg.message == WM_QUIT && m_exit)
				break;

			() @trusted {
				TranslateMessage(&msg);
				DispatchMessageW(&msg);
			} ();

			got_event = true;

			// process timers every now and then so that they don't get stuck
			//if (++cnt % 10 == 0) processTimers();
		}

		executeThreadCallbacks();

		return got_event;
	}


	package void registerEvent(HANDLE event, void delegate() @safe nothrow callback = null)
	@nogc {
		assert(m_registeredEventCount < MAXIMUM_WAIT_OBJECTS, "Too many registered events.");
		m_registeredEvents[m_registeredEventCount] = event;
		if (callback) m_registeredEventCallbacks[m_registeredEventCount] = callback;
		m_registeredEventCount++;
	}

	package SlotType* setupSlot(SlotType)(HANDLE h)
	{
		assert(h !in m_handles, "Handle already in use.");
		HandleSlot s;
		s.refCount = 1;
		s.validationCounter = ++m_validationCounter;
		s.specific = SlotType.init;
		debug (EventCoreLeakTrace) {
			import core.runtime : defaultTraceHandler;
			s.origin = defaultTraceHandler(null);
		}
		m_handles[h] = s;
		return () @trusted { return &m_handles[h].specific.get!SlotType(); } ();
	}

	package void freeSlot(HANDLE h)
	{
		nogc_assert((h in m_handles) !is null, "Handle not in use - cannot free.");
		m_handles.remove(h);
	}

	package void discardEvents(scope OVERLAPPED_CORE*[] overlapped...)
	@nogc {
		m_ioEvents.filterPending!((evt) @safe {
			foreach (ovl; overlapped)
				if (ovl is evt.overlapped)
					return false;
				return true;
			});
	}

	private void executeThreadCallbacks()
	{
		while (true) {
			ThreadCallbackEntry del;
			try {
				synchronized (m_threadCallbackMutex) {
					if (m_threadCallbacks.empty) break;
					del = m_threadCallbacks.consumeOne;
				}
			} catch (Exception e) assert(false, e.msg);
			del[0](del[1]);
		}
	}
}

private long currStdTime()
@safe nothrow {
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

private struct HandleSlot {
	static union SpecificTypes {
		typeof(null) none;
		FileSlot files;
		WatcherSlot watcher;
	}
	int refCount;
	uint validationCounter;
	TaggedAlgebraic!SpecificTypes specific;

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;

	debug (EventCoreLeakTrace) {
		Throwable.TraceInfo origin;
	}

	@safe nothrow:

	@property ref FileSlot file() return { return specific.get!FileSlot; }
	@property ref WatcherSlot watcher() return { return specific.get!WatcherSlot; }

	void addRef()
	{
		assert(refCount > 0);
		refCount++;
	}

	bool releaseRef(scope void delegate() @safe nothrow on_free)
	{
		nogc_assert(refCount > 0, "Releasing unreferenced slot.");
		if (--refCount == 0) {
			on_free();
			return false;
		}
		return true;
	}
}

package struct FileSlot {
	static struct Direction(bool RO) {
		OVERLAPPED_CORE overlapped;
		FileIOCallback callback;
		ulong offset;
		size_t bytesTransferred;
		IOMode mode;
		static if (RO) const(ubyte)[] buffer;
		else ubyte[] buffer;

		void invokeCallback(IOStatus status, size_t bytes_transferred)
		@safe nothrow {
			auto cb = this.callback;
			this.callback = null;
			assert(cb !is null);
			if (auto ps = overlapped.hEvent in overlapped.driver.m_handles) {
				auto vc = ps.validationCounter;
				auto fd = FileFD(cast(size_t)overlapped.hEvent, vc);
				cb(fd, status, bytes_transferred);
			}
		}
	}
	Direction!false read;
	Direction!true write;
	FileCloseCallback closeCallback;
}

package struct WatcherSlot {
	ubyte[] buffer;
	OVERLAPPED_CORE overlapped;
	string directory;
	bool recursive;
	FileChangesCallback callback;
}

package struct OVERLAPPED_CORE {
	OVERLAPPED overlapped;
	alias overlapped this;
	WinAPIEventDriverCore driver;
}

package struct IOEvent {
	void function(DWORD err, DWORD bts, OVERLAPPED_CORE*) @safe nothrow process;
	DWORD error;
	DWORD bytesTransferred;
	OVERLAPPED_CORE* overlapped;
}

package extern(System) @system nothrow
void overlappedIOHandler(alias process, EXTRA...)(DWORD error, DWORD bytes_transferred, OVERLAPPED* _overlapped, EXTRA extra)
{
	auto overlapped = cast(OVERLAPPED_CORE*)_overlapped;
	assert(overlapped.driver !is null, "Got overlapped callback after slot had already been cleared!");
	overlapped.driver.m_ioEvents.put(IOEvent(&process, error, bytes_transferred, overlapped));
}
