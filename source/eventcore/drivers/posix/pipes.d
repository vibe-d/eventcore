module eventcore.drivers.posix.pipes;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.utils : nogc_assert, print;

import std.algorithm : min, max;


final class PosixEventDriverPipes(Loop : PosixEventLoop) : EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
	import core.stdc.errno : errno, EAGAIN;
	import core.sys.posix.unistd : close, read, write;
	import core.sys.posix.fcntl;
	import core.sys.posix.poll;

	private Loop m_loop;

	this(Loop loop)
	@nogc {
		m_loop = loop;
	}

	final override PipeFD adopt(int system_fd)
	{
		if (m_loop.m_fds[system_fd].common.refCount) // FD already in use?
			return PipeFD.invalid;

        // Suprisingly cannot use O_CLOEXEC here, so use FD_CLOEXEC instead.
        () @trusted { fcntl(system_fd, F_SETFL, fcntl(system_fd, F_GETFL) | O_NONBLOCK | FD_CLOEXEC); } ();

		auto fd = m_loop.initFD!PipeFD(system_fd, FDFlags.none, PipeSlot.init);
		m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
		return fd;
	}

	final override void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish)
	{
		if (!isValid(pipe)) {
			on_read_finish(pipe, IOStatus.invalidHandle, 0);
			return;
		}

		auto ret = () @trusted { return read(cast(int)pipe, buffer.ptr, min(buffer.length, int.max)); } ();

		// Read failed
		if (ret < 0) {
			auto err = errno;
			if (err != EAGAIN) {
				print("Pipe error %s!", err);
				on_read_finish(pipe, IOStatus.error, 0);
				return;
			}
		}

		// EOF
		if (ret == 0 && buffer.length > 0) {
			on_read_finish(pipe, IOStatus.disconnected, 0);
			return;
		}

		// Handle immediate mode
		if (ret < 0 && mode == IOMode.immediate) {
			on_read_finish(pipe, IOStatus.wouldBlock, 0);
			return;
		}

		// Handle successful read
		if (ret >= 0) {
			buffer = buffer[ret .. $];

			// Handle completed read
			if (mode != IOMode.all || buffer.length == 0) {
				on_read_finish(pipe, IOStatus.ok, ret);
				return;
			}
		}

		auto slot = () @trusted { return &m_loop.m_fds[pipe].pipe(); } ();
		assert(slot.readCallback is null, "Concurrent reads are not allowed.");
		slot.readCallback = on_read_finish;
		slot.readMode = mode;
		slot.bytesRead = max(ret, 0);
		slot.readBuffer = buffer;

		// Need to use EventType.status as well, as pipes don't otherwise notify
		// of closes
		m_loop.setNotifyCallback!(EventType.read)(pipe, &onPipeRead);
		m_loop.setNotifyCallback!(EventType.status)(pipe, &onPipeRead);
	}

	private void onPipeRead(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].pipe(); } ();
		auto pipe = cast(PipeFD)fd;

		void finalize(IOStatus status)
		{
			addRef(pipe);
			scope(exit) releaseRef(pipe);

			m_loop.setNotifyCallback!(EventType.read)(pipe, null);
			m_loop.setNotifyCallback!(EventType.status)(pipe, null);
			auto cb = slot.readCallback;
			slot.readCallback = null;
			slot.readBuffer = null;
			cb(pipe, status, slot.bytesRead);
		}

		ssize_t ret = () @trusted { return read(cast(int)pipe, slot.readBuffer.ptr, min(slot.readBuffer.length, int.max)); } ();

		// Read failed
		if (ret < 0) {
			auto err = errno;
			if (err != EAGAIN) {
				print("Pipe error %s!", err);
				finalize(IOStatus.error);
				return;
			}
		}

		// EOF
		if (ret == 0 && slot.readBuffer.length > 0) {
			finalize(IOStatus.disconnected);
			return;
		}

		// Successful read
		if (ret > 0 || !slot.readBuffer.length) {
			slot.readBuffer = slot.readBuffer[ret .. $];
			slot.bytesRead += ret;

			// Handle completed read
			if (slot.readMode != IOMode.all || slot.readBuffer.length == 0) {
				finalize(IOStatus.ok);
				return;
			}
		}
	}

	final override void cancelRead(PipeFD pipe)
	{
		if (!isValid(pipe)) return;

		auto slot = () @trusted { return &m_loop.m_fds[pipe].pipe(); } ();
		assert(slot.readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(pipe, null);
		slot.readBuffer = null;
	}

	final override void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish)
	{
		if (!isValid(pipe)) {
			on_write_finish(pipe, IOStatus.invalidHandle, 0);
			return;
		}

		if (buffer.length == 0) {
			on_write_finish(pipe, IOStatus.ok, 0);
			return;
		}

		ssize_t ret = () @trusted { return write(cast(int)pipe, buffer.ptr, min(buffer.length, int.max)); } ();

		if (ret < 0) {
			auto err = errno;
			if (err != EAGAIN) {
				on_write_finish(pipe, IOStatus.error, 0);
				return;
			}

			if (mode == IOMode.immediate) {
				on_write_finish(pipe, IOStatus.wouldBlock, 0);
				return;
			}
		} else {
			buffer = buffer[ret .. $];

			if (mode != IOMode.all || buffer.length == 0) {
				on_write_finish(pipe, IOStatus.ok, ret);
				return;
			}
		}

		auto slot = () @trusted { return &m_loop.m_fds[pipe].pipe(); } ();
		assert(slot.writeCallback is null, "Concurrent writes not allowed.");
		slot.writeCallback = on_write_finish;
		slot.writeMode = mode;
		slot.bytesWritten = max(ret, 0);
		slot.writeBuffer = buffer;

		m_loop.setNotifyCallback!(EventType.write)(pipe, &onPipeWrite);
	}

	private void onPipeWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].pipe(); } ();
		auto pipe = cast(PipeFD)fd;

		void finalize(IOStatus status)
		{
			addRef(pipe);
			scope(exit) releaseRef(pipe);

			m_loop.setNotifyCallback!(EventType.write)(pipe, null);
			auto cb = slot.writeCallback;
			slot.writeCallback = null;
			slot.writeBuffer = null;
			cb(pipe, status, slot.bytesWritten);
		}

		ssize_t ret = () @trusted { return write(cast(int)pipe, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max)); } ();

		if (ret < 0) {
			auto err = errno;
			if (err != EAGAIN) {
				finalize(IOStatus.error);
			}
		} else {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];

			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				finalize(IOStatus.ok);
			}
		}

	}

	final override void cancelWrite(PipeFD pipe)
	{
		if (!isValid(pipe)) return;

		auto slot = () @trusted { return &m_loop.m_fds[pipe].pipe(); } ();
		assert(slot.writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(pipe, null);
		slot.writeCallback = null;
		slot.writeBuffer = null;
	}

	final override void waitForData(PipeFD pipe, PipeIOCallback on_data_available)
	{
		if (!isValid(pipe)) {
			on_data_available(pipe, IOStatus.invalidHandle, 0);
			return;
		}

		if (pollPipe(pipe, on_data_available))
		{
			return;
		}

		auto slot = () @trusted { return &m_loop.m_fds[pipe].pipe(); } ();

		assert(slot.readCallback is null, "Concurrent reads are not allowed.");
		slot.readCallback = on_data_available;
		slot.readMode = IOMode.once; // currently meaningless
		slot.bytesRead = 0; // currently meaningless
		slot.readBuffer = null;
		m_loop.setNotifyCallback!(EventType.read)(pipe, &onPipeDataAvailable);
	}

	private void onPipeDataAvailable(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].pipe(); } ();
		auto pipe = cast(PipeFD)fd;

		auto callback = (PipeFD f, IOStatus s, size_t m) {
			addRef(f);
			scope(exit) releaseRef(f);

			auto cb = slot.readCallback;
			slot.readCallback = null;
			slot.readBuffer = null;
			cb(f, s, m);
		};

		if (pollPipe(pipe, callback))
		{
			m_loop.setNotifyCallback!(EventType.read)(pipe, null);
		}
	}

	private bool pollPipe(PipeFD pipe, PipeIOCallback callback)
	@trusted {
		// Use poll to check if any data is available
		pollfd pfd;
		pfd.fd = cast(int)pipe;
		pfd.events = POLLIN;
		int ret = poll(&pfd, 1, 0);

		if (ret == -1) {
			print("Error polling pipe: %s!", errno);
			callback(pipe, IOStatus.error, 0);
			return true;
		}

		if (ret == 1) {
			callback(pipe, IOStatus.error, 0);
			return true;
		}

		return false;
	}

	final override void close(PipeFD pipe, PipeCloseCallback on_closed)
	{
		if (!isValid(pipe)) {
			on_closed(pipe, CloseStatus.invalidHandle);
			return;
		}

		int res = close(cast(int)pipe);
		m_loop.unregisterFD(pipe, EventMask.read|EventMask.write|EventMask.status);
		m_loop.clearFD!PipeSlot(pipe);

		if (on_closed)
			on_closed(pipe, res == 0 ? CloseStatus.ok : CloseStatus.ioError);
	}

	override bool isValid(PipeFD handle)
	const {
		if (handle.value >= m_loop.m_fds.length) return false;
		return m_loop.m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	final override void addRef(PipeFD pipe)
	{
		if (!isValid(pipe)) return;

		auto slot = () @trusted { return &m_loop.m_fds[pipe]; } ();
		assert(slot.common.refCount > 0, "Adding reference to unreferenced pipe FD.");
		slot.common.refCount++;
	}

	final override bool releaseRef(PipeFD pipe)
	{
		import taggedalgebraic : hasType;

		if (!isValid(pipe)) return true;

		auto slot = () @trusted { return &m_loop.m_fds[pipe]; } ();
		nogc_assert(slot.common.refCount > 0, "Releasing reference to unreferenced pipe FD.");

		if (--slot.common.refCount == 0) {
			close(pipe, null);
			return false;
		}
		return true;
	}

	final protected override void* rawUserData(PipeFD fd, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return m_loop.rawUserDataImpl(fd, size, initialize, destroy);
	}
}

final class DummyEventDriverPipes(Loop : PosixEventLoop) : EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
	this(Loop loop) {}

	override PipeFD adopt(int system_pipe_handle)
	{
		assert(false, "TODO!");
	}

	override void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelRead(PipeFD pipe)
	{
		assert(false, "TODO!");
	}

	override void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish)
	{
		assert(false, "TODO!");
	}

	override void cancelWrite(PipeFD pipe)
	{
		assert(false, "TODO!");
	}

	override void waitForData(PipeFD pipe, PipeIOCallback on_data_available)
	{
		assert(false, "TODO!");
	}

	override void close(PipeFD pipe, PipeCloseCallback on_closed)
	{
		if (!isValid(pipe)) {
			on_closed(pipe, CloseStatus.invalidHandle);
			return;
		}

		assert(false, "TODO!");
	}

	override bool isValid(PipeFD handle)
	const {
		return false;
	}

	override void addRef(PipeFD pid)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(PipeFD pid)
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(PipeFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		assert(false, "TODO!");
	}
}


package struct PipeSlot {
	alias Handle = PipeFD;

	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	PipeIOCallback readCallback;

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	PipeIOCallback writeCallback;
}
