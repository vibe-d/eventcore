EventCore
=========

This is a high-performance native event loop abstraction for D, focused on asynchronous I/O and GUI message integration. The API is callback (delegate) based. For a higher level fiber based abstraction, take a look at [vibe.d](https://vibed.org/).

The API documentation is part of vibe.d:
- [`EventDriver`](https://vibed.org/api/eventcore.driver/EventDriver)
- [`eventDriver`](https://vibed.org/api/eventcore.core/eventDriver)
- [Experimental `eventcore.socket`](https://vibed.org/api/eventcore.socket/)

[![DUB Package](https://img.shields.io/dub/v/eventcore.svg)](https://code.dlang.org/packages/eventcore)
[![Posix Build Status](https://api.travis-ci.com/vibe-d/eventcore.svg?branch=master)](https://travis-ci.com/github/vibe-d/eventcore)
[![Windows Build Status](https://ci.appveyor.com/api/projects/status/1a9r8sypyy9fq2j8/branch/master?svg=true)](https://ci.appveyor.com/project/s-ludwig/eventcore)


Supported drivers and operating systems
---------------------------------------

Driver               | Linux   | Windows | macOS   | FreeBSD | Android | iOS
---------------------|---------|---------|---------|---------|---------|---------
SelectEventDriver    | yes     | yes     | yes     | yes¹    | yes     | &mdash;
EpollEventDriver     | yes     | &mdash; | &mdash; | &mdash; | yes     | &mdash;
WinAPIEventDriver    | &mdash; | yes     | &mdash; | &mdash; | &mdash; | &mdash;
KqueueEventDriver    | &mdash; | &mdash; | yes     | yes¹    | &mdash; | &mdash;
LibasyncEventDriver  | &mdash;¹| &mdash;¹| &mdash;¹| &mdash;¹| &mdash; | &mdash;

¹ planned, but not currenly implemented


Supported compilers
-------------------

The following compilers are tested and supported:

- DMD 2.087.1
- DMD 2.086.1
- DMD 2.085.1
- DMD 2.084.1
- DMD 2.079.0
- LDC 1.17.0
- LDC 1.16.0
- LDC 1.15.0
- LDC 1.14.0
- LDC 1.13.0
- LDC 1.9.0


Driver development status
-------------------------

Feature \ EventDriver | Select | Epoll | WinAPI  | Kqueue  | Libasync
----------------------|--------|-------|---------|---------|----------
TCP Sockets           | yes    | yes   | yes     | yes     | &mdash;
UDP Sockets           | yes    | yes   | yes     | yes     | &mdash;
USDS                  | yes    | yes   | &mdash; | yes     | &mdash;
DNS                   | yes    | yes   | yes     | yes     | &mdash;
Timers                | yes    | yes   | yes     | yes     | &mdash;
Events                | yes    | yes   | yes     | yes     | &mdash;
Unix Signals          | yes²   | yes   | &mdash; | &mdash; | &mdash;
Files                 | yes    | yes   | yes     | yes     | &mdash;
UI Integration        | yes¹   | yes¹  | yes     | yes¹    | &mdash;
File watcher          | yes²   | yes   | yes     | yes²    | &mdash;
Pipes                 | yes    | yes   | &mdash; | yes     | &mdash;
Processes             | yes    | yes   | &mdash; | yes     | &mdash;

¹ Manually, by adopting the X11 display connection socket

² Systems other than Linux use a polling implementation


### Open questions

- Error code reporting
- Enqueued writes
- Use the type system to prohibit passing thread-local handles to foreign threads
