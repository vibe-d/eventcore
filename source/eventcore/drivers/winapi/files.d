module eventcore.drivers.winapi.files;

version (Windows):

import eventcore.driver;
import eventcore.drivers.winapi.core;
import eventcore.internal.ioworker;
import eventcore.internal.win32;

private extern(Windows) @trusted nothrow @nogc {
	BOOL SetEndOfFile(HANDLE hFile);
}

final class WinAPIEventDriverFiles : EventDriverFiles {
@safe /*@nogc*/ nothrow:
	private {
		WinAPIEventDriverCore m_core;
		IOWorkerPool m_workerPool;
	}

	this(WinAPIEventDriverCore core)
	@nogc {
		m_core = core;
	}

	deprecated("Use the callback based overload")
	override FileFD open(string path, FileOpenMode mode)
	{
		import std.utf : toUTF16z;

		DWORD access, creation, shareMode;
		determineOpenMode(mode, access, creation, shareMode);

		auto handle = () @trusted {
			scope (failure) assert(false);
			return CreateFileW(path.toUTF16z, access, shareMode, null, creation,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
		} ();
		auto errorcode = GetLastError();
		if (handle == INVALID_HANDLE_VALUE)
			return FileFD.invalid;

		if (mode == FileOpenMode.createTrunc && errorcode == ERROR_ALREADY_EXISTS) {
			BOOL ret = SetEndOfFile(handle);
			if (!ret) {
				CloseHandle(handle);
				return FileFD.invalid;
			}
		}

		return adoptInternal(handle);
	}

	override void open(string path, FileOpenMode mode, FileOpenCallback on_opened)
	{
		import std.utf : toUTF16z;

		DWORD access, creation, shareMode;
		determineOpenMode(mode, access, creation, shareMode);

		static void onThreadComplete(WinAPIEventDriverFiles driver,
			HANDLE handle, DWORD error, FileOpenCallback callback)
		@safe nothrow {
			FileFD fd = handle != INVALID_HANDLE_VALUE ? driver.adoptInternal(handle) : FileFD.invalid;
			OpenStatus st = OpenStatus.ok;
			if (fd == FileFD.invalid) {
				switch (error) {
					default: st = OpenStatus.failed; break;
					case ERROR_FILE_NOT_FOUND: st = OpenStatus.notFound; break;
					case ERROR_ACCESS_DENIED: st = OpenStatus.notAccessible; break;
					case ERROR_SHARING_VIOLATION: st = OpenStatus.sharingViolation; break;
					case ERROR_FILE_EXISTS: st = OpenStatus.alreadyExists; break;
				}
			}
			driver.m_core.removeWaiter();
			callback(fd, st);
		}

		static void openInThread(WinAPIEventDriverFiles driver, string path,
			DWORD access, DWORD creation, DWORD share_mode, FileOpenCallback on_opened)
		@safe nothrow {
			HANDLE handle = () @trusted {
				scope (failure) assert(false);
				return CreateFileW(path.toUTF16z, access, share_mode, null, creation,
					FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
			} ();
			DWORD errorcode = GetLastError();
			if (handle != INVALID_HANDLE_VALUE) {
				if (creation == CREATE_ALWAYS && errorcode == ERROR_ALREADY_EXISTS) {
					if (!SetEndOfFile(handle)) {
						CloseHandle(handle);
						handle = INVALID_HANDLE_VALUE;
					}
				}
			}

			() @trusted {
				auto core = cast(shared)driver.m_core;
				core.runInOwnerThread(&onThreadComplete, driver, handle, errorcode, on_opened);
			} ();
		}

		m_core.addWaiter();
		workerPool.run!openInThread(this, path, access, creation, shareMode, on_opened);
	}

	private void determineOpenMode(FileOpenMode mode, out DWORD access,
		out DWORD creation, out DWORD share_mode)
	{
		share_mode = FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE;

		final switch (mode) {
			case FileOpenMode.read:
				access = GENERIC_READ;
				creation = OPEN_EXISTING;
				break;
			case FileOpenMode.readWrite:
				access = GENERIC_READ | GENERIC_WRITE;
				creation = OPEN_EXISTING;
				break;
			case FileOpenMode.create:
				access = GENERIC_READ | GENERIC_WRITE;
				creation = CREATE_NEW;
				break;
			case FileOpenMode.createTrunc:
				access = GENERIC_READ | GENERIC_WRITE;
				creation = CREATE_ALWAYS;
				break;
			case FileOpenMode.append:
				access = FILE_APPEND_DATA;
				creation = OPEN_ALWAYS;
				break;
		}
	}

	override FileFD adopt(int system_handle)
	{
		return adoptInternal(() @trusted { return cast(HANDLE)system_handle; } ());
	}

	private FileFD adoptInternal(HANDLE handle)
	{
		DWORD f;
		if (!() @trusted { return GetHandleInformation(handle, &f); } ())
			return FileFD.invalid;

		auto s = m_core.setupSlot!FileSlot(handle);

		s.read.overlapped.driver = m_core;
		s.read.overlapped.hEvent = handle;
		s.write.overlapped.driver = m_core;
		s.write.overlapped.hEvent = handle;

		return FileFD(cast(size_t)handle, m_core.m_handles[handle].validationCounter);
	}

	override void close(FileFD file, FileCloseCallback on_closed)
	{
		static void doCloseCleanup(CloseParams p)
		{
			p.core.removeWaiter();
			if (p.callback) p.callback(p.file, p.status);
		}

		static void doClose(FileFD file, FileCloseCallback on_closed,
			shared(WinAPIEventDriverCore) core)
		{
			CloseParams p;
			CloseStatus st;
			p.file = file;
			p.callback = on_closed;
			p.core = () @trusted { return cast(WinAPIEventDriverCore)core; } ();
			if (CloseHandle(idToHandle(file))) p.status = CloseStatus.ok;
			else p.status = CloseStatus.ioError;

			() @trusted { core.runInOwnerThread(&doCloseCleanup, p); } ();
		}

		if (!isValid(file)) {
			on_closed(file, CloseStatus.invalidHandle);
			return;
		}

		auto h = idToHandle(file);
		auto slot = () @trusted { return &m_core.m_handles[h]; } ();
		if (slot.file.read.overlapped.hEvent != INVALID_HANDLE_VALUE)
			slot.file.read.overlapped.hEvent = slot.file.write.overlapped.hEvent = INVALID_HANDLE_VALUE;
		m_core.addWaiter();
		m_core.discardEvents(&slot.file.read.overlapped, &slot.file.write.overlapped);
		m_core.freeSlot(h);
		workerPool.run!doClose(file, on_closed, () @trusted { return cast(shared)m_core; } ());
	}

	override ulong getSize(FileFD file)
	{
		if (!isValid(file)) return ulong.max;

		LARGE_INTEGER size;
		auto succeeded = () @trusted { return GetFileSizeEx(idToHandle(file), &size); } ();
		if (!succeeded || size.QuadPart < 0)
			return ulong.max;
		return size.QuadPart;
	}

	override void truncate(FileFD file, ulong size, FileIOCallback on_finish)
	@trusted {
		if (!isValid(file)) {
			on_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		auto h = idToHandle(file);

		// FIXME: do this in a separate thread

		LARGE_INTEGER li = {QuadPart: size};
		if (!SetFilePointerEx(h, li, null, FILE_BEGIN)) {
			on_finish(file, IOStatus.error, 0);
			return;
		}

		if (!SetEndOfFile(h)) {
			on_finish(file, IOStatus.error, 0);
			return;
		}

		on_finish(file, IOStatus.ok, 0);
	}

	override void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish)
	{
		if (!isValid(file)) {
			on_write_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.write;

		if (slot.overlapped.hEvent == INVALID_HANDLE_VALUE) {
			on_write_finish(file, IOStatus.disconnected, 0);
			return;
		}

		if (!buffer.length) {
			on_write_finish(file, IOStatus.ok, 0);
			return;
		}

		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_write_finish;
		m_core.addWaiter();
		startIO!(WriteFileEx, true)(h, slot);
	}

	override void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish)
	{
		if (!isValid(file)) {
			on_read_finish(file, IOStatus.invalidHandle, 0);
			return;
		}

		auto h = idToHandle(file);
		auto slot = &m_core.m_handles[h].file.read;

		if (slot.overlapped.hEvent == INVALID_HANDLE_VALUE) {
			on_read_finish(file, IOStatus.disconnected, 0);
			return;
		}

		if (!buffer.length) {
			on_read_finish(file, IOStatus.ok, 0);
			return;
		}

		slot.bytesTransferred = 0;
		slot.offset = offset;
		slot.buffer = buffer;
		slot.mode = mode;
		slot.callback = on_read_finish;
		m_core.addWaiter();
		startIO!(ReadFileEx, false)(h, slot);
	}

	override void cancelWrite(FileFD file)
	{
		if (!isValid(file)) return;

		auto h = idToHandle(file);
		cancelIO!true(h, m_core.m_handles[h].file.write);
	}

	override void cancelRead(FileFD file)
	{
		if (!isValid(file)) return;

		auto h = idToHandle(file);
		cancelIO!false(h, m_core.m_handles[h].file.read);
	}

	override bool isValid(FileFD handle)
	const {
		auto h = idToHandle(handle);
		if (auto ps = h in m_core.m_handles)
			return ps.validationCounter == handle.validationCounter;
		return false;
	}

	override bool isUnique(FileFD handle)
	const {
		if (!isValid(handle)) return false;
		if (auto ps = idToHandle(handle) in m_core.m_handles)
			return ps.refCount == 1;
		return false;
	}

	override void addRef(FileFD descriptor)
	{
		if (!isValid(descriptor)) return;

		m_core.m_handles[idToHandle(descriptor)].addRef();
	}

	override bool releaseRef(FileFD descriptor)
	{
		if (!isValid(descriptor)) return true;

		auto h = idToHandle(descriptor);
		auto slot = &m_core.m_handles[h];
		return slot.releaseRef({ close(descriptor, null); });
	}

	protected override void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return m_core.rawUserDataImpl(idToHandle(descriptor), size, initialize, destroy);
	}

	private static void startIO(alias fun, bool RO)(HANDLE h, FileSlot.Direction!RO* slot)
	{
		import std.algorithm.comparison : min;

		with (slot.overlapped.overlapped) {
			Internal = 0;
			InternalHigh = 0;
			Offset = cast(uint)(slot.offset & 0xFFFFFFFF);
			OffsetHigh = cast(uint)(slot.offset >> 32);
			hEvent = h;
		}

		auto nbytes = min(slot.buffer.length, DWORD.max);
		auto handler = &overlappedIOHandler!(onIOFinished!(fun, RO));
		if (!() @trusted { return fun(h, &slot.buffer[0], nbytes, &slot.overlapped.overlapped, handler); } ()) {
			slot.overlapped.driver.removeWaiter();
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred);
		}
	}

	private void cancelIO(bool RO)(HANDLE h, ref FileSlot.Direction!RO slot)
	{
		if (slot.callback) {
			m_core.removeWaiter();
			() @trusted { CancelIoEx(h, &slot.overlapped.overlapped); } ();
			slot.callback = null;
			slot.buffer = null;
		}
	}

	private static nothrow
	void onIOFinished(alias fun, bool RO)(DWORD error, DWORD bytes_transferred, OVERLAPPED_CORE* overlapped)
	{
		HANDLE handle = overlapped.hEvent;
		if (handle == INVALID_HANDLE_VALUE) return;
		auto cslot = () @trusted { return &overlapped.driver.m_handles[handle]; } ();
		FileFD id = FileFD(cast(size_t)overlapped.hEvent, cslot.validationCounter);

		static if (RO)
			auto slot = () @trusted { return &cslot.file.write; } ();
		else
			auto slot = () @trusted { return &cslot.file.read; } ();
		assert(slot !is null);

		if (!slot.callback) {
			// request was already cancelled
			return;
		}

		if (error != 0) {
			overlapped.driver.removeWaiter();
			slot.invokeCallback(IOStatus.error, slot.bytesTransferred + bytes_transferred);
			return;
		}

		slot.bytesTransferred += bytes_transferred;
		slot.offset += bytes_transferred;

		if (slot.bytesTransferred >= slot.buffer.length || slot.mode != IOMode.all) {
			overlapped.driver.removeWaiter();
			slot.invokeCallback(IOStatus.ok, slot.bytesTransferred);
		} else {
			startIO!(fun, RO)(handle, slot);
		}
	}

	private @property ref IOWorkerPool workerPool()
	{
		if (!m_workerPool)
			m_workerPool = acquireIOWorkerPool();
		return m_workerPool;
	}

	private static HANDLE idToHandle(FileFD id)
	@trusted @nogc {
		return cast(HANDLE)cast(size_t)id;
	}
}

private static struct CloseParams {
	FileFD file;
	FileCloseCallback callback;
	CloseStatus status;
	WinAPIEventDriverCore core;
}
