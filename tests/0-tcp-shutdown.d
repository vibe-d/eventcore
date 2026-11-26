/++ dub.sdl:
	name "test"
	dependency "eventcore" path=".."
+/
module test;

import eventcore.core;
import eventcore.socket;
import eventcore.internal.utils : print;
import std.socket : InternetAddress;
import core.time : Duration, msecs;


void main()
{
	testShutdownNone();
	testShutdownWrite();
	testShutdownRead();
	testShutdownBoth();
	testShutdownWriteAfterPassiveClose();
	testShutdownReadAfterActiveClose();
	print("Shutdown tests passed.");
}


// shutdown(read=false, write=false) must not alter anything at all.
void testShutdownNone()
{
	beginScenario("shutdown(read=false, write=false)", 40011);
	acceptConnection!noneServer();
	connectClient!noneClient();
	runScenario();
}

void noneServer()
@safe nothrow {
	// the peer may not notice anything, so both directions keep working
	s_accepted.read!((status, bytes) {
		assert(status == IOStatus.ok, "Peer's data should be readable.");
		assert(bytes == data_a.length);
		assert(s_srv_buf[0 .. bytes] == data_a);
		assert(s_accepted.state == ConnectionState.connected);

		s_accepted.write!((wstatus, wbytes) {
			assert(wstatus == IOStatus.ok, "Writes should still work.");
			assert(wbytes == data_b.length);
			assert(s_accepted.state == ConnectionState.connected);
			endpointDone(true);
		})(data_b, IOMode.all);
	})(s_srv_buf[0 .. data_a.length], IOMode.all);
}

void noneClient()
@safe nothrow {
	s_client.shutdown(false, false);
	assert(s_client.state == ConnectionState.connected,
		"shutdown(read=false, write=false) must not change the connection state.");

	s_client.write!((status, bytes) {
		assert(status == IOStatus.ok, "Writes must still work after a no-op shutdown.");
		assert(bytes == data_a.length);
		assert(s_client.state == ConnectionState.connected);

		s_client.read!((rstatus, rbytes) {
			assert(rstatus == IOStatus.ok, "Reads must still work after a no-op shutdown.");
			assert(rbytes == data_b.length);
			assert(s_cli_buf[0 .. rbytes] == data_b);
			assert(s_client.state == ConnectionState.connected);
			endpointDone(false);
		})(s_cli_buf[0 .. data_b.length], IOMode.all);
	})(data_a, IOMode.all);
}


// shutdown(read=false, write=true) closes the write direction only: local
// writes fail and the peer sees end-of-stream, but reads keep working.
void testShutdownWrite()
{
	beginScenario("shutdown(read=false, write=true)", 40012);
	acceptConnection!shutWriteServer();
	connectClient!shutWriteClient();
	runScenario();
}

void shutWriteServer()
@safe nothrow {
	// the peer has to observe the write shutdown as end-of-stream ...
	s_accepted.read!((status, bytes) {
		assert(status == IOStatus.disconnected, "Peer's shutdown(write) should be seen as end-of-stream.");
		assert(bytes == 0);
		assert(s_accepted.state == ConnectionState.passiveClose);

		// ... while its own write direction remains usable
		s_accepted.write!((wstatus, wbytes) {
			assert(wstatus == IOStatus.ok, "Writes should still work after the peer's shutdown(write).");
			assert(wbytes == data_b.length);
			endpointDone(true);
		})(data_b, IOMode.all);
	})(s_srv_buf, IOMode.all);
}

void shutWriteClient()
@safe nothrow {
	s_client.shutdown(false, true);
	assert(s_client.state == ConnectionState.activeClose,
		"shutdown(read=false, write=true) should result in ConnectionState.activeClose.");

	s_client.write!((status, bytes) {
		assert(status == IOStatus.disconnected, "Writes must fail after shutdown(write).");
		assert(bytes == 0);

		s_client.read!((rstatus, rbytes) {
			assert(rstatus == IOStatus.ok, "Reads must still work after shutdown(write).");
			assert(rbytes == data_b.length);
			assert(s_cli_buf[0 .. rbytes] == data_b);
			endpointDone(false);
		})(s_cli_buf[0 .. data_b.length], IOMode.all);
	})(data_a, IOMode.all);
}


// shutdown(read=true, write=false) closes the read direction only: local
// reads see end-of-stream, but the peer is unaffected and our writes are
// still delivered to it.
void testShutdownRead()
{
	beginScenario("shutdown(read=true, write=false)", 40013);
	acceptConnection!shutReadServer();
	connectClient!shutReadClient();
	runScenario();
}

void shutReadServer()
@safe nothrow {
	// the peer must not notice the read shutdown: data written after it still
	// arrives and writing to it keeps working
	s_accepted.read!((status, bytes) {
		assert(status == IOStatus.ok, "Data written after the peer's shutdown(read) must arrive.");
		assert(bytes == data_a.length);
		assert(s_srv_buf[0 .. bytes] == data_a);
		assert(s_accepted.state == ConnectionState.connected);

		s_accepted.write!((wstatus, wbytes) {
			assert(wstatus == IOStatus.ok, "Writes must still work against a shut read direction.");
			assert(wbytes == data_b.length);
			endpointDone(true);
		})(data_b, IOMode.all);
	})(s_srv_buf[0 .. data_a.length], IOMode.all);
}

void shutReadClient()
@safe nothrow {
	s_client.shutdown(true, false);
	assert(s_client.state == ConnectionState.passiveClose,
		"shutdown(read=true, write=false) should result in ConnectionState.passiveClose.");

	s_client.read!((rstatus, rbytes) {
		assert(rstatus == IOStatus.disconnected, "Reads must report end-of-stream after shutdown(read).");
		assert(rbytes == 0);
		assert(s_client.state == ConnectionState.passiveClose);

		s_client.write!((status, bytes) {
			assert(status == IOStatus.ok, "Writes must still work after shutdown(read).");
			assert(bytes == data_a.length);
			endpointDone(false);
		})(data_a, IOMode.all);
	})(s_cli_buf, IOMode.all);
}


// shutdown(read=true, write=true) closes both directions at once.
void testShutdownBoth()
{
	beginScenario("shutdown(read=true, write=true)", 40014);
	acceptConnection!shutBothServer();
	connectClient!shutBothClient();
	runScenario();
}

void shutBothServer()
@safe nothrow {
	// both directions are gone, so the peer sees end-of-stream
	s_accepted.read!((status, bytes) {
		assert(status == IOStatus.disconnected, "Peer's shutdown(read,write) should be seen as end-of-stream.");
		assert(bytes == 0);
		endpointDone(true);
	})(s_srv_buf, IOMode.all);
}

void shutBothClient()
@safe nothrow {
	s_client.shutdown(true, true);
	assert(s_client.state == ConnectionState.closed,
		"shutdown(read=true, write=true) should result in ConnectionState.closed.");

	s_client.read!((status, bytes) {
		assert(status == IOStatus.disconnected, "Reads must fail after shutdown(read=true).");
		assert(bytes == 0);
		assert(s_client.state == ConnectionState.closed);

		s_client.write!((wstatus, wbytes) {
			assert(wstatus == IOStatus.disconnected, "Writes must fail after shutdown(write=true).");
			assert(wbytes == 0);
			endpointDone(false);
		})(data_a, IOMode.all);
	})(s_cli_buf, IOMode.all);
}


// Shutting the write direction of a socket which already saw end-of-stream
// (state passiveClose) completes the close.
void testShutdownWriteAfterPassiveClose()
{
	beginScenario("shutdown(read=false, write=true) in state passiveClose", 40015);
	acceptConnection!passiveCloseServer();
	connectClient!passiveCloseClient();
	runScenario();
}

void passiveCloseServer()
@safe nothrow {
	s_accepted.write!((status, bytes) {
		assert(status == IOStatus.ok, "Initial write should succeed.");
		assert(bytes == data_a.length);

		// shut our write side, so that the peer sees end-of-stream
		s_accepted.shutdown(false, true);
		assert(s_accepted.state == ConnectionState.activeClose,
			"shutdown(read=false, write=true) should result in ConnectionState.activeClose.");
		endpointDone(true);
	})(data_a, IOMode.all);
}

void passiveCloseClient()
@safe nothrow {
	s_client.read!((status, bytes) {
		assert(status == IOStatus.ok, "Initial read should succeed.");
		assert(bytes == data_a.length);
		assert(s_cli_buf[0 .. bytes] == data_a);

		// the peer's write shutdown leaves us in state passiveClose ...
		s_client.read!((rstatus, rbytes) {
			assert(rstatus == IOStatus.disconnected, "Peer's shutdown(write) should be seen as end-of-stream.");
			assert(rbytes == 0);
			assert(s_client.state == ConnectionState.passiveClose);

			// ... so shutting our own write direction closes the connection
			s_client.shutdown(false, true);
			assert(s_client.state == ConnectionState.closed,
				"shutdown(read=false, write=true) in state passiveClose should result in ConnectionState.closed.");

			s_client.write!((wstatus, wbytes) {
				assert(wstatus == IOStatus.disconnected, "Writes must fail once the connection is closed.");
				assert(wbytes == 0);
				endpointDone(false);
			})(data_b, IOMode.all);
		})(s_cli_buf, IOMode.all);
	})(s_cli_buf[0 .. data_a.length], IOMode.all);
}


// Shutting the read direction of a socket which already shut its own write
// side (state activeClose) completes the close.
void testShutdownReadAfterActiveClose()
{
	beginScenario("shutdown(read=true, write=false) in state activeClose", 40016);
	acceptConnection!activeCloseServer();
	connectClient!activeCloseClient();
	runScenario();
}

void activeCloseServer()
@safe nothrow {
	s_accepted.read!((status, bytes) {
		assert(status == IOStatus.disconnected, "Peer's shutdown(write) should be seen as end-of-stream.");
		assert(bytes == 0);
		endpointDone(true);
	})(s_srv_buf, IOMode.all);
}

void activeCloseClient()
@safe nothrow {
	s_client.shutdown(false, true);
	assert(s_client.state == ConnectionState.activeClose,
		"shutdown(read=false, write=true) should result in ConnectionState.activeClose.");

	// the write side is already shut, so the read shutdown completes the close
	s_client.shutdown(true, false);
	assert(s_client.state == ConnectionState.closed,
		"shutdown(read=true, write=false) in state activeClose should result in ConnectionState.closed.");

	s_client.read!((status, bytes) {
		assert(status == IOStatus.disconnected, "Reads must fail once the connection is closed.");
		assert(bytes == 0);

		s_client.write!((wstatus, wbytes) {
			assert(wstatus == IOStatus.disconnected, "Writes must fail once the connection is closed.");
			assert(wbytes == 0);
			endpointDone(false);
		})(data_a, IOMode.all);
	})(s_cli_buf, IOMode.all);
}



// Prepares a scenario using its own loopback address and sets up a watchdog
// timer, so that operations which the driver fails to complete (such as a
// read expected to see end-of-stream) are detected instead of hanging.
void beginScenario(string name, ushort port)
{
	s_scenario = name;
	s_server_done = s_client_done = s_finished = false;
	s_srv_buf[] = 0;
	s_cli_buf[] = 0;

	print("Shutdown test: %s (port %s)", name, port);

	s_baddr = new InternetAddress(0x7F000001, port);
	s_listen = listenStream(s_baddr);

	s_watchdog = eventDriver.timers.create();
	eventDriver.timers.set(s_watchdog, 10000.msecs, 0.msecs);
	eventDriver.timers.wait(s_watchdog, (tm) { assert(false, "Test hung: " ~ s_scenario); });
}

// Starts accepting a single connection, invoking `onAccept` once the
// connection has been established (via `connectClient`).
void acceptConnection(alias onAccept)()
{
	s_listen.waitForConnections!((sock, addr) {
		s_accepted = sock;
		assert(s_accepted.state == ConnectionState.connected,
			"Accepted socket should be connected in scenario: " ~ s_scenario);
		onAccept();
	})();
}

// Connects to the listening socket of the current scenario, invoking
// `onConnect` from the connection callback.
void connectClient(alias onConnect)()
{
	connectStream!((sock, status) {
		assert(status == ConnectStatus.connected, "Connect failed in scenario: " ~ s_scenario);
		s_client = sock;
		assert(s_client.state == ConnectionState.connected,
			"Connected socket should be connected in scenario: " ~ s_scenario);
		onConnect();
	})(s_baddr);
}

// Marks an endpoint as done and finalizes the scenario once both endpoints
// completed all their operations (no I/O is pending at that point).
//
// Explicitly attributed because it is called from the I/O callbacks.
void endpointDone(bool is_server)
@safe nothrow {
	if (is_server) {
		assert(!s_server_done, "Server endpoint completed twice in scenario: " ~ s_scenario);
		s_server_done = true;
	} else {
		assert(!s_client_done, "Client endpoint completed twice in scenario: " ~ s_scenario);
		s_client_done = true;
	}

	if (!s_server_done || !s_client_done) return;

	s_finished = true;
	destroy(s_accepted);
	destroy(s_client);
	destroy(s_listen); // removes the accept waiter, so the event loop can exit
	eventDriver.timers.stop(s_watchdog);
}

// Runs the event loop of the current scenario until all operations completed.
void runScenario()
{
	ExitReason er;
	do er = eventDriver.core.processEvents(Duration.max);
	while (er == ExitReason.idle);
	assert(er == ExitReason.outOfWaiters, "Unexpected exit reason in scenario: " ~ s_scenario);
	assert(s_finished, "Incomplete scenario: " ~ s_scenario);
}


immutable ubyte[4] data_a = [1, 2, 3, 4];
immutable ubyte[4] data_b = [5, 6, 7, 8];

StreamListenSocket s_listen;
StreamSocket s_client, s_accepted;
ubyte[16] s_srv_buf, s_cli_buf;
TimerID s_watchdog;
InternetAddress s_baddr;
string s_scenario;
bool s_server_done, s_client_done, s_finished;
