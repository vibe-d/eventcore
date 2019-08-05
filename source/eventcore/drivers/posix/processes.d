module eventcore.drivers.posix.processes;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.drivers.posix.signals;
import eventcore.internal.utils : nogc_assert, print;

import std.algorithm.comparison : among;
import std.variant : visit;


private enum SIGCHLD = 17;

final class SignalEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
    import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
    import core.sys.linux.sys.signalfd;
    import core.sys.posix.unistd : close, read, write, dup;

    private {
        static struct ProcessInfo {
            bool exited = true;
            int exitCode;
            ProcessWaitCallback[] callbacks;
            size_t refCount = 0;

            DataInitializer userDataDestructor;
            ubyte[16*size_t.sizeof] userData;
        }

        Loop m_loop;
        EventDriverPipes m_pipes;
        ProcessInfo[ProcessID] m_processes;
        SignalListenID m_sighandle;
    }

    this(Loop loop, EventDriverPipes pipes)
    {
        import core.sys.posix.signal;

        m_loop = loop;
        m_pipes = pipes;

        // Listen for child process exits using SIGCHLD
        m_sighandle = () @trusted {
            sigset_t sset;
            sigemptyset(&sset);
            sigaddset(&sset, SIGCHLD);

            assert(sigprocmask(SIG_BLOCK, &sset, null) == 0);

            return SignalListenID(signalfd(-1, &sset, SFD_NONBLOCK | SFD_CLOEXEC));
        } ();

        m_loop.initFD(cast(FD)m_sighandle, FDFlags.internal, SignalSlot(null));
        m_loop.registerFD(cast(FD)m_sighandle, EventMask.read);
        m_loop.setNotifyCallback!(EventType.read)(cast(FD)m_sighandle, &onSignal);

        onSignal(cast(FD)m_sighandle);
    }

    void dispose()
    {
        FD sighandle = cast(FD)m_sighandle;
        m_loop.m_fds[sighandle].common.refCount--;
        m_loop.setNotifyCallback!(EventType.read)(sighandle, null);
        m_loop.unregisterFD(sighandle, EventMask.read|EventMask.write|EventMask.status);
        m_loop.clearFD!(SignalSlot)(sighandle);
        close(cast(int)sighandle);
    }

    final override ProcessID adopt(int system_pid)
    {
        auto pid = cast(ProcessID)system_pid;
        assert(pid !in m_processes, "Process is already adopted");

        ProcessInfo info;
        info.exited = false;
        info.refCount = 1;
        m_processes[pid] = info;

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
        import std.process : pipe, Pid, spawnProcess;
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
                        process.stdin = m_pipes.adopt(dup(p.writeEnd.fileno));
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
                        process.stdout = m_pipes.adopt(dup(p.readEnd.fileno));
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
                        process.stderr = m_pipes.adopt(dup(p.readEnd.fileno));
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
                cast(std.process.Config)config,
                working_dir);
            process.pid = adopt(stdPid.osHandle);
            stdPid.destroy();

            return process;
        } catch (Exception e) {
            return Process.init;
        }
    }

    final override void kill(ProcessID pid, int signal)
    @trusted {
        import core.sys.posix.signal : pkill = kill;

        pkill(cast(int)pid, signal);
    }

    final override size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit)
    {
        auto info = () @trusted { return pid in m_processes; } ();
        assert(info !is null, "Unknown process ID");

        if (info.exited) {
            on_process_exit(pid, info.exitCode);
            return 0;
        } else {
            info.callbacks ~= on_process_exit;
            return info.callbacks.length - 1;
        }
    }

    final override void cancelWait(ProcessID pid, size_t waitId)
    {
        auto info = () @trusted { return pid in m_processes; } ();
        assert(info !is null, "Unknown process ID");
        assert(!info.exited, "Cannot cancel wait when none are pending");
        assert(info.callbacks.length > waitId, "Invalid process wait ID");

        info.callbacks[waitId] = null;
    }

    private void onSignal(FD fd)
    {
        SignalListenID lid = cast(SignalListenID)fd;

        signalfd_siginfo nfo;
        do {
            auto ret = () @trusted { return read(cast(int)fd, &nfo, nfo.sizeof); } ();

            if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS) || ret != nfo.sizeof)
                return;

            onProcessExit(nfo.ssi_pid, nfo.ssi_status);
        } while (true);
    }

    private void onProcessExit(int system_pid, int exitCode)
    {
        import core.sys.posix.sys.wait : waitpid;

        auto pid = cast(ProcessID)system_pid;
        auto info = () @trusted { return pid in m_processes; } ();

        // We get notified of any child exiting, so ignore the ones we're not
        // aware of
        if (info is null) {
            return;
        }

        // call wait to avoid zombie process (returns immediatelly now)
        (pid) @trusted { waitpid(pid, null, 0); }(system_pid);

        info.exited = true;
        info.exitCode = exitCode;

        foreach (cb; info.callbacks) {
            if (cb)
                cb(pid, exitCode);
        }
        info.callbacks = null;
    }

    final override bool hasExited(ProcessID pid)
    {
         auto info = () @trusted { return pid in m_processes; } ();
         assert(info !is null, "Unknown process ID");

         return info.exited;
    }

    final override void addRef(ProcessID pid)
    {
        auto info = () @trusted { return &m_processes[pid]; } ();
        nogc_assert(info.refCount > 0, "Adding reference to unreferenced process FD.");
        info.refCount++;
    }

    final override bool releaseRef(ProcessID pid)
    {
        auto info = () @trusted { return &m_processes[pid]; } ();
        nogc_assert(info.refCount > 0, "Releasing reference to unreferenced process FD.");
        if (--info.refCount == 0) {
            // Remove/deallocate process
            if (info.userDataDestructor)
                () @trusted { info.userDataDestructor(info.userData.ptr); } ();

            m_processes.remove(pid);
            return false;
        }
        return true;
    }

    final protected override void* rawUserData(ProcessID pid, size_t size, DataInitializer initialize, DataInitializer destroy)
    @system {
        auto info = () @trusted { return &m_processes[pid]; } ();
        assert(info.userDataDestructor is null || info.userDataDestructor is destroy,
            "Requesting user data with differing type (destructor).");
        assert(size <= ProcessInfo.userData.length, "Requested user data is too large.");

        if (!info.userDataDestructor) {
            initialize(info.userData.ptr);
            info.userDataDestructor = destroy;
        }
        return info.userData.ptr;
    }

    package final @property size_t pendingCount() const nothrow { return m_processes.length; }
}

final class DummyEventDriverProcesses(Loop : PosixEventLoop) : EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:

    this(Loop loop, EventDriverPipes pipes) {}

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
