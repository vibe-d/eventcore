/**
	Linux epoll based event driver implementation.

	Epoll is an efficient API for asynchronous I/O on Linux, suitable for large
	numbers of concurrently open sockets.
*/
module eventcore.drivers.posix.epoll;
@safe @nogc nothrow:

version (linux):

public import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timeval;
import core.sys.linux.epoll;

alias EpollEventDriver = PosixEventDriver!EpollEventLoop;

static if (!is(typeof(SOCK_CLOEXEC)))
	enum SOCK_CLOEXEC = 0x80000;

final class EpollEventLoop : PosixEventLoop {
@safe nothrow:

	private {
		int m_epoll;
		epoll_event[100] m_events;
	}

	this()
	@nogc {
		assumeSafeNoGC({
			m_epoll = epoll_create1(SOCK_CLOEXEC);
		});
	}

	override bool doProcessEvents(Duration timeout)
	@trusted {
		import std.algorithm : max;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		debug (EventCoreEpollDebug) print("Epoll wait %s, %s", m_events.length, timeout);
		long tomsec;
		if (timeout == Duration.max) tomsec = long.max;
		else tomsec = max((timeout.total!"hnsecs" + 9999) / 10_000, 0);
		auto ret = epoll_wait(m_epoll, m_events.ptr, cast(int)m_events.length, tomsec > int.max ? -1 : cast(int)tomsec);
		debug (EventCoreEpollDebug) print("Epoll wait done: %s", ret);

		if (ret > 0) {
			foreach (ref evt; m_events[0 .. ret]) {
				debug (EventCoreEpollDebug) print("Epoll event on %s: %s", evt.data.fd, evt.events);
				auto fd = cast(size_t)evt.data.fd;
				if (evt.events & (EPOLLERR|EPOLLHUP|EPOLLRDHUP)) notify!(EventType.status)(fd);
				if (evt.events & EPOLLIN) notify!(EventType.read)(fd);
				if (evt.events & EPOLLOUT) notify!(EventType.write)(fd);
			}
			return true;
		} else {
			// NOTE: In particular, EINTR needs to cause true to be returned
			//       here, so that user code has a chance to handle any effects
			//       of the signal handler before waiting again.
			//
			//       Other errors are very likely to to reoccur for the next
			//       loop iteration, so there is no value in attempting to
			//       wait again.
			return ret < 0;
		}
	}

	override void dispose()
	@nogc {
		import core.sys.posix.unistd : close;
		super.dispose();
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
		assumeSafeNoGC({
			epoll_ctl(m_epoll, EPOLL_CTL_ADD, cast(int)fd, &ev);
		});
	}

	override void unregisterFD(FD fd, EventMask mask)
	{
		debug (EventCoreEpollDebug) print("Epoll unregister FD %s", fd);
		assumeSafeNoGC({
			epoll_ctl(m_epoll, EPOLL_CTL_DEL, cast(int)fd, null);
		});
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
		assumeSafeNoGC({
			epoll_ctl(m_epoll, EPOLL_CTL_MOD, cast(int)fd, &ev);
		});
	}
}

private timeval toTimeVal(Duration dur)
{
	timeval tvdur;
	dur.split!("seconds", "usecs")(tvdur.tv_sec, tvdur.tv_usec);
	return tvdur;
}

private void assumeSafeNoGC(scope void delegate() nothrow doit)
@trusted {
	(cast(void delegate() nothrow @nogc)doit)();
}
