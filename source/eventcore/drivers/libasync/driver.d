/**
	libasync based event driver implementation.

	Optional backend (`dub --config=libasync`) that maps eventcore's proactor
	API onto libasync's reactor objects (`EventLoop`, `AsyncTCPConnection`,
	`AsyncUDPSocket`, `AsyncDNS`, `AsyncSignal`, `AsyncDirectoryWatcher`).

	The mapping is the same one the vibe.0 `LibasyncDriver` uses: drain TCP
	reads until a short `recv`, treat `Status.ASYNC` as a write-blocked edge,
	and wake a parked `loop()` through `AsyncSignal`. Timers reuse
	`LoopTimeoutTimerDriver` and files reuse `ThreadedFileEventDriver` so the
	hot paths stay on the implementations the other drivers already ship.

	Processes, pipes and POSIX signal listening are not provided by libasync
	and return invalid handles instead of aborting.
*/
module eventcore.drivers.libasync.driver;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.core;
import eventcore.drivers.libasync.dns;
import eventcore.drivers.libasync.events;
import eventcore.drivers.libasync.sockets;
import eventcore.drivers.libasync.unsupported;
import eventcore.drivers.libasync.watchers;
import eventcore.drivers.threadedfile;
import eventcore.drivers.timer;
import eventcore.internal.utils : mallocT, freeT;
import libasync : EventLoop;


final class LibasyncEventDriver : EventDriver {
	private {
		alias FileDriver = ThreadedFileEventDriver!(LibasyncEventDriverEvents, LibasyncEventDriverCore);

		EventLoop m_loop;
		LibasyncEventDriverCore m_core;
		FileDriver m_files;
		LibasyncEventDriverSockets m_sockets;
		LibasyncEventDriverDNS m_dns;
		LoopTimeoutTimerDriver m_timers;
		LibasyncEventDriverEvents m_events;
		LibasyncEventDriverSignals m_signals;
		LibasyncEventDriverWatchers m_watchers;
		LibasyncEventDriverProcesses m_processes;
		LibasyncEventDriverPipes m_pipes;
	}

	static LibasyncEventDriver threadInstance;

	this()
	@trusted nothrow @nogc {
		assert(threadInstance is null);
		threadInstance = this;

		static void init(LibasyncEventDriver self) nothrow {
			try self.m_loop = new EventLoop;
			catch (Exception e) assert(false, e.msg);
			self.m_timers = mallocT!LoopTimeoutTimerDriver();
			self.m_core = mallocT!LibasyncEventDriverCore(self.m_loop, self.m_timers);
			self.m_events = mallocT!LibasyncEventDriverEvents(self.m_core);
			self.m_sockets = mallocT!LibasyncEventDriverSockets(self.m_core);
			self.m_dns = mallocT!LibasyncEventDriverDNS(self.m_core);
			self.m_files = mallocT!FileDriver(self.m_events, self.m_core);
			self.m_watchers = mallocT!LibasyncEventDriverWatchers(self.m_core);
			self.m_signals = mallocT!LibasyncEventDriverSignals();
			self.m_processes = mallocT!LibasyncEventDriverProcesses();
			self.m_pipes = mallocT!LibasyncEventDriverPipes();
			self.m_core.finalizeInit(self.m_sockets);
		}
		(cast(void function(LibasyncEventDriver) @nogc nothrow)&init)(this);
	}

@safe: /*@nogc:*/ nothrow:

	override @property inout(LibasyncEventDriverCore) core() inout { return m_core; }
	override @property shared(inout(LibasyncEventDriverCore)) core() inout shared { return m_core; }
	override @property inout(FileDriver) files() inout { return m_files; }
	override @property inout(LibasyncEventDriverSockets) sockets() inout { return m_sockets; }
	override @property inout(LibasyncEventDriverDNS) dns() inout { return m_dns; }
	override @property inout(LoopTimeoutTimerDriver) timers() inout { return m_timers; }
	override @property inout(LibasyncEventDriverEvents) events() inout { return m_events; }
	override @property shared(inout(LibasyncEventDriverEvents)) events() inout shared { return m_events; }
	override @property inout(LibasyncEventDriverSignals) signals() inout { return m_signals; }
	override @property inout(LibasyncEventDriverWatchers) watchers() inout { return m_watchers; }
	override @property inout(LibasyncEventDriverProcesses) processes() inout { return m_processes; }
	override @property inout(LibasyncEventDriverPipes) pipes() inout { return m_pipes; }

	override bool dispose()
	{
		if (!m_core) return true;

		if (m_core.waiterCount > m_timers.pendingCount) {
			import eventcore.internal.utils : print;
			print("Warning: leaking libasync eventcore driver because waiters are still active");
			return false;
		}
		if (m_sockets.hasLeakedHandles || m_events.hasLeakedHandles
			|| m_watchers.hasLeakedHandles || m_dns.hasLeakedHandles)
			return false;

		m_files.dispose();
		m_watchers.dispose();
		m_dns.dispose();
		m_sockets.dispose();
		m_events.dispose();
		m_core.dispose();
		m_timers.dispose();

		assert(threadInstance !is null);
		threadInstance = null;

		try () @trusted {
			freeT(m_pipes);
			freeT(m_processes);
			freeT(m_signals);
			freeT(m_watchers);
			freeT(m_files);
			freeT(m_dns);
			freeT(m_sockets);
			freeT(m_events);
			freeT(m_core);
			freeT(m_timers);
			m_loop.exit();
			destroy(m_loop);
			m_loop = null;
		} ();
		catch (Exception e) assert(false, e.msg);

		return true;
	}
}
