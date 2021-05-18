/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.internal.utils : print;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;
import std.file : exists, remove, rename, rmdirRecurse, mkdir, isDir;
import std.format : format;
import std.functional : toDelegate;
import std.path : baseName, buildPath, dirName;
import std.stdio : File, writefln;
import std.array : replace;

bool s_done;
int s_cnt = 0;

enum testDir = "watcher_test";

WatcherID watcher;
FileChange[] pendingChanges;


void main()
{
	if (exists(testDir))
		rmdirRecurse(testDir);

	mkdir(testDir);
	mkdir(testDir~"/dira");

	// test non-recursive watcher
	watcher = eventDriver.watchers.watchDirectory(testDir, false, toDelegate(&testCallback));
	assert(watcher != WatcherID.invalid);
	// some watcher implementations need time to initialize or report past events
	dropChanges(2000.msecs);
	testFile(     "file1.dat");
	testFile(     "file2.dat");
	testFile(     "dira/file1.dat", false);
	testCreateDir("dirb");
	testFile(     "dirb/file1.dat", false);
	testRemoveDir("dirb");
	testFile(     "file1.dat");
	eventDriver.watchers.releaseRef(watcher);
	testFile(     "file1.dat", false);
	testRemoveDir("dira", false);
	testCreateDir("dira", false);

	// test recursive watcher
	watcher = eventDriver.watchers.watchDirectory(testDir, true, toDelegate(&testCallback));
	assert(watcher != WatcherID.invalid);
	// some watcher implementations need time to initialize or report past events
	dropChanges(2000.msecs);
	testFile(     "file1.dat");
	testFile(     "file2.dat");
	testFile(     "dira/file1.dat");
	testCreateDir("dirb");
	testFile(     "dirb/file1.dat");
	testRename(   "dirb", "dirc");
	testFile(     "dirc/file2.dat");
	testFile(     "file1.dat");
	eventDriver.watchers.releaseRef(watcher);
	testFile(     "file1.dat", false);
	testFile(     "dira/file1.dat", false);
	testFile(     "dirc/file1.dat", false);
	testRemoveDir("dirc", false);
	testRemoveDir("dira", false);

	rmdirRecurse(testDir);

	// make sure that no watchers are registered anymore
	auto er = eventDriver.core.processEvents(10.msecs);
	assert(er == ExitReason.outOfWaiters);
}

void testCallback(WatcherID w, ref const FileChange ch)
@safe nothrow {
	assert(w == watcher, "Wrong watcher generated a change");
	pendingChanges ~= ch;
	// the name is accesible scope-only!
	pendingChanges[$-1].name = pendingChanges[$-1].name.dup;
}

void dropChanges(Duration dur)
{
	auto starttime = MonoTime.currTime();
	auto remdur = dur;
	while (remdur > 0.msecs) {
		auto er = eventDriver.core.processEvents(remdur);
		switch (er) {
			default: assert(false, format("Unexpected event loop exit code: %s", er));
			case ExitReason.idle: break;
			case ExitReason.timeout: break;
			case ExitReason.outOfWaiters:
				assert(false, "No watcher left, but expected change.");
		}
		remdur = dur - (MonoTime.currTime() - starttime);
	}

	pendingChanges = null;
}

void skipDirectoryChanges()
{
	// ignore different directory modification notifications on Windows as
	// opposed to the other systems
	while (pendingChanges.length) {
		auto pch = pendingChanges[0];
		if (pch.kind == FileChangeKind.modified) {
			auto p = buildPath(pch.baseDirectory, pch.directory, pch.name);
			if (!exists(p) || isDir(p)) {
				pendingChanges = pendingChanges[1 .. $];
				continue;
			}
		}
		break;
	}
}

void expectChange(FileChange ch, bool expect_change)
{
	skipDirectoryChanges();

	auto starttime = MonoTime.currTime();
	again: while (!pendingChanges.length) {
		auto er = eventDriver.core.processEvents(100.msecs);
		switch (er) {
			default: assert(false, format("Unexpected event loop exit code: %s", er));
			case ExitReason.idle: break;
			case ExitReason.timeout:
				assert(!pendingChanges.length);
				break;
			case ExitReason.outOfWaiters:
				assert(!expect_change, "No watcher left, but expected change.");
				return;
		}
		if (!pendingChanges.length && MonoTime.currTime() - starttime >= 2000.msecs) {
			assert(!expect_change, format("Got no change, expected %s.", ch));
			return;
		}

		skipDirectoryChanges();
	}
	assert(expect_change, "Got change although none was expected.");

	auto pch = pendingChanges[0];

	// adjust for Windows behavior
	pch.directory = pch.directory.replace("\\", "/");
	pch.name = pch.name.replace("\\", "/");
	pendingChanges = pendingChanges[1 .. $];
	if (pch.kind == FileChangeKind.modified && (pch.name == "dira" || pch.name == "dirb"))
		goto again;

	// test all field except the isDir one, which does not work on all systems
	// we allow "modified" instead of "added" here, as the FSEvents based watcher
	// has strange results on the CI VM
	assert((pch.kind == ch.kind || pch.kind == FileChangeKind.modified && ch.kind == FileChangeKind.added)
		&& pch.baseDirectory == ch.baseDirectory
		&& pch.directory == ch.directory && pch.name == ch.name,
		format("Unexpected change: %s vs %s", pch, ch));
}

void testFile(string name, bool expect_change = true)
{
print("test %s CREATE %s", name, expect_change);
	auto fil = File(buildPath(testDir, name), "wt");
	expectChange(fchange(FileChangeKind.added, name), expect_change);

print("test %s MODIFY %s", name, expect_change);
	fil.write("test");
	fil.close();
	expectChange(fchange(FileChangeKind.modified, name), expect_change);

print("test %s DELETE %s", name, expect_change);
	remove(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.removed, name), expect_change);
}

void testCreateDir(string name, bool expect_change = true)
{
print("test %s CREATEDIR %s", name, expect_change);
	mkdir(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.added, name), expect_change);
}

void testRemoveDir(string name, bool expect_change = true)
{
print("test %s DELETEDIR %s", name, expect_change);
	rmdirRecurse(buildPath(testDir, name));
	expectChange(fchange(FileChangeKind.removed, name), expect_change);
}

void testRename(string from, string to, bool expect_change = true)
{
print("test %s RENAME %s %s", from, to, expect_change);
	rename(buildPath(testDir, from), buildPath(testDir, to));
	expectChange(fchange(FileChangeKind.removed, from), expect_change);
	expectChange(fchange(FileChangeKind.added, to), expect_change);
}

FileChange fchange(FileChangeKind kind, string name)
{
	auto dn = dirName(name);
	if (dn == ".") dn = "";
	return FileChange(kind, testDir, dn, baseName(name));
}
