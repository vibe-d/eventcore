/**
	Base class for BSD socket based driver implementations.

	See_also: `eventcore.drivers.select`, `eventcore.drivers.epoll`, `eventcore.drivers.kqueue`
*/
module eventcore.drivers.posix.driver;
@safe: /*@nogc:*/ nothrow:

public import eventcore.driver;
import eventcore.drivers.posix.dns;
import eventcore.drivers.posix.events;
import eventcore.drivers.posix.signals;
import eventcore.drivers.posix.sockets;
import eventcore.drivers.posix.watchers;
import eventcore.drivers.posix.processes;
import eventcore.drivers.posix.pipes;
import eventcore.drivers.posix.io_uring.io_uring : UringEventLoop, NoRing;
import eventcore.drivers.posix.io_uring.files : UringDriverFiles;
import eventcore.drivers.timer;
import eventcore.drivers.threadedfile;
import eventcore.internal.consumablequeue : ConsumableQueue;
import eventcore.internal.utils;

import core.time : MonoTime;
import std.algorithm.comparison : among, min, max;
import std.format : format;

version (Posix) {
	package alias sock_t = int;
}
version (Windows) {
	package alias sock_t = size_t;
}

private long currStdTime()
{
	import std.datetime : Clock;
	scope (failure) assert(false);
	return Clock.currStdTime;
}

version(EventcoreEpollUsesUring) {
	version (EventcoreEpollDriver) {}
	else { static assert(false, "uring only supported together with epoll for now"); }
}

final class PosixEventDriver(Loop : PosixEventLoop) : EventDriver {
@safe: /*@nogc:*/ nothrow:


	private {
		alias CoreDriver = PosixEventDriverCore!(Loop, TimerDriver, EventsDriver, ProcessDriver, UringCore);
		alias EventsDriver = PosixEventDriverEvents!(Loop, SocketsDriver);
		version (linux) alias SignalsDriver = SignalFDEventDriverSignals!Loop;
		else alias SignalsDriver = DummyEventDriverSignals!Loop;
		alias TimerDriver = LoopTimeoutTimerDriver;
		alias SocketsDriver = PosixEventDriverSockets!Loop;
		version (Windows) alias DNSDriver = EventDriverDNS_GHBN!(EventsDriver, SignalsDriver);
		else version (EventcoreUseGAIA) alias DNSDriver = EventDriverDNS_GAIA!(EventsDriver, SignalsDriver);
		else alias DNSDriver = EventDriverDNS_GAI!(EventsDriver, SignalsDriver);
		version (EventcoreEpollUsesUring) alias FileDriver = UringDriverFiles;
		else alias FileDriver = ThreadedFileEventDriver!(EventsDriver, CoreDriver);
		version (Posix) alias PipeDriver = PosixEventDriverPipes!Loop;
		else alias PipeDriver = DummyEventDriverPipes!Loop;
		version (linux) alias WatcherDriver = InotifyEventDriverWatchers!EventsDriver;
		else version (EventcoreCFRunLoopDriver) {
			version (OSX) alias WatcherDriver = FSEventsEventDriverWatchers!EventsDriver;
			else alias WatcherDriver = PollEventDriverWatchers!EventsDriver;
		} else alias WatcherDriver = PollEventDriverWatchers!EventsDriver;
		version (Posix) alias ProcessDriver = PosixEventDriverProcesses!Loop;
		else alias ProcessDriver = DummyEventDriverProcesses!Loop;
		version (EventcoreEpollUsesUring) alias UringCore = UringEventLoop;
		else alias UringCore = NoRing;

		Loop m_loop;
		UringCore m_uring;
		CoreDriver m_core;
		EventsDriver m_events;
		SignalsDriver m_signals;
		LoopTimeoutTimerDriver m_timers;
		SocketsDriver m_sockets;
		DNSDriver m_dns;
		FileDriver m_files;
		PipeDriver m_pipes;
		WatcherDriver m_watchers;
		ProcessDriver m_processes;
	}

	this()
	@nogc @trusted {
		m_loop = mallocT!Loop;
		version (EventcoreEpollUsesUring) m_uring = mallocT!UringCore;
		m_sockets = mallocT!SocketsDriver(m_loop);
		m_events = mallocT!EventsDriver(m_loop, m_sockets);
		m_signals = mallocT!SignalsDriver(m_loop);
		m_timers = mallocT!TimerDriver;
		m_pipes = mallocT!PipeDriver(m_loop);
		m_processes = mallocT!ProcessDriver(m_loop, this);
		m_core = mallocT!CoreDriver(m_loop, m_timers, m_events, m_processes, m_uring);
		m_dns = mallocT!DNSDriver(m_events, m_signals);
		version (EventcoreEpollUsesUring) m_files = mallocT!FileDriver(m_uring);
		else m_files = mallocT!FileDriver(m_events, m_core);
		m_watchers = mallocT!WatcherDriver(m_events);
	}

	// force overriding these in the (final) sub classes to avoid virtual calls
	final override @property inout(CoreDriver) core() inout { return m_core; }
	final override @property shared(inout(CoreDriver)) core() shared inout { return m_core; }
	final override @property inout(EventsDriver) events() inout { return m_events; }
	final override @property shared(inout(EventsDriver)) events() shared inout { return m_events; }
	final override @property inout(SignalsDriver) signals() inout { return m_signals; }
	final override @property inout(TimerDriver) timers() inout { return m_timers; }
	final override @property inout(SocketsDriver) sockets() inout { return m_sockets; }
	final override @property inout(DNSDriver) dns() inout { return m_dns; }
	final override @property inout(FileDriver) files() inout { return m_files; }
	final override @property inout(PipeDriver) pipes() inout { return m_pipes; }
	final override @property inout(WatcherDriver) watchers() inout { return m_watchers; }
	final override @property inout(ProcessDriver) processes() inout { return m_processes; }

	final override bool dispose()
	{
		import core.thread : Thread;
		import taggedalgebraic : hasType;

		if (!m_loop) return true;

		version (EventCoreSilenceLeakWarnings) {}
		else {
			static string getThreadName()
			{
				string thname;
				try thname = Thread.getThis().name;
				catch (Exception e) assert(false, e.msg);
				return thname.length ? thname : "unknown";
			}

			bool hasPrintedHeader;
			foreach (id, ref s; m_loop.m_fds) {
				if (!s.specific.hasType!(typeof(null)) && !(s.common.flags & FDFlags.internal)
					&& (!s.specific.hasType!(StreamSocketSlot) || s.streamSocket.state == ConnectionState.connected))
				{
					if (!hasPrintedHeader) {
						print("Warning (thread: %s): leaking eventcore driver because there are still active handles", getThreadName());
						hasPrintedHeader = true;
					}
					print("  FD %s (%s)", id, s.specific.kind);
					debug (EventCoreLeakTrace) {
						print("    Created by:");
						printStackTrace(s.common.origin);
					}
				}
			}
			debug (EventCoreLeakTrace) {}
			else {
				if (hasPrintedHeader)
						print("Use '-debug=EventCoreLeakTrace' to show where the instantiation happened");
			}
		}

		if (m_loop.m_handleCount > 0)
			return false;

		m_processes.dispose();
		m_files.dispose();
		m_dns.dispose();
		m_core.dispose();
		m_loop.dispose();
		m_timers.dispose();

		try () @trusted {
				freeT(m_processes);
				freeT(m_watchers);
				freeT(m_pipes);
				freeT(m_files);
				freeT(m_dns);
				freeT(m_core);
				freeT(m_timers);
				freeT(m_signals);
				freeT(m_events);
				freeT(m_sockets);
				freeT(m_loop);
			} ();
		catch (Exception e) assert(false, e.msg);

		return true;
	}
}


final class PosixEventDriverCore(Loop : PosixEventLoop, Timers : EventDriverTimers, Events : EventDriverEvents, Processes : EventDriverProcesses, Uring)
	: EventDriverCore {
@safe nothrow:
	import core.atomic : atomicLoad, atomicStore;
	import core.sync.mutex : Mutex;
	import core.time : Duration;
	import std.stdint : intptr_t;
	import std.typecons : Tuple, tuple;

	protected alias ExtraEventsCallback = bool delegate(long);

	private alias ThreadCallbackEntry = Tuple!(ThreadCallbackGen, ThreadCallbackGenParams);

	private {
		Loop m_loop;
		Timers m_timers;
		Events m_events;
		Processes m_processes;
		Uring m_uring;
		bool m_exit = false;
		EventID m_wakeupEvent;

		shared Mutex m_threadCallbackMutex;
		ConsumableQueue!ThreadCallbackEntry m_threadCallbacks;
	}

	this(Loop loop, Timers timers, Events events, Processes processes,
		Uring uring)
	@nogc {
		m_loop = loop;
		m_timers = timers;
		m_events = events;
		m_processes = processes;
		m_wakeupEvent = events.createInternal();
        m_threadCallbackMutex = mallocT!(shared(Mutex));
		m_threadCallbacks = mallocT!(ConsumableQueue!ThreadCallbackEntry);
		m_threadCallbacks.reserve(1000);
		m_uring = uring;
		m_uring.registerEventID(m_wakeupEvent);
	}

	final void dispose()
	{
		executeThreadCallbacks();
		m_events.releaseRef(m_wakeupEvent);
		m_wakeupEvent = EventID.invalid; // FIXME: this needs to be synchronized!
		try {
			() @trusted { freeT(m_threadCallbackMutex); } ();
			() @trusted { freeT(m_threadCallbacks); } ();
		} catch (Exception e) assert(false, e.msg);
	}

	@property size_t waiterCount() const {
		return m_loop.m_waiterCount + m_timers.pendingCount + m_processes.pendingCount + m_uring.waiterCount;
	}

	@property Loop loop() { return m_loop; }

	final override ExitReason processEvents(Duration timeout)
	{
		import core.time : hnsecs, seconds;

		executeThreadCallbacks();

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) {
			return ExitReason.outOfWaiters;
		}
		version (EventcoreEpollUsesUring) {
			// this is required to make the kernel aware of
			// submitted SEQ, otherwise the first call to
			// process events could stall
			m_uring.submit;
		}
		bool got_events;
		if (timeout <= 0.seconds) {
			got_events = m_loop.doProcessEvents(0.seconds);
			m_timers.process(MonoTime.currTime);
			version (EventcoreEpollUsesUring) got_events |= m_uring.doProcessEvents(0.seconds);
		} else {
			auto now = MonoTime.currTime;
			do {
				auto nextto = max(min(m_timers.getNextTimeout(now), timeout), 0.seconds);
				got_events = m_loop.doProcessEvents(nextto);
				auto prev_step = now;
				now = MonoTime.currTime;
				got_events |= m_timers.process(now);
				version(EventcoreEpollUsesUring) got_events |= m_uring.doProcessEvents(0.seconds);
				if (timeout != Duration.max)
					timeout -= now - prev_step;
			} while (timeout > 0.seconds && !m_exit && !got_events);
		}

		executeThreadCallbacks();

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}
		if (!waiterCount) {
			return ExitReason.outOfWaiters;
		}
		if (got_events) return ExitReason.idle;
		return ExitReason.timeout;
	}

	final override void exit()
	{
		m_exit = true; // FIXME: this needs to be synchronized!
		() @trusted { (cast(shared)m_events).trigger(m_wakeupEvent, true); } ();
	}

	final override void clearExitFlag()
	{
		m_exit = false;
	}

	final override void runInOwnerThread(ThreadCallbackGen del,
		ref ThreadCallbackGenParams params)
	shared {
		auto m = atomicLoad(m_threadCallbackMutex);
		auto evt = atomicLoad(m_wakeupEvent);
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

		m_events.trigger(m_wakeupEvent, false);
	}

	alias runInOwnerThread = EventDriverCore.runInOwnerThread;


	final protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	final protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	protected final void* rawUserDataImpl(FD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	private void executeThreadCallbacks()
	{
		import std.stdint : intptr_t;

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


package class PosixEventLoop {
@safe: nothrow:
	import core.time : Duration;

	package {
		AlgebraicChoppedVector!(FDSlot, StreamSocketSlot, StreamListenSocketSlot, DgramSocketSlot, DNSSlot, WatcherSlot, EventSlot, SignalSlot, PipeSlot) m_fds;
		size_t m_handleCount = 0;
		size_t m_waiterCount = 0;
	}

	protected @property int maxFD() const { return cast(int)m_fds.length; }

	protected void dispose() @nogc { destroy(m_fds); }

	/** Waits for and processes a single batch of events.

		Returns:
			Returns `false` if no event was received before the timeout expired
			and `true` if either an event was received, or if the wait was
			interrupted by an error or signal.
	*/
	protected abstract bool doProcessEvents(Duration dur);

	/// Registers the FD for general notification reception.
	protected abstract void registerFD(FD fd, EventMask mask, bool edge_triggered = true) @nogc;
	/// Unregisters the FD for general notification reception.
	protected abstract void unregisterFD(FD fd, EventMask mask) @nogc;
	/// Updates the event mask to use for listening for notifications.
	protected abstract void updateFD(FD fd, EventMask old_mask, EventMask new_mask, bool edge_triggered = true) @nogc;

	final protected void notify(EventType evt)(size_t fd)
	{
		//assert(m_fds[fd].callback[evt] !is null, "Notifying FD which is not listening for event.");
		if (m_fds[fd].common.callback[evt]) {
			auto vc = m_fds[fd].common.validationCounter;
			m_fds[fd].common.callback[evt](FD(fd, vc));
		}
	}

	final protected void enumerateFDs(EventType evt)(scope FDEnumerateCallback del)
	{
		// TODO: optimize!
		foreach (i; 0 .. cast(int)m_fds.length)
			if (m_fds[i].common.callback[evt])
				del(FD(i, m_fds[i].common.validationCounter));
	}

	package(eventcore.drivers) final void addWaiter() { m_waiterCount++; }
	package(eventcore.drivers) final void removeWaiter() { m_waiterCount--; }

	package void setNotifyCallback(EventType evt)(FD fd, FDSlotCallback callback)
	{
		assert(m_fds[fd.value].common.refCount > 0,
			"Setting notification callback on unreferenced file descriptor slot.");
		assert((callback !is null) != (m_fds[fd.value].common.callback[evt] !is null),
			"Overwriting notification callback.");
		// ensure that the FD doesn't get closed before the callback gets called.
		with (m_fds[fd.value]) {
			if (callback !is null) {
				if (!(common.flags & FDFlags.internal)) m_waiterCount++;
				common.refCount++;
			} else {
				common.refCount--;
				if (!(common.flags & FDFlags.internal)) m_waiterCount--;
			}
			common.callback[evt] = callback;
		}
	}

	package FDType initFD(FDType, T)(size_t fd, FDFlags flags, auto ref T slot_init)
	{
		uint vc;

		with (m_fds[fd]) {
			assert(common.refCount == 0, "Initializing referenced file descriptor slot.");
			assert(specific.kind == typeof(specific).Kind.none, "Initializing slot that has not been cleared.");
			common.refCount = 1;
			common.flags = flags;
			debug (EventCoreLeakTrace)
			{
				import core.runtime : defaultTraceHandler;
				common.origin = defaultTraceHandler(null);
			}
			specific = slot_init;
			vc = common.validationCounter;
		}

		if (!(flags & FDFlags.internal))
			m_handleCount++;

		return FDType(fd, vc);
	}

	package void clearFD(T)(FD fd)
	{
		import taggedalgebraic : hasType;

		auto slot = () @trusted { return &m_fds[fd.value]; } ();
		assert(slot.common.validationCounter == fd.validationCounter, "Clearing FD slot for invalid FD");
		assert(slot.specific.hasType!T, "Clearing file descriptor slot with unmatched type.");

		if (!(slot.common.flags & FDFlags.internal))
			m_handleCount--;

		if (slot.common.userDataDestructor)
			() @trusted { slot.common.userDataDestructor(slot.common.userData.ptr); } ();
		if (!(slot.common.flags & FDFlags.internal))
			foreach (cb; slot.common.callback)
				if (cb !is null)
					m_waiterCount--;

		auto vc = slot.common.validationCounter;
		*slot = m_fds.FullField.init;
		slot.common.validationCounter = vc + 1;
	}

	package final void* rawUserDataImpl(size_t descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc {
		FDSlot* fds = &m_fds[descriptor].common;
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= FDSlot.userData.length, "Requested user data is too large.");
		if (size > FDSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return fds.userData.ptr;
	}
}


alias FDEnumerateCallback = void delegate(FD);

alias FDSlotCallback = void delegate(FD);

private struct FDSlot {
	FDSlotCallback[EventType.max+1] callback;
	uint refCount;
	uint validationCounter;
	FDFlags flags;

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
	debug (EventCoreLeakTrace)
		Throwable.TraceInfo origin;

	@property EventMask eventMask() const nothrow {
		EventMask ret = cast(EventMask)0;
		if (callback[EventType.read] !is null) ret |= EventMask.read;
		if (callback[EventType.write] !is null) ret |= EventMask.write;
		if (callback[EventType.status] !is null) ret |= EventMask.status;
		return ret;
	}
}

enum FDFlags {
	none = 0,
	internal = 1<<0,
}

enum EventType {
	read,
	write,
	status
}

enum EventMask {
	read = 1<<0,
	write = 1<<1,
	status = 1<<2
}

void log(ARGS...)(string fmt, ARGS args)
@trusted {
	import std.stdio : writef, writefln;
	import core.thread : Thread;
	try {
		writef("[%s]: ", Thread.getThis().name);
		writefln(fmt, args);
	} catch (Exception) {}
}


/*version (Windows) {
	import std.c.windows.windows;
	import std.c.windows.winsock;

	alias EWOULDBLOCK = WSAEWOULDBLOCK;

	extern(System) DWORD FormatMessageW(DWORD dwFlags, const(void)* lpSource, DWORD dwMessageId, DWORD dwLanguageId, LPWSTR lpBuffer, DWORD nSize, void* Arguments);

	class WSAErrorException : Exception {
		int error;

		this(string message, string file = __FILE__, size_t line = __LINE__)
		{
			error = WSAGetLastError();
			this(message, error, file, line);
		}

		this(string message, int error, string file = __FILE__, size_t line = __LINE__)
		{
			import std.string : format;
			ushort* errmsg;
			FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER|FORMAT_MESSAGE_FROM_SYSTEM|FORMAT_MESSAGE_IGNORE_INSERTS,
						   null, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), cast(LPWSTR)&errmsg, 0, null);
			size_t len = 0;
			while (errmsg[len]) len++;
			auto errmsgd = (cast(wchar[])errmsg[0 .. len]).idup;
			LocalFree(errmsg);
			super(format("%s: %s (%s)", message, errmsgd, error), file, line);
		}
	}

	alias SystemSocketException = WSAErrorException;
} else {
	import std.exception : ErrnoException;
	alias SystemSocketException = ErrnoException;
}

T socketEnforce(T)(T value, lazy string msg = null, string file = __FILE__, size_t line = __LINE__)
{
	import std.exception : enforceEx;
	return enforceEx!SystemSocketException(value, msg, file, line);
}*/
