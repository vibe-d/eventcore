module eventcore.drivers.posix.processes;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.drivers.posix.signals;
import eventcore.internal.utils : nogc_assert, print;

import std.algorithm.comparison : among;
import std.variant : visit;
import std.stdint;



private enum SIGCHLD = 17;

final class PosixEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
	import core.sync.mutex : Mutex;
	import core.sys.posix.unistd : dup;
	import core.thread : Thread;

	private {
		static shared Mutex s_mutex;
		static __gshared ProcessInfo[int] s_processes;
		static __gshared Thread s_waitThread;

		Loop m_loop;
		// FIXME: avoid virtual funciton calls and use the final type instead
		EventDriver m_driver;
		uint m_validationCounter;
	}

	this(Loop loop, EventDriver driver)
	{
		m_loop = loop;
		m_driver = driver;
	}

	void dispose()
	{
	}

	final override ProcessID adopt(int system_pid)
	{
		ProcessInfo info;
		info.exited = false;
		info.refCount = 1;
		info.validationCounter = ++m_validationCounter;
		info.driver = this;

		auto pid = ProcessID(system_pid, info.validationCounter);
		add(system_pid, info);
		return pid;
	}

	final override Process spawn(
		string[] args,
		ProcessStdinFile stdin,
		ProcessStdoutFile stdout,
		ProcessStderrFile stderr,
		const string[string] env,
		ProcessConfig config,
		string working_dir)
	@trusted {
		// Use std.process to spawn processes
		version (iOS) {
			return Process.init;
		} else {
			import std.process : pipe, Pid, spawnProcess, StdProcessConfig = Config;
			import std.stdio : File;
			static import std.stdio;

			static File fdToFile(int fd, scope const(char)[] mode)
			{
				try {
					File f;
					f.fdopen(fd, mode);
					return f;
				} catch (Exception e) {
					assert(0);
				}
			}

			try {
				Process process;
				File stdinFile, stdoutFile, stderrFile;

				stdinFile = stdin.visit!(
					(int handle) => fdToFile(handle, "r"),
					(ProcessRedirect redirect) {
						final switch (redirect) {
						case ProcessRedirect.inherit: return std.stdio.stdin;
						case ProcessRedirect.none: return File.init;
						case ProcessRedirect.pipe:
							auto p = pipe();
							process.stdin = m_driver.pipes.adopt(dup(p.writeEnd.fileno));
							return p.readEnd;
						}
					});

				stdoutFile = stdout.visit!(
					(int handle) => fdToFile(handle, "w"),
					(ProcessRedirect redirect) {
						final switch (redirect) {
						case ProcessRedirect.inherit: return std.stdio.stdout;
						case ProcessRedirect.none: return File.init;
						case ProcessRedirect.pipe:
							auto p = pipe();
							process.stdout = m_driver.pipes.adopt(dup(p.readEnd.fileno));
							return p.writeEnd;
						}
					},
					(_) => File.init);

				stderrFile = stderr.visit!(
					(int handle) => fdToFile(handle, "w"),
					(ProcessRedirect redirect) {
						final switch (redirect) {
						case ProcessRedirect.inherit: return std.stdio.stderr;
						case ProcessRedirect.none: return File.init;
						case ProcessRedirect.pipe:
							auto p = pipe();
							process.stderr = m_driver.pipes.adopt(dup(p.readEnd.fileno));
							return p.writeEnd;
						}
					},
					(_) => File.init);

				const redirectStdout = stdout.convertsTo!ProcessStdoutRedirect;
				const redirectStderr = stderr.convertsTo!ProcessStderrRedirect;

				if (redirectStdout) {
					assert(!redirectStderr, "Can't redirect both stdout and stderr");

					stdoutFile = stderrFile;
				} else if (redirectStderr) {
					stderrFile = stdoutFile;
				}

				Pid stdPid = spawnProcess(
					args,
					stdinFile,
					stdoutFile,
					stderrFile,
					env,
					cast(StdProcessConfig)config,
					working_dir);
				process.pid = adopt(stdPid.osHandle);
				stdPid.destroy();

				return process;
			} catch (Exception e) {
				return Process.init;
			}
		}
	}

	final override void kill(ProcessID pid, int signal)
	@trusted {
		import core.sys.posix.signal : pkill = kill;

		if (!isValid(pid)) return;

		if (cast(int)pid > 0)
			pkill(cast(int)pid, signal);
	}

	final override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
	{
		bool exited;
		int exitCode;

		size_t id = size_t.max;
		lockedProcessInfo(pid, (info) {
			if (!info) return;

			if (info.exited) {
				exited = true;
				exitCode = info.exitCode;
			} else {
				info.callbacks ~= on_process_exit;
				id = info.callbacks.length - 1;
			}
		});

		if (exited) {
			on_process_exit(pid, exitCode);
		}

		return id;
	}

	final override void cancelWait(ProcessID pid, size_t wait_id)
	{
		if (wait_id == size_t.max) return;

		lockedProcessInfo(pid, (info) {
			if (!info) return;

			assert(!info.exited, "Cannot cancel wait when none are pending");
			assert(info.callbacks.length > wait_id, "Invalid process wait ID");

			info.callbacks[wait_id] = null;
		});
	}

	private void onProcessExit(int system_pid)
	shared {
		m_driver.core.runInOwnerThread(&onLocalProcessExit, system_pid);
	}

	private static void onLocalProcessExit(int system_pid)
	{
		int exitCode;
		ProcessWaitCallback[] callbacks;

		ProcessID pid;

		PosixEventDriverProcesses driver;
		lockedProcessInfoPlain(system_pid, (info) {
			assert(info !is null);

			exitCode = info.exitCode;
			callbacks = info.callbacks;
			pid = ProcessID(system_pid, info.validationCounter);
			info.callbacks = null;

			driver = info.driver;
		});

		foreach (cb; callbacks) {
			if (cb)
				cb(pid, exitCode);
		}

		driver.releaseRef(pid);
	}

	final override bool hasExited(ProcessID pid)
	{
		bool ret;
		lockedProcessInfo(pid, (info) {
			if (info) ret = info.exited;
			else ret = true;
		});
		return ret;
	}

	override bool isValid(ProcessID handle)
	const {
		s_mutex.lock_nothrow();
		scope (exit) s_mutex.unlock_nothrow();
		auto info = () @trusted { return cast(int)handle.value in s_processes; } ();
		return info && info.validationCounter == handle.validationCounter;
	}

	final override void addRef(ProcessID pid)
	{
		lockedProcessInfo(pid, (info) {
			if (!info) return;

			nogc_assert(info.refCount > 0, "Adding reference to unreferenced process FD.");
			info.refCount++;
		});
	}

	final override bool releaseRef(ProcessID pid)
	{
		bool ret;
		lockedProcessInfo(pid, (info) {
			if (!info) {
				ret = true;
				return;
			}

			nogc_assert(info.refCount > 0, "Releasing reference to unreferenced process FD.");
			if (--info.refCount == 0) {
				// Remove/deallocate process
				if (info.userDataDestructor)
					() @trusted { info.userDataDestructor(info.userData.ptr); } ();

				() @trusted { s_processes.remove(cast(int)pid.value); } ();
				ret = false;
			} else ret = true;
		});
		return ret;
	}

	final protected override void* rawUserData(ProcessID pid, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		void* ret;
		lockedProcessInfo(pid, (info) @safe nothrow {
			assert(info.userDataDestructor is null || info.userDataDestructor is destroy,
				"Requesting user data with differing type (destructor).");
			assert(size <= ProcessInfo.userData.length, "Requested user data is too large.");

			if (!info.userDataDestructor) {
				() @trusted { initialize(info.userData.ptr); } ();
				info.userDataDestructor = destroy;
			}
			ret = () @trusted { return info.userData.ptr; } ();
		});
		return ret;
	}

	package final @property size_t pendingCount() const nothrow @trusted { return s_processes.length; }


	shared static this()
	{
		s_mutex = new shared Mutex;
	}

	private static void lockedProcessInfoPlain(int pid, scope void delegate(ProcessInfo*) nothrow @safe fn)
	{
		s_mutex.lock_nothrow();
		scope (exit) s_mutex.unlock_nothrow();
		auto info = () @trusted { return pid in s_processes; } ();
		fn(info);
	}

	private static void lockedProcessInfo(ProcessID pid, scope void delegate(ProcessInfo*) nothrow @safe fn)
	{
		lockedProcessInfoPlain(cast(int)pid.value, (pi) {
			fn(pi.validationCounter == pid.validationCounter ? pi : null);
		});
	}

	private static void add(int pid, ProcessInfo info) @trusted {
		s_mutex.lock_nothrow();
		scope (exit) s_mutex.unlock_nothrow();

		if (!s_waitThread) {
			s_waitThread = new Thread(&waitForProcesses);
			s_waitThread.start();
		}

		assert(pid !in s_processes, "Process adopted twice");
		s_processes[pid] = info;
	}

	private static void waitForProcesses()
	@system {
		import core.sys.posix.sys.wait : idtype_t, WNOHANG, WNOWAIT, WEXITED, WEXITSTATUS, WIFEXITED, WTERMSIG, waitid, waitpid;
		import core.sys.posix.signal : siginfo_t;

		while (true) {
			siginfo_t dummy;

			static if (is(idtype_t)) {
				auto ret = waitid(idtype_t.P_ALL, -1, &dummy, WEXITED|WNOWAIT);
			} else {
				auto ret = waitid(0, -1, &dummy, WEXITED|WNOWAIT);
			}

			if (ret == -1) {
				{
					s_mutex.lock_nothrow();
					scope (exit) s_mutex.unlock_nothrow();
					s_waitThread = null;
				}
				break;
			}

			int[] allprocs;

			{
				s_mutex.lock_nothrow();
				scope (exit) s_mutex.unlock_nothrow();


				() @trusted {
					foreach (ref entry; s_processes.byKeyValue) {
						if (!entry.value.exited)
							allprocs ~= entry.key;
					}
				} ();
			}

			foreach (pid; allprocs) {
				int status;
				ret = () @trusted { return waitpid(pid, &status, WNOHANG); } ();
				if (ret == pid) {
					int exitstatus = WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status);
					onProcessExitStatic(ret, exitstatus);
				}
			}
		}
	}

	private static void onProcessExitStatic(int system_pid, int exit_status)
	{
		PosixEventDriverProcesses driver;
		lockedProcessInfoPlain(system_pid, (ProcessInfo* info) @safe {
			// We get notified of any child exiting, so ignore the ones we're
			// not aware of
			if (info is null) return;

			// Increment the ref count to make sure it doesn't get removed
			info.refCount++;
			info.exited = true;
			info.exitCode = exit_status;
			driver = info.driver;
		});

		if (driver)
			() @trusted { return cast(shared)driver; } ().onProcessExit(system_pid);
	}

	private static struct ProcessInfo {
		bool exited = true;
		int exitCode;
		ProcessWaitCallback[] callbacks;
		size_t refCount = 0;
		uint validationCounter;
		PosixEventDriverProcesses driver;

		DataInitializer userDataDestructor;
		ubyte[16*size_t.sizeof] userData;
	}
}

final class DummyEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:

	this(Loop loop, EventDriver driver) {}

	void dispose() {}

	override ProcessID adopt(int system_pid)
	{
		assert(false, "TODO!");
	}

	override Process spawn(string[] args, ProcessStdinFile stdin, ProcessStdoutFile stdout, ProcessStderrFile stderr, const string[string] env, ProcessConfig config, string working_dir)
	{
		assert(false, "TODO!");
	}

	override bool hasExited(ProcessID pid)
	{
		assert(false, "TODO!");
	}

	override void kill(ProcessID pid, int signal)
	{
		assert(false, "TODO!");
	}

	override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
	{
		assert(false, "TODO!");
	}

	override void cancelWait(ProcessID pid, size_t waitId)
	{
		assert(false, "TODO!");
	}

	override bool isValid(ProcessID handle)
	const {
		return false;
	}

	override void addRef(ProcessID pid)
	{
		assert(false, "TODO!");
	}

	override bool releaseRef(ProcessID pid)
	{
		assert(false, "TODO!");
	}

	protected override void* rawUserData(ProcessID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		assert(false, "TODO!");
	}

	package final @property size_t pendingCount() const nothrow { return 0; }
}
