#!/usr/bin/env dub
/+ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/

module test;

import core.time : Duration, msecs;
import eventcore.core;
import std.conv;
import std.datetime;
import std.process : thisProcessID;
import std.stdio;

version (Windows) {
	void main()
	{
		writefln("Skipping SIGCHLD coalesce test on Windows.");
	}
} else:

import core.sys.posix.sys.wait : waitpid, WNOHANG;

int numProc;

void main(string[] args)
{
	// child mode
	if (args.length == 2)
	{
		import core.thread : Thread;
		writefln("Child: %s (%s) from %s", args[1], (args[1].to!long - Clock.currStdTime).hnsecs, thisProcessID);
		Thread.sleep((args[1].to!long - Clock.currStdTime).hnsecs);
		return;
	}

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 5.seconds, 0.msecs);
	eventDriver.timers.wait(tm, (tm) @trusted {
		assert(false, "Test hung.");
	});

	// attempt to let all child processes finish in exactly 1 second to force
	// signal coalescing
	auto targettime = Clock.currTime(UTC()) + 1.seconds;

	auto procs = new Process[](20);
	foreach (i, ref p; procs) {
		p = eventDriver.processes.spawn(
			[args[0], targettime.stdTime.to!string],
			ProcessStdinFile(ProcessRedirect.inherit),
			ProcessStdoutFile(ProcessRedirect.inherit),
			ProcessStderrFile(ProcessRedirect.inherit),
			null, ProcessConfig.none, null
		);
		assert(p != Process.init);

		writeln("Started child: ", p.pid);
		numProc++;
	}

	foreach (p; procs) {
		eventDriver.processes.wait(p.pid, (ProcessID pid, int res) nothrow
		{
			numProc--;
			try writefln("Child %s exited with %s", pid, res);
			catch (Exception) {}
		});
	}

	do eventDriver.core.processEvents(Duration.max);
	while (numProc);

	foreach (p; procs) assert(waitpid(cast(int)p.pid, null, WNOHANG) == -1);
}
