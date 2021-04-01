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

alias OpIdx = std.typecons.Typedef!(int, -1, "eventcore.OpIdx");

// information regarding a specific resource / descriptor
private struct ResourceData
{
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

// the user can store extra information per resource
// which is kept in a sep. array
private struct UserData
{
	DataInitializer userDataDestructor;
	ubyte[16*size_t.sizeof] userData;
}


/// substitue for UringCore that does nothing for
/// non-uring posix event loops
final class NoRing
{
	void registerEventID(EventID id) nothrow @trusted @nogc { }
	void submit() nothrow @trusted @nogc { }
	@property size_t waiterCount() const nothrow @safe { return 0; }
	bool doProcessEvents(Duration timeout, bool dontWait = true) nothrow @trusted { return false; }
}


///
final class UringEventLoop
{
	import eventcore.internal.consumablequeue;
	import std.typecons : Tuple, tuple;

	private {
		Uring m_io;
		ChoppedVector!(ResourceData) m_fds;
		ChoppedVector!(OpData) m_ops;
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
				if (fds.runningOps[type] != OpIdx.init)
					cancelOp(fds.runningOps[type], type);
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
		import std.typecons : TypedefType;

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
				// e.g. open sets m_fds to FD.init
				if (op.fd != FD.init)
					m_fds[op.fd].runningOps[type] = OpIdx.init;
				m_runningOps -= 1;
				op.opCb(op.fd, e, op.userCb);
				*op = OpData.init;
			}
		}
		return gotEvents;
	}

	void resetFD(ref ResourceData data) nothrow @nogc
	{
		int vc = data.validationCounter;
		data = ResourceData.init;
		data.validationCounter = vc + 1;
	}

	@property size_t waiterCount() const nothrow @safe { return m_runningOps; }

	package FDType initFD(FDType)(size_t fd)
	{
		auto slot = &m_fds[fd];
		assert (slot.refCount == 0, "Initializing referenced file descriptor slot.");
		assert (slot.descriptor == -1, "Initializing referenced file descriptor slot.");
		slot.refCount = 1;
		return FDType(fd, slot.validationCounter);
	}

	package void put(in FD fd, in EventType type, SubmissionEntry e,
		OpCallback cb, UserCallback userCb) nothrow
	{
		import std.typecons : TypedefType;
		m_runningOps += 1;
		OpIdx idx = allocOpData();
		ulong userData = combineKey(idx, type);
		e.user_data = userData;
		m_io.put(e);
		if (fd != FD.init)
		{
			ResourceData* res = &m_fds[fd.value];
			assert (res.runningOps[type] == OpIdx.init);
			res.runningOps[type] = idx;
		}
		m_ops[cast(TypedefType!OpIdx) idx] = OpData(fd, cb, userCb);
	}

	void cancelOp(FD fd, EventType type) @safe nothrow @nogc
	{
		if (!isValid(fd))
			return;

		OpIdx idx = m_fds[fd].runningOps[type];
		if (idx != OpIdx.init)
			cancelOp(idx, type);
	}

	void cancelOp(OpIdx opIdx, EventType type) @trusted nothrow @nogc
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
			if (m_fds[opData.fd].runningOps[type] == OpIdx.init)
			{
				print("cancelling op that's not running");
				return;
			}
			m_fds[opData.fd].runningOps[type] = OpIdx.init;
		}
		print("cancel op: %s", opIdx);
		ulong op = combineKey(opIdx, type);
		m_io.putWith!((ref SubmissionEntry e, ulong op)
		{
			// result is ignored (own userData is ulong.max)
			prepCancel(e, op);
			e.user_data = ulong.max;
		})(op);
		m_runningOps -= 1;
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

	OpIdx allocOpData() nothrow @nogc
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

void splitKey(ulong key, out OpIdx op, out EventType type) @nogc nothrow
out { assert(op != OpIdx.init); }
body
{
	op = cast(int) (key >> 32);
	type = cast(EventType) ((key << 32) >>> 32);
}

ulong combineKey(OpIdx op, EventType type) @nogc nothrow
in { assert(op != OpIdx.init); }
body
{
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
