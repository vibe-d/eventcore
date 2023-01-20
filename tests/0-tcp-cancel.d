/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.internal.utils : print;
import core.time : Duration, MonoTime, msecs, seconds;
import std.socket : InternetAddress;
import std.stdio : writeln;

ubyte[256] s_rbuf;
bool s_done;

enum timeout = 1000.msecs;

void main()
{
	writeln("Testing read cancellation...");
	testReadCancel();
	writeln("Testing write cancellation...");
	testWriteCancel();
	writeln("Done.");
}

void testReadCancel()
{
	auto baddr 	= new InternetAddress(0x7F000001, 40001);
	auto server = eventDriver.sockets.listenStream(baddr, StreamListenOptions.defaults, null);
	StreamSocketFD client;
	StreamSocketFD incoming;

	eventDriver.sockets.waitForConnections(server, (StreamListenSocketFD srv, StreamSocketFD incoming_, scope RefAddress addr) {
		incoming = incoming_;
		eventDriver.sockets.read(incoming, s_rbuf, IOMode.once, (sock, status, bts) { assert(false); });
		eventDriver.sockets.cancelRead(incoming);

		auto tmw = eventDriver.timers.create();
		eventDriver.timers.set(tmw, 50.msecs, 0.msecs);
		eventDriver.timers.wait(tmw, (tmw) {
			assert(!eventDriver.sockets.releaseRef(incoming));
			eventDriver.sockets.shutdown(incoming, true, true);
			assert(!eventDriver.sockets.releaseRef(server));
			incoming = StreamSocketFD.invalid;
		});
	});

	eventDriver.sockets.connectStream(baddr, null, (sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);

		auto tmw = eventDriver.timers.create();
		eventDriver.timers.set(tmw, 300.msecs, 0.msecs);
		eventDriver.timers.wait(tmw, (tmw) {
			assert(incoming == StreamSocketFD.invalid);
			assert(!eventDriver.sockets.releaseRef(client));
			s_done = true;
		});
	});

	waitUntilIdle();
	assert(s_done);
	s_done = false;
}

void testWriteCancel()
{
	auto baddr 	= new InternetAddress(0x7F000001, 40001);
	auto server = eventDriver.sockets.listenStream(baddr, StreamListenOptions.defaults, null);
	StreamSocketFD client;
	StreamSocketFD incoming;

	eventDriver.sockets.waitForConnections(server, (StreamListenSocketFD srv, StreamSocketFD incoming_, scope RefAddress addr) {
		incoming = incoming_;
		auto bigbuf = new ubyte[](256*1024*1024);
		bool blocked;
		do {
			blocked = true;
			eventDriver.sockets.write(incoming, bigbuf, IOMode.once, (sock, status, bts) { assert(blocked); assert(status == IOStatus.ok); blocked = false; });
		} while (!blocked);
		blocked = true;
		eventDriver.sockets.cancelWrite(incoming);

		auto tmw = eventDriver.timers.create();
		eventDriver.timers.set(tmw, 50.msecs, 0.msecs);
		eventDriver.timers.wait(tmw, (tmw) {
			assert(!eventDriver.sockets.releaseRef(incoming));
			eventDriver.sockets.shutdown(incoming, true, true);
			assert(!eventDriver.sockets.releaseRef(server));
			incoming = StreamSocketFD.invalid;
		});
	});

	eventDriver.sockets.connectStream(baddr, null, (sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);

		auto tmw = eventDriver.timers.create();
		eventDriver.timers.set(tmw, 300.msecs, 0.msecs);
		eventDriver.timers.wait(tmw, (tmw) {
			assert(incoming == StreamSocketFD.invalid);
			assert(!eventDriver.sockets.releaseRef(client));
			s_done = true;
		});
	});

	waitUntilIdle();
	assert(s_done);
	s_done = false;
}

void waitUntilIdle()
{
	enum timeout = 1000.msecs;
	auto tmstart = MonoTime.currTime;
	while (true) {
		auto tm = MonoTime.currTime;
		if (tm >= tmstart + timeout) assert(false, "Timeout!");
		auto res = eventDriver.core.processEvents(tmstart + timeout - tm);
		if (res == ExitReason.outOfWaiters) break;
	}
}
