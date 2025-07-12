/**
	Linux io_uring based event driver implementation.

	io_uring is an efficient API for asynchronous I/O on Linux, suitable for
	large numbers of concurrently open sockets.

	It beats epoll if you have more than 10'000 connections, has a smaller
	systemcall overhead and supports sockets as well as timers and files.


	io_uring works differently from epoll. Poll/epoll/kqueue based solutions
	will tell you when it is safe to read or .write from a descriptor
	without blocking. Upon such a notification one has to do it manually by
	envoking the resp. system call.
	On the other hand in io_uring one asynchronously issues a command to
	read or write to a descriptor and gets a notification back once the
	operation is complete. Issuing a command is done by placing a
	Submission Queue Entry (SQE) in a ringbuffer shared by user space and
	kernel. Upon completion a Completion Queue Entry (CQE) is placed
	by the kernel into another shared ringbuffer.

	This has implications on the layout of the internal data structures. While
	the posix event loops center everything around the descriptors, the io_uring
	loop tracks individual operations (that reference descriptors).

		1. For some operations (e.g. opening a file) the descriptor is only
		available after the operation completes.
		2. After an operation is cancelled, it will result in an CQE nontheless,
		and we cannot reliably handle this without tracking individual operations
		(and multiple operations of the same kind per descriptor)

	We still have to track information per descriptor, e.g. to ensure that
	only one operation per kind is ongoing at the time.

	This implementation tries to integrate with an sockets based event loop
	(the base loop) for the primary reason that not all functionality
	(e.g. signalfd) is currently available via io_uring.

	We do this by registering an eventfd with the base loop that triggers
	whenever new completions are available and thus wakes up the base loop.
*/
module eventcore.drivers.posix.uring;

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.drivers.posix.epoll;
import eventcore.internal.utils;

import core.time : Duration;

static import std.typecons;


alias OpIdx = std.typecons.Typedef!(int, -1, "eventcore.OpIdx");

// information regarding a specific resource / descriptor
package struct UringSlot
{
	alias Handle = FileFD;

	// from the os, file descriptor, socket etc
	int descriptor = -1;
	// ref count, we'll clean up internal data structures
	// if this reaches zero
	uint refCount;
	// all data structures are reused and the validation
	// counter makes sure an user cannot access a reused
	// slot with an old handle
	uint validationCounter;

	// to track that at most one op per EventType is ongoing
	// contains the userData field of the resp. ops
	OpIdx[EventType.max+1] runningOps;
}


version (EventcoreUringDriver):

import core.stdc.errno;
import core.sys.posix.sys.types;
import core.sys.posix.sys.stat;
import core.sys.linux.fcntl;
import during;
import std.stdio;
import taggedalgebraic.taggedalgebraic;


alias UringEventDriver = PosixEventDriver!UringEventLoop;


/// eventcore allows exactly one simultaneous operation per kind per
/// descriptor.
enum EventType {
	read,
	write,
	status
}

private void assumeSafeNoGC(scope void delegate() nothrow doit) nothrow @nogc
@trusted {
	(cast(void delegate() nothrow @nogc)doit)();
}

// this is the callback provided by the user to e.g. EventDriverFiles
alias UserCallback = void delegate() nothrow;

// this is provided by i.e. EventDriverFiles to UringEventLoop. The event loop
// will call OpCallback which should in turn call UserCallback. This is useful
// to decouble the uring stuff from the actual drivers.
alias OpCallback = void delegate(FD, ref const(CompletionEntry), UserCallback) nothrow;

// data stored per operation. Since after completion the `OpCallback`
// is called with the descriptor and CompletionEntry, all necessary information
// should be available without creating a real closure for OpCallback.
struct OpData
{
	FD fd;
	OpCallback opCb;
	UserCallback userCb;
}

///
final class UringEventLoop : EpollEventLoop
{
	import eventcore.internal.consumablequeue;
	import std.typecons : Tuple, tuple;

	private {
		Uring m_io;
		ChoppedVector!OpData m_ops;
	}

	nothrow @nogc
	this()
	{
		assumeSafeNoGC({
			int res = m_io.setup();
			debug(UringEventLoopDebug)
			{
				if (res < 0)
					print("Setting up uring failed: %s", -res);
			}
		});
	}

	package void registerEventID(EventID id) nothrow @trusted @nogc
	{
		m_io.registerEventFD(cast(int) id);
	}

	private void submit() nothrow @trusted @nogc
	{
		m_io.submit(0);
	}

	override bool doProcessEvents(Duration timeout)
	nothrow @trusted
	{
		import std.algorithm : max;
		import std.typecons : TypedefType;

		// this is required to make the kernel aware of
		// submitted SEQ, otherwise the first call to
		// process events could stall
		submit();

		auto epevts = super.doProcessEvents(timeout);

		// we add a timeout so that we do not wait indef.
		/*if (!dontWait && timeout != Duration.max)
		{
			KernelTimespec timespec;
			timeout.split!("seconds", "nsecs")(timespec.tv_sec, timespec.tv_nsec);
			m_io.putWith!((ref SubmissionEntry e, KernelTimespec timespec)
			{
				// wait for timeout or first completion
				e.prepTimeout(timespec, 1);
				e.user_data = ulong.max;
			})(timespec);
		}*/
		int res = m_io.submit(/*dontWait ?*/ 0/* : 1*/);
		if (res < 0)
		{
			return epevts;
		}
		bool gotEvents = !m_io.empty || epevts;
		foreach (ref CompletionEntry e; m_io)
		{
			import eventcore.internal.utils : print;
			import std.algorithm : all;
			// internally used timeouts
			if (e.user_data == ulong.max)
				continue;
			OpIdx opIdx;
			EventType type;
			// let the specific driver handle the rest
			splitKey(e.user_data, opIdx, type);
			OpData* op = &m_ops[cast(TypedefType!OpIdx) opIdx];
			assert (op.fd == FD.init || isValid(op.fd));
			// cb might be null, if the operation was cancelled
			if (op.opCb)
			{
				print("reset op: %s", opIdx);
				// e.g. open sets m_uringFDs to FD.init
				if (op.fd != FD.init)
					m_fds[op.fd].specific.runningOps[type] = OpIdx.init;
				removeWaiter();
				op.opCb(op.fd, e, op.userCb);
				*op = OpData.init;
			}
		}
		return gotEvents;
	}

	private bool isValid(FD handle)
	@safe @nogc nothrow {
		if (handle.value > m_fds.length) return false;
		return m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	private void uringPut(in FD fd, in EventType type, SubmissionEntry e,
		OpCallback cb, UserCallback userCb) @safe nothrow
	{
		import std.typecons : TypedefType;
		addWaiter();
		OpIdx idx = allocOpData();
		ulong userData = combineKey(idx, type);
		e.user_data = userData;
		m_io.put(e);
		if (fd != FD.init) {
			auto res = () @trusted { return &m_fds[fd.value].specific.get!UringSlot; } ();
			assert (res.runningOps[type] == OpIdx.init);
			res.runningOps[type] = idx;
		}
		m_ops[cast(TypedefType!OpIdx) idx] = OpData(fd, cb, userCb);
	}

	private void cancelOp(FD fd, EventType type) @safe nothrow @nogc
	{
		if (!isValid(fd))
			return;

		OpIdx idx = m_fds[fd].specific.runningOps[type];
		if (idx != OpIdx.init)
			cancelOp(idx, type);
	}

	private void cancelOp(OpIdx opIdx, EventType type) @trusted nothrow @nogc
	{
		import std.typecons : TypedefType;
		OpData* opData = &m_ops[cast(TypedefType!OpIdx)opIdx];
		if (opData.fd != FD.init)
		{
			if (!isValid(opData.fd))
			{
				print("cancel for invalid fd");
				return;
			}
			if (m_fds[opData.fd].specific.runningOps[type] == OpIdx.init)
			{
				print("cancelling op that's not running");
				return;
			}
			m_fds[opData.fd].specific.runningOps[type] = OpIdx.init;
		}
		print("cancel op: %s", opIdx);
		ulong op = combineKey(opIdx, type);
		m_io.putWith!((ref SubmissionEntry e, ulong op)
		{
			// result is ignored (own userData is ulong.max)
			prepCancel(e, op);
			e.user_data = ulong.max;
		})(op);
		removeWaiter();
	}

	private OpIdx allocOpData() @trusted nothrow @nogc
	{
		// TODO: use a free list or sth
		for (int i = 0; ; ++i)
		{
			OpData* opData = &m_ops[i];
			// TODO need to distinguish cancelled and virgin slots
			if (*opData == OpData.init)
			{
				print("allocop %s", i);
				return OpIdx(i);
			}
		}
		assert(0);
	}
}

void splitKey(ulong key, out OpIdx op, out EventType type) @safe @nogc nothrow
out { assert(op != OpIdx.init); }
do {
	op = cast(int) (key >> 32);
	type = cast(EventType) ((key << 32) >>> 32);
}

ulong combineKey(OpIdx op, EventType type) @safe @nogc nothrow
in { assert(op != OpIdx.init); }
do {
	return cast(ulong)(op) << 32 | cast(uint) type;
}

@nogc nothrow
unittest
{
	ulong orig = 0xDEAD_BEEF_DECAF_BAD;
	OpIdx op;
	EventType type;
	splitKey(orig, op, type);
	assert (type == cast(EventType)0xDECAFBAD);
	assert (op == 0xDEADBEEF);
	assert (orig == combineKey(op, type));
}


final class UringDriverFiles : EventDriverFiles
{
	nothrow:
	private {
		UringEventLoop m_loop;
		int m_idx;
	}

	this(UringEventLoop loop) @nogc nothrow
	{
		m_loop = loop;
	}

	void dispose() @safe {}

	//
	FileFD open(string path, FileOpenMode mode)
	{
		import std.string : toStringz;
		import std.conv : octal;

		int flags;
		int amode;

		final switch (mode) {
			case FileOpenMode.read: flags = O_RDONLY; break;
			case FileOpenMode.readWrite: flags = O_RDWR; break;
			case FileOpenMode.create: flags = O_RDWR|O_CREAT|O_EXCL; amode = octal!644; break;
			case FileOpenMode.createTrunc: flags = O_RDWR|O_CREAT|O_TRUNC; amode = octal!644; break;
			case FileOpenMode.append: flags = O_WRONLY|O_CREAT|O_APPEND; amode = octal!644; break;
		}
		auto fd = () @trusted { return .open(path.toStringz(), flags, amode); } ();
		if (fd < 0) return FileFD.init;
		return adopt(fd);
	}

	void open(string path, FileOpenMode mode, FileOpenCallback userCb)
	{
		import std.string : toStringz;
		import std.conv : octal;

		int flags;
		int amode;

		final switch (mode) {
			case FileOpenMode.read: flags = O_RDONLY; break;
			case FileOpenMode.readWrite: flags = O_RDWR; break;
			case FileOpenMode.create: flags = O_RDWR|O_CREAT|O_EXCL; amode = octal!644; break;
			case FileOpenMode.createTrunc: flags = O_RDWR|O_CREAT|O_TRUNC; amode = octal!644; break;
			case FileOpenMode.append: flags = O_WRONLY|O_CREAT|O_APPEND; amode = octal!644; break;
		}

		SubmissionEntry e;
		prepOpenat(e, AT_FDCWD, path.toStringz, flags, amode);
		m_loop.uringPut(FD.init, EventType.status, e, &handleOpen, () @trusted { return cast(UserCallback)userCb; } ());
	}

	private void handleOpen(FD fd, ref const(CompletionEntry) e, UserCallback userCb)
		nothrow
	in { assert (fd == FD.init); }
	do {
		FileOpenCallback cb = cast(FileOpenCallback) userCb;
		if (e.res == -1)
		{
			OpenStatus status;
			switch (errno) {
				default: status = OpenStatus.failed; break;
				case ENOENT: status = OpenStatus.notFound; break;
				case EACCES: status = OpenStatus.notAccessible; break;
				case EBUSY: status = OpenStatus.sharingViolation; break;
				static if (is(typeof(ETXTBSY))) {
					case ETXTBSY: status = OpenStatus.sharingViolation; break;
				}
				case EEXIST: status = OpenStatus.alreadyExists; break;
			}
			cb(FileFD.init, status);
			return;
		}
		FileFD fileFD = adopt(e.res);
		cb(fileFD, OpenStatus.ok);
	}

	FileFD adopt(int system_file_handle)
	{
		auto flags = () @trusted { return fcntl(system_file_handle, F_GETFD); } ();
		if (flags == -1) return FileFD.invalid;
		return  () @trusted {
			UringSlot slot;
			return m_loop.initFD!FileFD(system_file_handle, FDFlags.none, slot);
		}();
	}

	/** Disallows any reads/writes and removes any exclusive locks.

		Note that the file handle may become invalid at any point after the
		call to `close`, regardless of its current reference count. Any
		operations on the handle will not have an effect.
	*/
	void close(FileFD file, FileCloseCallback onClosed) @trusted
	{
		if (!isValid(file)) {
			onClosed(file, CloseStatus.invalidHandle);
			return;
		}
		SubmissionEntry e;
		e.prepClose(cast(int) file);
		m_loop.uringPut(cast(FD) file, EventType.status, e, &handleClose,
			cast(UserCallback) onClosed);
	}

	private void handleClose(FD fd, ref const(CompletionEntry) e, UserCallback userCb)
		nothrow
	{
		FileCloseCallback cb = cast(FileCloseCallback) userCb;
		if (e.res < 0)
			cb(cast(FileFD) fd, CloseStatus.ioError);
		else
			cb(cast(FileFD) fd, CloseStatus.ok);
	}

	ulong getSize(FileFD file)
	{
		import core.sys.linux.unistd : lseek64;
		import core.sys.posix.stdio : SEEK_END;
		if (!isValid(file)) return ulong.max;

		// stat_t seems to be defined wrong on linux/64
		return lseek64(cast(int)file, 0, SEEK_END);
	}


	/** Shrinks or extends a file to the specified size.

		Params:
			file = Handle of the file to resize
			size = Desired file size in bytes
			on_finish = Called when the operation finishes - the `size`
				parameter is always set to zero
		Note: this is a blocking call, since io_uring does not support
		this yet.
	*/
	void truncate(FileFD file, ulong size, FileIOCallback on_finish)
	{
		import core.sys.linux.unistd : ftruncate;
		// currently not supported by uring
		if (ftruncate(cast(int)file, size) != 0) {
			on_finish(file, IOStatus.error, 0);
			return;
		}
		on_finish(file, IOStatus.ok, 0);
	}

	/** Writes data to a file

		Note that only a single write operation is allowed at once. The caller
		needs to make sure that either `on_write_finish` got called, or
		`cancelWrite` was called before issuing the next call to `write`.

		Note: IOMode is ignored
	*/
	void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	@trusted
	{
		if (!isValid(file))
		{
			on_write_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		SubmissionEntry e;
		e.prepWrite(cast(int) file, buffer, offset);
		m_loop.uringPut(file, EventType.write, e, &handleIO,
			cast(UserCallback) on_write_finish);
	}

	private void handleIO(FD file, ref const(CompletionEntry) e, UserCallback cb)
		nothrow
	{
		import std.algorithm : max;
		FileIOCallback ioCb = cast(FileIOCallback) cb;
		IOStatus status = e.res < 0 ? IOStatus.error : IOStatus.ok;
		size_t written = max(0, e.res);

		ioCb(cast(FileFD) file, status, written);
	}

	/** Cancels an ongoing write operation.

		After this function has been called, the `FileIOCallback` specified in
		the call to `write` is guaranteed not to be called.
	*/
	void cancelWrite(FileFD file)
	{
		m_loop.cancelOp(file, EventType.write);
	}

	/** Reads data from a file.

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.

		Note: `mode` is ignored for files
	*/
	void read(FileFD file, ulong offset, ubyte[] buffer, IOMode, FileIOCallback on_read_finish)
		@trusted
	{
		if (!isValid(file))
		{
			on_read_finish(file, IOStatus.invalidHandle, 0);
			return;
		}
		SubmissionEntry e;
		e.prepRead(cast(int) file, buffer, offset);
		m_loop.uringPut(file, EventType.read, e, &handleIO,
			cast(UserCallback) on_read_finish);
	}

	/** Cancels an ongoing read operation.

		After this function has been called, the `FileIOCallback` specified in
		the call to `read` is guaranteed not to be called.
	*/
	void cancelRead(FileFD file)
	{
		m_loop.cancelOp(file, EventType.read);
	}

	/** Determines whether the given file handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called and I/O operations will result in
		`IOStatus.invalidHandle`.

		A valid handle gets invalid when either the reference count drops to
		zero, or after the file was explicitly closed.
	*/
	bool isValid(FileFD handle) const @nogc
	{
		if (handle.value > m_loop.m_fds.length) return false;
		return m_loop.m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	final override bool isUnique(FileFD handle)
	const {
		if (!isValid(handle)) return false;

		auto slot = () @trusted { return &m_loop.m_fds[handle]; } ();
		return slot.common.refCount == 1;
	}

	/** Increments the reference count of the given file.
	*/
	void addRef(FileFD descriptor)
	{
		if (!isValid(descriptor)) return;

		auto slot = () @trusted { return &m_loop.m_fds[descriptor]; } ();
		assert(slot.common.refCount > 0, "Adding reference to unreferenced socket FD.");
		slot.common.refCount++;
	}

	/** Decrements the reference count of the given file.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(FileFD descriptor)
	{
		import taggedalgebraic : hasType;

		if (!isValid(descriptor)) return true;

		auto slot = () @trusted { return &m_loop.m_fds[descriptor]; } ();
		nogc_assert(slot.common.refCount > 0, "Releasing reference to unreferenced socket FD.");
		// listening sockets have an incremented the reference count because of setNotifyCallback
		int base_refcount = slot.specific.hasType!UringSlot ? 1 : 0;
		if (--slot.common.refCount == base_refcount) {
			import std.traits : EnumMembers;

			// cancel all pendings ops
			foreach (type; EnumMembers!EventType)
			{
				if (slot.specific.runningOps[type] != OpIdx.init)
					m_loop.cancelOp(slot.specific.runningOps[type], type);
			}
			return false;
		}
		return true;
	}

	final protected override void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}
}
