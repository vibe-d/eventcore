/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import core.time : Duration, MonoTime, msecs;
import std.socket : InternetAddress;
import std.stdio : writeln;


void main()
{
	writeln("Testing receive cancellation...");
	testRecvCancel();
	version (EventcoreWinAPIDriver) {
		// NOTE: Linux appears to drop packets instead of blocking on send
		writeln("Testing send cancellation...");
		testSendCancel();
	}
	writeln("Done.");
}

void testRecvCancel()
{
	DatagramSocketFD sock;
	ubyte[256] rbuf;
	auto baddr = new InternetAddress(0x7F000001, 40001);
	sock = eventDriver.sockets.createDatagramSocket(baddr, null);
	eventDriver.sockets.receive(sock, rbuf, IOMode.once,
		(DatagramSocketFD sock, IOStatus status, size_t bytes, scope RefAddress addr) { assert(false); });
	eventDriver.sockets.cancelReceive(sock);
	waitUntilIdle();
	assert(!eventDriver.sockets.releaseRef(sock));
}

void testSendCancel()
{
	DatagramSocketFD sock;
	ubyte[32768] rbuf;
	auto baddr = new InternetAddress(0x7F000001, 40001);
	sock = eventDriver.sockets.createDatagramSocket(baddr, baddr);

	// send packets until the output buffer is full
	while (true) {
		bool has_blocked = true;
		eventDriver.sockets.send(sock, rbuf, IOMode.once, null,
			(DatagramSocketFD sock, IOStatus status, size_t bytes, scope RefAddress addr) { has_blocked = false; });
		if (has_blocked) break;
	}
	eventDriver.sockets.cancelReceive(sock);
	waitUntilIdle();
	assert(!eventDriver.sockets.releaseRef(sock));
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
