module eventcore.drivers.threadedfile;

import eventcore.driver;
import eventcore.internal.ioworker;
import eventcore.internal.utils;
import core.atomic;
import core.stdc.errno;
import std.algorithm.comparison : among, min;

version (Posix) {
	import core.sys.posix.fcntl;
	import core.sys.posix.sys.stat;
	import core.sys.posix.unistd;
}
version (Windows) {
    import core.sys.windows.stat;

	private {
		// TODO: use CreateFile/HANDLE instead of the Posix API on Windows

		extern(C) nothrow {
			alias off_t = sizediff_t;
			int open(in char* name, int mode, ...);
			int chmod(in char* name, int mode);
			int close(int fd) @safe;
			int read(int fd, void *buffer, uint count);
			int write(int fd, in void *buffer, uint count);
			long _lseeki64(int fd, long offset, int origin) @safe;
		}

		enum O_RDONLY = 0;
		enum O_WRONLY = 1;
		enum O_RDWR = 2;
		enum O_APPEND = 8;
		enum O_CREAT = 0x0100;
		enum O_TRUNC = 0x0200;
		enum O_BINARY = 0x8000;

		enum _S_IREAD = 0x0100;          /* read permission, owner */
		enum _S_IWRITE = 0x0080;          /* write permission, owner */
		alias stat_t = struct_stat;
	}
}
else
{
	enum O_BINARY = 0;
}

version (darwin) {
	// NOTE: Always building for 64-bit, so these are identical
	alias lseek64 = lseek;
}

version (Android) {
	static if (!is(off64_t)) {
		alias off64_t = long;
		extern(C) off64_t lseek64(int, off64_t, int) @safe nothrow;
	}
}

private {
	enum SEEK_SET = 0;
	enum SEEK_CUR = 1;
	enum SEEK_END = 2;
}


final class ThreadedFileEventDriver(Events : EventDriverEvents) : EventDriverFiles
{
	import std.parallelism;

	private {
		enum ThreadedFileStatus {
			idle,         // -> initiated                 (by caller)
			initiated,    // -> processing                (by worker)
			processing,   // -> cancelling, finished      (by caller, worker)
			cancelling,   // -> cancelled                 (by worker)
			cancelled,    // -> idle                      (by event receiver)
			finished      // -> idle                      (by event receiver)
		}

		static struct IOInfo {
			FileIOCallback callback;
			shared ThreadedFileStatus status;
			shared size_t bytesWritten;
			shared IOStatus ioStatus;

			void finalize(FileFD fd, scope void delegate() @safe nothrow pre_cb)
			@safe nothrow {
				auto st = safeAtomicLoad(this.status);
				if (st == ThreadedFileStatus.finished) {
					auto ios = safeAtomicLoad(this.ioStatus);
					auto btw = safeAtomicLoad(this.bytesWritten);
					auto cb = this.callback;
					this.callback = null;
					safeAtomicStore(this.status, ThreadedFileStatus.idle);
					pre_cb();
					if (cb) {
						log("fire callback");
						cb(fd, ios, btw);
					}
				} else if (st == ThreadedFileStatus.cancelled) {
					this.callback = null;
					safeAtomicStore(this.status, ThreadedFileStatus.idle);
					pre_cb();
					log("ignore callback due to cancellation");
				}
			}
		}

		static struct FileInfo {
			IOInfo read;
			IOInfo write;

			uint validationCounter;

			int refCount;
			DataInitializer userDataDestructor;
			ubyte[16*size_t.sizeof] userData;
		}

		IOWorkerPool m_fileThreadPool;
		ChoppedVector!FileInfo m_files; // TODO: use the one from the posix loop
		SmallIntegerSet!size_t m_activeReads;
		SmallIntegerSet!size_t m_activeWrites;
		EventID m_readyEvent = EventID.invalid;
		bool m_waiting;
		Events m_events;
	}

	@safe: nothrow:

	this(Events events)
	{
		m_events = events;
	}

	void dispose()
	{
		m_fileThreadPool = IOWorkerPool.init;

		if (m_readyEvent != EventID.invalid) {
			log("finishing file events");
			if (m_waiting)
				m_events.cancelWait(m_readyEvent, &onReady);
			onReady(m_readyEvent);
			m_events.releaseRef(m_readyEvent);
			m_readyEvent = EventID.invalid;
			log("finished file events");
		}
	}

	final override FileFD open(string path, FileOpenMode mode)
	{
		import std.string : toStringz;

		import std.conv : octal;
		int flags;
		int amode;
		final switch (mode) {
			case FileOpenMode.read: flags = O_RDONLY|O_BINARY; break;
			case FileOpenMode.readWrite: flags = O_RDWR|O_BINARY; break;
			case FileOpenMode.createTrunc: flags = O_RDWR|O_CREAT|O_TRUNC|O_BINARY; amode = octal!644; break;
			case FileOpenMode.append: flags = O_WRONLY|O_CREAT|O_APPEND|O_BINARY; amode = octal!644; break;
		}
		auto fd = () @trusted { return .open(path.toStringz(), flags, amode); } ();
		if (fd < 0) return FileFD.init;
		return adopt(fd);
	}

	final override FileFD adopt(int system_file_handle)
	{
		version (Windows) {
			// TODO: check if FD is a valid file!
		} else {
			auto flags = () @trusted { return fcntl(system_file_handle, F_GETFD); } ();
			if (flags == -1) return FileFD.invalid;
		}

		if (m_files[system_file_handle].refCount > 0) return FileFD.invalid;
		auto vc = m_files[system_file_handle].validationCounter;
		m_files[system_file_handle] = FileInfo.init;
		m_files[system_file_handle].refCount = 1;
		m_files[system_file_handle].validationCounter = vc + 1;
		return FileFD(system_file_handle, vc + 1);
	}

	void close(FileFD file, FileCloseCallback on_closed)
	{
		if (!isValid(file)) {
			on_closed(file, CloseStatus.invalidHandle);
			return;
		}

		// TODO: close may block and should be executed in a worker thread
		int res = .close(cast(int)file.value);

		m_files[file.value] = FileInfo.init;

		if (on_closed)
			on_closed(file, res == 0 ? CloseStatus.ok : CloseStatus.ioError);
	}

	ulong getSize(FileFD file)
	{
		if (!isValid(file)) return ulong.max;

		version (linux) {
			// stat_t seems to be defined wrong on linux/64
			return .lseek64(cast(int)file, 0, SEEK_END);
		} else version (Windows) {
			return _lseeki64(cast(int)file, 0, SEEK_END);
		} else {
			stat_t st;
			() @trusted { fstat(cast(int)file, &st); } ();
			return st.st_size;
		}
	}

	override void truncate(FileFD file, ulong size, FileIOCallback on_finish)
	{
		if (!isValid(file)) return;

		version (Posix) {
			// FIXME: do this in the thread pool

			static if (off_t.max < ulong.max) {
				if (size > off_t.max) {
					on_finish(file, IOStatus.error, 0);
					return;
				}
			}

			if (ftruncate(cast(int)file, cast(off_t)size) != 0) {
				on_finish(file, IOStatus.error, 0);
				return;
			}
			on_finish(file, IOStatus.ok, 0);
		} else version (Windows) {
			version (Win64) {
				import core.sys.windows.windows : FILE_BEGIN, HANDLE, INVALID_HANDLE_VALUE,
					LARGE_INTEGER, SetFilePointerEx, SetEndOfFile;
				import core.stdc.stdio : _get_osfhandle;

				auto h = () @trusted { return cast(HANDLE)_get_osfhandle(cast(int)file); } ();
				if (h == INVALID_HANDLE_VALUE) {
					on_finish(file, IOStatus.error, 0);
					return;
				}
				LARGE_INTEGER ls = { QuadPart: size };
				if (!() @trusted { return SetFilePointerEx(h, ls, null, FILE_BEGIN); } ()) {
					on_finish(file, IOStatus.error, 0);
					return;
				}
				if (!() @trusted { return SetEndOfFile(h); } ()) {
					on_finish(file, IOStatus.error, 0);
					return;
				}
				on_finish(file, IOStatus.ok, 0);
			} else {
				on_finish(file, IOStatus.error, 0);
			}
		} else {
			on_finish(file, IOStatus.error, 0);
		}
	}


	final override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode, FileIOCallback on_write_finish)
	{
		if (!isValid(file)) {
			on_write_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		//assert(this.writable);
		auto f = () @trusted { return &m_files[file]; } ();

		if (!safeCAS(f.write.status, ThreadedFileStatus.idle, ThreadedFileStatus.initiated))
			assert(false, "Concurrent file writes are not allowed.");
		assert(f.write.callback is null, "Concurrent file writes are not allowed.");
		f.write.callback = on_write_finish;
		m_activeWrites.insert(file.value);
		threadSetup();
		log("start write task");
		try {
			auto thiss = () @trusted { return cast(shared)this; } ();
			auto fs = () @trusted { return cast(shared)f; } ();
			m_fileThreadPool.put(task!(taskFun!("write", const(ubyte)))(thiss, fs, file, offset, buffer));
			startWaiting();
		} catch (Exception e) {
			m_activeWrites.remove(file.value);
			on_write_finish(file, IOStatus.error, 0);
			return;
		}
	}

	final override void cancelWrite(FileFD file)
	{
		if (!isValid(file)) return;

		assert(m_activeWrites.contains(file.value), "Cancelling write when no write is in progress.");

		auto f = &m_files[file].write;
		f.callback = null;
		m_activeWrites.remove(file.value);
		m_events.trigger(m_readyEvent, true); // ensure that no stale wait operation is left behind
		safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.cancelling);
	}

	final override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode, FileIOCallback on_read_finish)
	{
		if (!isValid(file)) {
			on_read_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		auto f = () @trusted { return &m_files[file]; } ();

		if (!safeCAS(f.read.status, ThreadedFileStatus.idle, ThreadedFileStatus.initiated))
			assert(false, "Concurrent file reads are not allowed.");
		assert(f.read.callback is null, "Concurrent file reads are not allowed.");
		f.read.callback = on_read_finish;
		m_activeReads.insert(file.value);
		threadSetup();
		log("start read task");
		try {
			auto thiss = () @trusted { return cast(shared)this; } ();
			auto fs = () @trusted { return cast(shared)f; } ();
			m_fileThreadPool.put(task!(taskFun!("read", ubyte))(thiss, fs, file, offset, buffer));
			startWaiting();
		} catch (Exception e) {
			m_activeReads.remove(file.value);
			on_read_finish(file, IOStatus.error, 0);
			return;
		}
	}

	final override void cancelRead(FileFD file)
	{
		if (!isValid(file)) return;

		assert(m_activeReads.contains(file.value), "Cancelling read when no read is in progress.");

		auto f = &m_files[file].read;
		f.callback = null;
		m_activeReads.remove(file.value);
		m_events.trigger(m_readyEvent, true); // ensure that no stale wait operation is left behind
		safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.cancelling);
	}

	final override bool isValid(FileFD handle)
	const {
		if (handle.value >= m_files.length) return false;
		return m_files[handle.value].validationCounter == handle.validationCounter;
	}

	final override void addRef(FileFD descriptor)
	{
		if (!isValid(descriptor)) return;

		m_files[descriptor].refCount++;
	}

	final override bool releaseRef(FileFD descriptor)
	{
		if (!isValid(descriptor)) return true;

		auto f = () @trusted { return &m_files[descriptor]; } ();
		if (!--f.refCount) {
			close(descriptor, null);
			assert(!m_activeReads.contains(descriptor.value));
			assert(!m_activeWrites.contains(descriptor.value));
			return false;
		}
		return true;
	}

	protected final override void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;

		FileInfo* fds = &m_files[descriptor];
		assert(fds.userDataDestructor is null || fds.userDataDestructor is destroy,
			"Requesting user data with differing type (destructor).");
		assert(size <= FileInfo.userData.length, "Requested user data is too large.");
		if (size > FileInfo.userData.length) assert(false);
		if (!fds.userDataDestructor) {
			initialize(fds.userData.ptr);
			fds.userDataDestructor = destroy;
		}
		return fds.userData.ptr;
	}

	/// private
	static void taskFun(string op, UB)(shared(ThreadedFileEventDriver) files, shared(FileInfo)* fi, FileFD file, ulong offset, UB[] buffer)
	{
log("task fun");
		shared(IOInfo)* f = mixin("&fi."~op);
log("start processing");

		if (!safeCAS(f.status, ThreadedFileStatus.initiated, ThreadedFileStatus.processing))
			assert(false, "File slot not in initiated state when processor task is started.");

		auto bytes = buffer;
		version (Windows) {
			._lseeki64(cast(int)file, offset, SEEK_SET);
		} else .lseek64(cast(int)file, offset, SEEK_SET);

		scope (exit) {
log("trigger event");
			files.m_events.trigger(files.m_readyEvent, true);
		}

		if (bytes.length == 0) safeAtomicStore(f.ioStatus, IOStatus.ok);

		while (bytes.length > 0) {
			auto sz = min(bytes.length, 512*1024);
			auto ret = () @trusted { return mixin("."~op)(cast(int)file, bytes.ptr, cast(uint)sz); } ();
			if (ret != sz) {
				safeAtomicStore(f.ioStatus, IOStatus.error);
log("error");
				break;
			}
			bytes = bytes[sz .. $];
log("check for cancel");
			if (safeCAS(f.status, ThreadedFileStatus.cancelling, ThreadedFileStatus.cancelled)) return;
		}

		safeAtomicStore(f.bytesWritten, buffer.length - bytes.length);
log("wait for status set");
		while (true) {
			if (safeCAS(f.status, ThreadedFileStatus.processing, ThreadedFileStatus.finished)) break;
			if (safeCAS(f.status, ThreadedFileStatus.cancelling, ThreadedFileStatus.cancelled)) break;
		}
	}

	private void onReady(EventID)
	{
log("ready event");
		foreach (f; m_activeReads) {
			auto fd = FileFD(f, m_files[f].validationCounter);
			m_files[f].read.finalize(fd, { m_activeReads.remove(f); });
		}

		foreach (f; m_activeWrites) {
			auto fd = FileFD(f, m_files[f].validationCounter);
			m_files[f].write.finalize(fd, { m_activeWrites.remove(f); });
		}

		m_waiting = false;
		startWaiting();
	}

	private void startWaiting()
	{
		if (!m_waiting && (!m_activeWrites.empty || !m_activeReads.empty)) {
			log("wait for ready");
			m_events.wait(m_readyEvent, &onReady);
			m_waiting = true;
		}
	}

	private void threadSetup()
	{
		if (m_readyEvent == EventID.invalid) {
			log("create file event");
			m_readyEvent = m_events.create();
		}
		if (!m_fileThreadPool) {
			log("aquire thread pool");
			m_fileThreadPool = acquireIOWorkerPool();
		}
	}
}

private auto safeAtomicLoad(T)(ref shared(T) v) @trusted { return atomicLoad(v); }
private auto safeAtomicStore(T)(ref shared(T) v, T a) @trusted { return atomicStore(v, a); }
private auto safeCAS(T, U, V)(ref shared(T) v, U a, V b) @trusted { return cas(&v, a, b); }

private void log(ARGS...)(string fmt, ARGS args)
@trusted nothrow {
	debug (EventCoreLogFiles) {
		scope (failure) assert(false);
		import core.thread : Thread;
		import std.stdio : writef, writefln;
		writef("[%s] ", Thread.getThis().name);
		writefln(fmt, args);
	}
}
