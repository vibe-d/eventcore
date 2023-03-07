module eventcore.drivers.posix.io_uring.files;

import eventcore.internal.utils;

import eventcore.driver;
import eventcore.drivers.posix.io_uring.io_uring;
import core.sys.posix.sys.types;
import core.sys.posix.sys.stat;
import core.sys.linux.fcntl;
import during;

import taggedalgebraic;

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
			case FileOpenMode.createTrunc: flags = O_RDWR|O_CREAT|O_TRUNC; amode = octal!644; break;
			case FileOpenMode.append: flags = O_WRONLY|O_CREAT|O_APPEND; amode = octal!644; break;
		}

		SubmissionEntry e;
		prepOpenat(e, AT_FDCWD, path.toStringz, flags, amode);
		m_loop.put(FD.init, EventType.status, e, &handleOpen, cast(UserCallback) userCb);
	}

	private void handleOpen(FD fd, ref const(CompletionEntry) e, UserCallback userCb)
		nothrow
	in { assert (fd == FD.init); }
	do {
		FileOpenCallback cb = cast(FileOpenCallback) userCb;
		if (e.res == -1)
		{
			cb(FileFD.init, IOStatus.error);
			return;
		}
		FileFD fileFD = adopt(e.res);
		cb(fileFD, IOStatus.ok);
	}

	FileFD adopt(int system_file_handle)
	{
		auto flags = () @trusted { return fcntl(system_file_handle, F_GETFD); } ();
		if (flags == -1) return FileFD.invalid;
		return  () @trusted { return m_loop.initFD!FileFD(system_file_handle); }();
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
		m_loop.put(cast(FD) file, EventType.status, e, &handleClose,
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
		m_loop.put(file, EventType.write, e, &handleIO,
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
		m_loop.put(file, EventType.read, e, &handleIO,
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
		return m_loop.isValid(handle);
	}

	/** Increments the reference count of the given file.
	*/
	void addRef(FileFD descriptor)
	{
		m_loop.addRef(descriptor);
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
		return m_loop.releaseRef(descriptor);
	}

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(FileFD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system nothrow
	{
		return m_loop.rawUserData(descriptor, size, initialize, destroy);
	}

}
