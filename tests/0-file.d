/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
	debugVersions "EventCoreLogFiles"
+/
module test;

import eventcore.core;
import eventcore.socket;
import std.file : remove;
import std.socket : InternetAddress;
import core.time : Duration, msecs;

bool s_done = false;

void main()
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
