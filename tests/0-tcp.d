/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import eventcore.internal.utils : print;
import std.socket : InternetAddress;
import core.time : Duration, msecs, seconds;

ubyte[256] s_rbuf;
bool s_done;

void main()
{
	testBasicExchange();
	testShutdown();
	testLeftoverBurst();
}

void testBasicExchange()
{
	print("Basic test:");
	print("");

	// watchdog timer in case of starvation/deadlocks
	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 10000.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) { assert(false, "Test hung."); });

	static ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static ubyte[] pack2 = [4, 3, 2, 1, 0];

	auto baddr 	= new InternetAddress(0x7F000001, 40001);
	auto server = listenStream(baddr);
	StreamSocket client;
	StreamSocket incoming;

	server.waitForConnections!((incoming_, addr) {
		incoming = incoming_; // work around ref counting issue
		assert(incoming.state == ConnectionState.connected);
		print("Got incoming, reading data");
		incoming.read!((status, bts) {
			print("Got data");
			assert(status == IOStatus.ok);
			assert(bts == pack1.length);
			assert(s_rbuf[0 .. pack1.length] == pack1);

			auto tmw = eventDriver.timers.create();
			eventDriver.timers.set(tmw, 20.msecs, 0.msecs);
			eventDriver.timers.wait(tmw, (tmw) {
				print("Second write");
				client.write!((status, bytes) {
					print("Second write done");
					assert(status == IOStatus.ok);
					assert(bytes == pack2.length);
				})(pack2, IOMode.once);
			});

			print("Second read");
			incoming.read!((status, bts) {
				print("Second read done");
				assert(status == IOStatus.ok);
				assert(bts == pack2.length);
				assert(s_rbuf[0 .. pack2.length] == pack2);

				destroy(client);
				destroy(incoming);
				destroy(server);
				s_done = true;
				eventDriver.timers.stop(tm);

				// NOTE: one reference to incoming is still held by read()
				//assert(eventDriver.core.waiterCount == 1);
			})(s_rbuf, IOMode.once);
		})(s_rbuf, IOMode.once);
	});

	print("Connect...");
	connectStream!((sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);
		assert(sock.state == ConnectionState.connected);
		print("Setting keepalive and timeout options");
		client.setKeepAlive(true);
		client.setKeepAliveParams(10.seconds, 10.seconds, 4);
		client.setUserTimeout(5.seconds);
		print("Initial write");
		client.write!((wstatus, bytes) {
			print("Initial write done");
			assert(wstatus == IOStatus.ok);
			assert(bytes == 10);
		})(pack1, IOMode.all);
	})(baddr);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}

void testShutdown()
{
	static ubyte[10] srbuf, crbuf;

	print("");
	print("Shutdown test:");
	print("");

	// watchdog timer in case of starvation/deadlocks
	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 10000.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) { assert(false, "Test hung."); });

	auto baddr 	= new InternetAddress(0x7F000001, 40001);
	auto server = listenStream(baddr);

	StreamSocket client;
	StreamSocket incoming;

	server.waitForConnections!((sock, addr) {
		incoming = sock;
		assert(incoming.state == ConnectionState.connected);

		print("Server read");
		ubyte[10] buf;
		incoming.read!((rstatus, bytes) {
			print("Server read done %s", bytes);
			assert(rstatus == IOStatus.disconnected);
			assert(bytes == 4);
			assert(srbuf[0 .. 4] == [1, 2, 3, 4]);
			assert(incoming.state == ConnectionState.passiveClose);

			print("Server write 4 bytes");
			incoming.write!((wstatus, bytes) {
				print("Server write done");
				assert(wstatus == IOStatus.ok);
				assert(bytes == 4);
				print("Shutdown server write");
				incoming.shutdown(false, true);
				assert(incoming.state == ConnectionState.closed);
				print("Attempt server write after shutdown");
				incoming.write!((wstatus, bytes) {
					print("Attempted server write done");
					assert(wstatus == IOStatus.disconnected);
					assert(bytes == 0);
				})([1], IOMode.all);
			})([5, 6, 7, 8], IOMode.all);
		})(srbuf, IOMode.all);
	});

	print("Connect...");
	connectStream!((sock, status) {
		client = sock;
		assert(client.state == ConnectionState.connected);

		print("Client write 4 bytes");
		client.write!((wstatus, bytes) {
			print("Client write done");
			assert(wstatus == IOStatus.ok);
			assert(bytes == 4);
			print("Shutdown client write");
			client.shutdown(false, true);
			assert(client.state == ConnectionState.activeClose);
			print("Attempt client write after shutdown");
			client.write!((wstatus, bytes) {
				print("Attempted client write done");
				assert(wstatus == IOStatus.disconnected);
				assert(bytes == 0);

				print("Client read");
				client.read!((rstatus, bytes) {
					print("Client read done");
					assert(rstatus == IOStatus.disconnected);
					assert(bytes == 4);
					assert(crbuf[0 .. 4] == [5, 6, 7, 8]);
					assert(client.state == ConnectionState.closed);

					destroy(client);
					destroy(incoming);
					destroy(server);
					s_done = true;
					eventDriver.timers.stop(tm);
				})(crbuf, IOMode.all);
			})([1], IOMode.all);
		})([1, 2, 3, 4], IOMode.all);
	})(baddr);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}

void testLeftoverBurst()
{
	print("");
	print("Leftover burst test:");
	print("");

	auto tm = eventDriver.timers.create();
	eventDriver.timers.set(tm, 10000.msecs, 0.msecs);
	eventDriver.timers.wait(tm, (tm) { assert(false, "Test hung."); });

	static immutable ubyte[] pack1 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
	static immutable ubyte[] pack2 = [4, 3, 2, 1, 0];
	ubyte[15] burst;
	burst[0 .. 10] = pack1;
	burst[10 .. 15] = pack2;

	auto baddr = new InternetAddress(0x7F000001, 40002);
	auto server = listenStream(baddr);
	StreamSocket client;
	StreamSocket incoming;

	server.waitForConnections!((incoming_, addr) {
		incoming = incoming_;
		print("Got incoming, first read %s bytes", pack1.length);
		incoming.read!((status, bts) {
			print("First leftover read %s", bts);
			assert(status == IOStatus.ok);
			assert(bts == pack1.length);
			assert(s_rbuf[0 .. pack1.length] == pack1);

			print("Second leftover read %s bytes", pack2.length);
			incoming.read!((status, bts) {
				print("Second leftover read done %s", bts);
				assert(status == IOStatus.ok);
				assert(bts == pack2.length);
				assert(s_rbuf[0 .. pack2.length] == pack2);

				destroy(client);
				destroy(incoming);
				destroy(server);
				s_done = true;
				eventDriver.timers.stop(tm);
			})(s_rbuf[0 .. pack2.length], IOMode.once);
		})(s_rbuf[0 .. pack1.length], IOMode.once);
	});

	print("Connect leftover...");
	connectStream!((sock, status) {
		client = sock;
		assert(status == ConnectStatus.connected);
		print("Write burst %s bytes", burst.length);
		client.write!((wstatus, bytes) {
			print("Burst write done");
			assert(wstatus == IOStatus.ok);
			assert(bytes == burst.length);
		})(burst[], IOMode.all);
	})(baddr);

	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters);
	assert(s_done);
	s_done = false;
}
