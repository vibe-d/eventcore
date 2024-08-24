EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).

The API documentation is part of vibe.d:
- [`EventDriver`](https://vibed.org/api/eventcore.driver/EventDriver)
- [`eventDriver`](https://vibed.org/api/eventcore.core/eventDriver)
- [Experimental `eventcore.socket`](https://vibed.org/api/eventcore.socket/)

[![DUB Package](https://img.shields.io/dub/v/eventcore.svg)](https://code.dlang.org/packages/eventcore)
[![Posix and Windows Build Status](https://github.com/vibe-d/eventcore/actions/workflows/ci.yml/badge.svg)](https://github.com/vibe-d/eventcore/actions/workflows/ci.yml)

Supported drivers and operating systems
---------------------------------------

Driver               | Linux   | Windows | macOS   | FreeBSD | Android | iOS
---------------------|---------|---------|---------|---------|---------|---------
SelectEventDriver    | yes     | yes     | yes     | yes¹    | yes     | yes
EpollEventDriver     | yes     | &mdash; | &mdash; | &mdash; | yes     | &mdash;
WinAPIEventDriver    | &mdash; | yes     | &mdash; | &mdash; | &mdash; | &mdash;
KqueueEventDriver    | &mdash; | &mdash; | yes     | yes¹    | &mdash; | yes
CFRunloopEventDriver | &mdash; | &mdash; | yes     | &mdash; | &mdash; | yes
LibasyncEventDriver  | &mdash;¹| &mdash;¹| &mdash;¹| &mdash;¹| &mdash; | &mdash;
UringEventDriver     | &mdash;¹| no      | no      | no      | unknown | no

¹ planned, but not currenly implemented


Supported compilers
-------------------

The following compilers are tested and supported:

- DMD 2.103.0
- DMD 2.086.1
- LDC 1.32.0
- LDC 1.16.0


Driver development status
-------------------------

Feature \ EventDriver | Select | Epoll | WinAPI  | Kqueue  | CFRunloop | Libasync | Uring
----------------------|--------|-------|---------|---------|-----------|----------|-------
TCP Sockets           | yes    | yes   | yes     | yes     | yes       | &mdash;  | &mdash;
UDP Sockets           | yes    | yes   | yes     | yes     | yes       | &mdash;  | &mdash;
USDS                  | yes    | yes   | &mdash; | yes     | yes       | &mdash;  | &mdash;
DNS                   | yes    | yes   | yes     | yes     | yes       | &mdash;  | &mdash;
Timers                | yes    | yes   | yes     | yes     | yes       | &mdash;  | &mdash;
Events                | yes    | yes   | yes     | yes     | yes       | &mdash;  | &mdash;
Unix Signals          | yes²   | yes   | &mdash; | &mdash; | &mdash;   | &mdash;  | &mdash;
Files                 | yes    | yes   | yes     | yes     | yes       | &mdash;  | yes
UI Integration        | yes¹   | yes¹  | yes     | yes¹    | yes¹      | &mdash;  | yes?
File watcher          | yes²   | yes   | yes     | yes²    | yes²      | &mdash;  | &mdash;
Pipes                 | yes    | yes   | &mdash; | yes     | yes       | &mdash;  | &mdash;
Processes             | yes    | yes   | &mdash; | yes     | yes       | &mdash;  | &mdash;

¹ Manually, by adopting the X11 display connection socket

² Systems other than Linux use a polling implementation


Compile-time configuration
--------------------------

### Configurations

The DUB configuration meachnism can be used to force choosing a particular
event driver implementation. The following configurations are available:

`EventcoreCFRunLoopDriver`: Forces using the CFRunLoop driver (for DUB, use the "cfrunloop" configuration instead)
`EventcoreKqueueDriver`: Forces using the kqueue driver (for DUB, use the "kqueue" configuration instead)
`EventcoreWinAPIDriver`: Forces using the WinAPI driver (for DUB, use the "winapi" configuration instead)
`EventcoreLibasyncDriver`: Forces using the libasync driver (for DUB, use the "libasync" configuration instead)
`EventcoreSelectDriver`: Forces using the select driver (for DUB, use the "select" configuration instead)
`EventcoreUseGAIA`: Forces using getaddressinfo_a for the epoll driver (for DUB, use the "epoll-gaia" configuration instead)


### Version identifiers

Several version identifiers can be set to configure the behavior of the library
at compile time. Simply insert any of the following identifiers as a "version"
to the compiler command line or into your DUB recipe:

dub.sdl:
```SDL
versions "EventCoreSilenceLeakWarnings"
```

dub.json:
```JSON
{
	...
	"versions": ["EventCoreSilenceLeakWarnings"]
	...
}
```

- `EventCoreSilenceLeakWarnings`: Disables checking for leaked handles at shutdown
- `EventcoreCFRunLoopDriver`: Forces using the CFRunLoop driver (for DUB, use the "cfrunloop" configuration instead)
- `EventcoreKqueueDriver`: Forces using the kqueue driver (for DUB, use the "kqueue" configuration instead)
- `EventcoreWinAPIDriver`: Forces using the WinAPI driver (for DUB, use the "winapi" configuration instead)
- `EventcoreLibasyncDriver`: Forces using the libasync driver (for DUB, use the "libasync" configuration instead)
- `EventcoreSelectDriver`: Forces using the select driver (for DUB, use the "select" configuration instead)
- `EventcoreUseGAIA`: Forces using getaddressinfo_a for the epoll driver (for DUB, use the "epoll-gaia" configuration instead)


### Debug identifiers

For additional debug output, the following debug identifiers are available. When
building with DUB, you can specify them similar to version identifiers, but using
the `debugVersions` directive instead:

- `EventCoreLogDNS`: Prints detailed information about DNS lookups
- `EventCoreLeakTrace`: Gathers stack traces when allocating handles to assist in fixing leaked handles
- `EventCoreEpollDebug`: Outputs epoll event details
- `EventCoreLogFiles`: Outputs detailed logging for file operations carried out through the `threadedfile` implementation


Open questions
--------------

- Error code reporting
- Enqueued writes
- Use the type system to prohibit passing thread-local handles to foreign threads
