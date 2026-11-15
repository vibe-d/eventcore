module eventcore.drivers.libasync.sockets;

version (EventcoreLibasyncDriver):

import eventcore.driver;
import eventcore.drivers.libasync.core;
version (LibasyncUseCircBuf)
	import eventcore.drivers.libasync.circ_unread;
else {
	import eventcore.drivers.libasync.unread_ring;
	static assert(__traits(hasMember, UnreadRing, "drainRecv"));
	static assert(__traits(hasMember, UnreadRing, "onTCPUnread"));
}
import eventcore.internal.utils : ChoppedVector, print;
import core.time : Duration;
import libasync : AsyncTCPConnection, AsyncTCPListener, AsyncUDPSocket, TCPEvent, UDPEvent, TCPOption, NetworkAddress;
import libasync.types : Status;
import std.socket : Address, AddressFamily;


final class LibasyncEventDriverSockets : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:

	private {
		enum Kind { none, stream, listen, dgram }

		struct Slot {
			uint refCount;
			uint validation;
			Kind kind;
			ConnectionState state;
			AsyncTCPConnection stream;
			AsyncTCPListener listen;
			AsyncUDPSocket dgram;
			NetworkAddress peer;
			NetworkAddress local;
			NetworkAddress target;
			ConnHook hook;

			ConnectCallback onConnect;
			AcceptCallback onAccept;
			IOCallback onRead;
			IOCallback onWrite;
			DatagramIOCallback onReceive;
			DatagramIOCallback onSend;

			ubyte[] readBuf;
			const(ubyte)[] writeBuf;
			ubyte[] writeOwned;
			size_t readN, writeN;
			IOMode readMode, writeMode;
			bool readPending, writePending, waitData;
			bool readCancelled, writeCancelled;
			bool sockMaybeMore;
			bool closing;
			version (LibasyncUseCircBuf) CircUnread unread;
			else UnreadRing unread;

			DataInitializer userDataDestructor;
			ubyte[16 * size_t.sizeof] userData;
		}

		final class ConnHook {
			LibasyncEventDriverSockets owner;
			size_t idx;
			void onTCP(TCPEvent ev) { owner.onTCP(idx, ev); }
			void onUDP(UDPEvent ev) { owner.onUDP(idx, ev); }
			void delegate(TCPEvent) acceptHook(AsyncTCPConnection conn)
			{
				auto nfd = owner.adoptInbound(conn);
				if (nfd == StreamSocketFD.invalid)
					return (TCPEvent) {};
				auto ls = owner.m_slots[idx].onAccept;
				if (ls) {
					sockaddr_storage ss;
					auto na = owner.m_slots[cast(size_t)nfd].peer;
					copyAddr(na, ss);
					scope ra = () @trusted {
						return new RefAddress(cast(sockaddr*)&ss, na.sockAddrLen);
					} ();
					ls(StreamListenSocketFD(idx, owner.m_slots[idx].validation), nfd, ra);
				}
				return &owner.m_slots[cast(size_t)nfd].hook.onTCP;
			}
		}

		version (Posix) import core.sys.posix.sys.socket : sockaddr, sockaddr_storage, socklen_t;
		version (Windows) import core.sys.windows.winsock2 : sockaddr, sockaddr_storage, socklen_t;

		LibasyncEventDriverCore m_core;
		ChoppedVector!Slot m_slots;
		size_t[] m_free;
		size_t m_live;
		// Leftover take completes the next `read()` from inside its
		// callback. A one-slot queue overwrote a second completion
		// (batch 32 KiB POST after other JSON workloads). FIFO.
		bool m_inReadCb;
		enum size_t ReadQ = 64;
		IOCallback[ReadQ] m_qCb;
		StreamSocketFD[ReadQ] m_qFd;
		IOStatus[ReadQ] m_qSt;
		size_t[ReadQ] m_qN;
		size_t m_qHead, m_qLen;
		// Same nested-callback trap as reads: completeWrite must not
		// run the HTTP fiber (which kill()s the fd) inside pumpWrite.
		bool m_inWriteCb;
		IOCallback[ReadQ] m_wqCb;
		StreamSocketFD[ReadQ] m_wqFd;
		IOStatus[ReadQ] m_wqSt;
		size_t[ReadQ] m_wqN;
		size_t m_wqHead, m_wqLen;
	}

	this(LibasyncEventDriverCore core)
	{
		m_core = core;
	}

	package @property bool hasLeakedHandles()
	{
		if (!m_live) return false;
		print("Warning: %s socket handles leaked at libasync driver shutdown.", m_live);
		return true;
	}

	void dispose()
	{
		foreach (i; 0 .. m_slots.length)
			if (m_slots[i].refCount)
				closeSlot(i);
	}

	override StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect)
	@trusted {
		if (peer_address is null) {
			if (on_connect) on_connect(StreamSocketFD.invalid, ConnectStatus.addressNotAvailable);
			return StreamSocketFD.invalid;
		}

		auto conn = new AsyncTCPConnection(m_core.evloop);
		conn.peer = NetworkAddress(cast()peer_address);
		if (bind_address !is null) {
			// libasync connects from an ephemeral local port; an explicit bind
			// address other than any/0 is not applied here.
		}

		auto fd = allocStream(conn, ConnectionState.connecting);
		if (fd == StreamSocketFD.invalid) {
			if (on_connect) on_connect(StreamSocketFD.invalid, ConnectStatus.socketCreateFailure);
			return StreamSocketFD.invalid;
		}

		auto s = &m_slots[cast(size_t)fd];
		s.onConnect = on_connect;
		s.peer = conn.peer;
		m_core.addWaiter();

		if (!conn.run(&s.hook.onTCP)) {
			m_core.removeWaiter();
			s.onConnect = null;
			closeSlot(cast(size_t)fd);
			if (on_connect) on_connect(StreamSocketFD.invalid, ConnectStatus.socketCreateFailure);
			return StreamSocketFD.invalid;
		}
		return fd;
	}

	override void cancelConnectStream(StreamSocketFD sock)
	{
		if (!isValid(sock)) return;
		auto s = &m_slots[cast(size_t)sock];
		if (s.state != ConnectionState.connecting) return;
		if (s.onConnect) {
			s.onConnect = null;
			m_core.removeWaiter();
		}
		closeSlot(cast(size_t)sock);
	}

	override StreamSocketFD adoptStream(int socket)
	@trusted {
		auto conn = new AsyncTCPConnection(m_core.evloop, socket);
		auto fd = allocStream(conn, ConnectionState.connected);
		if (fd == StreamSocketFD.invalid) return fd;
		if (!conn.run(&m_slots[cast(size_t)fd].hook.onTCP)) {
			closeSlot(cast(size_t)fd);
			return StreamSocketFD.invalid;
		}
		return fd;
	}

	alias listenStream = EventDriverSockets.listenStream;
	override StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept)
	@trusted {
		if (bind_address is null) return StreamListenSocketFD.invalid;

		auto lst = new AsyncTCPListener(m_core.evloop);
		lst.local = NetworkAddress(cast()bind_address);
		auto fd = allocListen(lst);
		if (fd == StreamListenSocketFD.invalid) return fd;
		auto s = &m_slots[cast(size_t)fd];
		s.onAccept = on_accept;

		if (!lst.run(&s.hook.acceptHook)) {
			closeSlot(cast(size_t)fd);
			return StreamListenSocketFD.invalid;
		}
		if (options & StreamListenOptions.reusePort)
			trySetOption(lst.socket, TCPOption.REUSEPORT, true);
		if (options & StreamListenOptions.reuseAddress)
			trySetOption(lst.socket, TCPOption.REUSEADDR, true);
		if (on_accept) m_core.addWaiter();
		return fd;
	}

	override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		if (!isValid(sock)) return;
		auto s = &m_slots[cast(size_t)sock];
		if (!s.onAccept && on_accept) m_core.addWaiter();
		s.onAccept = on_accept;
	}

	override ConnectionState getConnectionState(StreamSocketFD sock)
	{
		if (!isValid(sock)) return ConnectionState.closed;
		return m_slots[cast(size_t)sock].state;
	}

	override bool getLocalAddress(SocketFD sock, scope RefAddress dst)
	{
		if (!isValid(sock) || dst is null) return false;
		auto s = &m_slots[cast(size_t)sock];
		NetworkAddress na;
		if (s.kind == Kind.stream && tcpConnected(s.stream))
			na = () @trusted { return s.stream.local; } ();
		else if (s.kind == Kind.listen && s.listen)
			na = () @trusted { return s.listen.local; } ();
		else if (s.kind == Kind.dgram && s.dgram)
			na = () @trusted { return s.dgram.local; } ();
		else na = s.local;
		size_t osfd = 0;
		if (s.kind == Kind.stream && s.stream) osfd = () @trusted { return cast(size_t) s.stream.socket; } ();
		else if (s.kind == Kind.listen && s.listen) osfd = () @trusted { return cast(size_t) s.listen.socket; } ();
		else if (s.kind == Kind.dgram && s.dgram) osfd = () @trusted { return cast(size_t) s.dgram.socket; } ();
		if (na.family == 0 && osfd)
			na = osSockName(osfd, false);
		if (na.family == 0) return false;
		() @trusted { dst.set(na.sockAddr, na.sockAddrLen); } ();
		return true;
	}

	override bool getRemoteAddress(SocketFD sock, scope RefAddress dst)
	{
		if (!isValid(sock) || dst is null) return false;
		auto s = &m_slots[cast(size_t)sock];
		auto na = s.peer;
		if (na.family == 0 && s.stream && tcpConnected(s.stream))
			na = () @trusted { return s.stream.peer; } ();
		size_t osfd = s.stream ? () @trusted { return cast(size_t) s.stream.socket; } () : 0;
		if (na.family == 0 && osfd)
			na = osSockName(osfd, true);
		if (na.family == 0) return false;
		() @trusted { dst.set(na.sockAddr, na.sockAddrLen); } ();
		return true;
	}

	private static NetworkAddress osSockName(size_t osfd, bool peer)
	@trusted {
		import std.socket : sockaddr, sockaddr_storage, socklen_t;
		version (Windows) {
			import core.sys.windows.winsock2 : SOCKET, getpeername, getsockname;
			alias sock_t = SOCKET;
		} else {
			import core.sys.posix.sys.socket : getpeername, getsockname;
			alias sock_t = int;
		}
		sockaddr_storage ss;
		socklen_t len = ss.sizeof;
		int err = peer
			? getpeername(cast(sock_t) osfd, cast(sockaddr*)&ss, &len)
			: getsockname(cast(sock_t) osfd, cast(sockaddr*)&ss, &len);
		if (err != 0) return NetworkAddress.init;
		return NetworkAddress(cast(sockaddr*)&ss, len);
	}

	override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (s.stream)
			() @trusted { s.stream.noDelay = enable; } ();
	}

	override void setKeepAlive(StreamSocketFD socket, bool enable)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (tcpConnected(s.stream))
			() @trusted { s.stream.setOption(TCPOption.KEEPALIVE_ENABLE, enable); } ();
	}

	override void setKeepAliveParams(StreamSocketFD socket, Duration idle, Duration interval, int probeCount = 5)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (!tcpConnected(s.stream)) return;
		() @trusted {
			s.stream.setOption(TCPOption.KEEPALIVE_ENABLE, true);
			s.stream.setOption(TCPOption.KEEPALIVE_DEFER, idle);
			s.stream.setOption(TCPOption.KEEPALIVE_INTERVAL, interval);
		} ();
	}

	override void setUserTimeout(StreamSocketFD socket, Duration timeout)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (tcpConnected(s.stream))
			() @trusted { s.stream.setOption(TCPOption.TIMEOUT_SEND, timeout); } ();
	}

	override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		if (!isValid(socket)) {
			if (on_read_finish) on_read_finish(socket, IOStatus.invalidHandle, 0);
			return;
		}
		auto s = &m_slots[cast(size_t)socket];
		if (s.readPending) return;
		s.readBuf = buffer;
		s.readN = 0;
		s.readMode = mode;
		s.onRead = on_read_finish;
		s.readPending = true;
		s.readCancelled = false;
		s.waitData = buffer.length == 0 && mode != IOMode.immediate;
		m_core.addWaiter();
		serviceRead(cast(size_t)socket);
	}

	override void cancelRead(StreamSocketFD socket)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (!s.readPending) return;
		s.readPending = false;
		s.readCancelled = true;
		s.onRead = null;
		s.waitData = false;
		m_core.removeWaiter();
	}

	override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		if (!isValid(socket)) {
			if (on_write_finish) on_write_finish(socket, IOStatus.invalidHandle, 0);
			return;
		}
		auto s = &m_slots[cast(size_t)socket];
		if (s.writePending) {
			if (on_write_finish) on_write_finish(socket, IOStatus.error, 0);
			return;
		}
		// Own the payload: TLS records are stack Vectors, and a peer
		// RST/reconnect must not leave pumpWrite holding a dangling slice.
		if (buffer.length) {
			s.writeOwned.length = buffer.length;
			s.writeOwned[] = buffer[];
			s.writeBuf = s.writeOwned;
		} else {
			s.writeOwned.length = 0;
			s.writeBuf = null;
		}
		s.writeN = 0;
		s.writeMode = mode;
		s.onWrite = on_write_finish;
		s.writePending = true;
		s.writeCancelled = false;
		m_core.addWaiter();
		pumpWrite(cast(size_t)socket, false);
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (!s.writePending) return;
		s.writePending = false;
		s.writeCancelled = true;
		s.onWrite = null;
		m_core.removeWaiter();
	}

	override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		read(socket, null, IOMode.once, on_data_available);
	}

	override void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write)
	{
		if (!isValid(socket)) return;
		auto idx = cast(size_t)socket;
		auto s = &m_slots[idx];
		if (s.closing) return;
		if (shut_write && s.state == ConnectionState.passiveClose)
			s.state = ConnectionState.closed;
		else if (shut_write)
			s.state = ConnectionState.activeClose;
		else if (shut_read)
			s.state = ConnectionState.passiveClose;
		if (shut_read && shut_write) {
			s.closing = true;
			if (s.writePending) completeWrite(idx, IOStatus.disconnected);
			if (s.readPending) completeRead(idx, IOStatus.disconnected, s.readN);
			auto conn = s.stream;
			// kill() delivers TCPEvent.DESTROY, which nulls s.stream,
			// then ThreadMem.free inbound. Always clear after.
			if (tcpConnected(conn))
				() @trusted { conn.kill(true); }();
			s.stream = null;
			return;
		}
		if (!tcpConnected(s.stream)) return;
		// Half-close through libasync so kqueue drops only the shut
		// filter (EV_EOF on EVFILT_WRITE is local SHUT_WR, not CLOSE).
		() @trusted { s.stream.shutdown(shut_read, shut_write); }();
	}

	override DatagramSocketFD createDatagramSocket(scope Address bind_address,
		scope Address target_address,
		DatagramCreateOptions options = DatagramCreateOptions.init)
	@trusted {
		if (bind_address is null) return DatagramSocketFD.invalid;
		auto udp = new AsyncUDPSocket(m_core.evloop);
		udp.local = NetworkAddress(cast()bind_address);
		auto fd = allocDgram(udp);
		if (fd == DatagramSocketFD.invalid) return fd;
		auto s = &m_slots[cast(size_t)fd];
		if (target_address)
			s.target = NetworkAddress(cast()target_address);
		if (!udp.run(&s.hook.onUDP)) {
			closeSlot(cast(size_t)fd);
			return DatagramSocketFD.invalid;
		}
		if (options & DatagramCreateOptions.reuseAddress)
			trySetOption(udp.socket, TCPOption.REUSEADDR, true);
		if (options & DatagramCreateOptions.reusePort)
			trySetOption(udp.socket, TCPOption.REUSEPORT, true);
		return fd;
	}

	override DatagramSocketFD adoptDatagramSocket(int socket)
	@trusted {
		auto udp = new AsyncUDPSocket(m_core.evloop, socket);
		auto fd = allocDgram(udp);
		if (fd == DatagramSocketFD.invalid) return fd;
		if (!udp.run(&m_slots[cast(size_t)fd].hook.onUDP)) {
			closeSlot(cast(size_t)fd);
			return DatagramSocketFD.invalid;
		}
		return fd;
	}

	override void setTargetAddress(DatagramSocketFD socket, scope Address target_address)
	{
		if (!isValid(socket) || target_address is null) return;
		m_slots[cast(size_t)socket].target = () @trusted { return NetworkAddress(cast()target_address); } ();
	}

	override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		if (!isValid(socket)) return false;
		auto s = &m_slots[cast(size_t)socket];
		if (!s.dgram) return false;
		return () @trusted { return s.dgram.broadcast(enable); } ();
	}

	override bool joinMulticastGroup(DatagramSocketFD socket, scope Address multicast_address, uint interface_index = 0)
	{
		return false;
	}

	override void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	{
		if (!isValid(socket)) {
			if (on_receive_finish) on_receive_finish(socket, IOStatus.invalidHandle, 0, null);
			return;
		}
		auto s = &m_slots[cast(size_t)socket];
		s.readBuf = buffer;
		s.onReceive = on_receive_finish;
		s.readMode = mode;
		s.readPending = true;
		m_core.addWaiter();
		pumpRecv(cast(size_t)socket, mode == IOMode.immediate);
	}

	override void cancelReceive(DatagramSocketFD socket)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (!s.readPending) return;
		s.readPending = false;
		s.onReceive = null;
		m_core.removeWaiter();
	}

	override void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish)
	{
		if (!isValid(socket)) {
			if (on_send_finish) on_send_finish(socket, IOStatus.invalidHandle, 0, null);
			return;
		}
		auto s = &m_slots[cast(size_t)socket];
		s.writeBuf = buffer;
		s.onSend = on_send_finish;
		s.writePending = true;
		if (target_address)
			s.target = () @trusted { return NetworkAddress(cast()target_address); } ();
		m_core.addWaiter();
		pumpSend(cast(size_t)socket);
	}

	override void cancelSend(DatagramSocketFD socket)
	{
		if (!isValid(socket)) return;
		auto s = &m_slots[cast(size_t)socket];
		if (!s.writePending) return;
		s.writePending = false;
		s.onSend = null;
		m_core.removeWaiter();
	}

	override bool isValid(SocketFD handle)
	const @nogc {
		if (handle == SocketFD.invalid) return false;
		auto v = cast(size_t)handle;
		if (v >= m_slots.length) return false;
		auto s = &m_slots[v];
		return s.refCount > 0 && s.validation == handle.validationCounter && s.kind != Kind.none;
	}

	override void addRef(SocketFD descriptor)
	{
		if (!isValid(descriptor)) return;
		m_slots[cast(size_t)descriptor].refCount++;
	}

	override bool releaseRef(SocketFD descriptor)
	{
		if (!isValid(descriptor)) return true;
		auto s = &m_slots[cast(size_t)descriptor];
		if (--s.refCount) return true;
		closeSlot(cast(size_t)descriptor);
		return false;
	}

	override bool setOption(DatagramSocketFD socket, DatagramSocketOption option, bool enable)
	{
		if (!isValid(socket)) return false;
		if (option == DatagramSocketOption.broadcast)
			return setBroadcast(socket, enable);
		return false;
	}

	override bool setOption(StreamSocketFD socket, StreamSocketOption option, bool enable)
	{
		if (!isValid(socket)) return false;
		final switch (option) {
			case StreamSocketOption.noDelay: setTCPNoDelay(socket, enable); return true;
			case StreamSocketOption.keepAlive: setKeepAlive(socket, enable); return true;
		}
	}

	protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc {
		return userDataImpl(cast(size_t)descriptor, size, initialize, destroy);
	}

	protected override void* rawUserData(StreamListenSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc {
		return userDataImpl(cast(size_t)descriptor, size, initialize, destroy);
	}

	protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc {
		return userDataImpl(cast(size_t)descriptor, size, initialize, destroy);
	}

	package void* userDataFor(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return userDataImpl(cast(size_t)descriptor, size, initialize, destroy);
	}

	package void* userDataFor(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		return userDataImpl(cast(size_t)descriptor, size, initialize, destroy);
	}

	private void* userDataImpl(size_t idx, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system @nogc {
		if (idx >= m_slots.length || !m_slots[idx].refCount) return null;
		auto s = &m_slots[idx];
		assert(s.userDataDestructor is null || s.userDataDestructor is destroy);
		assert(size <= s.userData.length);
		if (!s.userDataDestructor) {
			initialize(s.userData.ptr);
			s.userDataDestructor = destroy;
		}
		return s.userData.ptr;
	}

	private void onTCP(size_t idx, TCPEvent ev)
	{
		if (idx >= m_slots.length || !m_slots[idx].refCount) return;
		auto s = &m_slots[idx];
		if (s.closing && ev != TCPEvent.CLOSE && ev != TCPEvent.ERROR && ev != TCPEvent.DESTROY)
			return;
		final switch (ev) {
			case TCPEvent.CONNECT:
				s.state = ConnectionState.connected;
				if (tcpConnected(s.stream)) {
					s.local = () @trusted { return s.stream.local; } ();
					auto p = () @trusted { return s.stream.peer; } ();
					if (p.family) s.peer = p;
					auto osfd = () @trusted { return cast(size_t) s.stream.socket; } ();
					if (s.peer.family == 0 && osfd)
						s.peer = osSockName(osfd, true);
					if (s.local.family == 0 && osfd)
						s.local = osSockName(osfd, false);
				}
				auto cb = s.onConnect;
				s.onConnect = null;
				if (cb) {
					m_core.removeWaiter();
					cb(StreamSocketFD(idx, s.validation), ConnectStatus.connected);
				}
				break;
			case TCPEvent.READ:
				s.sockMaybeMore = true;
				serviceRead(idx);
				break;
			case TCPEvent.WRITE:
				pumpWrite(idx, true);
				break;
			case TCPEvent.CLOSE:
				s.sockMaybeMore = true;
				fillFromSocket(idx);
				drainTCP(idx);
				if (s.state == ConnectionState.activeClose)
					s.state = ConnectionState.closed;
				else
					s.state = ConnectionState.passiveClose;
				if (s.readPending) pumpRead(idx);
				if (s.readPending || s.writePending || s.onConnect)
					failStream(idx, IOStatus.disconnected, ConnectStatus.unknownError, false);
				break;
			case TCPEvent.ERROR:
				s.state = ConnectionState.closed;
				failStream(idx, IOStatus.error, ConnectStatus.unknownError, false);
				break;
			case TCPEvent.DESTROY:
				// Inbound ThreadMem.free follows this event. Drop every
				// pointer and complete I/O; do not kill() from here.
				s.closing = true;
				if (s.writePending) completeWrite(idx, IOStatus.disconnected);
				if (s.readPending) completeRead(idx, IOStatus.disconnected, s.readN);
				s.stream = null;
				break;
		}
	}

	private void onUDP(size_t idx, UDPEvent ev)
	{
		if (idx >= m_slots.length || !m_slots[idx].refCount) return;
		final switch (ev) {
			case UDPEvent.READ: pumpRecv(idx, false); break;
			case UDPEvent.WRITE: pumpSend(idx); break;
			case UDPEvent.ERROR:
				completeRecv(idx, IOStatus.error, 0, NetworkAddress.init);
				completeSend(idx, IOStatus.error);
				break;
		}
	}

	/// True when the app has a destination slice that can take kernel bytes.
	/// Stock/epoll recvs into that slice and leaves leftover in the socket.
	/// The unread-ring is only for leftover with no waiting user buffer
	/// (pipelined next request, waitForData, ET with no read pending).
	private bool userBufWaiting(size_t idx)
	{
		auto s = &m_slots[idx];
		return s.readPending && !s.waitData && s.readN < s.readBuf.length;
	}

	private void serviceRead(size_t idx)
	{
		auto s = &m_slots[idx];
		pumpRead(idx);
		if (s.readPending && !s.waitData) fillFromSocket(idx);
		if (s.readPending) pumpRead(idx);
		if (!userBufWaiting(idx)) {
			drainTCP(idx);
			if (s.readPending) pumpRead(idx);
			if (!userBufWaiting(idx) && s.sockMaybeMore) drainTCP(idx);
		}
	}

	private void fillFromSocket(size_t idx)
	@trusted {
		auto s = &m_slots[idx];
		if (!s.readPending || s.waitData) return;
		if (!tcpConnected(s.stream)) return;
		int retries;
		while (s.readN < s.readBuf.length) {
			ubyte[] dst = s.readBuf[s.readN .. $];
			auto n = s.stream.recv(dst);
			if (n > 0) {
				s.readN += n;
				// Virtio: a short copy is not an empty kernel. Only
				// EAGAIN (below) clears sockMaybeMore. Leftover is parked
				// in the ring only when no user buffer is waiting.
				s.sockMaybeMore = true;
				retries = 0;
				if (s.readMode == IOMode.once) break;
				if (s.readN == s.readBuf.length) break;
				continue;
			}
			auto st = s.stream.status.code;
			if (st == Status.RETRY && ++retries < 100)
				continue;
			s.sockMaybeMore = false;
			break;
		}
	}

	private void drainTCP(size_t idx)
	@trusted {
		auto s = &m_slots[idx];
		if (!tcpConnected(s.stream)) return;
		// Tight loop: `stream.recv` stays in this function so LDC inlines
		// it. Only called when `!userBufWaiting` — leftover with no app
		// slice (stock-shaped: waiting reads recv into the user buffer).
		if (!s.sockMaybeMore) return;
		if (!s.unread.cap)
			s.unread.reserve(64 * 1024);
		int retries;
		size_t got;
		enum size_t drainCap = 64 * 1024;
		for (;;) {
			if (!s.unread.freeSpace || got >= drainCap)
				break;
			ubyte[] dst = s.unread.peekDst();
			if (!dst.length) {
				s.sockMaybeMore = false;
				break;
			}
			if (dst.length > drainCap - got)
				dst = dst[0 .. drainCap - got];
			auto n = s.stream.recv(dst);
			if (n > 0) {
				s.unread.putN(n);
				got += n;
				retries = 0;
				continue;
			}
			auto st = s.stream.status.code;
			if (st == Status.RETRY && ++retries < 100)
				continue;
			s.sockMaybeMore = false;
			break;
		}
	}

	private void pumpRead(size_t idx)
	{
		auto s = &m_slots[idx];
		if (!s.readPending) return;

		if (s.waitData) {
			if (s.unread.length) completeRead(idx, IOStatus.ok, 0);
			return;
		}

		if (s.readMode == IOMode.immediate && !s.unread.length) {
			completeRead(idx, IOStatus.wouldBlock, 0);
			return;
		}

		if (s.readN < s.readBuf.length && s.unread.length)
			s.readN += s.unread.take(s.readBuf[s.readN .. $]);

		if (s.readN == s.readBuf.length || (s.readN && s.readMode != IOMode.all)
			|| (s.readMode == IOMode.once && s.readN))
			completeRead(idx, IOStatus.ok, s.readN);
		else if (!s.unread.length && (s.state == ConnectionState.passiveClose
				|| s.state == ConnectionState.closed))
			completeRead(idx, IOStatus.disconnected, s.readN);
	}

	private void pumpWrite(size_t idx, bool fromEvent)
	@trusted {
		auto s = &m_slots[idx];
		if (!s.writePending) return;
		auto conn = liveStream(idx);
		if (conn is null) {
			completeWrite(idx, IOStatus.disconnected);
			return;
		}
		if (s.writeN > s.writeBuf.length) {
			completeWrite(idx, IOStatus.error);
			return;
		}
		if (s.writeMode == IOMode.immediate && !fromEvent && s.writeN == 0) {
			// try once
		}

		while (s.writeN < s.writeBuf.length) {
			conn = liveStream(idx);
			if (conn is null) {
				completeWrite(idx, IOStatus.disconnected);
				return;
			}
			auto remain = s.writeBuf[s.writeN .. $];
			auto n = conn.send(remain);
			conn = liveStream(idx);
			if (conn is null) {
				completeWrite(idx, IOStatus.disconnected);
				return;
			}
			auto st = conn.status.code;
			if (st == Status.RETRY)
				continue;
			if (n)
				s.writeN += n;
			if (st == Status.ABORT) {
				completeWrite(idx, IOStatus.error);
				return;
			}
			// Short send or EAGAIN: OS buffer is full. Stock eventcore
			// skips the guaranteed-EAGAIN retry; AsyncTCPConnection.send
			// already set writeBlocked so EPOLLOUT will wake us.
			if (st == Status.ASYNC || n == 0 || n < remain.length) {
				if (s.writeMode == IOMode.immediate)
					completeWrite(idx, s.writeN ? IOStatus.ok : IOStatus.wouldBlock);
				return;
			}
			if (s.writeMode == IOMode.once) break;
		}
		completeWrite(idx, IOStatus.ok);
	}

	private void pumpRecv(size_t idx, bool immediate)
	@trusted {
		auto s = &m_slots[idx];
		if (!s.readPending) return;
		if (!s.dgram) {
			completeRecv(idx, IOStatus.invalidHandle, 0, NetworkAddress.init);
			return;
		}
		ubyte[] buf = s.readBuf;
		NetworkAddress src;
		auto n = s.dgram.recvFrom(buf, src);
		if (n == 0 && immediate) {
			completeRecv(idx, IOStatus.wouldBlock, 0, NetworkAddress.init);
			return;
		}
		if (n == 0 && !immediate) return;
		completeRecv(idx, IOStatus.ok, n, src);
	}

	private void pumpSend(size_t idx)
	@trusted {
		auto s = &m_slots[idx];
		if (!s.writePending) return;
		if (!s.dgram) {
			completeSend(idx, IOStatus.invalidHandle);
			return;
		}
		auto n = s.dgram.sendTo(s.writeBuf, s.target);
		completeSend(idx, n || s.writeBuf.length == 0 ? IOStatus.ok : IOStatus.error);
	}

	private void completeRead(size_t idx, IOStatus st, size_t n)
	{
		auto s = &m_slots[idx];
		if (!s.readPending) return;
		s.readPending = false;
		auto cb = s.onRead;
		s.onRead = null;
		s.waitData = false;
		m_core.removeWaiter();
		if (!cb) return;
		auto fd = StreamSocketFD(idx, s.validation);
		if (m_inReadCb) {
			if (m_qLen < ReadQ) {
				auto t = (m_qHead + m_qLen) % ReadQ;
				m_qCb[t] = cb;
				m_qFd[t] = fd;
				m_qSt[t] = st;
				m_qN[t] = n;
				m_qLen++;
			} else
				cb(fd, st, n);
			return;
		}
		m_inReadCb = true;
		cb(fd, st, n);
		while (m_qLen) {
			auto h = m_qHead;
			auto qcb = m_qCb[h];
			auto qfd = m_qFd[h];
			auto qst = m_qSt[h];
			auto qn = m_qN[h];
			m_qCb[h] = null;
			m_qHead = (h + 1) % ReadQ;
			m_qLen--;
			qcb(qfd, qst, qn);
		}
		m_inReadCb = false;
	}

	private void completeWrite(size_t idx, IOStatus st)
	{
		auto s = &m_slots[idx];
		if (!s.writePending) return;
		s.writePending = false;
		auto cb = s.onWrite;
		auto n = s.writeN;
		s.onWrite = null;
		m_core.removeWaiter();
		if (!cb) return;
		auto fd = StreamSocketFD(idx, s.validation);
		if (m_inWriteCb) {
			if (m_wqLen < ReadQ) {
				auto t = (m_wqHead + m_wqLen) % ReadQ;
				m_wqCb[t] = cb;
				m_wqFd[t] = fd;
				m_wqSt[t] = st;
				m_wqN[t] = n;
				m_wqLen++;
			} else
				cb(fd, st, n);
			return;
		}
		m_inWriteCb = true;
		cb(fd, st, n);
		while (m_wqLen) {
			auto h = m_wqHead;
			auto qcb = m_wqCb[h];
			auto qfd = m_wqFd[h];
			auto qst = m_wqSt[h];
			auto qn = m_wqN[h];
			m_wqCb[h] = null;
			m_wqHead = (h + 1) % ReadQ;
			m_wqLen--;
			qcb(qfd, qst, qn);
		}
		m_inWriteCb = false;
	}

	private void completeRecv(size_t idx, IOStatus st, size_t n, NetworkAddress src)
	@trusted {
		auto s = &m_slots[idx];
		if (!s.readPending) return;
		s.readPending = false;
		auto cb = s.onReceive;
		s.onReceive = null;
		m_core.removeWaiter();
		if (!cb) return;
		if (st == IOStatus.ok) {
			sockaddr_storage ss;
			copyAddr(src, ss);
			scope ra = new RefAddress(cast(sockaddr*)&ss, src.sockAddrLen);
			cb(DatagramSocketFD(idx, s.validation), st, n, ra);
		} else cb(DatagramSocketFD(idx, s.validation), st, n, null);
	}

	private void completeSend(size_t idx, IOStatus st)
	{
		auto s = &m_slots[idx];
		if (!s.writePending) return;
		s.writePending = false;
		auto cb = s.onSend;
		auto n = s.writeBuf.length;
		s.onSend = null;
		m_core.removeWaiter();
		if (cb) cb(DatagramSocketFD(idx, s.validation), st, n, null);
	}

	private void failStream(size_t idx, IOStatus io, ConnectStatus cs, bool mark_closed = true)
	{
		auto s = &m_slots[idx];
		if (mark_closed) s.state = ConnectionState.closed;
		if (s.onConnect) {
			auto cb = s.onConnect;
			s.onConnect = null;
			m_core.removeWaiter();
			cb(StreamSocketFD(idx, s.validation), cs);
		}
		if (s.readPending) completeRead(idx, io, s.readN);
		if (s.writePending) completeWrite(idx, io);
	}

	private StreamSocketFD adoptInbound(AsyncTCPConnection conn)
	{
		auto fd = allocStream(conn, ConnectionState.connected);
		if (fd != StreamSocketFD.invalid && conn) {
			auto s = &m_slots[cast(size_t)fd];
			s.peer = () @trusted { return conn.peer; } ();
			auto osfd = () @trusted { return cast(size_t) conn.socket; } ();
			if (s.peer.family == 0 && osfd)
				s.peer = osSockName(osfd, true);
			if (s.local.family == 0 && osfd)
				s.local = osSockName(osfd, false);
		}
		return fd;
	}

	private StreamSocketFD allocStream(AsyncTCPConnection conn, ConnectionState st)
	{
		auto id = allocSlot(Kind.stream);
		auto s = &m_slots[cast(size_t)id];
		s.stream = conn;
		s.state = st;
		auto idx = cast(size_t)id;
		s.hook = new ConnHook;
		s.hook.owner = this;
		s.hook.idx = idx;
		return StreamSocketFD(cast(size_t)id, s.validation);
	}

	private StreamListenSocketFD allocListen(AsyncTCPListener lst)
	{
		auto id = allocSlot(Kind.listen);
		auto s = &m_slots[cast(size_t)id];
		s.listen = lst;
		s.hook = new ConnHook;
		s.hook.owner = this;
		s.hook.idx = cast(size_t)id;
		return StreamListenSocketFD(cast(size_t)id, s.validation);
	}

	private DatagramSocketFD allocDgram(AsyncUDPSocket udp)
	{
		auto id = allocSlot(Kind.dgram);
		auto s = &m_slots[cast(size_t)id];
		s.dgram = udp;
		s.hook = new ConnHook;
		s.hook.owner = this;
		s.hook.idx = cast(size_t)id;
		return DatagramSocketFD(cast(size_t)id, s.validation);
	}

	private size_t allocSlot(Kind kind)
	{
		size_t idx;
		if (m_free.length) {
			idx = m_free[$ - 1];
			m_free = m_free[0 .. $ - 1];
		} else {
			idx = m_slots.length;
		}
		m_slots[idx] = Slot.init;
		m_slots[idx].refCount = 1;
		m_slots[idx].validation++;
		m_slots[idx].kind = kind;
		m_live++;
		return idx;
	}

	private void closeSlot(size_t idx)
	@trusted {
		if (idx >= m_slots.length) return;
		auto s = &m_slots[idx];
		if (s.onConnect) { s.onConnect = null; m_core.removeWaiter(); }
		if (s.onAccept) { s.onAccept = null; m_core.removeWaiter(); }
		import core.memory : GC;
		// Wake waiters unless we are in a GC sweep (callbacks allocate).
		if (GC.inFinalizer) {
			if (s.readPending) { s.readPending = false; s.onRead = null; s.onReceive = null; m_core.removeWaiter(); }
			if (s.writePending) { s.writePending = false; s.onWrite = null; s.onSend = null; m_core.removeWaiter(); }
		} else {
			if (s.readPending) completeRead(idx, IOStatus.disconnected, s.readN);
			if (s.writePending) completeWrite(idx, IOStatus.disconnected);
		}
		if (tcpConnected(s.stream)) s.stream.kill(true);
		if (s.listen) s.listen.kill();
		if (s.dgram && s.dgram.socket) s.dgram.kill();
		if (s.userDataDestructor)
			s.userDataDestructor(s.userData.ptr);
		s.unread.dispose();
		*s = Slot.init;
		s.validation++;
		// Recycle only outside a GC sweep. BotanTLSStream's dtor can
		// run from ConservativeGC.sweep and `m_free ~= idx` would
		// allocate (InvalidMemoryOperationError).
		if (!GC.inFinalizer)
			m_free ~= idx;
		if (m_live) m_live--;
	}

	private static void copyAddr(ref NetworkAddress na, ref sockaddr_storage ss)
	@trusted {
		import core.stdc.string : memcpy;
		memcpy(&ss, na.sockAddr, na.sockAddrLen);
	}

	private AsyncTCPConnection liveStream(size_t idx)
	@trusted {
		if (idx >= m_slots.length) return null;
		auto s = &m_slots[idx];
		if (s.closing) return null;
		auto c = s.stream;
		if (c is null || !c.isConnected || c.socket == 0) return null;
		return c;
	}

	private static bool tcpConnected(AsyncTCPConnection c) @trusted
	{
		return c !is null && c.isConnected;
	}

	private void trySetOption(size_t fd, TCPOption op, bool v)
	{
		// best-effort; listener options are applied by libasync at bind time
		if (!fd) return;
	}
}
