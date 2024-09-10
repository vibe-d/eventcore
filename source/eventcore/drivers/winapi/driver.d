/**
	WinAPI based event driver implementation.

	This driver uses overlapped I/O to model asynchronous I/O operations
	efficiently. The driver's event loop processes UI messages, so that
	it integrates with GUI applications transparently.
*/
module eventcore.drivers.winapi.driver;

version (Windows):

import eventcore.driver;
import eventcore.drivers.timer;
import eventcore.drivers.winapi.core;
import eventcore.drivers.winapi.dns;
import eventcore.drivers.winapi.events;
import eventcore.drivers.winapi.files;
import eventcore.drivers.winapi.pipes;
import eventcore.drivers.winapi.processes;
import eventcore.drivers.winapi.signals;
import eventcore.drivers.winapi.sockets;
import eventcore.drivers.winapi.watchers;
import eventcore.internal.utils : mallocT, freeT;
import core.sys.windows.windows;

static assert(HANDLE.sizeof <= FD.BaseType.sizeof);
static assert(FD(cast(size_t)INVALID_HANDLE_VALUE, 0) == FD.init);


final class WinAPIEventDriver : EventDriver {
	private {
		WinAPIEventDriverCore m_core;
		WinAPIEventDriverFiles m_files;
		WinAPIEventDriverSockets m_sockets;
		WinAPIEventDriverDNS m_dns;
		LoopTimeoutTimerDriver m_timers;
		WinAPIEventDriverEvents m_events;
		WinAPIEventDriverSignals m_signals;
		WinAPIEventDriverWatchers m_watchers;
		WinAPIEventDriverProcesses m_processes;
		WinAPIEventDriverPipes m_pipes;
	}

	static WinAPIEventDriver threadInstance;

	this()
	@safe nothrow @nogc {
		assert(threadInstance is null);
		threadInstance = this;

		import std.exception : enforce;

		WSADATA wd;

		auto res = () @trusted { return WSAStartup(0x0202, &wd); } ();
		assert(res == 0, "Failed to initialize WinSock");

		m_signals = mallocT!WinAPIEventDriverSignals();
		m_timers = mallocT!LoopTimeoutTimerDriver();
		m_core = mallocT!WinAPIEventDriverCore(m_timers);
		m_events = mallocT!WinAPIEventDriverEvents(m_core);
		m_files = mallocT!WinAPIEventDriverFiles(m_core);
		m_sockets = mallocT!WinAPIEventDriverSockets(m_core);
		m_pipes = mallocT!WinAPIEventDriverPipes();
		m_dns = mallocT!WinAPIEventDriverDNS();
		m_watchers = mallocT!WinAPIEventDriverWatchers(m_core);
		m_processes = mallocT!WinAPIEventDriverProcesses();
	}

@safe: /*@nogc:*/ nothrow:

	override @property inout(WinAPIEventDriverCore) core() inout { return m_core; }
	override @property shared(inout(WinAPIEventDriverCore)) core() inout shared { return m_core; }
	override @property inout(WinAPIEventDriverFiles) files() inout { return m_files; }
	override @property inout(WinAPIEventDriverSockets) sockets() inout { return m_sockets; }
	override @property inout(WinAPIEventDriverDNS) dns() inout { return m_dns; }
	override @property inout(LoopTimeoutTimerDriver) timers() inout { return m_timers; }
	override @property inout(WinAPIEventDriverEvents) events() inout { return m_events; }
	override @property shared(inout(WinAPIEventDriverEvents)) events() inout shared { return m_events; }
	override @property inout(WinAPIEventDriverSignals) signals() inout { return m_signals; }
	override @property inout(WinAPIEventDriverWatchers) watchers() inout { return m_watchers; }
	override @property inout(WinAPIEventDriverProcesses) processes() inout { return m_processes; }
	override @property inout(WinAPIEventDriverPipes) pipes() inout { return m_pipes; }

	override bool dispose()
	{
		if (!m_events) return true;

		if (m_core.checkForLeakedHandles()) return false;
		if (m_events.checkForLeakedHandles()) return false;
		if (m_sockets.checkForLeakedHandles()) return false;

		m_events.dispose();
		m_core.dispose();
		m_timers.dispose();
		assert(threadInstance !is null);
		threadInstance = null;

		try () @trusted {
			freeT(m_processes);
			freeT(m_watchers);
			freeT(m_dns);
			freeT(m_pipes);
			freeT(m_sockets);
			freeT(m_files);
			freeT(m_events);
			freeT(m_core);
			freeT(m_timers);
			freeT(m_signals);
		} ();
		catch (Exception e) assert(false, e.msg);

		return true;
	}
}
