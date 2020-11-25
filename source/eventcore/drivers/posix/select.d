/**
	A `select` based event driver implementation.

	This driver works on all BSD socket compatible operating systems, including
	Windows. It has a good performance for small numbers of cuncurrently open
	files/sockets, but is not suited for larger amounts.
*/
module eventcore.drivers.posix.select;
@safe: /*@nogc:*/ nothrow:

public import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import core.time : Duration;

version (Posix) {
	import core.sys.posix.sys.time : timeval;
	import core.sys.posix.sys.select;
}

version (Windows) {
	import core.sys.windows.winsock2;
}


alias SelectEventDriver = PosixEventDriver!SelectEventLoop;

final class SelectEventLoop : PosixEventLoop {
@safe: nothrow:
	override bool doProcessEvents(Duration timeout)
	{
		//assert(Fiber.getThis() is null, "processEvents may not be called from within a fiber!");
//scope (failure) assert(false); import std.stdio; writefln("%.3f: process %s ms", Clock.currAppTick.usecs * 1e-3, timeout.total!"msecs");
//scope (success) writefln("%.3f: process out", Clock.currAppTick.usecs * 1e-3);

		auto ts = timeout.toTimeVal;

		fd_set readfds, writefds, statusfds;

		() @trusted {
			FD_ZERO(&readfds);
			FD_ZERO(&writefds);
			FD_ZERO(&statusfds);
		} ();
		enumerateFDs!(EventType.read)((fd) @trusted { FD_SET(cast(sock_t)fd, &readfds); });
		enumerateFDs!(EventType.write)((fd) @trusted { FD_SET(cast(sock_t)fd, &writefds); });
		enumerateFDs!(EventType.status)((fd) @trusted { FD_SET(cast(sock_t)fd, &statusfds); });

//print("Wait for event... %s", timeout);
//writefln("%.3f: select in", Clock.currAppTick.usecs * 1e-3);
		auto ret = () @trusted { return select(this.maxFD+1, &readfds, &writefds, &statusfds, timeout == Duration.max ? null : &ts); } ();
//writefln("%.3f: select out", Clock.currAppTick.usecs * 1e-3);
//print("Done wait for event...");
		if (ret > 0) {
			enumerateFDs!(EventType.read)((fd) @trusted {
				if (FD_ISSET(cast(sock_t)fd, &readfds))
					notify!(EventType.read)(fd);
			});
			enumerateFDs!(EventType.write)((fd) @trusted {
				if (FD_ISSET(cast(sock_t)fd, &writefds))
					notify!(EventType.write)(fd);
			});
			enumerateFDs!(EventType.status)((fd) @trusted {
				if (FD_ISSET(cast(sock_t)fd, &statusfds))
					notify!(EventType.status)(fd);
			});
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
	}

	override void registerFD(FD fd, EventMask mask, bool edge_triggered = true)
	{
	}

	override void unregisterFD(FD fd, EventMask mask)
	{
	}

	override void updateFD(FD fd, EventMask old_mask, EventMask mask, bool edge_triggered = true)
	{
	}
}

private timeval toTimeVal(Duration dur)
{
	timeval tvdur;
	dur.split!("seconds", "usecs")(tvdur.tv_sec, tvdur.tv_usec);
	return tvdur;
}
