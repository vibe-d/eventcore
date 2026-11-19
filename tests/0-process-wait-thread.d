#!/usr/bin/env dub
/+ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/

// The thread that waits for child processes (posix/processes.d) must not leak
// its stack each time it terminates, must wait for every child process it is
// responsible for, must leave other child processes of the program alone and
// must not get in the way of terminating the program.

module test;

import core.memory : GC;
import core.time : Duration, MonoTime, msecs, seconds;
import eventcore.core;
import std.conv : to;
import std.stdio;

version (Windows) {
	void main()
	{
		writefln("Skipping process wait thread test on Windows.");
	}
} else:

void main(string[] args)
{
	if (args.length == 2) {
		// child mode for testExit()
		switch (args[1]) {
			default: assert(false, "Unknown mode " ~ args[1]);
			case "exit-after-child": runProcess(["true"]); break;
			case "exit-with-child": startProcess(["sleep", "1"]); break;
		}
		writefln("Child mode %s done.", args[1]);
		return;
	}

	testSequential();
	testOverlapping();
	testForeignChild();
	testExit(args[0], "exit-after-child", 0.seconds);
	testExit(args[0], "exit-with-child", 1.seconds);
	writefln("Process wait thread tests passed.");
}

// Every child process that gets spawned while no other one is running gets a
// new wait thread. The terminated wait threads must not leave their stacks
// behind (each one is 8 MiB of address space and two memory mappings), and
// their Thread objects must not stay reachable from the GC heap.
void testSequential()
{
	enum n = 200;

	runProcess(["true"]);
	// The first garbage collection starts the threads for parallel marking.
	// Their stacks would count as leaked if it happened during the loop.
	GC.collect();
	auto heap_before = GC.stats().usedSize;
	version (linux) auto before = memoryState();

	foreach (i; 0 .. n)
		runProcess(["true"]);

	GC.collect();
	auto heap_after = GC.stats().usedSize;
	writefln("%s child processes: GC heap %s -> %s bytes", n, heap_before, heap_after);
	assert(heap_after < heap_before + n * 64, "Terminated wait threads stay reachable.");

	version (linux) {
		auto after = memoryState();
		writefln("%s child processes: thread stacks %s -> %s, memory mappings %s -> %s",
			n, before.stacks, after.stacks, before.mappings, after.mappings);
		assert(after.stacks < before.stacks + 10, "Thread stacks of the process wait thread leak.");
		assert(after.mappings < before.mappings + n / 4, "Memory mappings leak.");
	}
}

// Child processes that end while others are still running are all waited for.
void testOverlapping()
{
	Process[] procs;
	foreach (i; 0 .. 10)
		procs ~= startProcess(["sleep", (0.05 * (i % 4)).to!string]);
	auto slow = startProcess(["sleep", "0.5"]);
	foreach (i; 0 .. 20)
		runProcess(["true"]);
	foreach (p; procs ~ slow)
		waitForProcess(p);
}

// Child processes that the program spawns by other means (here std.process)
// may be waited for by the program only.
void testForeignChild()
{
	import std.process : spawnProcess, wait;

	auto foreign = spawnProcess(["sh", "-c", "sleep 0.3; exit 3"]);
	foreach (i; 0 .. 10)
		runProcess(["true"]);
	// the foreign child process ends while the wait thread waits for this one
	runProcess(["sleep", "0.6"]);
	assert(wait(foreign) == 3, "Foreign child process was waited for by eventcore.");
}

// The program terminates cleanly after its child processes have ended and
// while one is still running, in which case it waits for the child process.
void testExit(string program, string mode, Duration child_duration)
{
	import std.algorithm.searching : canFind;
	import std.process : execute;

	auto start = MonoTime.currTime;
	auto res = execute([program, mode]);
	auto elapsed = MonoTime.currTime - start;
	writefln("Mode %s: exit status %s after %s, output: %s", mode, res.status, elapsed, res.output);
	assert(res.status == 0 && res.output.canFind("done."), "Program did not terminate cleanly.");
	assert(elapsed < child_duration + 2.seconds, "Program did not terminate in time.");
}

Process startProcess(string[] args)
{
	auto p = eventDriver.processes.spawn(args,
		ProcessStdinFile(ProcessRedirect.inherit),
		ProcessStdoutFile(ProcessRedirect.inherit),
		ProcessStderrFile(ProcessRedirect.inherit),
		null, ProcessConfig.none, null);
	assert(p != Process.init, "Failed to spawn process.");
	return p;
}

void runProcess(string[] args)
{
	waitForProcess(startProcess(args));
}

bool s_exited;

void waitForProcess(Process p)
{
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

version (linux) {
	struct MemoryState {
		size_t stacks;   // anonymous read-write mappings right above a guard page
		size_t mappings;
	}

	MemoryState memoryState()
	{
		import std.array : split;
		import std.string : indexOf;

		MemoryState ret;
		ulong guard_end;
		foreach (line; File("/proc/self/maps").byLine) {
			// address range, permissions, offset, device, inode[, path]
			auto fields = line.split;
			auto range = fields[0];
			auto sep = range.indexOf('-');
			auto start = range[0 .. sep].to!ulong(16);
			auto end = range[sep + 1 .. $].to!ulong(16);
			bool anonymous = fields.length == 5;

			ret.mappings++;
			if (anonymous && fields[1] == "rw-p" && guard_end == start)
				ret.stacks++;
			guard_end = anonymous && fields[1] == "---p" ? end : 0;
		}
		return ret;
	}
}
