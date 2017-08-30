module eventcore.drivers.posix.watchers;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;


final class InotifyEventDriverWatchers(Loop : PosixEventLoop) : EventDriverWatchers
{
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl, core.sys.posix.unistd, core.sys.linux.sys.inotify;
	import std.algorithm.comparison : among;
	import std.file;

	private {
		Loop m_loop;
		string[int][WatcherID] m_watches; // TODO: use a @nogc (allocator based) map
	}

	this(Loop loop) { m_loop = loop; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback)
	{
		enum IN_NONBLOCK = 0x800; // value in core.sys.linux.sys.inotify is incorrect
		auto handle = () @trusted { return inotify_init1(IN_NONBLOCK); } ();
		if (handle == -1) return WatcherID.invalid;

		auto ret = WatcherID(handle);

		addWatch(ret, path);
		if (recursive) {
			try {
				if (path.isDir) () @trusted {
					foreach (de; path.dirEntries(SpanMode.shallow))
						if (de.isDir) addWatch(ret, de.name);
				} ();
			} catch (Exception e) {
				// TODO: decide if this should be ignored or if the error should be forwarded
			}
		}

		m_loop.initFD(FD(handle), FDFlags.none);
		m_loop.registerFD(FD(handle), EventMask.read);
		m_loop.setNotifyCallback!(EventType.read)(FD(handle), &onChanges);
		m_loop.m_fds[handle].specific = WatcherSlot(callback);

		processEvents(WatcherID(handle));

		return ret;
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(m_loop.m_fds[descriptor].common.refCount > 0, "Adding reference to unreferenced event FD.");
		m_loop.m_fds[descriptor].common.refCount++;
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		FD fd = cast(FD)descriptor;
		assert(m_loop.m_fds[fd].common.refCount > 0, "Releasing reference to unreferenced event FD.");
		if (--m_loop.m_fds[fd].common.refCount == 1) { // NOTE: 1 because setNotifyCallback increments the reference count
			m_loop.unregisterFD(fd, EventMask.read);
			m_loop.clearFD(fd);
			m_watches.remove(descriptor);
			/*errnoEnforce(*/close(cast(int)fd)/* == 0)*/;
			return false;
		}

		return true;
	}

	private bool onChanges(FD fd)
	{
		processEvents(cast(WatcherID)fd);
		return false;
	}

	private void processEvents(WatcherID id)
	{
		import core.stdc.stdio : FILENAME_MAX;
		import core.stdc.string : strlen;

		ubyte[inotify_event.sizeof + FILENAME_MAX + 1] buf = void;
		while (true) {
			auto ret = () @trusted { return read(cast(int)id, &buf[0], buf.length); } ();

			if (ret == -1 && errno.among!(EAGAIN, EINPROGRESS))
				break;
			assert(ret <= buf.length);

			auto rem = buf[0 .. ret];
			while (rem.length > 0) {
				auto ev = () @trusted { return cast(inotify_event*)rem.ptr; } ();
				FileChange ch;
				if (ev.mask & (IN_CREATE|IN_MOVED_TO))
					ch.kind = FileChangeKind.added;
				else if (ev.mask & (IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF|IN_MOVED_FROM))
					ch.kind = FileChangeKind.removed;
				else if (ev.mask & IN_MODIFY)
					ch.kind = FileChangeKind.modified;

				auto name = () @trusted { return ev.name.ptr[0 .. strlen(ev.name.ptr)]; } ();
				ch.directory = m_watches[id][ev.wd];
				ch.isDirectory = (ev.mask & IN_ISDIR) != 0;
				ch.name = name;
				addRef(id); // assure that the id doesn't get invalidated until after the callback
				auto cb = m_loop.m_fds[id].watcher.callback;
				cb(id, ch);
				if (!releaseRef(id)) return;

				rem = rem[inotify_event.sizeof + ev.len .. $];
			}
		}
	}

	private bool addWatch(WatcherID handle, string path)
	{
		import std.string : toStringz;
		enum EVENTS = IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MODIFY |
			IN_MOVE_SELF | IN_MOVED_FROM | IN_MOVED_TO;
		immutable wd = () @trusted { return inotify_add_watch(cast(int)handle, path.toStringz, EVENTS); } ();
		if (wd == -1) return false;
		m_watches[handle][wd] = path;
		return true;
	}
}

version (OSX)
final class FSEventsEventDriverWatchers(Loop : PosixEventLoop) : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback on_change)
	{
		/*FSEventStreamCreate
		FSEventStreamScheduleWithRunLoop
		FSEventStreamStart*/
		assert(false, "TODO!");
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		/*FSEventStreamStop
		FSEventStreamUnscheduleFromRunLoop
		FSEventStreamInvalidate
		FSEventStreamRelease*/
		assert(false, "TODO!");
	}
}

final class PosixEventDriverWatchers(Loop : PosixEventLoop) : EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override WatcherID watchDirectory(string path, bool recursive, FileChangesCallback on_change)
	{
		assert(false, "TODO!");
	}

	final override void addRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}

	final override bool releaseRef(WatcherID descriptor)
	{
		assert(false, "TODO!");
	}
}

package struct WatcherSlot {
	alias Handle = WatcherID;
	FileChangesCallback callback;
}
