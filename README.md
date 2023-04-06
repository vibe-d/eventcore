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

Feature \ EventDriver | Select | Epoll | WinAPI  | Kqueue  | CFRunloop | Libasync
----------------------|--------|-------|---------|---------|-----------|----------
TCP Sockets           | yes    | yes   | yes     | yes     | yes       | &mdash;
UDP Sockets           | yes    | yes   | yes     | yes     | yes       | &mdash;
USDS                  | yes    | yes   | &mdash; | yes     | yes       | &mdash;
DNS                   | yes    | yes   | yes     | yes     | yes       | &mdash;
Timers                | yes    | yes   | yes     | yes     | yes       | &mdash;
Events                | yes    | yes   | yes     | yes     | yes       | &mdash;
Unix Signals          | yes²   | yes   | &mdash; | &mdash; | &mdash;   | &mdash;
Files                 | yes    | yes   | yes     | yes     | yes       | &mdash;
UI Integration        | yes¹   | yes¹  | yes     | yes¹    | yes¹      | &mdash;
File watcher          | yes²   | yes   | yes     | yes²    | yes²      | &mdash;
Pipes                 | yes    | yes   | &mdash; | yes     | yes       | &mdash;
Processes             | yes    | yes   | &mdash; | yes     | yes       | &mdash;

¹ Manually, by adopting the X11 display connection socket

² Systems other than Linux use a polling implementation


### Open questions

- Error code reporting
- Enqueued writes
- Use the type system to prohibit passing thread-local handles to foreign threads
