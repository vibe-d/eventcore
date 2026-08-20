module eventcore.drivers.libasync.watchers;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.core;
import eventcore.internal.utils : ChoppedVector, print;
import libasync : AsyncDirectoryWatcher, DWChangeInfo, DWFileEvent;


final class LibasyncEventDriverWatchers : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:

	private {
		struct Slot {
			uint refCount;
			uint validation;
			AsyncDirectoryWatcher watcher;
			FileChangesCallback callback;
			string path;
			DataInitializer userDataDestructor;
			ubyte[16 * size_t.sizeof] userData;
		}

		LibasyncEventDriverCore m_core;
		ChoppedVector!Slot m_slots;
		size_t[] m_free;
		size_t m_live;
	}

	this(LibasyncEventDriverCore core)
	{
		m_core = core;
	}

	package @property bool hasLeakedHandles()
	{
		if (!m_live) return false;
		print("Warning: %s directory watchers leaked at libasync driver shutdown.", m_live);
		return true;
	}

	void dispose()
	{
		foreach (i; 0 .. m_slots.length)
			if (m_slots[i].refCount)
				killSlot(i);
	}

	override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	@trusted {
		auto w = new AsyncDirectoryWatcher(m_core.evloop);
		auto id = allocSlot();
		auto idx = cast(size_t)id;
		auto s = &m_slots[idx];
		s.watcher = w;
		s.callback = callback;
		s.path = path;

		if (!w.run({ onChange(idx); })) {
			killSlot(idx);
			return WatcherID.invalid;
		}
		if (!w.watchDir(path, DWFileEvent.ALL, recursive)) {
			killSlot(idx);
			return WatcherID.invalid;
		}
		m_core.addWaiter();
		return id;
	}

	override bool isValid(WatcherID handle)
	const @nogc {
		if (handle == WatcherID.invalid) return false;
		auto v = cast(size_t)handle;
		if (v >= m_slots.length) return false;
		auto s = &m_slots[v];
		return s.refCount > 0 && s.validation == handle.validationCounter;
	}

	override void addRef(WatcherID descriptor)
	{
		if (!isValid(descriptor)) return;
		m_slots[cast(size_t)descriptor].refCount++;
	}

	override bool releaseRef(WatcherID descriptor)
	{
		if (!isValid(descriptor)) return true;
		auto s = &m_slots[cast(size_t)descriptor];
		if (--s.refCount) return true;
		m_core.removeWaiter();
		killSlot(cast(size_t)descriptor);
		return false;
	}

	protected override void* rawUserData(WatcherID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		auto s = &m_slots[cast(size_t)descriptor];
		assert(s.userDataDestructor is null || s.userDataDestructor is destroy);
		assert(size <= s.userData.length);
		if (!s.userDataDestructor) {
			initialize(s.userData.ptr);
			s.userDataDestructor = destroy;
		}
		return s.userData.ptr;
	}

	private void onChange(size_t idx)
	@trusted {
		if (idx >= m_slots.length || !m_slots[idx].refCount) return;
		auto s = &m_slots[idx];
		DWChangeInfo[16] buf;
		DWChangeInfo[] slice = buf[];
		auto n = s.watcher.readChanges(slice);
		foreach (ref ch; buf[0 .. n]) {
			FileChange fc;
			fc.kind = mapKind(ch.event);
			fc.baseDirectory = s.path;
			try fc.name = ch.path;
			catch (Exception) fc.name = null;
			if (s.callback) s.callback(WatcherID(idx, s.validation), fc);
		}
		// drain the rest so libasync does not assert
		while (n == buf.length) {
			slice = buf[];
			n = s.watcher.readChanges(slice);
		}
	}

	private static FileChangeKind mapKind(DWFileEvent ev)
	{
		if (ev & (DWFileEvent.CREATED | DWFileEvent.MOVED_TO))
			return FileChangeKind.added;
		if (ev & (DWFileEvent.DELETED | DWFileEvent.MOVED_FROM))
			return FileChangeKind.removed;
		return FileChangeKind.modified;
	}

	private WatcherID allocSlot()
	{
		size_t idx;
		if (m_free.length) {
			idx = m_free[$ - 1];
			m_free = m_free[0 .. $ - 1];
			m_free = m_free[0 .. $];
		} else {
			idx = m_slots.length;
		}
		m_slots[idx] = Slot.init;
		m_slots[idx].refCount = 1;
		m_slots[idx].validation++;
		m_live++;
		return WatcherID(idx, m_slots[idx].validation);
	}

	private void killSlot(size_t idx)
	@trusted {
		if (idx >= m_slots.length) return;
		auto s = &m_slots[idx];
		if (s.watcher) {
			s.watcher.kill();
			s.watcher = null;
		}
		if (s.userDataDestructor)
			s.userDataDestructor(s.userData.ptr);
		*s = Slot.init;
		s.validation++;
		m_free ~= idx;
		if (m_live) m_live--;
	}
}
