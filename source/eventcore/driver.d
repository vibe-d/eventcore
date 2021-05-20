/** Definition of the core event driver interface.

	This module contains all declarations necessary for defining and using
	event drivers. Event driver implementations will usually inherit from
	`EventDriver` using a `final` class to avoid virtual function overhead.

	Callback_Behavior:
		All callbacks follow the same rules to enable generic implementation
		of high-level libraries, such as vibe.d. Except for "listen" style
		callbacks, each callback will only ever be called at most once.

		If the operation does not get canceled, the callback will be called
		exactly once. In case it gets manually canceled using the corresponding
		API function, the callback is guaranteed to not be called. However,
		the associated operation might still finish - either before the
		cancellation function returns, or afterwards.
*/
module eventcore.driver;

import core.time : Duration;
import std.process : StdProcessConfig = Config;
import std.socket : Address;
import std.stdint : intptr_t;
import std.typecons : Tuple;
import std.variant : Algebraic;


/** Encapsulates a full event driver.

	This interface provides access to the individual driver features, as well as
	a central `dispose` method that must be called before the driver gets
	destroyed or before the process gets terminated.
*/
interface EventDriver {
@safe: /*@nogc:*/ nothrow:
	/// Core event loop functionality
	@property inout(EventDriverCore) core() inout;
	/// Core event loop functionality
	@property shared(inout(EventDriverCore)) core() shared inout;
	/// Single shot and recurring timers
	@property inout(EventDriverTimers) timers() inout;
	/// Cross-thread events (thread local access)
	@property inout(EventDriverEvents) events() inout;
	/// Cross-thread events (cross-thread access)
	@property shared(inout(EventDriverEvents)) events() shared inout;
	/// UNIX/POSIX signal reception
	@property inout(EventDriverSignals) signals() inout;
	/// Stream and datagram sockets
	@property inout(EventDriverSockets) sockets() inout;
	/// DNS queries
	@property inout(EventDriverDNS) dns() inout;
	/// Local file operations
	@property inout(EventDriverFiles) files() inout;
	/// Directory change watching
	@property inout(EventDriverWatchers) watchers() inout;
	/// Sub-process handling
	@property inout(EventDriverProcesses) processes() inout;
	/// Pipes
	@property inout(EventDriverPipes) pipes() inout;

	/** Releases all resources associated with the driver.

		In case of any left-over referenced handles, this function returns
		`false` and does not free any resources. It may choose to free the
		resources once the last handle gets dereferenced.
	*/
	bool dispose();
}


/** Provides generic event loop control.
*/
interface EventDriverCore {
	/** The number of pending callbacks.

		When this number drops to zero, the event loop can safely be quit. It is
		guaranteed that no callbacks will be made anymore, unless new callbacks
		get registered.
	*/
	size_t waiterCount() @safe nothrow;

	/** Runs the event loop to process a chunk of events.

		This method optionally waits for an event to arrive if none are present
		in the event queue. The function will return after either the specified
		timeout has elapsed, or once the event queue has been fully emptied.

		On implementations that support it, the function will treat
		interruptions by POSIX signals as if an event was received and will
		cause it to return. However, note that it is generally recommended to
		use `EventDriverSignals` instead of raw signal handlers in order to
		avoid their pitfalls as far as possible.

		Params:
			timeout = Maximum amount of time to wait for an event. A duration of
				zero will cause the function to only process pending events. A
				duration of `Duration.max`, if necessary, will wait indefinitely
				until an event arrives.
	*/
	ExitReason processEvents(Duration timeout) @safe nothrow;

	/** Causes `processEvents` to return with `ExitReason.exited` as soon as
		possible.

		A call to `processEvents` that is currently in progress will be notified
		so that it returns immediately. If no call is in progress, the next call
		to `processEvents` will immediately return with `ExitReason.exited`.
	*/
	void exit() @safe nothrow;

	/** Resets the exit flag.

		`processEvents` will automatically reset the exit flag before it returns
		with `ExitReason.exited`. However, if `exit` is called outside of
		`processEvents`, the next call to `processEvents` will return with
		`ExitCode.exited` immediately. This function can be used to avoid this.
	*/
	void clearExitFlag() @safe nothrow;

	/** Executes a callback in the thread owning the driver.
	*/
	void runInOwnerThread(ThreadCallbackGen fun, ref ThreadCallbackGenParams params) shared @safe nothrow;
	/// ditto
	final void runInOwnerThread(ARGS...)(void function(ARGS) @safe nothrow fun, ARGS args) shared
		if (ARGS.length != 1 || !is(ARGS[0] == ThreadCallbackGenParams))
	{
		alias F = void function(ARGS) @safe nothrow;
		alias T = Tuple!ARGS;
		static assert(F.sizeof + T.sizeof <= ThreadCallbackGenParams.length,
			"Parameters take up too much space.");

		ThreadCallbackGenParams params;
		() @trusted { (cast(F[])params[0 .. F.sizeof])[0] = fun; } ();
		(cast(T[])params[F.sizeof .. F.sizeof + T.sizeof])[0] = T(args);
		runInOwnerThread((ref ThreadCallbackGenParams p) {
			auto f = () @trusted { return cast(F[])p[0 .. F.sizeof]; } ()[0];
			auto pt = () @trusted { return cast(T[])p[F.sizeof .. F.sizeof + T.sizeof]; } ();
			f(pt[0].expand);
		}, params);
	}

	/// Low-level user data access. Use `getUserData` instead.
	protected void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
	/// ditto
	protected void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;

	/** Deprecated - use `EventDriverSockets.userData` instead.
	*/
	deprecated("Use `EventDriverSockets.userData` instead.")
	@property final ref T userData(T, FD)(FD descriptor)
	@trusted nothrow {
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}
}


/** Provides access to socket functionality.

	The interface supports two classes of sockets - stream sockets and datagram
	sockets.
*/
interface EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	/** Connects to a stream listening socket.
	*/
	StreamSocketFD connectStream(scope Address peer_address, scope Address bind_address, ConnectCallback on_connect);

	/** Aborts asynchronous connect by closing the socket.

		This function may only invoked if the connection state is
		`ConnectionState.connecting`. It will cancel the connection attempt and
		guarantees that the connection callback will not be invoked in the
		future.

		Note that upon completion, the socket handle will be invalid, regardless
		of the number of calls to `addRef`, and must not be used for further
		operations.

		Params:
			sock = Handle of the socket that is currently establishing a
				connection
	*/
	void cancelConnectStream(StreamSocketFD sock);

	/** Adopts an existing stream socket.

		The given socket must be in a connected state. It will be automatically
		switched to non-blocking mode if necessary. Beware that this may have
		side effects in other code that uses the socket and assumes blocking
		operations.

		Params:
			socket = Socket file descriptor to adopt

		Returns:
			Returns a socket handle corresponding to the passed socket
				descriptor. If the same file descriptor is already registered,
				`StreamSocketFD.invalid` will be returned instead.
	*/
	StreamSocketFD adoptStream(int socket);

	/// Creates a socket listening for incoming stream connections.
	StreamListenSocketFD listenStream(scope Address bind_address, StreamListenOptions options, AcceptCallback on_accept);

	final StreamListenSocketFD listenStream(scope Address bind_address, AcceptCallback on_accept) {
		return listenStream(bind_address, StreamListenOptions.defaults, on_accept);
	}

	/// Starts to wait for incoming connections on a listening socket.
	void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept);

	/// Determines the current connection state.
	ConnectionState getConnectionState(StreamSocketFD sock);

	/** Retrieves the bind address of a socket.

		Example:
		The following code can be used to retrieve an IPv4/IPv6 address
		allocated on the stack. Note that Unix domain sockets require a larger
		buffer (e.g. `sockaddr_storage`).
		---
		scope storage = new UnknownAddress;
		scope sockaddr = new RefAddress(storage.name, storage.nameLen);
		eventDriver.sockets.getLocalAddress(sock, sockaddr);
		---
	*/
	bool getLocalAddress(SocketFD sock, scope RefAddress dst);

	/** Retrieves the address of the connected peer.

		Example:
		The following code can be used to retrieve an IPv4/IPv6 address
		allocated on the stack. Note that Unix domain sockets require a larger
		buffer (e.g. `sockaddr_storage`).
		---
		scope storage = new UnknownAddress;
		scope sockaddr = new RefAddress(storage.name, storage.nameLen);
		eventDriver.sockets.getLocalAddress(sock, sockaddr);
		---
	*/
	bool getRemoteAddress(SocketFD sock, scope RefAddress dst);

	/// Sets the `TCP_NODELAY` option on a socket
	void setTCPNoDelay(StreamSocketFD socket, bool enable);

	/// Sets to `SO_KEEPALIVE` socket option on a socket.
	void setKeepAlive(StreamSocketFD socket, bool enable);

	/** Enables keepalive for the TCP socket and sets additional parameters.
		Silently ignores unsupported systems (anything but Windows and Linux).

		Params:
			socket = Socket file descriptor to set options on.
			idle = The time the connection needs to remain idle
				before TCP starts sending keepalive probes.
			interval = The time between individual keepalive probes.
			probeCount = The maximum number of keepalive probes TCP should send
				before dropping the connection. Has no effect on Windows.
	*/
	void setKeepAliveParams(StreamSocketFD socket, Duration idle, Duration interval, int probeCount = 5);

	/// Sets `TCP_USER_TIMEOUT` socket option (linux only). https://tools.ietf.org/html/rfc5482
	void setUserTimeout(StreamSocketFD socket, Duration timeout);

	/** Reads data from a stream socket.

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.

		Waiting_for_data_availability:
			With the special combination of a zero-length buffer and `mode`
			set to either `IOMode.once` or `IOMode.all`, this function will
			wait until data is available on the socket without reading
			anything.

			Note that in this case the `IOStatus` parameter of the callback
			will not reliably reflect a passive connection close. It is
			necessary to actually read some data to make sure this case
			is detected.
	*/
	void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish);

	/** Cancels an ongoing read operation.

		After this function has been called, the `IOCallback` specified in
		the call to `read` is guaranteed to not be called.
	*/
	void cancelRead(StreamSocketFD socket);

	/** Reads data from a stream socket.

		Note that only a single write operation is allowed at once. The caller
		needs to make sure that either `on_write_finish` got called, or
		`cancelWrite` was called before issuing the next call to `write`.
	*/
	void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish);

	/** Cancels an ongoing write operation.

		After this function has been called, the `IOCallback` specified in
		the call to `write` is guaranteed to not be called.
	*/
	void cancelWrite(StreamSocketFD socket);

	/** Waits for incoming data without actually reading it.
	*/
	void waitForData(StreamSocketFD socket, IOCallback on_data_available);

	/** Initiates a connection close.
	*/
	void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write);

	/** Creates a connection-less datagram socket.

		Params:
			bind_address = The local bind address to use for the socket. It
				will be able to receive any messages sent to this address.
			target_address = Optional default target address. If this is
				specified and the target address parameter of `send` is
				left to `null`, it will be used instead.

		Returns:
			Returns a datagram socket handle if the socket was created
			successfully. Otherwise returns `DatagramSocketFD.invalid`.
	*/
	DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address);

	/** Adopts an existing datagram socket.

		The socket must be properly bound before this function is called.

		Params:
			socket = Socket file descriptor to adopt

		Returns:
			Returns a socket handle corresponding to the passed socket
				descriptor. If the same file descriptor is already registered,
				`DatagramSocketFD.invalid` will be returned instead.
	*/
	DatagramSocketFD adoptDatagramSocket(int socket);

	/** Sets an address to use as the default target address for sent datagrams.
	*/
	void setTargetAddress(DatagramSocketFD socket, scope Address target_address);

	/// Sets the `SO_BROADCAST` socket option.
	bool setBroadcast(DatagramSocketFD socket, bool enable);

	/// Joins the multicast group associated with the given IP address.
	bool joinMulticastGroup(DatagramSocketFD socket, scope Address multicast_address, uint interface_index = 0);

	/// Receives a single datagram.
	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish);
	/// Cancels an ongoing wait for an incoming datagram.
	void cancelReceive(DatagramSocketFD socket);
	/// Sends a single datagram.
	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish);
	/// Cancels an ongoing wait for an outgoing datagram.
	void cancelSend(DatagramSocketFD socket);

	/** Determines whether the given socket handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called and I/O operations will result in
		`IOStatus.invalidHandle`.

		A valid handle gets invalid when either the reference count drops to
		zero, or after the socket was explicitly closed.
	*/
	bool isValid(SocketFD handle) const @nogc;

	/** Increments the reference count of the given socket.
	*/
	void addRef(SocketFD descriptor);

	/** Decrements the reference count of the given socket.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(SocketFD descriptor);

	/** Enables or disables a socket option.
	*/
	bool setOption(DatagramSocketFD socket, DatagramSocketOption option, bool enable);
	/// ditto
	bool setOption(StreamSocketFD socket, StreamSocketOption option, bool enable);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T, FD)(FD descriptor) @trusted @nogc
		if (hasNoGCLifetime!T)
	{
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}
	/// ditto
	deprecated("Only @nogc constructible and destructible user data allowed.")
	@property final ref T userData(T, FD)(FD descriptor) @trusted
		if (!hasNoGCLifetime!T)
	{
		import std.conv : emplace;
		static void init(void* ptr) { emplace(cast(T*)ptr); }
		static void destr(void* ptr) { destroy(*cast(T*)ptr); }
		static if (__traits(compiles, () nothrow { init(null); destr(null); }))
			alias F = void function(void*) @nogc nothrow;
		else alias F = void function(void*) @nogc;
		return *cast(T*)rawUserData(descriptor, T.sizeof, cast(F)&init, cast(F)&destr);
	}

	/// Low-level user data access. Use `getUserData` instead.
	protected void* rawUserData(StreamSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system @nogc;
	/// ditto
	protected void* rawUserData(StreamListenSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system @nogc;
	/// ditto
	protected void* rawUserData(DatagramSocketFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system @nogc;
}

enum hasNoGCLifetime(T) = __traits(compiles, () @nogc @trusted { import std.conv : emplace; T b = void; emplace!T(&b); destroy(b); });
unittest {
	static struct S1 {}
	static struct S2 { ~this() { new int; } }
	static assert(hasNoGCLifetime!S1);
	static assert(!hasNoGCLifetime!S2);
}


/** Performs asynchronous DNS queries.
*/
interface EventDriverDNS {
@safe: /*@nogc:*/ nothrow:
	/// Looks up addresses corresponding to the given DNS name.
	DNSLookupID lookupHost(string name, DNSLookupCallback on_lookup_finished);

	/// Cancels an ongoing DNS lookup.
	void cancelLookup(DNSLookupID handle);

	/** Determines whether the given DNS lookup handle is valid.

		A valid handle gets invalid when the lookup has completed or got
		cancelled.
	*/
	bool isValid(DNSLookupID handle) const @nogc;
}


/** Provides read/write operations on the local file system.
*/
interface EventDriverFiles {
@safe: /*@nogc:*/ nothrow:
	FileFD open(string path, FileOpenMode mode);
	FileFD adopt(int system_file_handle);

	/** Disallows any reads/writes and removes any exclusive locks.

		Note that the file handle may become invalid at any point after the
		call to `close`, regardless of its current reference count. Any
		operations on the handle will not have an effect.
	*/
	void close(FileFD file, FileCloseCallback on_closed);

	ulong getSize(FileFD file);

	/** Shrinks or extends a file to the specified size.

		Params:
			file = Handle of the file to resize
			size = Desired file size in bytes
			on_finish = Called when the operation finishes - the `size`
				parameter is always set to zero
	*/
	void truncate(FileFD file, ulong size, FileIOCallback on_finish);

	/** Writes data to a file

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.
	*/
	void write(FileFD file, ulong offset, const(ubyte)[] buffer, IOMode mode, FileIOCallback on_write_finish);

	/** Cancels an ongoing write operation.

		After this function has been called, the `FileIOCallback` specified in
		the call to `write` is guaranteed not to be called.
	*/
	void cancelWrite(FileFD file);

	/** Reads data from a file.

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.
	*/
	void read(FileFD file, ulong offset, ubyte[] buffer, IOMode mode, FileIOCallback on_read_finish);

	/** Cancels an ongoing read operation.

		After this function has been called, the `FileIOCallback` specified in
		the call to `read` is guaranteed not to be called.
	*/
	void cancelRead(FileFD file);

	/** Determines whether the given file handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called and I/O operations will result in
		`IOStatus.invalidHandle`.

		A valid handle gets invalid when either the reference count drops to
		zero, or after the file was explicitly closed.
	*/
	bool isValid(FileFD handle) const @nogc;

	/** Increments the reference count of the given file.
	*/
	void addRef(FileFD descriptor);

	/** Decrements the reference count of the given file.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(FileFD descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(FileFD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(FileFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


/** Cross-thread notifications

	"Events" can be used to wake up the event loop of a foreign thread. This is
	the basis for all kinds of thread synchronization primitives, such as
	mutexes, condition variables, message queues etc. Such primitives, in case
	of extended wait periods, should use events rather than traditional means
	to block, such as busy loops or kernel based wait mechanisms to avoid
	stalling the event loop.
*/
interface EventDriverEvents {
@safe: /*@nogc:*/ nothrow:
	/// Creates a new cross-thread event.
	EventID create();

	/// Triggers an event owned by the current thread.
	void trigger(EventID event, bool notify_all);

	/// Triggers an event possibly owned by a different thread.
	void trigger(EventID event, bool notify_all) shared;

	/** Waits until an event gets triggered.

		Multiple concurrent waits are allowed.
	*/
	void wait(EventID event, EventCallback on_event);

	/// Cancels an ongoing wait operation.
	void cancelWait(EventID event, EventCallback on_event);

	/** Determines whether the given event handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called.

		A valid handle gets invalid when the reference count drops to zero.
	*/
	bool isValid(EventID handle) const @nogc;

	/** Increments the reference count of the given event.
	*/
	void addRef(EventID descriptor);

	/** Decrements the reference count of the given event.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(EventID descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(EventID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(EventID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}


/** Handling of POSIX signals.
*/
interface EventDriverSignals {
@safe: /*@nogc:*/ nothrow:
	/** Starts listening for the specified POSIX signal.

		Note that if a default signal handler exists for the signal, it will be
		disabled by using this function.

		Params:
			sig = The number of the signal to listen for
			on_signal = Callback that gets called whenever a matching signal
				gets received

		Returns:
			Returns an identifier that identifies the resource associated with
			the signal. Giving up ownership of this resource using `releaseRef`
			will re-enable the default signal handler, if any was present.

			For any error condition, `SignalListenID.invalid` will be returned
			instead.
	*/
	SignalListenID listen(int sig, SignalCallback on_signal);

	/** Determines whether the given signal handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called.

		A valid handle gets invalid when the reference count drops to zero.
	*/
	bool isValid(SignalListenID handle) const @nogc;

	/** Increments the reference count of the given resource.
	*/
	void addRef(SignalListenID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(SignalListenID descriptor);
}

interface EventDriverTimers {
@safe: /*@nogc:*/ nothrow:
	TimerID create();

	/** Run the timer.

		Params:
			timer = the id of the timer, created by `create` call.
			timeout = a duration to the first firing of the timer
			repeat = a duration between periodic timer firings - set to zero
				to set a single-fire timer
	*/
	void set(TimerID timer, Duration timeout, Duration repeat);

	void stop(TimerID timer);

	bool isPending(TimerID timer);
	bool isPeriodic(TimerID timer);

	/** Waits for the timer to fire.

		Important: the callback of the timer will be called exactly once, unless
		`cancelWait` gets called first. `wait` needs to be called again to
		receive future timer events (see https://github.com/vibe-d/eventcore/issues/172
		for reasons behind that behavior).

		Note that the `TimerCallback` based overload will not call the
		callback if `stop` gets called before the timer fires, whereas the
		`TimerCallback2` based overload will call the callback with the `fired`
		parameter set to `false`.
	*/
	final void wait(TimerID timer, TimerCallback callback) {
		wait(timer, (tm, fired) {
			if (fired) callback(tm);
		});
	}
	/// ditto
	void wait(TimerID timer, TimerCallback2 callback);
	void cancelWait(TimerID timer);

	/** Determines whether the given timer handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called.

		A valid handle gets invalid when the reference count drops to zero.
	*/
	bool isValid(TimerID handle) const @nogc;

	/** Increments the reference count of the given resource.
	*/
	void addRef(TimerID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(TimerID descriptor);

	/// Determines if the given timer's reference count equals one.
	bool isUnique(TimerID descriptor) const;

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(TimerID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(TimerID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}

interface EventDriverWatchers {
@safe: /*@nogc:*/ nothrow:
	/// Watches a directory or a directory sub tree for changes.
	WatcherID watchDirectory(string path, bool recursive, FileChangesCallback callback);

	/** Determines whether the given watcher handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called.

		A valid handle gets invalid when the reference count drops to zero.
	*/
	bool isValid(WatcherID handle) const @nogc;

	/** Increments the reference count of the given resource.
	*/
	void addRef(WatcherID descriptor);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(WatcherID descriptor);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(WatcherID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(WatcherID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}

interface EventDriverProcesses {
@safe: /*@nogc:*/ nothrow:
	/** Adopt an existing process.
	*/
	ProcessID adopt(int system_pid);

	/** Spawn a child process.

		Note that if a default signal handler exists for the signal, it will be
		disabled by using this function.

		Params:
			args = The program arguments. First one must be an executable.
			stdin = What should be done for stdin. Allows inheritance, piping,
				nothing or any specific fd. If this results in a Pipe,
				the PipeFD will be set in the stdin result.
			stdout = See stdin, but also allows redirecting to stderr.
			stderr = See stdin, but also allows redirecting to stdout.
			env = The environment variables to spawn the process with.
			config = Special process configurations.
			working_dir = What to set the working dir in the process.

		Returns:
			Returns a Process struct containing the ProcessID and whatever
			pipes have been adopted for stdin, stdout and stderr.
	*/
	Process spawn(string[] args, ProcessStdinFile stdin, ProcessStdoutFile stdout, ProcessStderrFile stderr, const string[string] env = null, ProcessConfig config = ProcessConfig.none, string working_dir = null);

	/** Returns whether the process has exited yet.
	*/
	bool hasExited(ProcessID pid);

	/** Kill the process using the given signal. Has different effects on different platforms.
	*/
	void kill(ProcessID pid, int signal);

	/** Wait for the process to exit.

		Returns an identifier that can be used to cancel the wait.
	*/
	size_t wait(ProcessID pid, ProcessWaitCallback on_process_exit);

	/** Cancel a wait for the given identifier returned by wait.
	*/
	void cancelWait(ProcessID pid, size_t waitId);

	/** Determines whether the given process handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called.

		A valid handle gets invalid when the reference count drops to zero.
	*/
	bool isValid(ProcessID handle) const @nogc;

	/** Increments the reference count of the given resource.
	*/
	void addRef(ProcessID pid);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated. This will not kill
		the sub-process, nor "detach" it.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(ProcessID pid);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(ProcessID descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(ProcessID descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;
}

interface EventDriverPipes {
@safe: /*@nogc:*/ nothrow:
	/** Adopt an existing pipe. This will modify the pipe to be non-blocking.

		Note that pipes generally only allow either reads or writes but not
		both, it is up to you to only call valid functions.
	*/
	PipeFD adopt(int system_pipe_handle);

	/** Reads data from a stream socket.

		Note that only a single read operation is allowed at once. The caller
		needs to make sure that either `on_read_finish` got called, or
		`cancelRead` was called before issuing the next call to `read`.
	*/
	void read(PipeFD pipe, ubyte[] buffer, IOMode mode, PipeIOCallback on_read_finish);

	/** Cancels an ongoing read operation.

		After this function has been called, the `PipeIOCallback` specified in
		the call to `read` is guaranteed to not be called.
	*/
	void cancelRead(PipeFD pipe);

	/** Writes data from a stream socket.

		Note that only a single write operation is allowed at once. The caller
		needs to make sure that either `on_write_finish` got called, or
		`cancelWrite` was called before issuing the next call to `write`.
	*/
	void write(PipeFD pipe, const(ubyte)[] buffer, IOMode mode, PipeIOCallback on_write_finish);

	/** Cancels an ongoing write operation.

		After this function has been called, the `PipeIOCallback` specified in
		the call to `write` is guaranteed to not be called.
	*/
	void cancelWrite(PipeFD pipe);

	/** Waits for incoming data without actually reading it.
	*/
	void waitForData(PipeFD pipe, PipeIOCallback on_data_available);

	/** Immediately close the pipe. Future read or write operations may fail.

		Note that the file handle may become invalid at any point after the
		call to `close`, regardless of its current reference count. Any
		operations on the handle will not have an effect.
	*/
	void close(PipeFD file, PipeCloseCallback on_closed);

	/** Determines whether the given pipe handle is valid.

		A handle that is invalid will result in no operations being carried out
		when used. In particular `addRef`/`releaseRef` will have no effect, but
		can safely be called and I/O operations will result in
		`IOStatus.invalidHandle`.

		A valid handle gets invalid when either the reference count drops to
		zero, or the pipe is explicitly closed.
	*/
	bool isValid(PipeFD handle) const @nogc;

	/** Increments the reference count of the given resource.
	*/
	void addRef(PipeFD pid);

	/** Decrements the reference count of the given resource.

		Once the reference count reaches zero, all associated resources will be
		freed and the resource descriptor gets invalidated.

		Returns:
			Returns `false` $(I iff) the last reference was removed by this call.

			Passing an invalid handle will result in a return value of `true`.
	*/
	bool releaseRef(PipeFD pid);

	/** Retrieves a reference to a user-defined value associated with a descriptor.
	*/
	@property final ref T userData(T)(PipeFD descriptor)
	@trusted {
		import std.conv : emplace;
		static void init(void* ptr) @nogc { emplace(cast(T*)ptr); }
		static void destr(void* ptr) @nogc { destroy(*cast(T*)ptr); }
		return *cast(T*)rawUserData(descriptor, T.sizeof, &init, &destr);
	}

	/// Low-level user data access. Use `userData` instead.
	protected void* rawUserData(PipeFD descriptor, size_t size, DataInitializer initialize, DataInitializer destroy) @system;

}

// Helper class to enable fully stack allocated `std.socket.Address` instances.
final class RefAddress : Address {
	version (Posix) import 	core.sys.posix.sys.socket : sockaddr, socklen_t;
	version (Windows) import core.sys.windows.winsock2 : sockaddr, socklen_t;

	private {
		sockaddr* m_addr;
		socklen_t m_addrLen;
	}

	this() @safe nothrow {}
	this(sockaddr* addr, socklen_t addr_len) @safe nothrow { set(addr, addr_len); }

	override @property sockaddr* name() scope { return m_addr; }
	override @property const(sockaddr)* name() const scope { return m_addr; }
	override @property socklen_t nameLen() const scope { return m_addrLen; }

	void set(sockaddr* addr, socklen_t addr_len) @safe nothrow { m_addr = addr; m_addrLen = addr_len; }

	void cap(socklen_t new_len)
	scope @safe nothrow {
		assert(new_len <= m_addrLen, "Cannot grow size of a RefAddress.");
		m_addrLen = new_len;
	}
}

@safe: /*@nogc:*/ nothrow:

alias ConnectCallback = void delegate(StreamSocketFD, ConnectStatus);
alias AcceptCallback = void delegate(StreamListenSocketFD, StreamSocketFD, scope RefAddress remote_address);
alias IOCallback = void delegate(StreamSocketFD, IOStatus, size_t);
alias DatagramIOCallback = void delegate(DatagramSocketFD, IOStatus, size_t, scope RefAddress);
alias DNSLookupCallback = void delegate(DNSLookupID, DNSStatus, scope RefAddress[]);
alias FileIOCallback = void delegate(FileFD, IOStatus, size_t);
alias FileCloseCallback = void delegate(FileFD, CloseStatus);
alias PipeIOCallback = void delegate(PipeFD, IOStatus, size_t);
alias PipeCloseCallback = void delegate(PipeFD, CloseStatus);
alias EventCallback = void delegate(EventID);
alias SignalCallback = void delegate(SignalListenID, SignalStatus, int);
alias TimerCallback = void delegate(TimerID);
alias TimerCallback2 = void delegate(TimerID, bool fired);
alias FileChangesCallback = void delegate(WatcherID, ref const FileChange change);

alias ProcessWaitCallback = void delegate(ProcessID, int);
@system alias DataInitializer = void function(void*) @nogc;

enum ProcessRedirect { inherit, pipe, none }
alias ProcessStdinFile = Algebraic!(int, ProcessRedirect);
enum ProcessStdoutRedirect { toStderr }
alias ProcessStdoutFile = Algebraic!(int, ProcessRedirect, ProcessStdoutRedirect);
enum ProcessStderrRedirect { toStdout }
alias ProcessStderrFile = Algebraic!(int, ProcessRedirect, ProcessStderrRedirect);

enum ExitReason {
	timeout,
	idle,
	outOfWaiters,
	exited
}

enum CloseStatus {
	ok,
	ioError,
	invalidHandle,
}

enum ConnectStatus {
	connected,
	refused,
	timeout,
	bindFailure,
	socketCreateFailure,
	unknownError
}

enum ConnectionState {
	initialized,
	connecting,
	connected,
	passiveClose,
	activeClose,
	closed
}

enum StreamListenOptions {
	none = 0,
	/// Applies the `SO_REUSEPORT` flag
	reusePort = 1<<0,
	/// Avoids applying the `SO_REUSEADDR` flag
	reuseAddress = 1<<1,
	///
	defaults = reuseAddress,
}

enum StreamSocketOption {
	noDelay,
	keepAlive
}

enum DatagramSocketOption {
	broadcast,
	multicastLoopback
}

/**
	Specifies how a file is manipulated on disk.
*/
enum FileOpenMode {
	/// The file is opened read-only.
	read,
	/// The file is opened for read-write random access.
	readWrite,
	/// The file is truncated if it exists or created otherwise and then opened for read-write access.
	createTrunc,
	/// The file is opened for appending data to it and created if it does not exist.
	append
}

enum IOMode {
	immediate, /// Process only as much as possible without waiting
	once,      /// Process as much as possible with a single call
	all        /// Process the full buffer
}

enum IOStatus {
	ok,           /// The data has been transferred normally
	disconnected, /// The connection was closed before all data could be transterred
	error,        /// An error occured while transferring the data
	wouldBlock,    /// Returned for `IOMode.immediate` when no data is readily readable/writable
	invalidHandle, /// The passed handle is not valid
}

enum DNSStatus {
	ok,
	error
}

/** Specifies the kind of change in a watched directory.
*/
enum FileChangeKind {
	/// A file or directory was added
	added,
	/// A file or directory was deleted
	removed,
	/// A file or directory was modified
	modified
}

enum SignalStatus {
	ok,
	error
}

/// See std.process.Config
enum ProcessConfig {
	none = StdProcessConfig.none,
	detached = StdProcessConfig.detached,
	newEnv = StdProcessConfig.newEnv,
	suppressConsole = StdProcessConfig.suppressConsole,
}

/** Describes a single change in a watched directory.
*/
struct FileChange {
	/// The type of change
	FileChangeKind kind;

	/// The root directory of the watcher
	string baseDirectory;

	/// Subdirectory containing the changed file
	string directory;

	/// Name of the changed file
	const(char)[] name;
}

/** Describes a spawned process
*/
struct Process {
	ProcessID pid;

	// TODO: Convert these to PipeFD once dmd is fixed
	PipeFD stdin;
	PipeFD stdout;
	PipeFD stderr;
}

mixin template Handle(string NAME, T, T invalid_value = T.init) {
	alias name = NAME;

	enum invalid = typeof(this).init;

	nothrow @nogc @safe:

	T value = invalid_value;

	static if (is(T.BaseType)) {
		alias BaseType = T.BaseType;

		this(BaseType value, uint validation_counter)
		{
			this.value = T(value, validation_counter);
		}
	} else {
		alias BaseType = T;

		uint validationCounter;

		this(BaseType value, uint validation_counter)
		{
			this.value = value;
			this.validationCounter = validation_counter;
		}
	}

	U opCast(U)() const
		if (is(U.BaseType) && is(typeof(U.value)))
	{
		// TODO: verify that U derives from typeof(this)!
		return U(cast(U.BaseType)value, validationCounter);
	}

	U opCast(U)() const
		if (is(typeof(U(BaseType.init))))
	{
		return cast(U)value;
	}

	alias value this;
}

alias ThreadCallbackGenParams = ubyte[8 * intptr_t.sizeof];
alias ThreadCallbackGen = void function(ref ThreadCallbackGenParams param3) @safe nothrow;
deprecated alias ThreadCallback = void function(intptr_t param1) @safe nothrow;

struct FD { mixin Handle!("fd", size_t, size_t.max); }
struct SocketFD { mixin Handle!("socket", FD); }
struct StreamSocketFD { mixin Handle!("streamSocket", SocketFD); }
struct StreamListenSocketFD { mixin Handle!("streamListen", SocketFD); }
struct DatagramSocketFD { mixin Handle!("datagramSocket", SocketFD); }
struct FileFD { mixin Handle!("file", FD); }
// FD.init is required here due to https://issues.dlang.org/show_bug.cgi?id=19585
struct PipeFD { mixin Handle!("pipe", FD, FD.init); }
struct EventID { mixin Handle!("event", FD); }
struct TimerID { mixin Handle!("timer", size_t, size_t.max); }
struct WatcherID { mixin Handle!("watcher", size_t, size_t.max); }
struct EventWaitID { mixin Handle!("eventWait", size_t, size_t.max); }
struct SignalListenID { mixin Handle!("signal", size_t, size_t.max); }
struct DNSLookupID { mixin Handle!("dns", size_t, size_t.max); }
struct ProcessID { mixin Handle!("process", size_t, size_t.max); }
