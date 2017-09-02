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
import eventcore.drivers.timer;
import eventcore.drivers.threadedfile;
import eventcore.internal.consumablequeue : ConsumableQueue;
import eventcore.internal.utils;

import std.algorithm.comparison : among, min, max;

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

final class PosixEventDriver(Loop : PosixEventLoop) : EventDriver {
@safe: /*@nogc:*/ nothrow:


	private {
		alias CoreDriver = PosixEventDriverCore!(Loop, TimerDriver, EventsDriver);
		alias EventsDriver = PosixEventDriverEvents!(Loop, SocketsDriver);
		version (linux) alias SignalsDriver = SignalFDEventDriverSignals!Loop;
		else alias SignalsDriver = DummyEventDriverSignals!Loop;
		alias TimerDriver = LoopTimeoutTimerDriver;
		alias SocketsDriver = PosixEventDriverSockets!Loop;
		version (Windows) alias DNSDriver = EventDriverDNS_GHBN!(EventsDriver, SignalsDriver);
		//version (linux) alias DNSDriver = EventDriverDNS_GAIA!(EventsDriver, SignalsDriver);
		else alias DNSDriver = EventDriverDNS_GAI!(EventsDriver, SignalsDriver);
		alias FileDriver = ThreadedFileEventDriver!EventsDriver;
		version (linux) alias WatcherDriver = InotifyEventDriverWatchers!Loop;
		else version (OSX) alias WatcherDriver = FSEventsEventDriverWatchers!Loop;
		else alias WatcherDriver = PosixEventDriverWatchers!Loop;

		Loop m_loop;
		CoreDriver m_core;
		EventsDriver m_events;
		SignalsDriver m_signals;
		LoopTimeoutTimerDriver m_timers;
		SocketsDriver m_sockets;
		DNSDriver m_dns;
		FileDriver m_files;
		WatcherDriver m_watchers;
	}

	this()
	{
		m_loop = new Loop;
		m_sockets = new SocketsDriver(m_loop);
		m_events = new EventsDriver(m_loop, m_sockets);
		m_signals = new SignalsDriver(m_loop);
		m_timers = new TimerDriver;
		m_core = new CoreDriver(m_loop, m_timers, m_events);
		m_dns = new DNSDriver(m_events, m_signals);
		m_files = new FileDriver(m_events);
		m_watchers = new WatcherDriver(m_loop);
	}

	// force overriding these in the (final) sub classes to avoid virtual calls
	final override @property CoreDriver core() { return m_core; }
	final override @property EventsDriver events() { return m_events; }
	final override @property shared(EventsDriver) events() shared { return m_events; }
	final override @property SignalsDriver signals() { return m_signals; }
	final override @property TimerDriver timers() { return m_timers; }
	final override @property SocketsDriver sockets() { return m_sockets; }
	final override @property DNSDriver dns() { return m_dns; }
	final override @property FileDriver files() { return m_files; }
	final override @property WatcherDriver watchers() { return m_watchers; }

	final override void dispose()
	{
		m_files.dispose();
		m_dns.dispose();
		m_loop.dispose();
	}
}


final class PosixEventDriverCore(Loop : PosixEventLoop, Timers : EventDriverTimers, Events : EventDriverEvents) : EventDriverCore {
@safe: nothrow:
	import core.time : Duration;

	protected alias ExtraEventsCallback = bool delegate(long);

	private {
		Loop m_loop;
		Timers m_timers;
		Events m_events;
		bool m_exit = false;
		EventID m_wakeupEvent;
	}

	protected this(Loop loop, Timers timers, Events events)
	{
		m_loop = loop;
		m_timers = timers;
		m_events = events;
		m_wakeupEvent = events.createInternal();
	}

	@property size_t waiterCount() const { return m_loop.m_waiterCount + m_timers.pendingCount; }

	final override ExitReason processEvents(Duration timeout)
	{
		import core.time : hnsecs, seconds;

		if (m_exit) {
			m_exit = false;
			return ExitReason.exited;
		}

		if (!waiterCount) {
			return ExitReason.outOfWaiters;
		}

		bool got_events;

		if (timeout <= 0.seconds) {
			got_events = m_loop.doProcessEvents(0.seconds);
			m_timers.process(currStdTime);
		} else {
			long now = currStdTime;
			do {
				auto nextto = max(min(m_timers.getNextTimeout(now), timeout), 0.seconds);
				got_events = m_loop.doProcessEvents(nextto);
				long prev_step = now;
				now = currStdTime;
				got_events |= m_timers.process(now);
				if (timeout != Duration.max)
					timeout -= (now - prev_step).hnsecs;
			} while (timeout > 0.seconds && !m_exit && !got_events);
		}

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
		m_exit = true;
		() @trusted { (cast(shared)m_events).trigger(m_wakeupEvent, true); } ();
	}

	final override void clearExitFlag()
	{
		m_exit = false;
	}

	final protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	final protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	private void* rawUserDataImpl(FD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		FDSlot* fds = &m_loop.m_fds[descriptor].common;
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= FDSlot.userData.length, "Requested user data is too large.");
		if (size > FDSlot.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return m_loop.m_fds[descriptor].common.userData.ptr;
	}
}


package class PosixEventLoop {
@safe: nothrow:
	import core.time : Duration;

	package {
		AlgebraicChoppedVector!(FDSlot, StreamSocketSlot, StreamListenSocketSlot, DgramSocketSlot, DNSSlot, WatcherSlot, EventSlot, SignalSlot) m_fds;
		size_t m_waiterCount = 0;
	}

	protected @property int maxFD() const { return cast(int)m_fds.length; }

	protected abstract void dispose();

	protected abstract bool doProcessEvents(Duration dur);

	/// Registers the FD for general notification reception.
	protected abstract void registerFD(FD fd, EventMask mask, bool edge_triggered = true);
	/// Unregisters the FD for general notification reception.
	protected abstract void unregisterFD(FD fd, EventMask mask);
	/// Updates the event mask to use for listening for notifications.
	protected abstract void updateFD(FD fd, EventMask old_mask, EventMask new_mask, bool edge_triggered = true);

	final protected bool notify(EventType evt)(FD fd)
	{
		//assert(m_fds[fd].callback[evt] !is null, "Notifying FD which is not listening for event.");
		if (m_fds[fd.value].common.callback[evt])
			return m_fds[fd.value].common.callback[evt](fd);
		return false;
	}

	final protected void enumerateFDs(EventType evt)(scope FDEnumerateCallback del)
	{
		// TODO: optimize!
		foreach (i; 0 .. cast(int)m_fds.length)
			if (m_fds[i].common.callback[evt])
				del(cast(FD)i);
	}

	package void setNotifyCallback(EventType evt)(FD fd, FDSlotCallback callback)
	{
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

	package void initFD(FD fd, FDFlags flags)
	{
		with (m_fds[fd.value]) {
			common.refCount = 1;
			common.flags = flags;
		}
	}

	package void clearFD(FD fd)
	{
		if (m_fds[fd.value].common.userDataDestructor)
			() @trusted { m_fds[fd.value].common.userDataDestructor(m_fds[fd.value].common.userData.ptr); } ();
		if (!(m_fds[fd.value].common.flags & FDFlags.internal))
			foreach (cb; m_fds[fd.value].common.callback)
				if (cb !is null)
					m_waiterCount--;
		m_fds[fd.value] = m_fds.FullField.init;
	}
}


alias FDEnumerateCallback = void delegate(FD);

alias FDSlotCallback = bool delegate(FD);

private struct FDSlot {
	FDSlotCallback[EventType.max+1] callback;
	uint refCount;
	FDFlags flags;

	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;

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
