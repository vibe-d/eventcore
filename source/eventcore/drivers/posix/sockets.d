module eventcore.drivers.posix.sockets;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.corefoundation : isAppleOS;
import eventcore.internal.utils;

import std.algorithm.comparison : among, min, max;
import std.socket : Address, AddressFamily, InternetAddress, Internet6Address, UnknownAddress;

import core.time: Duration;

version (Posix) {
	import std.socket : UnixAddress;
	import core.sys.posix.netdb : AI_ADDRCONFIG, AI_V4MAPPED, addrinfo, freeaddrinfo, getaddrinfo;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.sys.un;
	import core.sys.posix.unistd : close, read, write;
	import core.stdc.errno;
	import core.sys.posix.fcntl;
	import core.sys.posix.sys.socket;

	version (linux) enum SO_REUSEPORT = 15;
	else enum SO_REUSEPORT = 0x200;

	version (linux) {
		static if (!is(typeof(IP_TRANSPARENT)))
			enum IP_TRANSPARENT = 19;
	}

	static if (!is(typeof(O_CLOEXEC)))
	{
		version (linux) enum O_CLOEXEC = 0x80000;
		else version (FreeBSD) enum O_CLOEXEC = 0x100000;
		else version (Solaris) enum O_CLOEXEC = 0x800000;
		else version (DragonFlyBSD) enum O_CLOEXEC = 0x0020000;
		else version (NetBSD) enum O_CLOEXEC = 0x400000;
		else version (OpenBSD) enum O_CLOEXEC = 0x10000;
		else static if (isAppleOS) enum O_CLOEXEC = 0x1000000;
	}
}
version (linux) {
	extern (C) int accept4(int sockfd, sockaddr *addr, socklen_t *addrlen, int flags) nothrow @nogc;
	static if (!is(typeof(SOCK_NONBLOCK)))
		enum SOCK_NONBLOCK = 0x800;
	static if (!is(typeof(SOCK_CLOEXEC)))
		enum SOCK_CLOEXEC = 0x80000;

    import core.sys.linux.netinet.in_ : IP_ADD_MEMBERSHIP, IP_MULTICAST_LOOP;

	// Linux-specific TCP options
	// https://github.com/torvalds/linux/blob/master/include/uapi/linux/tcp.h#L95
	// Some day we should siply import core.sys.linux.netinet.tcp;
	static if (!is(typeof(SOL_TCP)))
		enum SOL_TCP = 6;
	static if (!is(typeof(TCP_KEEPIDLE)))
		enum TCP_KEEPIDLE = 4;
	static if (!is(typeof(TCP_KEEPINTVL)))
		enum TCP_KEEPINTVL = 5;
	static if (!is(typeof(TCP_KEEPCNT)))
		enum TCP_KEEPCNT = 6;
	static if (!is(typeof(TCP_USER_TIMEOUT)))
		enum TCP_USER_TIMEOUT = 18;
}
static if (isAppleOS) {
    import core.sys.darwin.netinet.in_ : IP_ADD_MEMBERSHIP, IP_MULTICAST_LOOP;
	static if (!is(typeof(ESHUTDOWN))) enum ESHUTDOWN = 58;
}
version (FreeBSD) {
    import core.sys.freebsd.netinet.in_ : IP_ADD_MEMBERSHIP, IP_MULTICAST_LOOP;
}
version (DragonFlyBSD) {
	import core.sys.dragonflybsd.netinet.in_ : IP_ADD_MEMBERSHIP, IP_MULTICAST_LOOP;
}
version (Solaris) {
	enum IP_ADD_MEMBERSHIP = 0x13;
	enum IP_MULTICAST_LOOP = 0x12;
}
version (Windows) {
	import core.sys.windows.windows;
	import core.sys.windows.winsock2;
	alias sockaddr_storage = SOCKADDR_STORAGE;

	alias EAGAIN = WSAEWOULDBLOCK;
	alias ECONNREFUSED = WSAECONNREFUSED;
	alias EPIPE = WSAECONNABORTED;
	alias ECONNRESET = WSAECONNRESET;
	alias ENETRESET = WSAENETRESET;
	alias ENOTCONN = WSAENOTCONN;
	alias ETIMEDOUT = WSAETIMEDOUT;
	alias ESHUTDOWN = WSAESHUTDOWN;

	enum SHUT_RDWR = SD_BOTH;
	enum SHUT_RD = SD_RECEIVE;
	enum SHUT_WR = SD_SEND;

	extern (C) int read(int fd, void *buffer, uint count) nothrow;
	extern (C) int write(int fd, const(void) *buffer, uint count) nothrow;
	extern (C) int close(int fd) nothrow @safe;
}

version (Android) {
	static if (!is(typeof(MSG_NOSIGNAL)))
		enum MSG_NOSIGNAL = 0x4000;
}

version (Posix) {
	static if (isAppleOS) {
		enum SEND_FLAGS = 0;
	} else {
		enum SEND_FLAGS = MSG_NOSIGNAL;
	}
} else {
	enum SEND_FLAGS = 0;
}


final class PosixEventDriverSockets(Loop : PosixEventLoop) : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override StreamSocketFD connectStream(scope Address address, scope Address bind_address, ConnectCallback on_connect)
	{
		assert(on_connect !is null);

		// @trusted to escape DIP1000's `scope` check
		auto sockfd = () @trusted { return createSocket(address.addressFamily, SOCK_STREAM); }();
		if (sockfd == -1) {
			on_connect(StreamSocketFD.invalid, ConnectStatus.socketCreateFailure);
			return StreamSocketFD.invalid;
		}

		int bret;
		if (bind_address !is null)
			() @trusted { bret = bind(sockfd, bind_address.name, bind_address.nameLen); } ();

		if (bret != 0) {
			closeSocket(sockfd);
			on_connect(StreamSocketFD.invalid, ConnectStatus.bindFailure);
			return StreamSocketFD.invalid;
		}

		auto sock = m_loop.initFD!StreamSocketFD(sockfd, FDFlags.none, StreamSocketSlot.init);
		m_loop.registerFD(sock, EventMask.read|EventMask.write);

		auto ret = () @trusted { return connect(cast(sock_t)sock, address.name, address.nameLen); } ();
		if (ret == 0) {
			m_loop.m_fds[sock].streamSocket.state = ConnectionState.connected;
			on_connect(sock, ConnectStatus.connected);
		} else {
			auto err = getSocketError();
			if (err.among!(EAGAIN, EINPROGRESS)) {
				with (m_loop.m_fds[sock].streamSocket) {
					connectCallback = on_connect;
					state = ConnectionState.connecting;
				}
				m_loop.setNotifyCallback!(EventType.write)(sock, &onConnect);
			} else {
				m_loop.unregisterFD(sock, EventMask.read|EventMask.write);
				m_loop.clearFD!StreamSocketSlot(sock);
				closeSocket(sockfd);
				on_connect(StreamSocketFD.invalid, determineConnectStatus(err));
				return StreamSocketFD.invalid;
			}
		}

		return sock;
	}

	final override void cancelConnectStream(StreamSocketFD sock)
	{
		if (!isValid(sock)) return;

		with (m_loop.m_fds[sock].streamSocket)
		{
			assert(state == ConnectionState.connecting,
				"Unable to cancel connect on the socket that is not in connecting state");
			state = ConnectionState.closed;
			connectCallback = null;
			m_loop.setNotifyCallback!(EventType.write)(sock, null);
		}
	}

	final override StreamSocketFD adoptStream(int socket)
	{
		if (m_loop.m_fds[socket].common.refCount) // FD already in use?
			return StreamSocketFD.invalid;
		setSocketNonBlocking(socket);
		auto fd = m_loop.initFD!StreamSocketFD(socket, FDFlags.none, StreamSocketSlot.init);
		m_loop.registerFD(fd, EventMask.read|EventMask.write);
		return fd;
	}

	private void onConnect(FD fd)
	{
		auto sock = cast(StreamSocketFD)fd;
		auto l = lockHandle(sock);
		m_loop.setNotifyCallback!(EventType.write)(sock, null);

		ConnectStatus status = ConnectStatus.unknownError;
		int err;
		socklen_t errlen = err.sizeof;
		if (() @trusted { return getsockopt(cast(sock_t)fd, SOL_SOCKET, SO_ERROR, &err, &errlen); } () == 0)
			status = determineConnectStatus(err);

		with (m_loop.m_fds[sock].streamSocket) {
			assert(state == ConnectionState.connecting);

			state = status == ConnectStatus.connected
				? ConnectionState.connected
				: ConnectionState.closed;

			auto cb = connectCallback;
			connectCallback = null;
			if (cb) cb(cast(StreamSocketFD)sock, status);
		}
	}

	private ConnectStatus determineConnectStatus(int sock_err)
	{
		switch (sock_err) {
			default: return ConnectStatus.unknownError;
			case 0: return ConnectStatus.connected;
			case ECONNREFUSED: return ConnectStatus.refused;
		}
	}

	alias listenStream = EventDriverSockets.listenStream;
	final override StreamListenSocketFD listenStream(scope Address address, StreamListenOptions options, AcceptCallback on_accept)
	{
		// @trusted to escape DIP1000's `scope` check
		auto sockfd = () @trusted { return createSocket(address.addressFamily, SOCK_STREAM); }();
		if (sockfd == -1) return StreamListenSocketFD.invalid;

		auto succ = () @trusted {
			int tmp_reuse = 1;
			// FIXME: error handling!
			if (options & StreamListenOptions.reuseAddress) {
				if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0)
					return false;
			}

			version (Windows) {}
			else {
				if ((options & StreamListenOptions.reusePort) && setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &tmp_reuse, tmp_reuse.sizeof) != 0)
					return false;
			}

			version (linux)
			{
				if ((options & StreamListenOptions.ipTransparent) && setsockopt(sockfd, IPPROTO_IP, IP_TRANSPARENT, &tmp_reuse, tmp_reuse.sizeof) != 0)
					return false;
			}

			if (bind(sockfd, address.name, address.nameLen) != 0)
				return false;

			if (listen(sockfd, getBacklogSize()) != 0)
				return false;

			return true;
		} ();

		if (!succ) {
			closeSocket(sockfd);
			return StreamListenSocketFD.invalid;
		}

		auto sock = m_loop.initFD!StreamListenSocketFD(sockfd, FDFlags.none, StreamListenSocketSlot.init);

		if (on_accept) waitForConnections(sock, on_accept);

		return sock;
	}

	final override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		if (!isValid(sock)) return;

		m_loop.registerFD(sock, EventMask.read, false);
		m_loop.m_fds[sock].streamListen.acceptCallback = on_accept;
		m_loop.setNotifyCallback!(EventType.read)(sock, &onAccept);
		onAccept(sock);
	}

	private void onAccept(FD listenfd)
	{
		sock_t sockfd;
		sockaddr_storage addr;
		socklen_t addr_len = addr.sizeof;
		version (linux) {
			() @trusted { sockfd = accept4(cast(sock_t)listenfd, () @trusted { return cast(sockaddr*)&addr; } (), &addr_len, SOCK_NONBLOCK | SOCK_CLOEXEC); } ();
			if (sockfd == -1) return;
		} else {
			() @trusted { sockfd = accept(cast(sock_t)listenfd, () @trusted { return cast(sockaddr*)&addr; } (), &addr_len); } ();
			if (sockfd == -1) return;
			setSocketNonBlocking(sockfd, true);
		}
		auto fd = m_loop.initFD!StreamSocketFD(sockfd, FDFlags.none, StreamSocketSlot.init);
		m_loop.m_fds[fd].streamSocket.state = ConnectionState.connected;
		m_loop.registerFD(fd, EventMask.read|EventMask.write);
		//print("accept %d", sockfd);
		scope RefAddress addrc = new RefAddress(() @trusted { return cast(sockaddr*)&addr; } (), addr_len);
		m_loop.m_fds[listenfd].streamListen.acceptCallback(cast(StreamListenSocketFD)listenfd, fd, addrc);
	}

	ConnectionState getConnectionState(StreamSocketFD sock)
	{
		if (!isValid(sock)) return ConnectionState.closed;
		return m_loop.m_fds[sock].streamSocket.state;
	}

	final override bool getLocalAddress(SocketFD sock, scope RefAddress dst)
	{
		if (!isValid(sock)) return false;

		socklen_t addr_len = dst.nameLen;
		if (() @trusted { return getsockname(cast(sock_t)sock, dst.name, &addr_len); } () != 0)
			return false;
		dst.cap(addr_len);
		return true;
	}

	final override bool getRemoteAddress(SocketFD sock, scope RefAddress dst)
	{
		if (!isValid(sock)) return false;

		socklen_t addr_len = dst.nameLen;
		if (() @trusted { return getpeername(cast(sock_t)sock, dst.name, &addr_len); } () != 0)
			return false;
		dst.cap(addr_len);
		return true;
	}

	final override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		if (!isValid(socket)) return;

		int opt = enable;
		() @trusted { setsockopt(cast(sock_t)socket, IPPROTO_TCP, TCP_NODELAY, cast(char*)&opt, opt.sizeof); } ();
	}

	override void setKeepAlive(StreamSocketFD socket, bool enable) @trusted
	{
		if (!isValid(socket)) return;

		int opt = enable;
		int err = setsockopt(cast(sock_t)socket, SOL_SOCKET, SO_KEEPALIVE, &opt, int.sizeof);
		if (err != 0)
			print("sock error in setKeepAlive: %s", getSocketError);
	}

	override void setKeepAliveParams(StreamSocketFD socket, Duration idle, Duration interval, int probeCount) @trusted
	{
		if (!isValid(socket)) return;

		// dunnno about BSD\OSX, maybe someone should fix it for them later
		version (linux) {
			setKeepAlive(socket, true);
			int int_opt = cast(int) idle.total!"seconds"();
			int err = setsockopt(cast(sock_t)socket, SOL_TCP, TCP_KEEPIDLE, &int_opt, int.sizeof);
			if (err != 0) {
				print("sock error on setsockopt TCP_KEEPIDLE: %s", getSocketError);
				return;
			}
			int_opt = cast(int) interval.total!"seconds"();
			err = setsockopt(cast(sock_t)socket, SOL_TCP, TCP_KEEPINTVL, &int_opt, int.sizeof);
			if (err != 0) {
				print("sock error on setsockopt TCP_KEEPINTVL: %s", getSocketError);
				return;
			}
			err = setsockopt(cast(sock_t)socket, SOL_TCP, TCP_KEEPCNT, &probeCount, int.sizeof);
			if (err != 0)
				print("sock error on setsockopt TCP_KEEPCNT: %s", getSocketError);
		}
	}

	override void setUserTimeout(StreamSocketFD socket, Duration timeout) @trusted
	{
		if (!isValid(socket)) return;

		version (linux) {
			uint tmsecs = cast(uint) timeout.total!"msecs";
			int err = setsockopt(cast(sock_t)socket, SOL_TCP, TCP_USER_TIMEOUT, &tmsecs, uint.sizeof);
			if (err != 0)
				print("sock error on setsockopt TCP_USER_TIMEOUT %s", getSocketError);
		}
	}

	final override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		if (!isValid(socket)) {
			on_read_finish(socket, IOStatus.invalidHandle, 0);
			return;
		}

		/*if (buffer.length == 0) {
			on_read_finish(socket, IOStatus.ok, 0);
			return;
		}*/

		sizediff_t ret;
		() @trusted { ret = .recv(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err.among!(EAGAIN, EINPROGRESS)) {
				if (mode == IOMode.immediate) {
					on_read_finish(socket, IOStatus.wouldBlock, 0);
					return;
				}
			} else {
				auto st = handleReadError(err, m_loop.m_fds[socket].streamSocket);
				print("sock error %s!", err);
				on_read_finish(socket, st, 0);
				return;
			}
		}

		if (ret == 0 && buffer.length > 0) {
			// treat as if the connection read end was shut down
			handleReadError(ESHUTDOWN, m_loop.m_fds[socket].streamSocket);
			on_read_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret >= 0) {
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_read_finish(socket, IOStatus.ok, ret);
				return;
			}
		}

		// NOTE: since we know that not all data was read from the stream
		//       socket, the next call to recv is guaranteed to return EGAIN
		//       and we can avoid that call.

		with (m_loop.m_fds[socket].streamSocket) {
			readCallback = on_read_finish;
			readMode = mode;
			bytesRead = ret > 0 ? ret : 0;
			readBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketRead);
	}

	override void cancelRead(StreamSocketFD socket)
	{
		if (!isValid(socket)) return;

		assert(m_loop.m_fds[socket].streamSocket.readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		with (m_loop.m_fds[socket].streamSocket) {
			readBuffer = null;
		}
	}

	private void onSocketRead(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			auto l = lockHandle(socket);
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
			assert(m_loop.m_fds[socket].common.refCount > 0);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, slot.bytesRead);
			assert(m_loop.m_fds[socket].common.refCount > 0);
		}

		while (true) {
			sizediff_t ret = 0;
			() @trusted { ret = .recv(cast(sock_t)socket, slot.readBuffer.ptr, min(slot.readBuffer.length, int.max), 0); } ();
			if (ret < 0) {
				auto err = getSocketError();
				if (!err.among!(EAGAIN, EINPROGRESS)) {
					auto st = handleReadError(err, *slot);
					finalize(st);
					return;
				}
			}

			if (ret == 0 && slot.readBuffer.length) {
				// treat as if the connection read end was shut down
				handleReadError(ESHUTDOWN, m_loop.m_fds[socket].streamSocket);
				finalize(IOStatus.disconnected);
				return;
			}

			if (ret > 0 || !slot.readBuffer.length) {
				slot.bytesRead += ret;
				slot.readBuffer = slot.readBuffer[ret .. $];
				if (slot.readMode != IOMode.all || slot.readBuffer.length == 0) {
					finalize(IOStatus.ok);
					return;
				}
			}

			// retry if this was just a partial read, as it could mean that
			// the connection was closed by the remove peer
			if (ret <= 0 || !slot.readBuffer.length) break;
		}
	}

	private static IOStatus handleReadError(int err, ref StreamSocketSlot slot)
	@safe nothrow {
		switch (err) {
			case 0: return IOStatus.ok;
			case EPIPE, ECONNRESET, ENETRESET, ENOTCONN, ETIMEDOUT:
				slot.state = ConnectionState.closed;
				return IOStatus.disconnected;
			case ESHUTDOWN:
				if (slot.state == ConnectionState.activeClose)
					slot.state = ConnectionState.closed;
				else if (slot.state != ConnectionState.closed)
					slot.state = ConnectionState.passiveClose;
				return IOStatus.disconnected;
			default: return IOStatus.error;
		}
	}


	final override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		if (!isValid(socket)) {
			on_write_finish(socket, IOStatus.invalidHandle, 0);
			return;
		}

		if (buffer.length == 0) {
			on_write_finish(socket, IOStatus.ok, 0);
			return;
		}

		sizediff_t ret;
		() @trusted { ret = .send(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), SEND_FLAGS); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (err.among!(EAGAIN, EINPROGRESS)) {
				if (mode == IOMode.immediate) {
					on_write_finish(socket, IOStatus.wouldBlock, 0);
					return;
				}
			} else {
				auto st = handleWriteError(err, m_loop.m_fds[socket].streamSocket);
				on_write_finish(socket, st, 0);
				return;
			}
		}

		size_t bytes_written = 0;

		if (ret >= 0) {
			bytes_written += ret;
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_write_finish(socket, IOStatus.ok, bytes_written);
				return;
			}
		}

		// NOTE: since we know that not all data was writtem to the stream
		//       socket, the next call to send is guaranteed to return EGAIN
		//       and we can avoid that call.

		with (m_loop.m_fds[socket].streamSocket) {
			writeCallback = on_write_finish;
			writeMode = mode;
			bytesWritten = ret >= 0 ? ret : 0;
			writeBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.write)(socket, &onSocketWrite);
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		if (!isValid(socket)) return;

		assert(m_loop.m_fds[socket].streamSocket.writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].streamSocket.writeBuffer = null;
	}

	private void onSocketWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		sizediff_t ret;
		() @trusted { ret = .send(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), SEND_FLAGS); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				auto l = lockHandle(socket);
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				auto st = handleWriteError(err, *slot);
				slot.writeCallback(socket, st, slot.bytesRead);
				return;
			}
		}

		if (ret >= 0) {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];
			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				auto l = lockHandle(socket);
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.ok, slot.bytesWritten);
				return;
			}
		}
	}

	private static IOStatus handleWriteError(int err, ref StreamSocketSlot slot)
	@safe nothrow {
		switch (err) {
			case 0: return IOStatus.ok;
			case EPIPE, ECONNRESET, ENETRESET, ENOTCONN, ETIMEDOUT:
				slot.state = ConnectionState.closed;
				return IOStatus.disconnected;
			case ESHUTDOWN:
				if (slot.state == ConnectionState.passiveClose)
					slot.state = ConnectionState.closed;
				else if (slot.state != ConnectionState.closed)
					slot.state = ConnectionState.activeClose;
				return IOStatus.disconnected;
			default: return IOStatus.error;
		}
	}


	final override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		if (!isValid(socket)) {
			on_data_available(socket, IOStatus.invalidHandle, 0);
			return;
		}

		sizediff_t ret;
		ubyte dummy;
		() @trusted { ret = recv(cast(sock_t)socket, &dummy, 1, MSG_PEEK); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				on_data_available(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_read = 0;

		if (ret == 0) {
			on_data_available(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret > 0) {
			on_data_available(socket, IOStatus.ok, 0);
			return;
		}

		with (m_loop.m_fds[socket].streamSocket) {
			readCallback = on_data_available;
			readMode = IOMode.once;
			bytesRead = 0;
			readBuffer = null;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketDataAvailable);
	}

	private void onSocketDataAvailable(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			auto l = lockHandle(socket);
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, 0);
		}

		sizediff_t ret;
		ubyte tmp;
		() @trusted { ret = recv(cast(sock_t)socket, &tmp, 1, MSG_PEEK); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) finalize(IOStatus.error);
		} else finalize(ret ? IOStatus.ok : IOStatus.disconnected);
	}

	final override void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write)
	{
		if (!isValid(socket)) return;

		auto st = m_loop.m_fds[socket].streamSocket.state;
		() @trusted { .shutdown(cast(sock_t)socket, shut_read ? shut_write ? SHUT_RDWR : SHUT_RD : shut_write ? SHUT_WR : 0); } ();
		if (st == ConnectionState.passiveClose) shut_read = true;
		if (st == ConnectionState.activeClose) shut_write = true;
		m_loop.m_fds[socket].streamSocket.state = shut_read ? shut_write ? ConnectionState.closed : ConnectionState.passiveClose : shut_write ? ConnectionState.activeClose : ConnectionState.connected;
	}

	final override DatagramSocketFD createDatagramSocket(scope Address bind_address,
		scope Address target_address, DatagramCreateOptions options = DatagramCreateOptions.init)
	{
		return createDatagramSocketInternal(bind_address, target_address, options, false);
	}

	package DatagramSocketFD createDatagramSocketInternal(scope Address bind_address,
		scope Address target_address, DatagramCreateOptions options = DatagramCreateOptions.init,
		bool is_internal = true)
	{
		// @trusted to escape DIP1000's `scope` check
		auto sockfd = () @trusted { return createSocket(bind_address.addressFamily, SOCK_DGRAM); }();
		if (sockfd == -1) return DatagramSocketFD.invalid;

		auto optsucc = () @trusted {
			int tmp_reuse = 1;
			// FIXME: error handling!
			if (options & DatagramCreateOptions.reuseAddress) {
				if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0)
					return false;
			}

			version (Windows) {}
			else {
				if ((options & DatagramCreateOptions.reusePort) && setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &tmp_reuse, tmp_reuse.sizeof) != 0)
					return false;
			}

			return true;
		} ();

		if (!optsucc) {
			closeSocket(sockfd);
			return DatagramSocketFD.init;
		}


		if (bind_address && () @trusted { return bind(sockfd, bind_address.name, bind_address.nameLen); } () != 0) {
			closeSocket(sockfd);
			return DatagramSocketFD.init;
		}

		if (target_address) {
			int ret;
			if (target_address is bind_address) {
				// special case of bind_address==target_address: determine the actual bind address
				// in case of a zero port
				sockaddr_storage sa;
				socklen_t addr_len = sa.sizeof;
				if (() @trusted { return getsockname(sockfd, cast(sockaddr*)&sa, &addr_len); } () != 0) {
					closeSocket(sockfd);
					return DatagramSocketFD.init;
				}

				ret = () @trusted { return connect(sockfd, cast(sockaddr*)&sa, addr_len); } ();
			} else ret = () @trusted { return connect(sockfd, target_address.name, target_address.nameLen); } ();

			if (ret != 0) {
				closeSocket(sockfd);
				return DatagramSocketFD.init;
			}
		}

		auto flags = is_internal ? FDFlags.internal : FDFlags.none;
		auto sock = m_loop.initFD!DatagramSocketFD(sockfd, flags, DgramSocketSlot.init);
		m_loop.registerFD(sock, EventMask.read|EventMask.write);
		return sock;
	}

	final override DatagramSocketFD adoptDatagramSocket(int socket)
	{
		return adoptDatagramSocketInternal(socket, false);
	}

	package DatagramSocketFD adoptDatagramSocketInternal(int socket, bool is_internal = true, bool close_on_exec = false)
	@nogc {
		if (m_loop.m_fds[socket].common.refCount) // FD already in use?
			return DatagramSocketFD.init;
		setSocketNonBlocking(socket, close_on_exec);
		auto flags = is_internal ? FDFlags.internal : FDFlags.none;
		auto fd = m_loop.initFD!DatagramSocketFD(socket, flags, DgramSocketSlot.init);
		m_loop.registerFD(fd, EventMask.read|EventMask.write);
		return fd;
	}

	final override void setTargetAddress(DatagramSocketFD socket, scope Address target_address)
	{
		if (!isValid(socket)) return;

		() @trusted { connect(cast(sock_t)socket, target_address.name, target_address.nameLen); } ();
	}

	final override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		if (!isValid(socket)) return false;

		int tmp_broad = enable;
		return () @trusted { return setsockopt(cast(sock_t)socket, SOL_SOCKET, SO_BROADCAST, &tmp_broad, tmp_broad.sizeof); } () == 0;
	}

	final override bool joinMulticastGroup(DatagramSocketFD socket, scope Address multicast_address, uint interface_index = 0)
	{
		if (!isValid(socket)) return false;

		// @trusted to escape DIP1000's `scope` check
		switch (() @trusted { return multicast_address.addressFamily; }()) {
			default: assert(false, "Multicast only supported for IPv4/IPv6 sockets.");
			case AddressFamily.INET:
				struct ip_mreq {
					in_addr imr_multiaddr;   /* IP multicast address of group */
					in_addr imr_interface;   /* local IP address of interface */
				}
				auto addr = () @trusted { return cast(sockaddr_in*)multicast_address.name; } ();
				ip_mreq mreq;
				mreq.imr_multiaddr = addr.sin_addr;
				mreq.imr_interface.s_addr = htonl(interface_index);
				return () @trusted { return setsockopt(cast(sock_t)socket, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, ip_mreq.sizeof); } () == 0;
			case AddressFamily.INET6:
				version (Windows) {
					struct ipv6_mreq {
						in6_addr ipv6mr_multiaddr;
						uint ipv6mr_interface;
					}
				}
				auto addr = () @trusted { return cast(sockaddr_in6*)multicast_address.name; } ();
				ipv6_mreq mreq;
				mreq.ipv6mr_multiaddr = addr.sin6_addr;

				version (Android) {
					// ipv6mr_interface is defined as ipv6mr_ifindex on android
					mreq.ipv6mr_ifindex = htonl(interface_index);
				} else {
					mreq.ipv6mr_interface = htonl(interface_index);
				}
				return () @trusted { return setsockopt(cast(sock_t)socket, IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, ipv6_mreq.sizeof); } () == 0;
		}
	}

	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	@safe {
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		if (!isValid(socket)) {
			RefAddress addr;
			on_receive_finish(socket, IOStatus.invalidHandle, 0, addr);
			return;
		}

		sizediff_t ret;
		sockaddr_storage src_addr;
		socklen_t src_addr_len = src_addr.sizeof;
		() @trusted { ret = .recvfrom(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0, cast(sockaddr*)&src_addr, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				print("sock error %s for %s!", err, socket);
				on_receive_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_receive_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_loop.m_fds[socket].datagramSocket) {
					readCallback = on_receive_finish;
					readMode = mode;
					bytesRead = 0;
					readBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.read)(socket, &onDgramRead);
			}
			return;
		}

		scope src_addrc = new RefAddress(() @trusted { return cast(sockaddr*)&src_addr; } (), src_addr_len);
		if (ret == 0) {
			on_receive_finish(socket, IOStatus.disconnected, 0, src_addrc);
		} else {
			on_receive_finish(socket, IOStatus.ok, ret, src_addrc);
		}
	}

	package void receiveNoGC(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, void delegate(DatagramSocketFD, IOStatus, size_t, scope RefAddress) @safe nothrow @nogc on_receive_finish)
	@trusted @nogc {
		// FIXME: push @nogc further down the call chain instead of
		//        performing this ugly workaround
		static struct S {
			PosixEventDriverSockets this_;
			DatagramSocketFD socket;
			ubyte[] buffer;
			IOMode mode;
			void delegate(DatagramSocketFD, IOStatus, size_t, scope RefAddress) @safe nothrow @nogc on_receive_finish;
			void doit() { this_.receive(socket, buffer, mode, on_receive_finish); }

		}
		scope s = S(this, socket, buffer, mode, on_receive_finish);
		(cast(void delegate() @safe nothrow @nogc)&s.doit)();
	}

	void cancelReceive(DatagramSocketFD socket)
	@nogc {
		if (!isValid(socket)) return;

		auto slot = () @trusted { return &m_loop.m_fds[socket].datagramSocket(); } ();
		if (slot.readCallback is null) return;

		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		slot.readCallback = null;
		slot.readBuffer = null;
	}

	private void onDgramRead(FD fd)
	@safe {
		auto slot = () @trusted { return &m_loop.m_fds[fd].datagramSocket(); } ();
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		sockaddr_storage src_addr;
		socklen_t src_addr_len = src_addr.sizeof;
		() @trusted { ret = .recvfrom(cast(sock_t)socket, slot.readBuffer.ptr, min(slot.readBuffer.length, int.max), 0, cast(sockaddr*)&src_addr, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				auto l = lockHandle(socket);
				m_loop.setNotifyCallback!(EventType.read)(socket, null);
				slot.readCallback(socket, IOStatus.error, 0, null);
				return;
			}
		}

		auto l = lockHandle(socket);
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		scope src_addrc = new RefAddress(() @trusted { return cast(sockaddr*)&src_addr; } (), src_addr.sizeof);
		auto cb = () @trusted { return cast(DatagramIOCallback)slot.readCallback; } ();
		slot.readCallback = null;
		cb(socket, IOStatus.ok, ret, src_addrc);
	}

	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish)
	{
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		if (!isValid(socket)) {
			RefAddress addr;
			on_send_finish(socket, IOStatus.invalidHandle, 0, addr);
			return;
		}

		sizediff_t ret;
		if (target_address) {
			() @trusted { ret = .sendto(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), SEND_FLAGS, target_address.name, target_address.nameLen); } ();
			m_loop.m_fds[socket].datagramSocket.targetAddr = target_address;
		} else {
			() @trusted { ret = .send(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), SEND_FLAGS); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				print("sock error %s!", err);
				on_send_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_send_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_loop.m_fds[socket].datagramSocket) {
					writeCallback = on_send_finish;
					writeMode = mode;
					bytesWritten = 0;
					writeBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.write)(socket, &onDgramWrite);
			}
			return;
		}

		on_send_finish(socket, IOStatus.ok, ret, null);
	}

	void cancelSend(DatagramSocketFD socket)
	{
		if (!isValid(socket)) return;

		assert(m_loop.m_fds[socket].datagramSocket.writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].datagramSocket.writeBuffer = null;
	}

	private void onDgramWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].datagramSocket(); } ();
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		if (slot.targetAddr) {
			() @trusted { ret = .sendto(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), SEND_FLAGS, slot.targetAddr.name, slot.targetAddr.nameLen); } ();
		} else {
			() @trusted { ret = .send(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), SEND_FLAGS); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				auto l = lockHandle(socket);
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		auto l = lockHandle(socket);
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.ok, ret, null);
	}

	final override bool isValid(SocketFD handle)
	const {
		if (handle.value > m_loop.m_fds.length) return false;
		return m_loop.m_fds[handle.value].common.validationCounter == handle.validationCounter;
	}

	final override void addRef(SocketFD fd)
	{
		if (!isValid(fd)) return;

		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		assert(slot.common.refCount > 0, "Adding reference to unreferenced socket FD.");
		slot.common.refCount++;
	}

	final override bool releaseRef(SocketFD fd)
	@nogc {
		import taggedalgebraic : hasType;

		if (!isValid(fd)) return true;

		auto slot = () @trusted { return &m_loop.m_fds[fd]; } ();
		nogc_assert(slot.common.refCount > 0, "Releasing reference to unreferenced socket FD.");
		// listening sockets have an incremented the reference count because of setNotifyCallback
		int base_refcount = slot.specific.hasType!StreamListenSocketSlot ? 1 : 0;
		if (--slot.common.refCount == base_refcount) {
			m_loop.unregisterFD(fd, EventMask.read|EventMask.write);
			switch (slot.specific.kind) with (slot.specific.Kind) {
				default: assert(false, "File descriptor slot is not a socket.");
				case streamSocket:
					m_loop.clearFD!StreamSocketSlot(fd);
					break;
				case streamListen:
					m_loop.setNotifyCallback!(EventType.read)(fd, null);
					m_loop.clearFD!StreamListenSocketSlot(fd);
					break;
				case datagramSocket:
					m_loop.clearFD!DgramSocketSlot(fd);
					break;
			}
			closeSocket(cast(sock_t)fd);
			return false;
		}
		return true;
	}

	final override bool setOption(DatagramSocketFD socket, DatagramSocketOption option, bool enable)
	{
		if (!isValid(socket)) return false;

		int proto, opt;
		final switch (option) {
			case DatagramSocketOption.broadcast: proto = SOL_SOCKET; opt = SO_BROADCAST; break;
			case DatagramSocketOption.multicastLoopback: proto = IPPROTO_IP; opt = IP_MULTICAST_LOOP; break;
		}
		int tmp = enable;
		return () @trusted { return setsockopt(cast(sock_t)socket, proto, opt, &tmp, tmp.sizeof); } () == 0;
	}

	final override bool setOption(StreamSocketFD socket, StreamSocketOption option, bool enable)
	{
		if (!isValid(socket)) return false;

		int proto, opt;
		final switch (option) {
			case StreamSocketOption.noDelay: proto = IPPROTO_TCP; opt = TCP_NODELAY; break;
			case StreamSocketOption.keepAlive: proto = SOL_SOCKET; opt = SO_KEEPALIVE; break;
		}
		int tmp = enable;
		return () @trusted { return setsockopt(cast(sock_t)socket, proto, opt, &tmp, tmp.sizeof); } () == 0;
	}

	final protected override void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	final protected override void* rawUserData(StreamListenSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	final protected override void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy)
	@system {
		if (!isValid(descriptor)) return null;
		return m_loop.rawUserDataImpl(descriptor, size, initialize, destroy);
	}

	private sock_t createSocket(AddressFamily family, int type)
	{
		sock_t sock;
		version (linux) {
			() @trusted { sock = socket(family, type | SOCK_NONBLOCK | SOCK_CLOEXEC, 0); } ();
			if (sock == -1) return -1;
		} else {
			() @trusted { sock = socket(family, type, 0); } ();
			if (sock == -1) return -1;
			setSocketNonBlocking(sock, true);

			// Prevent SIGPIPE on failed send
			static if (isAppleOS) {
				int val = 1;
				() @trusted { setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &val, val.sizeof); } ();
			}
		}
		return sock;
	}

	// keeps a scoped reference to a handle to avoid it getting destroyed
	private auto lockHandle(H)(H handle)
	{
		addRef(handle);
		static struct R {
			PosixEventDriverSockets drv;
			H handle;
			@disable this(this);
			~this() { drv.releaseRef(handle); }
		}
		return R(this, handle);
	}
}

package struct StreamSocketSlot {
	alias Handle = StreamSocketFD;

	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	IOCallback readCallback; // FIXME: this type only works for stream sockets

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	IOCallback writeCallback; // FIXME: this type only works for stream sockets

	ConnectCallback connectCallback;
	ConnectionState state;
}

package struct StreamListenSocketSlot {
	alias Handle = StreamListenSocketFD;

	AcceptCallback acceptCallback;
}

package struct DgramSocketSlot {
	alias Handle = DatagramSocketFD;
	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	DatagramIOCallback readCallback; // FIXME: this type only works for stream sockets

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	DatagramIOCallback writeCallback; // FIXME: this type only works for stream sockets
	Address targetAddr;
}

private void closeSocket(sock_t sockfd)
@nogc nothrow {
	version (Windows) () @trusted { closesocket(sockfd); } ();
	else close(sockfd);
}

private void setSocketNonBlocking(SocketFD.BaseType sockfd, bool close_on_exec = false)
@nogc nothrow {
	version (Windows) {
		uint enable = 1;
		() @trusted { ioctlsocket(sockfd, FIONBIO, &enable); } ();
	} else {
		int f = O_NONBLOCK;
		if (close_on_exec) f |= O_CLOEXEC;
		() @trusted { fcntl(cast(int)sockfd, F_SETFL, f); } ();
	}
}

private int getSocketError()
@nogc nothrow {
	version (Windows) return WSAGetLastError();
	else return errno;
}

private int getBacklogSize()
@trusted @nogc nothrow {
	int backlog = 128;
	version (linux)
	{
		import core.stdc.stdio : fclose, fopen, fscanf;
		auto somaxconn = fopen("/proc/sys/net/core/somaxconn", "re");
		if (somaxconn)
		{
			int tmp;
			if (fscanf(somaxconn, "%d", &tmp) == 1)
				backlog = tmp;
			fclose(somaxconn);
		}
	}
	return backlog;
}
