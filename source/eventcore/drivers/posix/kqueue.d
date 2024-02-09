/**
	BSD kqueue based event driver implementation.

	Kqueue is an efficient API for asynchronous I/O on BSD flavors, including
	OS X/macOS, suitable for large numbers of concurrently open sockets.
*/
module eventcore.drivers.posix.kqueue;
@safe: /*@nogc:*/ nothrow:

import eventcore.internal.corefoundation : isAppleOS;

version (FreeBSD) enum have_kqueue = true;
else version (DragonFlyBSD) enum have_kqueue = true;
else static if (isAppleOS) enum have_kqueue = true;
else enum have_kqueue = false;

static if (have_kqueue):

public import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import core.time : Duration;
import core.sys.posix.sys.time : timespec, time_t;

static if (isAppleOS) import core.sys.darwin.sys.event;
else version (FreeBSD) import core.sys.freebsd.sys.event;
else version (DragonFlyBSD) import core.sys.dragonflybsd.sys.event;
else static assert(false, "Kqueue not supported on this OS.");


alias KqueueEventDriver = PosixEventDriver!KqueueEventLoop;

final class KqueueEventLoop : KqueueEventLoopBase {
	override bool doProcessEvents(Duration timeout)
	@trusted {
		return doProcessEventsBase(timeout);
	}
}


abstract class KqueueEventLoopBase : PosixEventLoop {
	protected {
		int m_queue = -1;
		size_t m_changeCount = 0;
		kevent_t[100] m_changes;
		kevent_t[100] m_events;
	}

	this()
	@safe nothrow @nogc {
		m_queue = () @trusted { return kqueue(); } ();
		assert(m_queue >= 0, "Failed to create kqueue.");
	}

	protected bool doProcessEventsBase(Duration timeout)
	@trusted nothrow {
		import std.algorithm : min;
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");

		//print("wait %s", m_events.length);
		timespec ts;
		long secs, hnsecs;
		timeout.split!("seconds", "hnsecs")(secs, hnsecs);
		ts.tv_sec = cast(time_t)secs;
		ts.tv_nsec = cast(uint)hnsecs * 100;

		auto ret = kevent(m_queue, m_changes.ptr, cast(int)m_changeCount, m_events.ptr, cast(int)m_events.length, timeout == Duration.max ? null : &ts);
		m_changeCount = 0;

		//print("kevent returned %s", ret);

		if (ret > 0) {
			foreach (ref evt; m_events[0 .. ret]) {
				//print("event %s %s", evt.ident, evt.filter, evt.flags);
				assert(evt.ident <= uint.max);
				auto fd = cast(size_t)evt.ident;
				if (evt.flags & (EV_EOF|EV_ERROR))
					notify!(EventType.status)(fd);
				switch (evt.filter) {
					default: break;
					case EVFILT_READ: notify!(EventType.read)(fd); break;
					case EVFILT_WRITE: notify!(EventType.write)(fd); break;
				}
				// EV_SIGNAL, EV_TIMEOUT
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
	{
		super.dispose();
		import core.sys.posix.unistd : close;
		close(m_queue);
		m_queue = -1;
	}

	override void registerFD(FD fd, EventMask mask, bool edge_triggered = true)
	{
		//print("register %s %s", fd, mask);
		kevent_t ev;
		ev.ident = fd;
		ev.flags = EV_ADD|EV_ENABLE;
		if (edge_triggered) ev.flags |= EV_CLEAR;
		if (mask & EventMask.read) {
			ev.filter = EVFILT_READ;
			putChange(ev);
		}
		if (mask & EventMask.write) {
			ev.filter = EVFILT_WRITE;
			putChange(ev);
		}
		//if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}

	override void unregisterFD(FD fd, EventMask mask)
	{
		kevent_t ev;
		ev.ident = fd;
		ev.flags = EV_DELETE;
		putChange(ev);
	}

	override void updateFD(FD fd, EventMask old_mask, EventMask new_mask, bool edge_triggered = true)
	{
		//print("update %s %s", fd, mask);
		kevent_t ev;
		auto changes = old_mask ^ new_mask;

		if (changes & EventMask.read) {
			ev.filter = EVFILT_READ;
			ev.flags = new_mask & EventMask.read ? EV_ADD : EV_DELETE;
			if (edge_triggered) ev.flags |= EV_CLEAR;
			putChange(ev);
		}

		if (changes & EventMask.write) {
			ev.filter = EVFILT_WRITE;
			ev.flags = new_mask & EventMask.write ? EV_ADD : EV_DELETE;
			if (edge_triggered) ev.flags |= EV_CLEAR;
			putChange(ev);
		}

		//if (mask & EventMask.status) ev.events |= EPOLLERR|EPOLLRDHUP;
	}

	private void putChange(ref kevent_t ev)
	@safe nothrow @nogc {
		if (m_queue == -1) {
			printWarningWithStackTrace("Warning: generating kqueue event after the driver has been disposed");
			return;
		}

		// if an filter is going to be deleted, remove all earlier entries
		// from the queue
		if (ev.flags & EV_DELETE) {
			size_t j = 0;
			foreach (i; 0 .. m_changeCount)
				if (m_changes[i].ident != ev.ident) {
					if (i != j) m_changes[j] = m_changes[i];
					j++;
				}
			m_changeCount = j;
		}

		m_changes[m_changeCount++] = ev;
		if (m_changeCount == m_changes.length) {
			auto ret = (() @trusted => kevent(m_queue, &m_changes[0], cast(int)m_changes.length, null, 0, null)) ();
			debug {
				import core.stdc.errno : errno;
				import std.format : format;
				try assert(ret == 0, format("Failed to place kqueue change: %s %s", ret, errno));
				catch (Exception e) assert(false, "kqueue call for flushing changes failed");
			}
			m_changeCount = 0;
		}
	}
}
