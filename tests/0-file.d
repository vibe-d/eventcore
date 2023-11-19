/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
	debugVersions "EventCoreLogFiles"
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.file : exists, remove;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

bool s_done = false;

void main()
{
	testBasicIO();
	testAsyncOpen();
	testReadOnce();
}

void testBasicIO()
{
	auto f = eventDriver.files.open("test.txt", FileOpenMode.createTrunc);
	assert(eventDriver.files.getSize(f) == 0);
	auto data = cast(const(ubyte)[])"Hello, World!";

	scope (failure) {
		try remove("test.txt");
		catch (Exception e) {}
	}

	eventDriver.files.write(f, 0, data[0 .. 7], IOMode.all, (f, status, nbytes) {
		assert(status == IOStatus.ok);
		assert(nbytes == 7);
		assert(eventDriver.files.getSize(f) == 7);
		eventDriver.files.write(f, 5, data[5 .. $], IOMode.all, (f, status, nbytes) {
			assert(status == IOStatus.ok);
			assert(nbytes == data.length - 5);
			assert(eventDriver.files.getSize(f) == data.length);
			auto dst = new ubyte[data.length];
			eventDriver.files.read(f, 0, dst[0 .. 7], IOMode.all, (f, status, nbytes) {
				assert(status == IOStatus.ok);
				assert(nbytes == 7);
				assert(dst[0 .. 7] == data[0 .. 7]);
				eventDriver.files.read(f, 5, dst[5 .. $], IOMode.all, (f, status, nbytes) {
					assert(status == IOStatus.ok);
					assert(nbytes == data.length - 5);
					assert(dst == data);
					eventDriver.files.close(f, (f, s) {
						assert(s == CloseStatus.ok);

						// attempt to re-create the existing file, should fail
						assert(eventDriver.files.open("test.txt", FileOpenMode.create) == FileFD.invalid);

						() @trusted {
							scope (failure) assert(false);
							remove("test.txt");
						} ();
						eventDriver.files.releaseRef(f);

						// attempt to create the file after it has been deleted, should succeed
						auto f2 = eventDriver.files.open("test.txt", FileOpenMode.create);
						assert(f2 != FileFD.invalid);
						assert(eventDriver.files.getSize(f2) == 0);
						eventDriver.files.releaseRef(f2);
						() @trusted {
							scope (failure) assert(false);
							remove("test.txt");
						} ();

						s_done = true;
					});
				});
			});
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}


void testAsyncOpen()
{
	eventDriver.files.open("test.txt", FileOpenMode.createTrunc, (f, status) {
		assert(f != FileFD.invalid);
		assert(status == OpenStatus.ok);

		eventDriver.files.open("test.txt", FileOpenMode.create, (f2, status2) {
			assert(f2 == FileFD.invalid);
			import std.conv : to;
			try assert(status2 == OpenStatus.alreadyExists, status2.to!string);
			catch (Exception e) assert(false, e.msg);

			eventDriver.files.releaseRef(f);
			try remove("test.txt");
			catch (Exception e) {}
			s_done = true;
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;

	if (exists("test.txt")) {
		try remove("test.txt");
		catch (Exception e) {}
	}
}

ulong totalSystemMemory()
{
	version (Posix)
	{
		import core.sys.posix.unistd;

		long pages = sysconf(_SC_PHYS_PAGES);
		long page_size = sysconf(_SC_PAGE_SIZE);
		return pages * page_size;
	}
	else version (Windows)
	{
		import core.sys.windows.windows;

		MEMORYSTATUSEX status;
		status.dwLength = sizeof(status);
		GlobalMemoryStatusEx(&status);
		return status.ullTotalPhys;
	}
	else
	{
		// 4 GB as fallback

		return 1024 * 1024 * 1024 * 4;
	}
}

void testReadOnce()
{
	// 3x this amount will be allocated in memory
	// by default 3/16 of system memory will be attempted to be allocated for large buffer tests
	auto MBs = totalSystemMemory / 16 / 1024 / 1024;
	if (MBs < 1024)
		log("warning: may not have enough system memory for this test, if the following assert fails, the buffer was too small");

	auto f = eventDriver.files.open("test.txt", FileOpenMode.createTrunc);
	assert(eventDriver.files.getSize(f) == 0);
	auto data = new ubyte[1024 * 1024 * MBs];
	ubyte[] buffer = new ubyte[2 * 1024 * 1024 * MBs];
	(cast(int[]) data)[] = int('A' | 'a' << 8 | 'a' << 16 | 'a' << 24);

	scope (failure) {
		try remove("test.txt");
		catch (Exception e) {}
	}

	eventDriver.files.write(f, 0, data, IOMode.all, (f, status, nbytes) {
		assert(status == IOStatus.ok);
		assert(nbytes == data.length);
		assert(eventDriver.files.getSize(f) == data.length);

		eventDriver.files.write(f, data.length, data, IOMode.all, (f, status, nbytes) {
			assert(status == IOStatus.ok);
			assert(nbytes == data.length);
			assert(eventDriver.files.getSize(f) == data.length * 2);

			eventDriver.files.read(f, 0, buffer, IOMode.once, (f, status, nbytes) {
				assert(status == IOStatus.ok);
				assert(nbytes < buffer.length, "did not expect to be able to read this much data at once in an immediate step!");
				if (nbytes > data.length)
					nbytes = data.length;
				assert(buffer[0 .. nbytes] == data[0 .. nbytes]);

				() @trusted {
					scope (failure) assert(false);
					remove("test.txt");
				} ();
				s_done = true;
			});
		});
	});

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}

void log(string s)
@safe nothrow {
	import std.stdio : writeln;
	scope (failure) assert(false);
	writeln(s);
}
