module eventcore.core;

public import eventcore.driver;

import eventcore.drivers.posix.cfrunloop;
import eventcore.drivers.posix.epoll;
import eventcore.drivers.posix.kqueue;
import eventcore.drivers.posix.select;
import eventcore.drivers.libasync;
import eventcore.drivers.winapi.driver;
import eventcore.internal.utils : mallocT, freeT;

version (EventcoreEpollDriver) alias NativeEventDriver = EpollEventDriver;
else version (EventcoreCFRunLoopDriver) alias NativeEventDriver = CFRunLoopEventDriver;
else version (EventcoreKqueueDriver) alias NativeEventDriver = KqueueEventDriver;
else version (EventcoreWinAPIDriver) alias NativeEventDriver = WinAPIEventDriver;
else version (EventcoreLibasyncDriver) alias NativeEventDriver = LibasyncEventDriver;
else version (EventcoreSelectDriver) alias NativeEventDriver = SelectEventDriver;
else alias NativeEventDriver = EventDriver;

@property NativeEventDriver eventDriver()
@safe @nogc nothrow {
	static if (is(NativeEventDriver == EventDriver))
		assert(s_driver !is null, "setupEventDriver() was not called for this thread.");
	else {
		if (!s_driver) {
			s_driver = mallocT!NativeEventDriver;
		}
	}
	return s_driver;
}

static if (!is(NativeEventDriver == EventDriver)) {
	static this()
	{
		if (!s_isMainThread) {
			s_initCount++;
		}
	}

	static ~this()
	{
		if (!s_isMainThread) {
			if (!--s_initCount) {
				if (s_driver) {
					if (s_driver.dispose())
						freeT(s_driver);
				}
			}
		}
	}

	shared static this()
	{
		if (!s_initCount++) {
			s_isMainThread = true;
		}
	}

	shared static ~this()
	{
		if (!--s_initCount) {
			if (s_driver) {
				if (s_driver.dispose())
					freeT(s_driver);
			}
		}
	}
} else {
	void setupEventDriver(EventDriver driver)
	{
		assert(driver !is null, "The event driver instance must be non-null.");
		assert(!s_driver, "Can only set up the event driver once per thread.");
		s_driver = driver;
	}
}

private {
	NativeEventDriver s_driver;
	bool s_isMainThread;
	// keeps track of nested DRuntime initializations that happen when
	// (un)loading shared libaries.
	int s_initCount = 0;
}
