/**
	Linux epoll based event driver implementation.

	Epoll is an efficient API for asynchronous I/O on Linux, suitable for large
	numbers of concurrently open sockets.
*/
module eventcore.drivers.posix.epoll;
@safe: /*@nogc:*/ nothrow:

version (linux):

public import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timeval;
import core.sys.linux.epoll;

alias EpollEventDriver = PosixEventDriver!EpollEventLoop;


final class EpollEventLoop : PosixEventLoop {
@safe: nothrow:

	private {
		int m_epoll;
		epoll_event[] m_events;

		struct UnfinishedRecord
		{
			bool status_unfinished;
			bool read_unfinished;
			bool write_unfinished;
			FD fd;	// file to process on next loop
			bool all_finished() nothrow @safe
			{
				return !(status_unfinished || read_unfinished || write_unfinished);
			}
		}

		// some files may exhibit explosive event generation patters.
		// TCP socket is perfect example. When thousand of new connections is
		// established, we may never leave onAccept handler, if we don't limit
		// event count. If we do though, we are left with buffered connection
		// requests wich will not be handled until next epoll event. In order to
		// increase fairness we let notify method of PosixEventLoop to report
		// wheter event still requires processing.
		UnfinishedRecord[] unfinished_events;
	}

	this()
	{
		m_epoll = () @trusted { return epoll_create1(0); } ();
		m_events.length = 100;
		unfinished_events.reserve(100);
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm : min, max, remove, canFind, SwapStrategy;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		debug (EventCoreEpollDebug) print("Epoll wait %s, %s", m_events.length, timeout);
		long tomsec;
		if (timeout == Duration.max) tomsec = long.max;
		else tomsec = max((timeout.total!"hnsecs" + 9999) / 10_000, 0);
		auto ret = epoll_wait(m_epoll, m_events.ptr, cast(int)m_events.length, tomsec > int.max ? -1 : cast(int)tomsec);
		debug (EventCoreEpollDebug) print("Epoll wait done: %s", ret);

		bool processed_any = false;

		// we finish what we didn't do in previous handling cycle
		if (unfinished_events.length)
		{
			processed_any = true;
			debug (EventCoreEpollDebug) print("Epoll unfinished cycle");
			foreach (ref unf; unfinished_events)
			{
				auto fd = unf.fd;
				if (unf.status_unfinished)
					unf.status_unfinished = notify!(EventType.status)(fd);
				if (unf.read_unfinished)
					unf.read_unfinished = notify!(EventType.read)(fd);
				if (unf.write_unfinished)
					unf.write_unfinished = notify!(EventType.write)(fd);
			}
			// remove all records that were served
			unfinished_events =
				remove!(u => u.all_finished, SwapStrategy.unstable)(unfinished_events);
		}

		if (ret > 0) {
			processed_any = true;
			foreach (ref evt; m_events[0 .. ret]) {
				debug (EventCoreEpollDebug) print("Epoll event on %s: %s", evt.data.fd, evt.events);
				UnfinishedRecord ur;
				auto fd = cast(FD)evt.data.fd;
				if (evt.events & (EPOLLERR|EPOLLHUP|EPOLLRDHUP))
					ur.status_unfinished = notify!(EventType.status)(fd);
				if (evt.events & EPOLLIN)
					ur.read_unfinished = notify!(EventType.read)(fd);
				if (evt.events & EPOLLOUT)
					ur.write_unfinished = notify!(EventType.write)(fd);
				if (!ur.all_finished) {
					if (!unfinished_events.canFind!(a => a.fd == fd)()) {
						ur.fd = fd;
						unfinished_events ~= ur;
					}
				}
			}
		}

		return processed_any;
	}

	override void dispose()
	{
		import core.sys.posix.unistd : close;
		close(m_epoll);
	}

	override void registerFD(FD fd, EventMask mask, bool edge_triggered = true)
	{
		debug (EventCoreEpollDebug) print("Epoll register FD %s: %s", fd, mask);
		epoll_event ev;
		if (edge_triggered) ev.events |= EPOLLET;
		if (mask & EventMask.read) ev.events |= EPOLLIN;
		if (mask & EventMask.write) ev.events |= EPOLLOUT;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLHUP|EPOLLRDHUP;
		ev.data.fd = cast(int)fd;
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_ADD, cast(int)fd, &ev); } ();
	}

	override void unregisterFD(FD fd, EventMask mask)
	{
		debug (EventCoreEpollDebug) print("Epoll unregister FD %s", fd);
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_DEL, cast(int)fd, null); } ();
	}

	override void updateFD(FD fd, EventMask old_mask, EventMask mask, bool edge_triggered = true)
	{
		debug (EventCoreEpollDebug) print("Epoll update FD %s: %s", fd, mask);
		epoll_event ev;
		if (edge_triggered) ev.events |= EPOLLET;
		//ev.events = EPOLLONESHOT;
		if (mask & EventMask.read) ev.events |= EPOLLIN;
		if (mask & EventMask.write) ev.events |= EPOLLOUT;
		if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLHUP|EPOLLRDHUP;
		ev.data.fd = cast(int)fd;
		() @trusted { epoll_ctl(m_epoll, EPOLL_CTL_MOD, cast(int)fd, &ev); } ();
	}
}

private timeval toTimeVal(Duration dur)
{
	timeval tvdur;
	dur.split!("seconds", "usecs")(tvdur.tv_sec, tvdur.tv_usec);
	return tvdur;
}
