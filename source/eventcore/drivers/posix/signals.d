module eventcore.drivers.posix.signals;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;

import std.algorithm.comparison : among;


final class SignalFDEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.signal;
	import core.sys.posix.unistd : close, read, write;
	import core.sys.linux.sys.signalfd;

	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return listenInternal(sig, on_signal, false);
	}

	package SignalListenID listenInternal(int sig, SignalCallback on_signal, bool is_internal = true)
	{
		auto fd = () @trusted {
			sigset_t sset;
			sigemptyset(&sset);
			sigaddset(&sset, sig);

			if (sigprocmask(SIG_BLOCK, &sset, null) != 0)
				return SignalListenID.invalid;

			return SignalListenID(signalfd(-1, &sset, SFD_NONBLOCK));
		} ();


		m_loop.initFD(cast(FD)fd, is_internal ? FDFlags.internal : FDFlags.none);
		m_loop.m_fds[fd].specific = SignalSlot(on_signal);
		m_loop.registerFD(cast(FD)fd, EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(cast(FD)fd, &onSignal);

		onSignal(cast(FD)fd);

		return fd;
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(m_loop.m_fds[descriptor].common.refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].common.refCount++;
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		FD fd = cast(FD)descriptor;
		assert(m_loop.m_fds[fd].common.refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].common.refCount == 1) { // NOTE: 1 because setNotifyCallback adds a second reference
			m_loop.unregisterFD(fd, EventMask.read);
			m_loop.clearFD(fd);
			close(cast(int)fd);
			return false;
		}
		return true;
	}

	private bool onSignal(FD fd)
	{
		SignalListenID lid = cast(SignalListenID)fd;
		signalfd_siginfo nfo;
		do {
			auto ret = () @trusted { return read(cast(int)fd, &nfo, nfo.sizeof); } ();
			if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS))
				break;
			auto cb = m_loop.m_fds[fd].signal.callback;
			if (ret != nfo.sizeof) {
				cb(lid, SignalStatus.error, -1);
				return false;
			}
			addRef(lid);
			cb(lid, SignalStatus.ok, nfo.ssi_signo);
			releaseRef(lid);
		} while (m_loop.m_fds[fd].common.refCount > 0);
		return false;
	}
}

final class DummyEventDriverSignals(Loop : PosixEventLoop) : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:

	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return listenInternal(sig, on_signal, false);
	}

	package SignalListenID listenInternal(int sig, SignalCallback on_signal, bool is_internal = true)
	{
		assert(false);
	}

	override void addRef(SignalListenID descriptor)
	{
		assert(false);
	}

	override bool releaseRef(SignalListenID descriptor)
	{
		assert(false);
	}
}

package struct SignalSlot {
	alias Handle = SignalListenID;
	SignalCallback callback;
}
