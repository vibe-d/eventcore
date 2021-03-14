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
module eventcore.drivers.posix.io_uring.io_uring;

version (linux):

import eventcore.driver;
import eventcore.internal.utils;

import core.time : Duration;

import during;
import std.stdio;

/// eventcore allows exactly one simultaneous operation per kind per
/// descriptor.
enum EventType {
	none,
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
	OpCallback opCb;
	UserCallback userCb;
}

// information regarding a specific resource / descriptor
private struct ResourceData
{
	// from the os, file descriptor, socket etc
	int descriptor;
	// ref count, we'll clean up internal data structures
	// if this reaches zero
	uint refCount;
	// all data structures are reused and the validation
	// counter makes sure an user cannot access a reused
	// slot with an old handle
	uint validationCounter;

	// to track that at most one op per EventType is ongoing
	OpData[EventType.max+1] runningOps;
}

// the user can store extra information per resource
// which is kept in a sep. array
private struct UserData
{
	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}

///
final class UringEventLoop
{
	import eventcore.internal.consumablequeue;
	import std.typecons : Tuple, tuple;

	private {
		Uring m_io;
		ChoppedVector!(ResourceData) m_fds;
		int m_runningOps;
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

	void registerEventID(EventID id) nothrow @trusted @nogc
	{
		m_io.registerEventFD(cast(int) id);
	}

	bool isValid(FD fd) const @nogc nothrow @safe
	{
		return fd.value < m_fds.length
			&& m_fds[fd].validationCounter == fd.validationCounter;
	}

	void addRef(FD fd) @nogc nothrow @safe
	{
		if (!isValid(fd))
			return;
		m_fds[fd].refCount += 1;
	}

	bool releaseRef(FD fd) @nogc nothrow @trusted
	{
		if (!isValid(fd))
			return true;

		ResourceData* fds = &m_fds[fd];
		fds.refCount -= 1;
		if (fds.refCount == 0)
		{
			import std.traits : EnumMembers;

			// cancel all pendings ops
			foreach (type; EnumMembers!EventType)
			{
				if (fds.runningOps[type].opCb != null)
					cancelOp(fd, type);
			}
		}
		return fds.refCount == 0;
	}

	void submit() nothrow @trusted @nogc
	{
		m_io.submit(0);
	}

	bool doProcessEvents(Duration timeout, bool dontWait = true) nothrow @trusted
	{
		import std.algorithm : max;

		// we add a timeout so that we do not wait indef.
		if (!dontWait && timeout != Duration.max)
		{
			KernelTimespec timespec;
			timeout.split!("seconds", "nsecs")(timespec.tv_sec, timespec.tv_nsec);
			m_io.putWith!((ref SubmissionEntry e, KernelTimespec timespec)
			{
				// wait for timeout or first completion
				e.prepTimeout(timespec, 1);
				e.user_data = ulong.max;
			})(timespec);
		}
		int res = m_io.submit(dontWait ? 0 : 1);
		if (res < 0)
		{
			return false;
		}
		bool gotEvents = !m_io.empty;
		foreach (ref CompletionEntry e; m_io)
		{
			import eventcore.internal.utils : print;
			import std.algorithm : all;
			// internally used timeouts
			if (e.user_data == ulong.max)
				continue;
			int fd;
			EventType type;
			// let the specific driver handle the rest
			splitKey(e.user_data, fd, type);
			assert (fd < m_fds.length);
			OpData* op = &m_fds[fd].runningOps[type];
			// cb might be null, if the operation was cancelled
			if (op.opCb)
			{
				m_runningOps -= 1;
				op.opCb(FD(fd, m_fds[fd].validationCounter), e, op.userCb);
				*op = OpData.init;
			} else if (m_fds[fd].runningOps[].all!(x => x.opCb == null))
			{
				resetFD(m_fds[fd]);
			}
		}
		return gotEvents;
	}

	void resetFD(ref ResourceData data) nothrow @nogc
	{
		data.descriptor = 0;
	}

	@property size_t waiterCount() const nothrow @safe { return m_runningOps; }

	package FDType initFD(FDType)(size_t fd)
	{
		auto slot = &m_fds[fd];
		assert (slot.refCount == 0, "Initializing referenced file descriptor slot.");
		assert (slot.descriptor == 0, "Initializing referenced file descriptor slot.");
		slot.refCount = 1;
		return FDType(fd, slot.validationCounter);
	}

	package void put(in FD fd, in EventType type, SubmissionEntry e,
		OpCallback cb, UserCallback userCb) nothrow
	{
		m_runningOps += 1;
		ulong userData = combineKey(cast(int) fd, type);
		e.user_data = userData;
		m_io.put(e);
		assert (m_fds[fd.value].runningOps[type].opCb == null);
		m_fds[fd.value].runningOps[type] = OpData(cb, userCb);
	}

	void cancelOp(FD fd, EventType type) @trusted nothrow @nogc
	{
		if (!isValid(fd))
		{
			print("cancel for invalid fd");
			return;
		}
		if (m_fds[fd].runningOps[type] == OpData.init)
		{
			print("cancelling op that's not running");
			return;
		}
		ulong op = combineKey(cast(int) fd, type);
		m_io.putWith!((ref SubmissionEntry e, ulong op)
		{
			// result is ignored (own userData is ulong.max)
			prepCancel(e, op);
			e.user_data = ulong.max;
		})(op);
		m_runningOps -= 1;
		m_fds[fd].runningOps[type] = OpData.init;
	}

	package void* rawUserData(FD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
		nothrow @system
	{
		return null;
	}

	package final void* rawUserDataImpl(size_t descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc nothrow
	{
		return null;
	}
}

void splitKey(ulong key, out int fd, out EventType type) @nogc nothrow
{
	fd = cast(int) (key >> 32);
	type = cast(EventType) ((key << 32) >>> 32);
}

ulong combineKey(int fd, EventType type) @nogc nothrow
{
	return cast(ulong)(fd) << 32 | cast(int) type;
}

@nogc nothrow
unittest
{
	ulong orig = 0xDEAD0001;
	int fd;
	EventType type;
	splitKey(orig, fd, type);
	assert (type == cast(EventType)1);
	assert (fd == 0xDEAD);
	assert (orig == combineKey(driver, op));
}
