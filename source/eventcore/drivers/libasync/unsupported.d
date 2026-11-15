/**
	Handles libasync cannot implement: POSIX signals, processes and pipes.

	These return invalid handles and no-op on use so a process that never
	touches them stays stable. Callers that do use them get a clean failure
	instead of `assert(false)`.
*/
module eventcore.drivers.libasync.unsupported;

version (EventcoreLibasyncDriver):

import eventcore.driver;


final class LibasyncEventDriverSignals : EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	override SignalListenID listen(int sig, SignalCallback on_signal)
	{
		return SignalListenID.invalid;
	}

	override bool isValid(SignalListenID handle) const @nogc { return false; }
	override void addRef(SignalListenID descriptor) {}
	override bool releaseRef(SignalListenID descriptor) { return true; }
}


final class LibasyncEventDriverProcesses : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
	void dispose() {}

	override ProcessID adopt(int system_pid) { return ProcessID.invalid; }

	override Process spawn(string[] args, ProcessStdinFile stdin, ProcessStdoutFile stdout,
		ProcessStderrFile stderr, const string[string] env = null,
		ProcessConfig config = ProcessConfig.none, string working_dir = null)
	{
		return Process.init;
	}

	override bool hasExited(ProcessID pid) { return true; }
	override void kill(ProcessID pid, int signal) {}
	override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit) { return 0; }
	override void cancelWait(ProcessID pid, size_t waitId) {}
	override bool isValid(ProcessID handle) const @nogc { return false; }
	override void addRef(ProcessID pid) {}
	override bool releaseRef(ProcessID pid) { return true; }

	protected override void* rawUserData(ProcessID descriptor, size_t size,
		DataInitializer initialize, DataInitializer destroy)
	@system {
		return null;
	}

	package @property size_t pendingCount() const nothrow { return 0; }
}


final class LibasyncEventDriverPipes : EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
	override PipeFD adopt(int system_pipe_handle) { return PipeFD.invalid; }

	override void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish)
	{
		if (on_read_finish) on_read_finish(pipe, IOStatus.invalidHandle, 0);
	}

	override void cancelRead(PipeFD pipe) {}

	override void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish)
	{
		if (on_write_finish) on_write_finish(pipe, IOStatus.invalidHandle, 0);
	}

	override void cancelWrite(PipeFD pipe) {}

	override void waitForData(PipeFD pipe, PipeIOCallback on_data_available)
	{
		if (on_data_available) on_data_available(pipe, IOStatus.invalidHandle, 0);
	}

	override void close(PipeFD file, PipeCloseCallback on_closed)
	{
		if (on_closed) on_closed(file, CloseStatus.invalidHandle);
	}

	override bool isValid(PipeFD handle) const @nogc { return false; }
	override void addRef(PipeFD pid) {}
	override bool releaseRef(PipeFD pid) { return true; }

	protected override void* rawUserData(PipeFD descriptor, size_t size,
		DataInitializer initialize, DataInitializer destroy)
	@system {
		return null;
	}
}
