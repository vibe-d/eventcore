#!/usr/bin/env dub
/+ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
	versions "EventcoreTestProcessRace"
+/

// A child process that gets added while the process wait thread has just
// found no child processes (ECHILD), but has not yet taken the lock, must
// still be waited for. The version EventcoreTestProcessRace widens that window
// to 500 ms in posix/processes.d, so that the test is deterministic.

module test;

import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import eventcore.core;
import std.stdio;

version (Windows) {
	void main()
	{
		writefln("Skipping process wait race test on Windows.");
	}
} else:

bool s_exited;

void main()
{
	runProcess(["true"]);

	// the wait thread now sleeps between ECHILD and taking the lock
	Thread.sleep(100.msecs);

	auto start = MonoTime.currTime;
	runProcess(["true"]);
	auto elapsed = MonoTime.currTime - start;
	writefln("Second child process was waited for after %s", elapsed);

	// Without the delay, the race window is too small to be hit reliably and
	// the test would not prove anything.
	assert(elapsed >= 300.msecs, "The test hook is not active, was eventcore built with version EventcoreTestProcessRace?");
}

void runProcess(string[] args)
{
	auto p = eventDriver.processes.spawn(args,
		ProcessStdinFile(ProcessRedirect.inherit),
		ProcessStdoutFile(ProcessRedirect.inherit),
		ProcessStderrFile(ProcessRedirect.inherit),
		null, ProcessConfig.none, null);
	assert(p != Process.init, "Failed to spawn process.");

	s_exited = false;
	eventDriver.processes.wait(p.pid, (ProcessID pid, int status) nothrow { s_exited = true; });

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 5.seconds, 0.msecs);
	eventDriver.timers.wait(tm, (tm) nothrow {
		assert(false, "Child process was not waited for (test hung).");
	});

	while (!s_exited)
		eventDriver.core.processEvents(Duration.max);

	eventDriver.timers.stop(tm);
	eventDriver.timers.releaseRef(tm);
	eventDriver.processes.releaseRef(p.pid);
}
