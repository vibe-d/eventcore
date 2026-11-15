module eventcore.drivers.libasync.core;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.sockets;
import eventcore.drivers.timer;
import eventcore.internal.consumablequeue;
import eventcore.internal.utils : mallocT, freeT, print;
import libasync : EventLoop;
import libasync.signal : AsyncSignal;
import core.sync.mutex : Mutex;
import core.time : Duration, MonoTime, seconds;
import std.typecons : Tuple;


final class LibasyncEventDriverCore : EventDriverCore {
@safe: /*@nogc:*/ nothrow:

	private alias ThreadCallbackEntry = Tuple!(ThreadCallbackGen, ThreadCallbackGenParams);

	private {
		EventLoop m_loop;
		LoopTimeoutTimerDriver m_timers;
		LibasyncEventDriverSockets m_sockets;
		shared AsyncSignal m_wake;
		shared Mutex m_threadCallbackMutex;
		ConsumableQueue!ThreadCallbackEntry m_threadCallbacks;
		size_t m_waiterCount;
		bool m_exit;
		bool m_initialized;
	}

	this(EventLoop loop, LoopTimeoutTimerDriver timers)
	@trusted @nogc {
		static void init(LibasyncEventDriverCore self, EventLoop evl, LoopTimeoutTimerDriver timers) nothrow {
			self.m_loop = evl;
			self.m_timers = timers;
			self.m_threadCallbackMutex = mallocT!(shared(Mutex));
			self.m_threadCallbacks = mallocT!(ConsumableQueue!ThreadCallbackEntry);
			self.m_threadCallbacks.reserve(64);
			try self.m_wake = new shared AsyncSignal(evl);
			catch (Exception e) assert(false, e.msg);
			if (!self.m_wake.run({ self.drainThreadCallbacks(); }))
				assert(false, "Failed to register libasync wake signal");
			self.m_initialized = true;
		}
		(cast(void function(LibasyncEventDriverCore, EventLoop, LoopTimeoutTimerDriver) @nogc nothrow)&init)(this, loop, timers);
	}

	package void finalizeInit(LibasyncEventDriverSockets sockets)
	{
		m_sockets = sockets;
	}

	package @property EventLoop evloop() { return m_loop; }

	/// Lets `ThreadedFileEventDriver` increment the waiter count through `.loop`.
	@property LibasyncEventDriverCore loop() { return this; }

	void addWaiter() @nogc { m_waiterCount++; }
	void removeWaiter()
	@nogc {
		assert(m_waiterCount > 0, "Decrementing waiter count below zero.");
		m_waiterCount--;
	}

	override size_t waiterCount() { return m_waiterCount + m_timers.pendingCount; }

	void dispose()
	@trusted {
		if (!m_initialized) return;
		if (m_wake) {
			m_wake.kill();
			m_wake = null;
		}
		try {
			freeT(m_threadCallbacks);
			freeT(m_threadCallbackMutex);
		} catch (Exception e) assert(false, e.msg);
		m_initialized = false;
	}

	override ExitReason processEvents(Duration timeout = Duration.max)
	{
		import std.algorithm : min;

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
			got_event |= drainThreadCallbacks();
			auto prev = now;
			now = MonoTime.currTime;
			got_event |= m_timers.process(now);

			if (m_exit) {
				m_exit = false;
				return ExitReason.exited;
			} else if (got_event) break;
			if (timeout != Duration.max)
				timeout -= now - prev;
		} while (timeout > 0.seconds);

		if (!waiterCount) return ExitReason.outOfWaiters;
		if (got_event) return ExitReason.idle;
		return ExitReason.timeout;
	}

	private bool doProcessEvents(Duration timeout)
	@trusted {
		Duration wait = timeout;
		if (wait < Duration.zero) wait = 0.seconds;
		else if (wait == Duration.max) wait = -1.seconds;
		return m_loop.loop(wait);
	}

	override void exit()
	@trusted {
		m_exit = true;
		if (m_wake) m_wake.trigger();
	}

	override void clearExitFlag()
	{
		m_exit = false;
	}

	override void runInOwnerThread(ThreadCallbackGen del, ref ThreadCallbackGenParams params)
	shared {
		import core.atomic : atomicLoad;

		auto m = atomicLoad(m_threadCallbackMutex);
		if (!m) return;

		try {
			synchronized (m)
				() @trusted { return (cast()this).m_threadCallbacks; } ()
					.put(ThreadCallbackEntry(del, params));
		} catch (Exception e) assert(false, e.msg);

		auto wake = () @trusted { return (cast()this).m_wake; } ();
		if (wake) {
			try () @trusted { wake.trigger(); } ();
			catch (Exception) {}
		}
	}

	alias runInOwnerThread = EventDriverCore.runInOwnerThread;

	private bool drainThreadCallbacks()
	@trusted {
		bool got;
		while (m_threadCallbacks.length) {
			auto cb = m_threadCallbacks.consumeOne();
			cb[0](cb[1]);
			got = true;
		}
		return got;
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return m_sockets.userDataFor(descriptor, size, initialize, destroy);
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return m_sockets.userDataFor(descriptor, size, initialize, destroy);
	}
}
